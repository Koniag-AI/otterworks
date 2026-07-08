#!/usr/bin/env python3
"""
End-to-end test for the ServiceNow ↔ Devin Automations webhook integration.

Tests the full callback loop that the Devin playbook performs:
1. Creates a test incident in ServiceNow
2. Simulates the work note callback that a Devin session would post
3. Verifies the work note appears on the incident
4. Cleans up by closing the test incident

This validates the ServiceNow credentials and the callback flow described
in the playbook — the same curl commands the Devin session will execute.

Usage:
  # Uses SERVICENOW_INSTANCE_URL, SERVICENOW_USERNAME, SERVICENOW_PASSWORD env vars:
  python3 test_webhook_e2e.py

  # Or pass credentials explicitly:
  python3 test_webhook_e2e.py \
    --instance https://dev12345.service-now.com \
    --username admin \
    --password 'secret'
"""

import argparse
import base64
import json
import logging
import os
import sys
import time
from urllib import request as urllib_request
from urllib.error import HTTPError, URLError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger(__name__)

TEST_PREFIX = "[E2E-Test]"


def snow_request(instance_url, username, password, method, path, body=None):
    """Make an authenticated ServiceNow REST API request."""
    url = f"{instance_url.rstrip('/')}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib_request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")

    credentials = f"{username}:{password}"
    encoded = base64.b64encode(credentials.encode()).decode()
    req.add_header("Authorization", f"Basic {encoded}")

    try:
        with urllib_request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode())
    except HTTPError as e:
        body_text = e.read().decode()
        log.error("HTTP %d from %s: %s", e.code, url, body_text[:500])
        return e.code, {"error": body_text}
    except URLError as e:
        log.error("Connection failed to %s: %s", url, e.reason)
        return 0, {"error": str(e.reason)}


def create_test_incident(instance_url, username, password):
    """Create a test incident in ServiceNow."""
    log.info("Creating test incident in ServiceNow...")
    status, data = snow_request(
        instance_url, username, password, "POST",
        "/api/now/table/incident",
        {
            "short_description": f"{TEST_PREFIX} Search indexing failure in search-service",
            "description": (
                f"{TEST_PREFIX} E2E test incident for Devin Automations webhook integration. "
                "Users report search results are stale after bulk document uploads."
            ),
            "category": "Software",
            "impact": "1",
            "urgency": "1",
            "cmdb_ci": "search-service",
            "assignment_group": "Platform Engineering",
        },
    )
    if status not in (200, 201):
        log.error("Failed to create incident: %d %s", status, data)
        return None

    result = data.get("result", {})
    sys_id = result.get("sys_id")
    number = result.get("number")
    log.info("Created incident %s (sys_id=%s)", number, sys_id)
    return {"sys_id": sys_id, "number": number}


def build_webhook_payload(incident_info):
    """Build the same payload shape that ServiceNow Business Rule would send."""
    return {
        "source": "servicenow",
        "incident": {
            "sys_id": incident_info["sys_id"],
            "number": incident_info["number"],
            "short_description": f"{TEST_PREFIX} Search indexing failure in search-service",
            "description": (
                f"{TEST_PREFIX} E2E test incident for Devin Automations webhook integration. "
                "Users report search results are stale after bulk document uploads."
            ),
            "priority": "1",
            "category": "Software",
            "subcategory": "Application",
            "assignment_group": "Platform Engineering",
            "assigned_to": "admin",
            "caller_id": "admin",
            "cmdb_ci": "search-service",
            "state": "1",
            "sys_created_on": time.strftime("%Y-%m-%d %H:%M:%S"),
        },
    }


def post_work_note(instance_url, username, password, sys_id, message):
    """Simulate the work note callback that the Devin playbook performs."""
    log.info("Posting work note to incident %s...", sys_id)
    status, data = snow_request(
        instance_url, username, password, "PATCH",
        f"/api/now/table/incident/{sys_id}",
        {"work_notes": message},
    )
    if status not in (200, 201):
        log.error("Failed to post work note: %d %s", status, data)
        return False
    log.info("Work note posted successfully")
    return True


def verify_work_note(instance_url, username, password, sys_id, expected_substring):
    """Verify the work note was added by querying the journal field table.

    ServiceNow's incident GET does not return work_notes as readable text.
    The sys_journal_field table stores individual journal entries and is
    the reliable way to verify that a work note was persisted.
    """
    log.info("Verifying work note on incident %s via journal entries...", sys_id)
    query = f"element_id={sys_id}^element=work_notes"
    status, data = snow_request(
        instance_url, username, password, "GET",
        f"/api/now/table/sys_journal_field?sysparm_query={query}"
        f"&sysparm_fields=value&sysparm_limit=10",
    )
    if status != 200:
        log.error("Failed to read journal entries: %d %s", status, data)
        return False

    entries = data.get("result", [])
    for entry in entries:
        if expected_substring in entry.get("value", ""):
            log.info("Work note verified — journal entry contains expected content")
            return True

    log.warning(
        "No journal entry contains expected substring: %s (found %d entries)",
        expected_substring,
        len(entries),
    )
    return False


def resolve_test_incident(instance_url, username, password, sys_id):
    """Simulate the resolve callback that the Devin playbook performs."""
    log.info("Resolving test incident %s...", sys_id)
    status, data = snow_request(
        instance_url, username, password, "PATCH",
        f"/api/now/table/incident/{sys_id}",
        {
            "work_notes": (
                f"{TEST_PREFIX} Devin AI Remediation Complete\n"
                "PR: https://github.com/Cognition-Partner-Workshops/otterworks/pull/999\n"
                "Summary: Fixed search indexing by adding bulk reindex trigger\n"
                "Session: https://app.devin.ai/sessions/test-session-id"
            ),
            "state": "6",
            "close_code": "Solved (Permanently)",
            "close_notes": f"{TEST_PREFIX} Auto-resolved by Devin AI (E2E test)",
        },
    )
    if status not in (200, 201):
        log.error("Failed to resolve incident: %d %s", status, data)
        return False
    log.info("Incident resolved successfully")
    return True


def verify_resolution(instance_url, username, password, sys_id):
    """Confirm the incident is in resolved state."""
    status, data = snow_request(
        instance_url, username, password, "GET",
        f"/api/now/table/incident/{sys_id}?sysparm_fields=state,close_code,close_notes",
    )
    if status != 200:
        log.error("Failed to read incident state: %d", status)
        return False

    result = data.get("result", {})
    state = result.get("state")
    if state == "6":
        log.info("Incident confirmed resolved (state=6)")
        return True

    log.warning("Incident state is %s, expected 6 (Resolved)", state)
    return False


def main():
    parser = argparse.ArgumentParser(description="E2E test for ServiceNow webhook integration")
    parser.add_argument("--instance", default=os.environ.get("SERVICENOW_INSTANCE_URL", ""))
    parser.add_argument("--username", default=os.environ.get("SERVICENOW_USERNAME", ""))
    parser.add_argument("--password", default=os.environ.get("SERVICENOW_PASSWORD", ""))
    parser.add_argument("--skip-cleanup", action="store_true", help="Leave the test incident open")
    args = parser.parse_args()

    if not all([args.instance, args.username, args.password]):
        log.error(
            "Missing ServiceNow credentials. Set SERVICENOW_INSTANCE_URL, "
            "SERVICENOW_USERNAME, and SERVICENOW_PASSWORD environment variables, "
            "or pass --instance, --username, --password."
        )
        sys.exit(1)

    results = {}

    # 1. Create test incident
    incident = create_test_incident(args.instance, args.username, args.password)
    if not incident:
        log.error("FAIL: Could not create test incident")
        sys.exit(1)
    results["create_incident"] = True

    sys_id = incident["sys_id"]
    number = incident["number"]

    # 2. Build the webhook payload (what ServiceNow Business Rule would send)
    payload = build_webhook_payload(incident)
    log.info("Webhook payload built for %s:\n%s", number, json.dumps(payload, indent=2))
    results["build_payload"] = True

    # 3. Post a work note (simulating what the Devin session does via the playbook)
    work_note_marker = f"[Devin AI Auto-Remediation] Session started for {number}"
    work_note_ok = post_work_note(
        args.instance, args.username, args.password, sys_id,
        work_note_marker,
    )
    results["post_work_note"] = work_note_ok

    # 4. Verify the work note appears on the incident
    if work_note_ok:
        time.sleep(2)
        verify_ok = verify_work_note(
            args.instance, args.username, args.password, sys_id,
            "Devin AI Auto-Remediation",
        )
        results["verify_work_note"] = verify_ok
    else:
        results["verify_work_note"] = False

    # 5. Resolve the incident (simulating end-of-session callback from the playbook)
    if args.skip_cleanup:
        log.info("Skipping cleanup (--skip-cleanup was passed)")
    else:
        resolve_ok = resolve_test_incident(
            args.instance, args.username, args.password, sys_id,
        )
        results["resolve_incident"] = resolve_ok

        # 6. Verify resolution
        if resolve_ok:
            time.sleep(2)
            resolution_ok = verify_resolution(
                args.instance, args.username, args.password, sys_id,
            )
            results["verify_resolution"] = resolution_ok
        else:
            results["verify_resolution"] = False

    # Summary
    print("\n" + "=" * 60)
    print("E2E TEST RESULTS")
    print("=" * 60)
    all_passed = True
    for test_name, passed in results.items():
        status_str = "PASS" if passed else "FAIL"
        if not passed:
            all_passed = False
        print(f"  {test_name:30s} {status_str}")
    print("=" * 60)
    print(f"  {'OVERALL':30s} {'PASS' if all_passed else 'FAIL'}")
    print(f"  Test incident: {number} (sys_id={sys_id})")
    print("=" * 60)

    if not all_passed:
        sys.exit(1)

    log.info("All E2E tests passed")


if __name__ == "__main__":
    main()
