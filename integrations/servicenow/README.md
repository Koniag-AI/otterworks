# ServiceNow → Devin → Harness: the ALERT workflow

Connects ServiceNow incident management to Devin and Harness using **Devin Automations
webhooks** — no custom middleware (Lambda, Flask, or Rails session-creation code)
required.

## Flow

```
 end user            Devin triage         requester        product owner
 files incident  →   valid? enrich   →   answers      →   approves
                     or ask                questions        or rejects
                          │                                     │
                          └──────── awaiting_info ───────────────┘
                                                                 ↓
 Harness deploy   ←   tech lead      ←   Devin remediation  ←  development
 (on merge)           approves+merges     opens PR
       ↓
  verified → closed        (deploy failure → back to development)
```

Every arrow is a `u_alert_stage` change on the incident; ServiceNow remains the system
of record and each Devin session is started by a stage change rather than an ad-hoc call.
The two Devin sessions are deliberately separate: **triage never writes code**, and
**remediation only runs after a product owner has approved the issue**.

The design rationale, gate ownership, and rollout sequencing live in
`ALERT_TICKET_WORKFLOW_DESIGN.md` in the `kgs-alert` repository.

### What changed from the previous (single-session) approach

| Before | After |
|---|---|
| One session: investigate + fix + PR, on incident insert | Two stage-triggered sessions: triage, then remediation after approval |
| No validity judgement | `u_devin_verdict` + `u_devin_confidence`, with low confidence routed to a human |
| No way to ask the requester anything | `awaiting_info` stage posts questions as a customer-visible comment and resumes on the answer |
| No approval before code was written | Product-owner approval gates the development stage |
| PR merge enforced by nothing | `CODEOWNERS` + branch protection; Devin cannot approve or merge its own PR |
| Merge did not start a pipeline | Per-application Harness push triggers (`harness/generated/triggers/`) |

### What changed from the original (direct API) approach

| Before (Direct Devin API) | After (Automations Webhook) |
|---|---|
| ServiceNow → Lambda/Flask → `POST /v3/.../sessions` | ServiceNow → Devin Automation webhook (direct) |
| Custom Lambda + API Gateway + CloudFormation | Zero infra — Devin-managed webhook endpoint |
| `DEVIN_API_KEY` / `DEVIN_ORG_ID` in middleware | No API keys needed in your code |
| Custom prompt-building code (Python + Ruby) | Prompt template in Devin Automation UI + playbook |
| Sidekiq poller every 60s for session status | Playbook-driven callbacks from within the session |
| ~800 lines of webhook/session code | Automation config + playbook |

## Setup

Follow these in order — each step is inert until the next one enables it.

1. **ServiceNow configuration:** [alert-workflow/README.md](./alert-workflow/README.md) —
   install script, owner mapping table, form layout, and the staged activation order.
2. **Devin playbooks and automations:** [AUTOMATION_SETUP.md](./AUTOMATION_SETUP.md).
3. **GitHub gate:** `.github/CODEOWNERS` plus branch protection on the deploy branch
   (required code-owner review, no self-approval).
4. **Harness deploy on merge:** set `merge_trigger_enabled: true` for one application in
   `harness/apps.yaml`, then
   `python3 harness/sync_harness.py --apply --apply-triggers --only <app>`.

### Test

```bash
# Simulate a ServiceNow webhook hitting a Devin Automation:
python3 test_webhook_e2e.py
```

Or create a pilot incident in ServiceNow (Category=Software, ALERT pilot checked).

## Files

| File | Purpose |
|------|---------|
| `alert-workflow/` | ServiceNow install/verify/uninstall scripts and the configuration guide |
| `AUTOMATION_SETUP.md` | The two Devin automations (triage, remediation) |
| `PLAYBOOK_A_TRIAGE.md` | Triage playbook: validity, enrichment, questions. Writes no code |
| `PLAYBOOK_B_REMEDIATION.md` | Remediation playbook: implement approved fix, open PR |
| `SERVICENOW_SETUP.md` | Superseded — the single-rule setup of the previous flow |
| `PLAYBOOK.md` | Superseded — the single-session playbook of the previous flow |
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
