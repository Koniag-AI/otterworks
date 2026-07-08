# Playbook: ServiceNow Incident Auto-Remediation (Webhook)

This is the content of the Devin playbook used by the ServiceNow automation.
Create it in **Devin Settings → Playbooks → New playbook** with the title
`ServiceNow Incident Auto-Remediation (Webhook)`.

---

## Playbook Content

```markdown
# ServiceNow Incident Auto-Remediation

This playbook is triggered by a Devin Automation with a **Webhook trigger**. The webhook
payload is a JSON object from a ServiceNow Business Rule containing incident details.

## Step 1: Parse the ServiceNow Payload

Extract these fields from the webhook payload (included as context in your prompt):
- `incident.sys_id` — unique ServiceNow record ID (needed for callbacks)
- `incident.number` — human-readable ticket number (e.g. INC0010042)
- `incident.short_description` — one-line summary of the bug
- `incident.description` — detailed bug description
- `incident.priority` — 1 (critical) through 5 (low)
- `incident.cmdb_ci` — affected service name (e.g. `file-service`)
- `incident.category` — incident category (e.g. `Software`)
- `incident.assignment_group` — responsible team

## Step 2: Identify the Affected Service

Map `cmdb_ci` to one of the OtterWorks microservices:

| Service | Language | Port | Path |
|---------|----------|------|------|
| api-gateway | Go/Chi | 8080 | `services/api-gateway` |
| auth-service | Java/Spring Boot | 8081 | `services/auth-service` |
| file-service | Rust/Actix-Web | 8082 | `services/file-service` |
| document-service | Python/FastAPI | 8083 | `services/document-service` |
| collab-service | Node.js/Socket.io | 8084 | `services/collab-service` |
| notification-service | Kotlin/Ktor | 8086 | `services/notification-service` |
| search-service | Python/Flask | 8087 | `services/search-service` |
| analytics-service | Scala/Akka HTTP | 8088 | `services/analytics-service` |
| admin-service | Ruby/Rails | 8089 | `services/admin-service` |
| audit-service | C#/ASP.NET | 8090 | `services/audit-service` |
| report-service | Java/Spring Boot | 8091 | `services/report-service` |

If `cmdb_ci` doesn't match directly, scan `short_description` for service names.

## Step 3: Investigate and Fix the Bug

1. Navigate to the affected service directory.
2. Search for code related to the bug description — error messages, endpoints, functions.
3. Check recent commits for related changes.
4. Identify the root cause.
5. Implement a fix following the service's existing code conventions.
6. Run the service's lint and test commands to verify.

## Step 4: Open a PR

Create a PR with:
- Title referencing the ServiceNow ticket: `fix(<service>): <short description> [<INC number>]`
- Description including the ServiceNow ticket number, root cause analysis, and what was changed.

## Step 5: Post Work Note to ServiceNow

After opening the PR, update the ServiceNow incident with a work note using Basic Auth.

Use this curl command (the SERVICENOW_INSTANCE_URL, SERVICENOW_USERNAME, and
SERVICENOW_PASSWORD secrets are available as environment variables):

    curl -s -X PATCH "${SERVICENOW_INSTANCE_URL}/api/now/table/incident/<sys_id>" \
      -u "${SERVICENOW_USERNAME}:${SERVICENOW_PASSWORD}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d '{"work_notes": "[Devin AI Auto-Remediation]\nPR: <pr_url>\nSession: <session_url>\nRoot cause: <brief summary>"}'

Replace `<sys_id>`, `<pr_url>`, `<session_url>`, and `<brief summary>` with actual values.

## Step 6: Verify and Report

- Confirm the work note was posted successfully (HTTP 200).
- Report completion to the user with links to both the PR and ServiceNow ticket.

## Important Notes

- The repo is `Cognition-Partner-Workshops/otterworks` on the `koniag-harness-aws` branch.
- Do NOT use the Devin API to create sessions — this playbook IS the session.
- ServiceNow credentials are available as org secrets: `SERVICENOW_INSTANCE_URL`,
  `SERVICENOW_USERNAME`, `SERVICENOW_PASSWORD`.
- Always include the ServiceNow ticket number in PR titles and descriptions for traceability.
```
