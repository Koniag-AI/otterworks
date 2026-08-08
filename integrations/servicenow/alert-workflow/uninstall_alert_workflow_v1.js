/**
 * ALERT Workflow v1 - uninstall (ServiceNow background script)
 *
 * Backing out the update set is the preferred rollback. This script is the manual
 * equivalent for an instance where the update set is not available.
 *
 * By default it only DEACTIVATES the business rules and clears the webhook
 * properties, which stops all automation while leaving the data intact. Set
 * DROP_FIELDS to true to also delete the u_* fields and their data - that is
 * destructive and irreversible.
 */
(function uninstallAlertWorkflowV1() {
    var DROP_FIELDS = false;
    var out = [];

    ['ALERT: start triage',
        'ALERT: resume triage on answer',
        'ALERT: ask requester for information',
        'ALERT: request owner approval',
        'ALERT: start development on approval',
        'ALERT: apply owner approval decision'
    ].forEach(function (name) {
        var gr = new GlideRecord('sys_script');
        gr.addQuery('name', name);
        gr.query();
        while (gr.next()) {
            gr.setValue('active', false);
            gr.update();
            out.push('deactivated business rule: ' + name);
        }
    });

    ['alert.workflow.triage_webhook_url', 'alert.workflow.development_webhook_url'].forEach(
        function (name) {
            var gr = new GlideRecord('sys_properties');
            gr.addQuery('name', name);
            gr.query();
            if (gr.next()) {
                gr.setValue('value', '');
                gr.update();
                out.push('cleared property: ' + name);
            }
        }
    );

    if (DROP_FIELDS) {
        ['u_alert_stage', 'u_devin_verdict', 'u_devin_confidence', 'u_affected_service',
            'u_devin_session_url', 'u_devin_findings', 'u_repro_steps', 'u_open_questions',
            'u_pr_url', 'u_harness_execution_url', 'u_automation_hold', 'u_alert_pilot'
        ].forEach(function (element) {
            var choices = new GlideRecord('sys_choice');
            choices.addQuery('name', 'incident');
            choices.addQuery('element', element);
            choices.query();
            choices.deleteMultiple();

            var gr = new GlideRecord('sys_dictionary');
            gr.addQuery('name', 'incident');
            gr.addQuery('element', element);
            gr.query();
            if (gr.next()) {
                gr.deleteRecord();
                out.push('DELETED field and data: ' + element);
            }
        });
    } else {
        out.push('fields left in place (DROP_FIELDS = false)');
    }

    gs.print('ALERT Workflow v1 uninstall\n' + out.join('\n'));
})();
