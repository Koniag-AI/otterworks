/**
 * ALERT Workflow v1 - verification (ServiceNow background script)
 *
 * Read-only. Prints what is installed, which business rules are active, whether
 * the webhook properties are set, and whether the owner mapping table exists and
 * covers every OtterWorks application. Run it after install and after each
 * activation step.
 */
(function verifyAlertWorkflowV1() {
    var out = [];
    var problems = 0;

    function ok(msg) {
        out.push('  OK      ' + msg);
    }
    function bad(msg) {
        problems++;
        out.push('  MISSING ' + msg);
    }
    function note(msg) {
        out.push('  note    ' + msg);
    }

    out.push('Fields on incident:');
    [
        'u_alert_stage',
        'u_devin_verdict',
        'u_devin_confidence',
        'u_affected_service',
        'u_devin_session_url',
        'u_devin_findings',
        'u_repro_steps',
        'u_open_questions',
        'u_pr_url',
        'u_harness_execution_url',
        'u_automation_hold',
        'u_alert_pilot'
    ].forEach(function (element) {
        var gr = new GlideRecord('sys_dictionary');
        gr.addQuery('name', 'incident');
        gr.addQuery('element', element);
        gr.query();
        gr.next()
            ? ok(element + ' (' + gr.getValue('internal_type') + ')')
            : bad(element);
    });

    out.push('Stage choices:');
    var choices = new GlideRecord('sys_choice');
    choices.addQuery('name', 'incident');
    choices.addQuery('element', 'u_alert_stage');
    choices.addQuery('inactive', false);
    choices.orderBy('sequence');
    choices.query();
    var stages = [];
    while (choices.next()) {
        stages.push(choices.getValue('value'));
    }
    stages.length === 8 ? ok(stages.join(' -> ')) : bad('expected 8 stages, found ' + stages.length);

    out.push('Script include:');
    var si = new GlideRecord('sys_script_include');
    si.addQuery('name', 'ALERTWorkflow');
    si.query();
    si.next() && si.getValue('active') == '1' ? ok('ALERTWorkflow active') : bad('ALERTWorkflow');

    out.push('Business rules (active flag shown - inactive is the safe install state):');
    [
        'ALERT: start triage',
        'ALERT: resume triage on answer',
        'ALERT: ask requester for information',
        'ALERT: request owner approval',
        'ALERT: start development on approval',
        'ALERT: apply owner approval decision'
    ].forEach(function (name) {
        var gr = new GlideRecord('sys_script');
        gr.addQuery('name', name);
        gr.query();
        if (!gr.next()) {
            bad(name);
            return;
        }
        ok(name + ' [' + (gr.getValue('active') == '1' ? 'ACTIVE' : 'inactive') + ' on ' +
            gr.getValue('collection') + ']');
    });

    out.push('Properties:');
    ['alert.workflow.triage_webhook_url', 'alert.workflow.development_webhook_url'].forEach(
        function (name) {
            var value = gs.getProperty(name, '');
            value
                ? ok(name + ' set')
                : note(name + ' EMPTY - that stage will not trigger (intentional before go-live)');
        }
    );
    note('alert.workflow.pilot_only = ' + gs.getProperty('alert.workflow.pilot_only', '(unset)'));

    out.push('Owner mapping table u_alert_service_owner:');
    var map = new GlideRecord('u_alert_service_owner');
    if (!map.isValid()) {
        bad('table does not exist - create it per README.md, approvals cannot route without it');
    } else {
        var mapped = {};
        map.query();
        while (map.next()) {
            mapped[map.getValue('u_service')] = true;
        }
        var services = [
            'api-gateway', 'auth-service', 'file-service', 'document-service',
            'collab-service', 'notification-service', 'search-service',
            'analytics-service', 'admin-service', 'audit-service', 'report-service',
            'web-app', 'admin-dashboard'
        ];
        var missing = services.filter(function (s) {
            return !mapped[s];
        });
        missing.length === 0
            ? ok('all ' + services.length + ' services mapped')
            : bad('unmapped services: ' + missing.join(', '));
    }

    out.push('Incidents currently in the workflow:');
    var agg = new GlideAggregate('incident');
    agg.addNotNullQuery('u_alert_stage');
    agg.groupBy('u_alert_stage');
    agg.addAggregate('COUNT');
    agg.query();
    var any = false;
    while (agg.next()) {
        any = true;
        note(agg.getValue('u_alert_stage') + ': ' + agg.getAggregate('COUNT'));
    }
    if (!any) {
        note('none');
    }

    gs.print('ALERT Workflow v1 verification\n' + out.join('\n') +
        '\n\n' + (problems === 0 ? 'No problems found.' : problems + ' item(s) need attention.'));
})();
