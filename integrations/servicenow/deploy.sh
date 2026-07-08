#!/usr/bin/env bash
set -euo pipefail
#
# Deploy the ServiceNow → Devin webhook receiver to AWS Lambda + API Gateway.
#
# Usage:
#   ./deploy.sh                          # Interactive — prompts for missing params
#   ./deploy.sh --devin-api-key KEY \    # Non-interactive
#               --devin-org-id ORG \
#               --snow-secret SECRET
#
# Prerequisites:
#   - AWS CLI configured with credentials (aws sts get-caller-identity)
#   - zip utility
#
# Environment variable overrides (fallback if flags not provided):
#   DEVIN_API_KEY, DEVIN_ORG_ID, SERVICENOW_WEBHOOK_SECRET,
#   SERVICENOW_INSTANCE_URL, SERVICENOW_CLIENT_ID, SERVICENOW_CLIENT_SECRET
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_NAME="${STACK_NAME:-otterworks-servicenow-webhook}"
REGION="${AWS_REGION:-us-east-1}"

# ---- Parse flags ----
DEVIN_API_KEY="${DEVIN_API_KEY:-}"
DEVIN_ORG_ID="${DEVIN_ORG_ID:-}"
SNOW_SECRET="${SERVICENOW_WEBHOOK_SECRET:-}"
SNOW_INSTANCE="${SERVICENOW_INSTANCE_URL:-}"
SNOW_CLIENT_ID="${SERVICENOW_CLIENT_ID:-}"
SNOW_CLIENT_SECRET="${SERVICENOW_CLIENT_SECRET:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --devin-api-key)  DEVIN_API_KEY="$2"; shift 2 ;;
    --devin-org-id)   DEVIN_ORG_ID="$2"; shift 2 ;;
    --snow-secret)    SNOW_SECRET="$2"; shift 2 ;;
    --snow-instance)      SNOW_INSTANCE="$2"; shift 2 ;;
    --snow-client-id)     SNOW_CLIENT_ID="$2"; shift 2 ;;
    --snow-client-secret) SNOW_CLIENT_SECRET="$2"; shift 2 ;;
    --stack-name)     STACK_NAME="$2"; shift 2 ;;
    --region)         REGION="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---- Prompt for required values if missing ----
if [[ -z "$DEVIN_API_KEY" ]]; then
  read -rsp "Devin API Key: " DEVIN_API_KEY; echo
fi
if [[ -z "$DEVIN_ORG_ID" ]]; then
  read -rp "Devin Org ID: " DEVIN_ORG_ID
fi
if [[ -z "$SNOW_SECRET" ]]; then
  read -rsp "ServiceNow Webhook Secret (shared with REST Message header): " SNOW_SECRET; echo
fi

echo ""
echo "=== OtterWorks ServiceNow Webhook Deploy ==="
echo "Stack:  $STACK_NAME"
echo "Region: $REGION"
echo ""

# ---- Package Lambda code ----
echo "[1/3] Packaging Lambda function..."
TMPDIR=$(mktemp -d)
cp "$SCRIPT_DIR/lambda_handler.py" "$TMPDIR/"
pushd "$TMPDIR" > /dev/null
zip -q lambda.zip lambda_handler.py
popd > /dev/null
LAMBDA_ZIP="$TMPDIR/lambda.zip"
echo "       → $LAMBDA_ZIP"

# ---- Deploy CloudFormation stack ----
echo "[2/3] Deploying CloudFormation stack..."
aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/template.yaml" \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    "DevinApiKey=$DEVIN_API_KEY" \
    "DevinOrgId=$DEVIN_ORG_ID" \
    "ServiceNowWebhookSecret=$SNOW_SECRET" \
    "ServiceNowInstanceUrl=$SNOW_INSTANCE" \
    "ServiceNowClientId=$SNOW_CLIENT_ID" \
    "ServiceNowClientSecret=$SNOW_CLIENT_SECRET" \
  --no-fail-on-empty-changeset

# ---- Update Lambda code (CloudFormation uses inline placeholder) ----
echo "[3/3] Updating Lambda function code..."
FUNCTION_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`LambdaFunctionName`].OutputValue' \
  --output text)

aws lambda update-function-code \
  --function-name "$FUNCTION_NAME" \
  --zip-file "fileb://$LAMBDA_ZIP" \
  --region "$REGION" \
  --no-cli-pager

# Wait for update to complete
aws lambda wait function-updated \
  --function-name "$FUNCTION_NAME" \
  --region "$REGION"

# ---- Print outputs ----
echo ""
echo "=== Deployment Complete ==="
echo ""
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[*].[Description,OutputValue]' \
  --output table

WEBHOOK_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`WebhookEndpoint`].OutputValue' \
  --output text)

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  SERVICENOW REST MESSAGE ENDPOINT:                             ║"
echo "║  $WEBHOOK_URL"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Paste the above URL into your ServiceNow Outbound REST Message endpoint."
echo ""

# ---- Health check ----
HEALTH_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`HealthEndpoint`].OutputValue' \
  --output text)

echo "Running health check..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
  echo "✓ Health check passed (HTTP $HTTP_CODE)"
else
  echo "⚠ Health check returned HTTP $HTTP_CODE — the function may need a moment to warm up"
fi

# ---- Cleanup ----
rm -rf "$TMPDIR"
echo ""
echo "Done."
