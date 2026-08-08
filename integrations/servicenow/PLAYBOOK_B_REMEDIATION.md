# Playbook B: `ALERT Approved Issue Remediation`

Content of the Devin playbook used by the **ALERT Approved Remediation** automation.
Create it in **Devin Settings → Playbooks → New playbook** with the title
`ALERT Approved Issue Remediation`.

This session only ever starts from `u_alert_stage = development`, which is reached
by a product-owner approval. The diagnosis has already been accepted; this session
implements it and hands the change to the tech lead.

---

## Playbook Content

```markdown
# ALERT Approved Issue Remediation

A product owner has approved a triaged issue for remediation. Implement the fix,
open a pull request, and hand it to the tech lead. You do not re-open the question
of whether the issue is valid.

## Step 1: Read the approved assignment

From the webhook payload:
- `incident.sys_id`, `incident.number`
- `incident.u_alert_stage` — must be `development`; stop if it is not
- `incident.u_affected_service` — the service to change
- `incident.u_devin_findings` — the ACCEPTED diagnosis. Treat it as the spec.
- `incident.u_repro_steps` — use these to verify your fix
- `incident.comments` — any owner conditions attached to the approval

If the findings turn out to be wrong, do not silently redesign the fix. Post a work
note explaining the conflict, set `u_alert_stage` back to `triage`, and stop.

## Step 2: Implement the fix

1. Branch: `devin/<INC number>-<short-slug>`.
2. Change the minimum needed in `services/<service>` (or `frontend/<app>`), following
   the conventions already in that service. No drive-by refactors.
3. Add or extend a test that fails before the fix and passes after it, derived from
   `u_repro_steps`.
4. Run that service's lint/test commands — the exact commands per service are in
   `harness/apps.yaml` (`build_command`, `test_command`, `static_analysis_command`),
   which is what the Harness pipeline will run.

## Step 3: Open the pull request

- Title: `fix(<service>): <one-line summary> [<INC number>]`
  The `INC` token is required: the Harness pipeline resolves which incident to
  update from the first `INC<digits>` token in the PR title and, on merge-triggered
  runs, in the merge commit message. Without it the deploy will not update the ticket.
- Body: follow `.github/pull_request_template.md` — incident number, root cause,
  what changed, verification performed, and how to roll back.
- Request review from the code owner of the changed path (`.github/CODEOWNERS`).
  Do not approve your own PR and do not merge it. The tech-lead approval and merge
  are what start the Harness deployment.

## Step 4: Hand off in ServiceNow

    curl -s -X PATCH "${SERVICENOW_INSTANCE_URL}/api/now/table/incident/<sys_id>" \
      -u "${SERVICENOW_USERNAME}:${SERVICENOW_PASSWORD}" \
      -H "Content-Type: application/json" -H "Accept: application/json" \
      -d '{
            "u_alert_stage": "tech_lead_review",
            "u_pr_url": "<pr url>",
            "u_devin_session_url": "<session url>",
            "work_notes": "[Devin remediation] PR ready for tech-lead review: <pr url>\nTests: <what you ran>\nSession: <session url>"
          }'

## Step 5: Respond to review

While the incident is in `tech_lead_review`:
- Address review comments with follow-up commits on the same branch; leave the
  stage as `tech_lead_review`.
- Fix failing required checks the same way.
- If a reviewer asks for a materially different approach, say so in a work note
  before rewriting, so the owner sees the scope change.

## Step 6: If a deploy fails

A failed Harness deploy sets the stage back to `development` with the failure
summary in the work notes, which restarts this playbook. On such a re-entry:
- Read the newest work notes for the Harness failure output first.
- Fix forward on the same branch if the cause is in the change; if the cause is
  environmental or unclear, post the evidence, request an automation hold
  (`u_automation_hold = true`), and stop rather than retrying blindly.

## Hard limits

- Never merge your own PR, never approve it, never bypass a required check, never
  push to the deploy branch directly.
- Never trigger a Harness pipeline manually to work around a gate.
- No production access. Dev environment only.
- Never write secrets or personal data into the ticket, PR, or code.
- Stay inside the approved service. Changing a second service or the delivery
  configuration (`harness/`, `infrastructure/`, `.github/`) needs a new approval —
  post a work note and stop.
```
