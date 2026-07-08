# Devin Automation Setup — ServiceNow Webhook Trigger

Create a Devin Automation that starts a remediation session whenever ServiceNow sends an incident webhook.

---

## Step 1: Open the Automations Page

Navigate to **Automations** in the Devin web UI:

```
https://<your-devin-instance>/automations
```

Click **New automation**.

---

## Step 2: Configure the Trigger

| Field | Value |
|-------|-------|
| **Name** | `ServiceNow Incident Remediation` |
| **Trigger type** | **Webhook** |
| **Payload filter** *(optional)* | `"priority"\s*:\s*"[12]"` |

The payload filter (regex) ensures only P1/P2 incidents trigger a session. Remove it to trigger on all priorities.

---

## Step 3: Configure the Action

| Field | Value |
|-------|-------|
| **Action** | **Start session** |
| **Prompt** | *(see below)* |
| **Tags** | `servicenow`, `incident-response` |

### Prompt template

```
You are investigating a bug reported via ServiceNow in the OtterWorks platform.

The full ServiceNow incident payload is included below as context (from the webhook body).
Parse the incident JSON to extract: number, priority, short_description, description, cmdb_ci (affected service), sys_id, and assignment_group.

Follow the @ServiceNow Incident Auto-Remediation (Webhook) playbook.
```

> The `@ServiceNow Incident Auto-Remediation (Webhook)` reference links the playbook created in Devin Settings → Playbooks.

---

## Step 4: Set Limits

| Field | Recommended value |
|-------|-------------------|
| **ACU limit** | `50` per session |
| **Invocation limit** | `20 per hour` |

---

## Step 5: Save and Copy the Webhook URL

1. Click **Save**
2. On the automation detail page, copy:
   - **Webhook URL** — e.g. `https://automations.devin.ai/hooks/<automation-id>`
   - **Webhook secret** *(if displayed)* — for request validation

---

## Step 6: Update ServiceNow

Use the webhook URL from step 5 as the endpoint in the ServiceNow Outbound REST Message. See [SERVICENOW_SETUP.md](./SERVICENOW_SETUP.md) for details.

---

## Verification

1. Go to the automation detail page → **Activity** tab
2. Create a test incident in ServiceNow (Category=Software, Priority=1-Critical)
3. Within a few seconds, you should see:
   - A new invocation in the Activity tab
   - A new Devin session linked from that invocation
   - The session prompt includes the ServiceNow incident payload
