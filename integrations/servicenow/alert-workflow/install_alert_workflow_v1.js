/**
 * ALERT Workflow v1 - installer (ServiceNow background script)
 *
 * Run this from System Definition > Scripts - Background WITH AN UPDATE SET
 * SELECTED (see README.md). Everything it creates is then captured in that
 * update set and can be exported to XML, previewed on another instance, or
 * backed out.
 *
 * What it creates:
 *   - 12 u_* fields on the incident table (additive; no OOB field is modified)
 *   - the choice lists for the three choice fields
 *   - system properties holding the two Devin automation webhook URLs
 *   - script include ALERTWorkflow (guard checks + webhook POST)
 *   - 6 business rules, ALL INACTIVE, so nothing changes until they are activated
 *
 * The script is idempotent: re-running it updates the records it already created
 * and never duplicates them. It never activates a business rule that exists, so
 * re-running after go-live will not disable a rule you turned on.
 *
 * Verify with verify_alert_workflow_v1.js. Uninstall with uninstall_alert_workflow_v1.js.
 */
(function installAlertWorkflowV1() {
    var TABLE = 'incident';
    var log = [];

    function say(msg) {
        log.push(msg);
        gs.info('[ALERT install] ' + msg);
    }

    // ---------------------------------------------------------------- fields

    function upsertField(spec) {
        var gr = new GlideRecord('sys_dictionary');
        gr.addQuery('name', TABLE);
        gr.addQuery('element', spec.element);
        gr.query();
        var isNew = !gr.next();
        if (isNew) {
            gr.initialize();
            gr.setValue('name', TABLE);
            gr.setValue('element', spec.element);
        }
        gr.setValue('column_label', spec.label);
        gr.setValue('internal_type', spec.type);
        gr.setValue('max_length', spec.length || 40);
        gr.setValue('active', true);
        gr.setValue('read_only', false);
        if (spec.choice) {
            gr.setValue('choice', 1); // dropdown with --None--
        }
        if (spec.hint) {
            gr.setValue('comments', spec.hint);
        }
        if (isNew) {
            gr.insert();
            say('field created: ' + spec.element);
        } else {
            gr.update();
            say('field updated: ' + spec.element);
        }
    }

    var FIELDS = [
        {
            element: 'u_alert_stage',
            label: 'ALERT stage',
            type: 'string',
            length: 40,
            choice: true,
            hint: 'Position in the ALERT autonomous workflow. Drives every automation trigger.'
        },
        {
            element: 'u_devin_verdict',
            label: 'Devin verdict',
            type: 'string',
            length: 40,
            choice: true,
            hint: 'Validity conclusion from the Devin triage session.'
        },
        {
            element: 'u_devin_confidence',
            label: 'Devin confidence',
            type: 'string',
            length: 40,
            choice: true,
            hint: 'Confidence in the verdict. Low confidence must be reviewed by a human.'
        },
        {element: 'u_affected_service', label: 'Affected service', type: 'string', length: 80},
        {element: 'u_devin_session_url', label: 'Devin session URL', type: 'url', length: 1024},
        {
            element: 'u_devin_findings',
            label: 'Devin findings',
            type: 'string',
            length: 8000,
            hint: 'Evidence, root cause and proposed fix. The product owner approves against this.'
        },
        {element: 'u_repro_steps', label: 'Reproduction steps', type: 'string', length: 4000},
        {
            element: 'u_open_questions',
            label: 'Open questions for requester',
            type: 'string',
            length: 4000,
            hint: 'Posted to the requester as a customer-visible comment when stage is awaiting_info.'
        },
        {element: 'u_pr_url', label: 'Pull request URL', type: 'url', length: 1024},
        {element: 'u_harness_execution_url', label: 'Harness execution URL', type: 'url', length: 1024},
        {
            element: 'u_automation_hold',
            label: 'Automation hold',
            type: 'boolean',
            length: 40,
            hint: 'Kill switch. Every ALERT business rule exits immediately when this is true.'
        },
        {
            element: 'u_alert_pilot',
            label: 'ALERT pilot',
            type: 'boolean',
            length: 40,
            hint: 'Pilot scope flag. Only pilot incidents enter the ALERT workflow until go-live.'
        }
    ];

    FIELDS.forEach(upsertField);

    // ---------------------------------------------------------------- choices

    function upsertChoice(element, value, label, sequence) {
        var gr = new GlideRecord('sys_choice');
        gr.addQuery('name', TABLE);
        gr.addQuery('element', element);
        gr.addQuery('value', value);
        gr.addQuery('language', 'en');
        gr.query();
        var isNew = !gr.next();
        if (isNew) {
            gr.initialize();
            gr.setValue('name', TABLE);
            gr.setValue('element', element);
            gr.setValue('value', value);
            gr.setValue('language', 'en');
        }
        gr.setValue('label', label);
        gr.setValue('sequence', sequence);
        gr.setValue('inactive', false);
        isNew ? gr.insert() : gr.update();
    }

    var STAGES = [
        ['triage', 'Triage (Devin investigating)'],
        ['awaiting_info', 'Awaiting information from requester'],
        ['owner_review', 'Product owner review'],
        ['development', 'Development (Devin implementing)'],
        ['tech_lead_review', 'Tech lead review'],
        ['deploying', 'Deploying (Harness)'],
        ['verified', 'Verified'],
        ['rejected', 'Rejected']
    ];
    STAGES.forEach(function (c, i) {
        upsertChoice('u_alert_stage', c[0], c[1], (i + 1) * 100);
    });
    say('stage choices: ' + STAGES.length);

    var VERDICTS = [
        ['valid', 'Valid'],
        ['needs_info', 'Needs information'],
        ['not_a_defect', 'Not a defect'],
        ['duplicate', 'Duplicate'],
        ['invalid', 'Invalid']
    ];
    VERDICTS.forEach(function (c, i) {
        upsertChoice('u_devin_verdict', c[0], c[1], (i + 1) * 100);
    });

    [['high', 'High'], ['medium', 'Medium'], ['low', 'Low']].forEach(function (c, i) {
        upsertChoice('u_devin_confidence', c[0], c[1], (i + 1) * 100);
    });
    say('verdict and confidence choices created');

    // ------------------------------------------------------------ properties

    function upsertProperty(name, value, description) {
        var gr = new GlideRecord('sys_properties');
        gr.addQuery('name', name);
        gr.query();
        var isNew = !gr.next();
        if (isNew) {
            gr.initialize();
            gr.setValue('name', name);
            gr.setValue('value', value);
        }
        gr.setValue('description', description);
        gr.setValue('type', 'string');
        gr.setValue('is_private', false);
        isNew ? gr.insert() : gr.update();
        say((isNew ? 'property created: ' : 'property kept: ') + name);
    }

    upsertProperty(
        'alert.workflow.triage_webhook_url',
        '',
        'Devin automation webhook URL for ALERT Incident Triage. Empty = triage automation disabled.'
    );
    upsertProperty(
        'alert.workflow.development_webhook_url',
        '',
        'Devin automation webhook URL for ALERT Approved Remediation. Empty = remediation automation disabled.'
    );
    upsertProperty(
        'alert.workflow.pilot_only',
        'true',
        'When true, only incidents with ALERT pilot = true enter the workflow. Setting this to false is the go-live action.'
    );

    // -------------------------------------------------------- script include

    var SCRIPT_INCLUDE = [
        'var ALERTWorkflow = Class.create();',
        'ALERTWorkflow.prototype = {',
        '    initialize: function() {},',
        '',
        '    /* An incident is in scope when automation is not held and, while',
        '       alert.workflow.pilot_only is true, only when it is flagged as pilot. */',
        '    inScope: function(incident) {',
        '        if (incident.u_automation_hold == true) {',
        '            gs.info("[ALERT] " + incident.number + ": automation hold set, skipping");',
        '            return false;',
        '        }',
        '        if (gs.getProperty("alert.workflow.pilot_only", "true") == "true" &&',
        '                incident.u_alert_pilot != true) {',
        '            return false;',
        '        }',
        '        return true;',
        '    },',
        '',
        '    payload: function(incident, extra) {',
        '        var body = {',
        '            source: "servicenow",',
        '            incident: {',
        '                sys_id: incident.getUniqueValue(),',
        '                number: incident.getValue("number") + "",',
        '                short_description: incident.getValue("short_description") + "",',
        '                description: incident.getValue("description") + "",',
        '                priority: incident.getValue("priority") + "",',
        '                category: incident.getValue("category") + "",',
        '                state: incident.getValue("state") + "",',
        '                cmdb_ci: incident.cmdb_ci.getDisplayValue() + "",',
        '                caller_id: incident.caller_id.getDisplayValue() + "",',
        '                assignment_group: incident.assignment_group.getDisplayValue() + "",',
        '                comments: incident.comments.getJournalEntry(1) + "",',
        '                u_alert_stage: incident.getValue("u_alert_stage") + "",',
        '                u_affected_service: incident.getValue("u_affected_service") + "",',
        '                u_devin_verdict: incident.getValue("u_devin_verdict") + "",',
        '                u_devin_findings: incident.getValue("u_devin_findings") + "",',
        '                u_repro_steps: incident.getValue("u_repro_steps") + "",',
        '                u_open_questions: incident.getValue("u_open_questions") + "",',
        '                u_pr_url: incident.getValue("u_pr_url") + ""',
        '            }',
        '        };',
        '        for (var k in (extra || {})) {',
        '            body[k] = extra[k];',
        '        }',
        '        return new global.JSON().encode(body);',
        '    },',
        '',
        '    /* POST the incident to a Devin automation webhook. The URL lives in a',
        '       system property so an operator can stop a stage by clearing it. */',
        '    trigger: function(propertyName, incident, extra) {',
        '        var url = gs.getProperty(propertyName, "");',
        '        if (!url) {',
        '            gs.warn("[ALERT] " + propertyName + " is empty, not triggering " + incident.number);',
        '            return false;',
        '        }',
        '        try {',
        '            var r = new sn_ws.RESTMessageV2();',
        '            r.setHttpMethod("post");',
        '            r.setEndpoint(url);',
        '            r.setRequestHeader("Content-Type", "application/json");',
        '            r.setRequestBody(this.payload(incident, extra));',
        '            var response = r.execute();',
        '            gs.info("[ALERT] " + incident.number + " -> " + propertyName + " HTTP " +',
        '                    response.getStatusCode());',
        '            return true;',
        '        } catch (ex) {',
        '            gs.error("[ALERT] webhook failed for " + incident.number + ": " + ex.message);',
        '            return false;',
        '        }',
        '    },',
        '',
        '    /* Owner/tech-lead routing for a service, from u_alert_service_owner. */',
        '    ownerGroupFor: function(service) {',
        '        var gr = new GlideRecord("u_alert_service_owner");',
        '        if (!gr.isValid()) {',
        '            return "";',
        '        }',
        '        gr.addQuery("u_service", service);',
        '        gr.setLimit(1);',
        '        gr.query();',
        '        return gr.next() ? gr.getValue("u_owner_group") : "";',
        '    },',
        '',
        '    type: "ALERTWorkflow"',
        '};'
    ].join('\n');

    (function upsertScriptInclude() {
        var gr = new GlideRecord('sys_script_include');
        gr.addQuery('name', 'ALERTWorkflow');
        gr.query();
        var isNew = !gr.next();
        if (isNew) {
            gr.initialize();
            gr.setValue('name', 'ALERTWorkflow');
            gr.setValue('api_name', 'global.ALERTWorkflow');
        }
        gr.setValue('script', SCRIPT_INCLUDE);
        gr.setValue('description', 'ALERT workflow guards, webhook trigger and owner routing.');
        gr.setValue('active', true);
        gr.setValue('access', 'public');
        gr.setValue('client_callable', false);
        isNew ? gr.insert() : gr.update();
        say((isNew ? 'script include created' : 'script include updated') + ': ALERTWorkflow');
    })();

    // -------------------------------------------------------- business rules

    function upsertBusinessRule(spec) {
        var table = spec.table || TABLE;
        var gr = new GlideRecord('sys_script');
        gr.addQuery('name', spec.name);
        gr.addQuery('collection', table);
        gr.query();
        var isNew = !gr.next();
        if (isNew) {
            gr.initialize();
            gr.setValue('name', spec.name);
            gr.setValue('collection', table);
            // Inactive on install: activating a rule is a separate, deliberate step.
            gr.setValue('active', false);
        }
        gr.setValue('when', 'after');
        gr.setValue('action_insert', !!spec.on_insert);
        gr.setValue('action_update', !!spec.on_update);
        gr.setValue('order', spec.order);
        gr.setValue('advanced', true);
        gr.setValue('condition', spec.condition || '');
        gr.setValue('script', spec.script);
        gr.setValue('description', spec.description);
        isNew ? gr.insert() : gr.update();
        say(
            (isNew ? 'business rule created (INACTIVE): ' : 'business rule script updated: ') +
                spec.name
        );
    }

    upsertBusinessRule({
        name: 'ALERT: start triage',
        on_insert: true,
        on_update: false,
        order: 1000,
        condition: 'current.category == "software"',
        description:
            'New software incident enters the ALERT workflow: stage triage, then trigger the Devin triage automation.',
        script: [
            '(function executeRule(current, previous) {',
            '    var alert = new global.ALERTWorkflow();',
            '    if (!alert.inScope(current)) {',
            '        return;',
            '    }',
            '    if (current.u_alert_stage) {',
            '        return; // already in the workflow',
            '    }',
            '    current.u_alert_stage = "triage";',
            '    current.setWorkflow(false); // no recursion into the ALERT rules',
            '    current.update();',
            '    alert.trigger("alert.workflow.triage_webhook_url", current, {reason: "new_incident"});',
            '})(current, previous);'
        ].join('\n')
    });

    upsertBusinessRule({
        name: 'ALERT: resume triage on answer',
        on_insert: false,
        on_update: true,
        order: 1000,
        condition: 'current.u_alert_stage == "awaiting_info" && current.comments.changes()',
        description:
            'Requester answered the open questions: return to triage and resume the Devin session with the answer.',
        script: [
            '(function executeRule(current, previous) {',
            '    var alert = new global.ALERTWorkflow();',
            '    if (!alert.inScope(current)) {',
            '        return;',
            '    }',
            '    current.u_alert_stage = "triage";',
            '    current.state = 2; // In Progress',
            '    current.setWorkflow(false);',
            '    current.update();',
            '    alert.trigger("alert.workflow.triage_webhook_url", current, {reason: "requester_answered"});',
            '})(current, previous);'
        ].join('\n')
    });

    upsertBusinessRule({
        name: 'ALERT: ask requester for information',
        on_insert: false,
        on_update: true,
        order: 1100,
        condition: 'current.u_alert_stage.changesTo("awaiting_info")',
        description:
            'Publish Devin open questions to the requester as a customer-visible comment and put the incident on hold.',
        script: [
            '(function executeRule(current, previous) {',
            '    var questions = current.getValue("u_open_questions");',
            '    if (!questions) {',
            '        gs.warn("[ALERT] " + current.number + " is awaiting_info with no open questions");',
            '        return;',
            '    }',
            '    current.comments = "We need a little more detail to investigate this:\\n\\n" +',
            '        questions + "\\n\\nReplying here will resume the investigation automatically.";',
            '    current.state = 3; // On Hold',
            '    current.hold_reason = 1; // Awaiting Caller',
            '    current.setWorkflow(false);',
            '    current.update();',
            '})(current, previous);'
        ].join('\n')
    });

    upsertBusinessRule({
        name: 'ALERT: request owner approval',
        on_insert: false,
        on_update: true,
        order: 1100,
        condition: 'current.u_alert_stage.changesTo("owner_review")',
        description:
            'Triage accepted the issue: request approval from the product owner group for the affected service.',
        script: [
            '(function executeRule(current, previous) {',
            '    var alert = new global.ALERTWorkflow();',
            '    var group = alert.ownerGroupFor(current.getValue("u_affected_service"));',
            '    if (!group) {',
            '        current.work_notes = "[ALERT] No product owner group mapped for service \\"" +',
            '            current.getValue("u_affected_service") + "\\". Assign an approver manually.";',
            '        current.setWorkflow(false);',
            '        current.update();',
            '        return;',
            '    }',
            '    var members = new GlideRecord("sys_user_grmember");',
            '    members.addQuery("group", group);',
            '    members.query();',
            '    while (members.next()) {',
            '        var approval = new GlideRecord("sysapproval_approver");',
            '        approval.initialize();',
            '        approval.setValue("document_id", current.getUniqueValue());',
            '        approval.setValue("source_table", "incident");',
            '        approval.setValue("approver", members.getValue("user"));',
            '        approval.setValue("state", "requested");',
            '        approval.insert();',
            '    }',
            '})(current, previous);'
        ].join('\n')
    });

    upsertBusinessRule({
        name: 'ALERT: start development on approval',
        on_insert: false,
        on_update: true,
        order: 1000,
        condition: 'current.u_alert_stage.changesTo("development")',
        description:
            'Product owner approved the issue: trigger the Devin remediation automation.',
        script: [
            '(function executeRule(current, previous) {',
            '    var alert = new global.ALERTWorkflow();',
            '    if (!alert.inScope(current)) {',
            '        return;',
            '    }',
            '    alert.trigger("alert.workflow.development_webhook_url", current, {reason: "owner_approved"});',
            '})(current, previous);'
        ].join('\n')
    });

    upsertBusinessRule({
        name: 'ALERT: apply owner approval decision',
        table: 'sysapproval_approver',
        on_insert: false,
        on_update: true,
        order: 1000,
        condition:
            'current.source_table == "incident" && (current.state.changesTo("approved") || current.state.changesTo("rejected"))',
        description:
            'Translate the product owner decision on an ALERT incident into a stage change: approved -> development, rejected -> rejected.',
        script: [
            '(function executeRule(current, previous) {',
            '    var incident = new GlideRecord("incident");',
            '    if (!incident.get(current.getValue("document_id"))) {',
            '        return;',
            '    }',
            '    if (incident.getValue("u_alert_stage") != "owner_review") {',
            '        return; // decision belongs to some other approval on this incident',
            '    }',
            '    var approver = current.approver.getDisplayValue();',
            '    if (current.getValue("state") == "approved") {',
            '        incident.setValue("u_alert_stage", "development");',
            '        incident.work_notes = "[ALERT] Issue approved for remediation by " + approver + ".";',
            '    } else {',
            '        incident.setValue("u_alert_stage", "rejected");',
            '        incident.setValue("state", 8); // Closed',
            '        incident.work_notes = "[ALERT] Issue rejected by " + approver + ". No remediation will be developed.";',
            '    }',
            '    incident.update();',
            '})(current, previous);'
        ].join('\n')
    });

    gs.info('[ALERT install] complete:\n' + log.join('\n'));
    gs.print('ALERT Workflow v1 install complete. ' + log.length + ' steps:\n' + log.join('\n'));
    gs.print(
        '\nAll 6 business rules are INACTIVE. Set the two webhook URL properties, then ' +
            'activate them in the order given in README.md.'
    );
})();
