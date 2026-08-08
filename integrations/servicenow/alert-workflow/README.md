# ALERT Workflow v1 — ServiceNow configuration

Installs the ticket-side half of the ALERT workflow:

```
end user files incident
  → triage            (Devin: valid? enrich, or ask)
  → awaiting_info     (requester answers → back to triage)
  → owner_review      (product owner approves or rejects)
  → development       (Devin: implement, open PR)
  → tech_lead_review  (tech lead approves + merges)
  → deploying         (Harness)
  → verified → closed
```

Design constraints this configuration respects:

* **Additive only.** New `u_*` fields, new business rules, one new script include. No
  OOB field, choice, rule, or flow is modified. The old `Trigger Devin Remediation`
  rule is untouched — you deactivate it by hand at step 6.
* **Inert on install.** All six business rules install **inactive** and both webhook
  URL properties install **empty**. Nothing changes behavior until you act.
* **Pilot-scoped.** While `alert.workflow.pilot_only` is `true`, only incidents with
  **ALERT pilot = true** enter the workflow. Everything else keeps its current path.
* **Kill switch.** Every rule exits immediately when **Automation hold** is true on
  the incident.
* **Reversible.** Everything is captured in one update set; back it out to remove it.

## Files

| File | Purpose |
|---|---|
| `install_alert_workflow_v1.js` | Creates fields, choices, properties, script include, and the six inactive business rules. Idempotent. |
| `verify_alert_workflow_v1.js` | Read-only: reports what exists, what is active, and what is unmapped. |
| `uninstall_alert_workflow_v1.js` | Deactivates rules and clears webhook URLs. Optional destructive field drop behind a flag. |

## Install

### 1. Create the update set

**System Update Sets → Local Update Sets → New**: name `ALERT Workflow v1`, then
**make it the current update set**. Everything below is captured in it.

### 2. Run the installer

**System Definition → Scripts - Background**, paste `install_alert_workflow_v1.js`,
run in scope `global`. It prints every record it created. Re-running is safe.

### 3. Create the owner mapping table

The installer does not create tables. In **System Definition → Tables → New**:

| | |
|---|---|
| Label / Name | `ALERT service owner` / `u_alert_service_owner` |
| Extends | (none) |

Columns:

| Column | Type | Notes |
|---|---|---|
| `u_service` | String (80) | OtterWorks application name, e.g. `file-service` |
| `u_owner_group` | Reference → `sys_user_group` | Product owner approvers for that service |
| `u_tech_lead_group` | Reference → `sys_user_group` | Reference only; the PR gate is enforced by GitHub `CODEOWNERS` |

Add one row per application (13 of them; `verify_alert_workflow_v1.js` lists the
names and reports which are unmapped). Keep `u_tech_lead_group` consistent with
`.github/CODEOWNERS` so a ticket and its PR route to the same people.

### 4. Add the fields to the form and list

On the Incident form, add a section **ALERT** with: ALERT stage, Devin verdict,
Devin confidence, Affected service, Devin findings, Reproduction steps, Open
questions, Devin session URL, Pull request URL, Harness execution URL, Automation
hold, ALERT pilot. Add **ALERT stage** to the incident list layout.

Make Devin verdict, confidence, findings, reproduction steps, session URL, PR URL,
and Harness execution URL read-only on the form: they are written by automation and
hand-editing them silently changes what an approver is approving.

### 5. Verify

Run `verify_alert_workflow_v1.js`. Expect all fields OK, 8 stages, script include
active, six rules present and **inactive**, both webhook properties empty.

### 6. Enable, one step at a time

Run the verification script after each step.

1. **Triage in shadow mode.** Create the Devin playbooks and automations
   (`../PLAYBOOK_A_TRIAGE.md`, `../PLAYBOOK_B_REMEDIATION.md`, `../AUTOMATION_SETUP.md`),
   put the triage automation's webhook URL in `alert.workflow.triage_webhook_url`,
   and activate only **ALERT: start triage** and **ALERT: resume triage on answer**.
   Deactivate the old `Trigger Devin Remediation` rule so a pilot incident does not
   start both flows.
   Devin now triages pilot incidents and writes its verdict, findings, and stage —
   but no requester is contacted and no code is written, because the remaining rules
   are still inactive. Run 5–10 pilot tickets and check whether you agree with the
   verdicts before continuing.
2. **Requester loop.** Activate **ALERT: ask requester for information**. Verify on
   a deliberately vague pilot ticket that the questions arrive as a customer-visible
   comment and that answering resumes triage.
3. **Owner approval.** Populate `u_alert_service_owner`, then activate **ALERT:
   request owner approval** and **ALERT: apply owner approval decision**. Verify that
   a rejection closes the ticket with no code written.
4. **Remediation.** Set `alert.workflow.development_webhook_url` and activate
   **ALERT: start development on approval**. Verify the PR appears, is attributed to
   the incident, and cannot be merged without the code-owner review.
5. **Deploy.** Enable the Harness merge trigger for one service
   (`harness/apps.yaml`, `merge_trigger_enabled: true`, then
   `python3 harness/sync_harness.py --apply --apply-triggers --only file-service`).
6. **Go live.** Set `alert.workflow.pilot_only` to `false` when the pilot results are
   acceptable. This is the only step that affects tickets nobody opted in.

### 7. Export the update set

Mark it **Complete**, then **Export to XML** and commit the file next to this README
so the configuration is reviewable in git and importable on another instance.

## Stopping it

| Situation | Action |
|---|---|
| One ticket is misbehaving | Set **Automation hold** on that incident |
| One stage is misbehaving | Clear that stage's webhook URL property |
| Stop all new work | Set `alert.workflow.pilot_only` back to `true`, or deactivate **ALERT: start triage** |
| Remove the automation | Run `uninstall_alert_workflow_v1.js` |
| Remove everything | Back out the `ALERT Workflow v1` update set |

## Known constraints

* There is a single ServiceNow instance today, so this cannot be rehearsed on a
  sub-production instance first. The pilot flag is the only isolation mechanism;
  a sub-prod instance should be requested before the workflow handles real tickets.
* `ALERT: start triage` filters on `category == "software"`, matching the filter the
  current `Trigger Devin Remediation` rule uses. Widen it deliberately.
* The requester loop uses a business rule rather than Flow Designer. If the agency
  standard is Flow Designer, the rule bodies translate directly and the trigger
  conditions stay the same.
* Approvals are created for every member of the owner group (first response wins).
  Swap in an approval group record if the agency requires quorum behavior.
