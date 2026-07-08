# ServiceNow → Devin Automations Webhook Integration

Connects ServiceNow incident management to Devin AI for automated bug remediation using **Devin Automations webhooks** — no custom middleware (Lambda, Flask, or Rails session-creation code) required.

## Architecture

```
┌─────────────┐  Business Rule   ┌─────────────────────────┐  auto-start   ┌────────────────┐
│  ServiceNow │ ─── webhook ───▶ │  Devin Automations      │ ───────────▶ │  Devin Session │
│  Incident   │                  │  (managed by Devin)     │              │  (+ playbook)  │
│             │ ◀── work note ─  │  payload → prompt ctx   │              │                │
└─────────────┘  (from session)  └─────────────────────────┘              └────────────────┘
```

**Flow:**
1. User creates a Software/Critical incident in ServiceNow
2. Business Rule fires → POSTs incident JSON directly to the Devin Automation webhook URL
3. Devin Automations starts a session with the ServiceNow payload as context
4. The session follows the `ServiceNow Incident Auto-Remediation` playbook
5. Devin investigates the bug, opens a PR, and posts a work note back to ServiceNow

### What changed from the previous (direct API) approach

| Before (Direct Devin API) | After (Automations Webhook) |
|---|---|
| ServiceNow → Lambda/Flask → `POST /v3/.../sessions` | ServiceNow → Devin Automation webhook (direct) |
| Custom Lambda + API Gateway + CloudFormation | Zero infra — Devin-managed webhook endpoint |
| `DEVIN_API_KEY` / `DEVIN_ORG_ID` in middleware | No API keys needed in your code |
| Custom prompt-building code (Python + Ruby) | Prompt template in Devin Automation UI + playbook |
| Sidekiq poller every 60s for session status | Playbook-driven callbacks from within the session |
| ~800 lines of webhook/session code | Automation config + playbook |

## Setup

### 1. Create the Devin Playbook

The playbook `ServiceNow Incident Auto-Remediation (Webhook)` should already exist in **Devin Settings → Playbooks**. If not, create it following the template in [PLAYBOOK.md](./PLAYBOOK.md).

### 2. Create the Devin Automation

See [AUTOMATION_SETUP.md](./AUTOMATION_SETUP.md) for step-by-step instructions to create the webhook automation in the Devin UI.

### 3. Configure ServiceNow

See [SERVICENOW_SETUP.md](./SERVICENOW_SETUP.md) for configuring the Business Rule and Outbound REST Message.

**Key change:** The REST Message endpoint is now the Devin Automation webhook URL (from step 2) instead of a Lambda/API Gateway URL.

### 4. Test

```bash
# Simulate a ServiceNow webhook hitting the Devin Automation:
python3 test_webhook_e2e.py
```

Or create an incident in ServiceNow with Category=Software and Priority=1-Critical.

## Files

| File | Purpose |
|------|---------|
| `AUTOMATION_SETUP.md` | Step-by-step Devin Automation creation guide |
| `SERVICENOW_SETUP.md` | ServiceNow configuration (Business Rule + REST Message) |
| `PLAYBOOK.md` | Devin playbook content for the remediation session |
| `test_webhook_e2e.py` | E2E test: creates a SNOW incident → verifies work note callback |
| `test_lambda_local.py` | Legacy tests for the old Lambda handler (archived) |

## Legacy Files (Archived)

The following files are from the previous direct-API approach and are no longer needed for the Automations webhook flow. They are kept for reference:

| File | Status |
|------|--------|
| `lambda_handler.py` | **Archived** — replaced by Devin Automation webhook |
| `webhook_receiver.py` | **Archived** — replaced by Devin Automation webhook |
| `template.yaml` | **Archived** — CloudFormation stack no longer needed |
| `deploy.sh` | **Archived** — no deployment needed |
| `Dockerfile` | **Archived** — no container needed |
| `requirements.txt` | Used by `test_webhook_e2e.py` |

### Teardown (old Lambda stack)

If the old Lambda stack is still deployed:

```bash
aws cloudformation delete-stack --stack-name otterworks-servicenow-webhook --region us-east-1
```
