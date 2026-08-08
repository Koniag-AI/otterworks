# Devin Automation Setup — ALERT workflow

The ALERT workflow uses **two** Devin automations, one per stage, each with its own
playbook. Splitting them is what keeps investigation separate from development: the
triage automation can only look, and the remediation automation only ever runs after
a product owner has approved the issue.

| Automation | Fires when | Playbook | Writes code? |
|---|---|---|---|
| `ALERT Incident Triage` | incident enters stage `triage` (new incident, or requester answered) | [PLAYBOOK_A_TRIAGE.md](./PLAYBOOK_A_TRIAGE.md) | no |
| `ALERT Approved Remediation` | incident enters stage `development` (owner approved) | [PLAYBOOK_B_REMEDIATION.md](./PLAYBOOK_B_REMEDIATION.md) | yes |

Both are triggered by the ServiceNow business rules installed by
[alert-workflow/README.md](./alert-workflow/README.md), which POST the incident JSON
(including `u_alert_stage`) to the automation's webhook URL.

---

## Step 1: Create the playbooks

**Devin Settings → Playbooks → New playbook**, once per file:

| Playbook title | Content |
|---|---|
| `ALERT Incident Triage and Enrichment` | [PLAYBOOK_A_TRIAGE.md](./PLAYBOOK_A_TRIAGE.md) |
| `ALERT Approved Issue Remediation` | [PLAYBOOK_B_REMEDIATION.md](./PLAYBOOK_B_REMEDIATION.md) |

## Step 2: Create the triage automation

**Automations → New automation**:

| Field | Value |
|---|---|
| Name | `ALERT Incident Triage` |
| Trigger type | Webhook |
| Payload filter | `"u_alert_stage"\s*:\s*"triage"` |
| Action | Start session |
| Tags | `servicenow`, `alert`, `triage` |
| ACU limit | `20` per session |
| Invocation limit | `20 per hour` |

Prompt:

```
You are triaging an issue reported through ServiceNow against the OtterWorks platform.

The ServiceNow incident payload is included below as context (the webhook body).
Parse it for: sys_id, number, short_description, description, priority, cmdb_ci,
u_alert_stage, u_open_questions, and the latest entry in comments.

Follow the @ALERT Incident Triage and Enrichment playbook.

Do not modify code, create a branch, or open a pull request in this session.
```

The stage payload filter is what makes the webhook safe to retry: a duplicate POST
for an incident that has already moved past `triage` does not match, so no second
session starts. The lower ACU limit reflects that triage is investigation only.

## Step 3: Create the remediation automation

| Field | Value |
|---|---|
| Name | `ALERT Approved Remediation` |
| Trigger type | Webhook |
| Payload filter | `"u_alert_stage"\s*:\s*"development"` |
| Action | Start session |
| Tags | `servicenow`, `alert`, `remediation` |
| ACU limit | `50` per session |
| Invocation limit | `10 per hour` |

Prompt:

```
A product owner has approved a triaged OtterWorks issue for remediation.

The ServiceNow incident payload is included below as context (the webhook body).
Parse it for: sys_id, number, u_alert_stage, u_affected_service, u_devin_findings,
u_repro_steps, and the latest entry in comments.

Treat u_devin_findings as the accepted diagnosis. Follow the
@ALERT Approved Issue Remediation playbook.

Do not merge or approve your own pull request.
```

## Step 4: Wire the webhook URLs into ServiceNow

Copy each automation's **Webhook URL** into the matching system property
(**System Properties → All Properties**, or `sys_properties_list.do`):

| Automation | Property |
|---|---|
| `ALERT Incident Triage` | `alert.workflow.triage_webhook_url` |
| `ALERT Approved Remediation` | `alert.workflow.development_webhook_url` |

An empty property means that stage does not trigger — this is the intended state
before go-live, and clearing one is how you stop a single stage in a hurry.

## Step 5: Required org secrets

Both playbooks call back to ServiceNow with Basic Auth, so **Devin Settings →
Secrets** needs: `SERVICENOW_INSTANCE_URL`, `SERVICENOW_USERNAME`,
`SERVICENOW_PASSWORD`. The account needs write access to the `u_*` fields on
`incident`; a 403 on the callback PATCH usually means an ACL, not a bad password.

## Verification

1. Create a pilot incident (Category `Software`, **ALERT pilot** checked).
2. The **ALERT Incident Triage** automation's Activity tab shows one invocation and
   one linked session; the incident stage becomes `triage`.
3. When the session finishes, the incident carries a verdict, findings, session URL,
   and a new stage (`owner_review`, `awaiting_info`, or `rejected`).
4. After an owner approval, the **ALERT Approved Remediation** automation shows an
   invocation and the incident ends up in `tech_lead_review` with a PR URL.

If nothing happens: check that the business rule is active, that the property holds
the URL, that **Automation hold** is not set, and that the incident is flagged as
pilot while `alert.workflow.pilot_only` is true. The rules log with the `[ALERT]`
prefix in **System Logs → All**.

---

## Legacy single-shot automation

The earlier `ServiceNow Incident Remediation` automation (one session doing
investigate + fix + PR, triggered directly on incident insert) is superseded by the
two above. Disable it when you activate `ALERT: start triage`, otherwise a pilot
incident starts both flows. Its playbook is kept at [PLAYBOOK.md](./PLAYBOOK.md) for
reference.
