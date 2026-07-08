# ServiceNow Configuration Guide (Automations Webhook)

Step-by-step instructions for configuring ServiceNow to send incident webhooks
directly to a **Devin Automation webhook endpoint** for automated bug remediation.

> **Prerequisite:** Complete [AUTOMATION_SETUP.md](./AUTOMATION_SETUP.md) first to get
> the Devin Automation webhook URL.

---

## Step 1: Create the Outbound REST Message

This saves a reusable HTTP call template that the Business Rule will invoke.

1. Open the REST Message list:
   `https://<your-instance>.service-now.com/sys_rest_message_list.do`

2. Click **New**

3. Fill in:
   | Field | Value |
   |-------|-------|
   | **Name** | `Devin Automation Webhook` |
   | **Endpoint** | *(the webhook URL from AUTOMATION_SETUP.md step 5)* |
   | **Authentication type** | `No authentication` |

4. Click **Submit**

5. Re-open the record. Scroll down to **HTTP Methods** and click **New**:
   | Field | Value |
   |-------|-------|
   | **Name** | `POST_Incident` |
   | **HTTP method** | `POST` |

6. Under **HTTP Request**, add this **HTTP Header**:
   | Name | Value |
   |------|-------|
   | `Content-Type` | `application/json` |

7. Set the **Content** (request body):
   ```json
   {
     "source": "servicenow",
     "incident": {
       "sys_id": "${sys_id}",
       "number": "${number}",
       "short_description": "${short_description}",
       "description": "${description}",
       "priority": "${priority}",
       "category": "${category}",
       "subcategory": "${subcategory}",
       "assignment_group": "${assignment_group}",
       "assigned_to": "${assigned_to}",
       "caller_id": "${caller_id}",
       "cmdb_ci": "${cmdb_ci}",
       "state": "${state}",
       "sys_created_on": "${sys_created_on}"
     }
   }
   ```

8. Scroll down to **Variable Substitutions**. Add each variable with a test value:

   | Name | Test value |
   |------|-----------|
   | `sys_id` | `abc123` |
   | `number` | `INC0010001` |
   | `short_description` | `Test incident` |
   | `description` | `Test description` |
   | `priority` | `1` |
   | `category` | `Software` |
   | `subcategory` | `Operating System` |
   | `assignment_group` | `Service Desk` |
   | `assigned_to` | `admin` |
   | `caller_id` | `admin` |
   | `cmdb_ci` | `file-service` |
   | `state` | `1` |
   | `sys_created_on` | `2026-01-01 00:00:00` |

9. Click **Submit**

---

## Step 2: Create the Business Rule

This automatically fires the webhook when a qualifying incident is created.

1. Open the Business Rules list:
   `https://<your-instance>.service-now.com/sys_script_list.do`

2. Click **New**

3. Fill in the **When to run** section:
   | Field | Value |
   |-------|-------|
   | **Name** | `Trigger Devin Remediation` |
   | **Table** | `Incident [incident]` |
   | **Advanced** | Check this box |
   | **When** | `after` |
   | **Insert** | Check |
   | **Update** | Uncheck (unless you want updates too) |

4. Set **Filter Conditions** (click "Add filter condition"):
   - `Category` → `is` → `Software`
   - AND `Priority` → `is one of` → `1 - Critical`, `2 - High`

5. Switch to the **Advanced** script tab and paste:

   ```javascript
   (function executeRule(current, previous) {
       try {
           var r = new sn_ws.RESTMessageV2('Devin Automation Webhook', 'POST_Incident');
           r.setStringParameterNoEscape('sys_id', current.sys_id.toString());
           r.setStringParameterNoEscape('number', current.number.toString());
           r.setStringParameterNoEscape('short_description', current.short_description.toString());
           r.setStringParameterNoEscape('description', current.description.toString());
           r.setStringParameterNoEscape('priority', current.priority.toString());
           r.setStringParameterNoEscape('category', current.category.toString());
           r.setStringParameterNoEscape('subcategory', current.subcategory.toString());
           r.setStringParameterNoEscape('assignment_group', current.assignment_group.getDisplayValue());
           r.setStringParameterNoEscape('assigned_to', current.assigned_to.getDisplayValue());
           r.setStringParameterNoEscape('caller_id', current.caller_id.getDisplayValue());
           r.setStringParameterNoEscape('cmdb_ci', current.cmdb_ci.getDisplayValue());
           r.setStringParameterNoEscape('state', current.state.toString());
           r.setStringParameterNoEscape('sys_created_on', current.sys_created_on.toString());
           var response = r.execute();
           gs.info('Devin automation webhook response: ' + response.getStatusCode());
       } catch (ex) {
           gs.error('Devin automation webhook failed: ' + ex.message);
       }
   })(current, previous);
   ```

6. Click **Submit**

---

## Step 3: Test End-to-End

1. Go to the incident list:
   `https://<your-instance>.service-now.com/now/sow/list/incident`

2. Click **New** to create a new incident

3. Fill in:
   | Field | Value |
   |-------|-------|
   | **Caller** | Pick any user |
   | **Category** | `Software` |
   | **Impact** | `1 - High` |
   | **Urgency** | `1 - High` |
   | **Short description** | `File upload returns 500 error in file-service` |
   | **Description** | `Users report intermittent 500 errors when uploading files larger than 10MB` |

4. Click **Save**

5. The Business Rule fires → webhook hits Devin Automation → Devin session starts

6. Check the Devin Automation **Activity** tab for the invocation and linked session.

7. Once the session completes, the incident's **Work Notes** should show a note
   from Devin with the PR link and remediation summary.

---

## Troubleshooting

### Business Rule not firing
- Check **System Logs → System Log → All**: filter by `Devin automation webhook`
- Verify the filter conditions match your incident (Category=Software, Priority=1 or 2)

### REST Message errors
- Open the REST Message → HTTP Method → click **Test**
- Check the response code and body

### Automation not triggering
- Check the Devin Automation detail page → **Activity** tab for invocation history
- Verify the payload filter regex matches the incident JSON (if configured)
- Ensure the automation is **enabled** (toggle on)

### Work notes not appearing
- Verify the `SERVICENOW_INSTANCE_URL`, `SERVICENOW_USERNAME`, and
  `SERVICENOW_PASSWORD` org secrets are set in Devin Settings → Secrets
- Check the Devin session logs for curl output from the work note step
