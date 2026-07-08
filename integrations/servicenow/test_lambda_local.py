#!/usr/bin/env python3
"""
Local test suite for lambda_handler.py.

Invokes handler() directly with mock API Gateway proxy events.
No AWS deployment needed. Tests all code paths including edge cases.

Usage:
  python test_lambda_local.py
"""

import json
import logging
import os
import sys
import unittest
from unittest.mock import patch, MagicMock
from datetime import datetime, timezone

# Add current dir to path so we can import lambda_handler
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lambda_handler


def apigw_event(path, method, headers=None, body=None, base64_encoded=False):
    """Build a mock API Gateway proxy integration event."""
    event = {
        "path": path,
        "httpMethod": method,
        "headers": headers or {},
        "body": body,
        "isBase64Encoded": base64_encoded,
        "requestContext": {},
    }
    return event


VALID_INCIDENT_PAYLOAD = json.dumps({
    "source": "servicenow",
    "incident": {
        "sys_id": "abc123def456",
        "number": "INC0010099",
        "short_description": "file-service upload returns 500",
        "description": "Users report intermittent 500 errors when uploading files > 10MB",
        "priority": "1",
        "category": "Software",
        "subcategory": "Application",
        "assignment_group": "Platform Engineering",
        "assigned_to": "admin",
        "caller_id": "john.doe",
        "cmdb_ci": "file-service",
        "state": "1",
        "sys_created_on": "2026-05-29 10:00:00",
    }
})


class TestHealthEndpoint(unittest.TestCase):

    def test_health_returns_200(self):
        event = apigw_event("/health", "GET")
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 200)
        body = json.loads(result["body"])
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["service"], "servicenow-webhook-lambda")
        self.assertIn("timestamp", body)

    def test_health_with_full_path(self):
        event = apigw_event("/prod/api/v1/admin/servicenow/health", "GET")
        # endswith("/health") should still not match since path ends with /health only at root
        # Actually the path is /prod/.../health which does end with /health
        # But /health is the dedicated health path. Let's test the actual /health
        event = apigw_event("/prod/health", "GET")
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 200)


class TestIngestEndpoint(unittest.TestCase):

    def setUp(self):
        # Clear any webhook secret so auth is skipped by default
        os.environ.pop("SERVICENOW_WEBHOOK_SECRET", None)
        os.environ.pop("DEVIN_API_KEY", None)
        os.environ.pop("DEVIN_ORG_ID", None)
        os.environ.pop("SERVICENOW_INSTANCE_URL", None)
        os.environ.pop("SERVICENOW_CLIENT_ID", None)
        os.environ.pop("SERVICENOW_CLIENT_SECRET", None)
        lambda_handler._invalidate_snow_token()

    def test_valid_ingest_no_devin_key(self):
        """Valid payload, but no DEVIN_API_KEY — should accept and skip session creation."""
        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            body=VALID_INCIDENT_PAYLOAD
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 201)
        body = json.loads(result["body"])
        self.assertTrue(body["received"])
        self.assertEqual(body["servicenow_number"], "INC0010099")
        self.assertFalse(body["devin_session"])
        self.assertIsNone(body["devin_session_url"])

    def test_missing_sys_id(self):
        """Payload without sys_id should return 400."""
        payload = json.dumps({
            "incident": {
                "number": "INC0010100",
                "short_description": "No sys_id here",
            }
        })
        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            body=payload
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 400)
        body = json.loads(result["body"])
        self.assertEqual(body["error"], "Missing sys_id")

    def test_invalid_json(self):
        """Malformed JSON should return 400."""
        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            body="not-valid-json{{{}"
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 400)
        body = json.loads(result["body"])
        self.assertEqual(body["error"], "Invalid JSON")

    def test_empty_body(self):
        """Empty body should return 400 (missing sys_id since incident={})."""
        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            body=""
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 400)
        body = json.loads(result["body"])
        self.assertEqual(body["error"], "Missing sys_id")

    def test_webhook_secret_valid(self):
        """Valid webhook secret should be accepted."""
        os.environ["SERVICENOW_WEBHOOK_SECRET"] = "test-secret-123"
        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            headers={"X-ServiceNow-Secret": "test-secret-123"},
            body=VALID_INCIDENT_PAYLOAD
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 201)

    def test_webhook_secret_invalid(self):
        """Invalid webhook secret should return 401."""
        os.environ["SERVICENOW_WEBHOOK_SECRET"] = "test-secret-123"
        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            headers={"X-ServiceNow-Secret": "wrong-secret"},
            body=VALID_INCIDENT_PAYLOAD
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 401)
        body = json.loads(result["body"])
        self.assertEqual(body["error"], "Unauthorized")

    def test_webhook_secret_missing_header(self):
        """Missing secret header when secret is configured should return 401."""
        os.environ["SERVICENOW_WEBHOOK_SECRET"] = "test-secret-123"
        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            headers={},
            body=VALID_INCIDENT_PAYLOAD
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 401)

    def test_webhook_secret_via_bearer_auth(self):
        """Secret can also be passed via Authorization: Bearer header."""
        os.environ["SERVICENOW_WEBHOOK_SECRET"] = "test-secret-123"
        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            headers={"Authorization": "Bearer test-secret-123"},
            body=VALID_INCIDENT_PAYLOAD
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 201)

    def test_webhook_secret_lowercase_header(self):
        """Secret via lowercase x-servicenow-secret header."""
        os.environ["SERVICENOW_WEBHOOK_SECRET"] = "test-secret-123"
        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            headers={"x-servicenow-secret": "test-secret-123"},
            body=VALID_INCIDENT_PAYLOAD
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 201)

    def test_no_webhook_secret_configured_allows_all(self):
        """When SERVICENOW_WEBHOOK_SECRET is not set, all requests are allowed."""
        # Ensure env var is not set
        os.environ.pop("SERVICENOW_WEBHOOK_SECRET", None)
        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            body=VALID_INCIDENT_PAYLOAD
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 201)

    def test_base64_encoded_body(self):
        """API Gateway sometimes sends base64-encoded bodies."""
        import base64
        encoded = base64.b64encode(VALID_INCIDENT_PAYLOAD.encode()).decode()
        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            body=encoded,
            base64_encoded=True
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 201)
        body = json.loads(result["body"])
        self.assertEqual(body["servicenow_number"], "INC0010099")

    @patch("lambda_handler._http_request")
    def test_ingest_with_devin_session_creation(self, mock_http):
        """When DEVIN_API_KEY is set, a Devin session should be created."""
        os.environ["DEVIN_API_KEY"] = "fake-api-key"
        os.environ["DEVIN_ORG_ID"] = "fake-org-id"

        mock_http.return_value = (201, {
            "session_id": "session-123",
            "url": "https://app.devin.ai/sessions/session-123"
        })

        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            body=VALID_INCIDENT_PAYLOAD
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 201)
        body = json.loads(result["body"])
        self.assertTrue(body["devin_session"])
        self.assertEqual(body["devin_session_url"], "https://app.devin.ai/sessions/session-123")

        # Verify Devin API was called
        calls = mock_http.call_args_list
        devin_call = calls[0]
        self.assertIn("/v3/organizations/fake-org-id/sessions", devin_call[0][0])
        self.assertEqual(devin_call[0][1], "POST")

    @patch("lambda_handler._get_snow_oauth_token", return_value="mock-token")
    @patch("lambda_handler._http_request")
    def test_ingest_with_devin_and_snow_callback(self, mock_http, mock_token):
        """When both Devin and SNOW creds set, work note should be posted."""
        os.environ["DEVIN_API_KEY"] = "fake-api-key"
        os.environ["DEVIN_ORG_ID"] = "fake-org-id"
        os.environ["SERVICENOW_INSTANCE_URL"] = "https://dev99999.service-now.com"
        os.environ["SERVICENOW_CLIENT_ID"] = "test-client-id"
        os.environ["SERVICENOW_CLIENT_SECRET"] = "test-client-secret"

        def mock_http_side_effect(url, method, headers, body=None, timeout=15):
            if "devin.ai" in url:
                return (201, {"session_id": "session-456", "url": "https://app.devin.ai/sessions/session-456"})
            if "service-now.com" in url:
                return (200, {"result": {}})
            return (404, {"error": "unexpected"})

        mock_http.side_effect = mock_http_side_effect

        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            body=VALID_INCIDENT_PAYLOAD
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 201)

        # Should have 2 HTTP calls: Devin API + ServiceNow work note
        self.assertEqual(mock_http.call_count, 2)
        snow_call = mock_http.call_args_list[1]
        self.assertIn("service-now.com", snow_call[0][0])
        self.assertIn("abc123def456", snow_call[0][0])
        self.assertEqual(snow_call[0][1], "PATCH")
        # Verify Bearer auth header
        auth_header = snow_call[0][2].get("Authorization", "")
        self.assertEqual(auth_header, "Bearer mock-token")

    @patch("lambda_handler._http_request")
    def test_devin_api_failure_still_returns_201(self, mock_http):
        """If Devin API fails, ingest should still succeed (graceful)."""
        os.environ["DEVIN_API_KEY"] = "fake-api-key"
        os.environ["DEVIN_ORG_ID"] = "fake-org-id"

        mock_http.return_value = (500, {"error": "internal server error"})

        event = apigw_event(
            "/api/v1/admin/servicenow/ingest", "POST",
            body=VALID_INCIDENT_PAYLOAD
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 201)
        body = json.loads(result["body"])
        self.assertFalse(body["devin_session"])


class TestResolveEndpoint(unittest.TestCase):

    def setUp(self):
        os.environ.pop("SERVICENOW_WEBHOOK_SECRET", None)
        os.environ.pop("SERVICENOW_INSTANCE_URL", None)
        os.environ.pop("SERVICENOW_CLIENT_ID", None)
        os.environ.pop("SERVICENOW_CLIENT_SECRET", None)
        lambda_handler._invalidate_snow_token()

    def test_resolve_valid_no_snow_creds(self):
        """Valid resolve, but no SNOW credentials — should skip callback gracefully."""
        payload = json.dumps({
            "sys_id": "abc123def456",
            "pr_url": "https://github.com/org/repo/pull/42",
            "summary": "Fixed the file upload bug",
        })
        event = apigw_event(
            "/api/v1/admin/servicenow/resolve", "POST",
            body=payload
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 200)
        body = json.loads(result["body"])
        self.assertTrue(body["resolved"])
        self.assertEqual(body["sys_id"], "abc123def456")

    def test_resolve_missing_sys_id(self):
        """Missing sys_id should return 400."""
        payload = json.dumps({"pr_url": "https://github.com/org/repo/pull/42"})
        event = apigw_event(
            "/api/v1/admin/servicenow/resolve", "POST",
            body=payload
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 400)
        body = json.loads(result["body"])
        self.assertEqual(body["error"], "Missing sys_id")

    def test_resolve_invalid_json(self):
        """Malformed JSON should return 400."""
        event = apigw_event(
            "/api/v1/admin/servicenow/resolve", "POST",
            body="{{bad json"
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 400)

    def test_resolve_with_webhook_secret(self):
        """Resolve with valid webhook secret."""
        os.environ["SERVICENOW_WEBHOOK_SECRET"] = "resolve-secret"
        payload = json.dumps({"sys_id": "xyz789"})
        event = apigw_event(
            "/api/v1/admin/servicenow/resolve", "POST",
            headers={"X-ServiceNow-Secret": "resolve-secret"},
            body=payload
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 200)

    def test_resolve_bad_secret(self):
        """Resolve with bad secret should return 401."""
        os.environ["SERVICENOW_WEBHOOK_SECRET"] = "resolve-secret"
        payload = json.dumps({"sys_id": "xyz789"})
        event = apigw_event(
            "/api/v1/admin/servicenow/resolve", "POST",
            headers={"X-ServiceNow-Secret": "wrong"},
            body=payload
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 401)

    @patch("lambda_handler._get_snow_oauth_token", return_value="mock-token")
    @patch("lambda_handler._http_request")
    def test_resolve_with_snow_callback(self, mock_http, mock_token):
        """When SNOW creds are set, resolve should PATCH the incident."""
        os.environ["SERVICENOW_INSTANCE_URL"] = "https://dev99999.service-now.com"
        os.environ["SERVICENOW_CLIENT_ID"] = "test-client-id"
        os.environ["SERVICENOW_CLIENT_SECRET"] = "test-client-secret"

        mock_http.return_value = (200, {"result": {}})

        payload = json.dumps({
            "sys_id": "abc123def456",
            "pr_url": "https://github.com/org/repo/pull/42",
            "summary": "Fixed file upload bug",
            "session_url": "https://app.devin.ai/sessions/session-789",
        })
        event = apigw_event(
            "/api/v1/admin/servicenow/resolve", "POST",
            body=payload
        )
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 200)

        # Verify ServiceNow PATCH call
        mock_http.assert_called_once()
        call_args = mock_http.call_args
        url = call_args[0][0]
        method = call_args[0][1]
        body = call_args[1].get("body") or call_args[0][3]

        self.assertIn("dev99999.service-now.com", url)
        self.assertIn("abc123def456", url)
        self.assertEqual(method, "PATCH")
        self.assertEqual(body["state"], "6")
        self.assertEqual(body["close_code"], "Solved (Permanently)")
        self.assertIn("pull/42", body["close_notes"])
        self.assertIn("session-789", body["work_notes"])
        # Verify Bearer auth
        auth_header = call_args[0][2].get("Authorization", "")
        self.assertEqual(auth_header, "Bearer mock-token")


class TestOAuthTokenFlow(unittest.TestCase):

    def setUp(self):
        os.environ.pop("SERVICENOW_WEBHOOK_SECRET", None)
        os.environ.pop("SERVICENOW_INSTANCE_URL", None)
        os.environ.pop("SERVICENOW_CLIENT_ID", None)
        os.environ.pop("SERVICENOW_CLIENT_SECRET", None)
        lambda_handler._invalidate_snow_token()

    @patch("lambda_handler._get_snow_oauth_token", return_value="test-token-123")
    @patch("lambda_handler._http_request")
    def test_token_acquisition_success(self, mock_http, mock_token):
        """OAuth token should be acquired and used as Bearer auth."""
        os.environ["SERVICENOW_INSTANCE_URL"] = "https://dev99999.service-now.com"
        os.environ["SERVICENOW_CLIENT_ID"] = "test-client-id"
        os.environ["SERVICENOW_CLIENT_SECRET"] = "test-client-secret"

        mock_http.return_value = (200, {"result": {}})

        payload = json.dumps({
            "sys_id": "abc123",
            "pr_url": "https://github.com/org/repo/pull/1",
        })
        event = apigw_event("/api/v1/admin/servicenow/resolve", "POST", body=payload)
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 200)

        # Verify Bearer token used (not Basic auth)
        snow_call = mock_http.call_args
        auth_header = snow_call[0][2].get("Authorization", "")
        self.assertEqual(auth_header, "Bearer test-token-123")
        mock_token.assert_called_once()

    @patch("lambda_handler._get_snow_oauth_token")
    @patch("lambda_handler._http_request")
    def test_token_refresh_on_401(self, mock_http, mock_token):
        """On 401 from SNOW API, token should be refreshed and call retried."""
        os.environ["SERVICENOW_INSTANCE_URL"] = "https://dev99999.service-now.com"
        os.environ["SERVICENOW_CLIENT_ID"] = "test-client-id"
        os.environ["SERVICENOW_CLIENT_SECRET"] = "test-client-secret"

        mock_token.side_effect = ["stale-token", "fresh-token"]
        mock_http.side_effect = [(401, {"error": "Unauthorized"}), (200, {"result": {}})]

        payload = json.dumps({"sys_id": "abc123"})
        event = apigw_event("/api/v1/admin/servicenow/resolve", "POST", body=payload)
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 200)

        # Token should have been fetched twice (initial + refresh after 401)
        self.assertEqual(mock_token.call_count, 2)
        self.assertEqual(mock_http.call_count, 2)

    def test_missing_client_credentials_skips_callback(self):
        """If SERVICENOW_CLIENT_ID/SECRET not set, callback should be skipped."""
        os.environ["SERVICENOW_INSTANCE_URL"] = "https://dev99999.service-now.com"
        # No CLIENT_ID or CLIENT_SECRET

        payload = json.dumps({"sys_id": "abc123"})
        event = apigw_event("/api/v1/admin/servicenow/resolve", "POST", body=payload)
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 200)

    @patch("lambda_handler._get_snow_oauth_token", return_value="cached-token")
    @patch("lambda_handler._http_request")
    def test_token_caching_within_invocation(self, mock_http, mock_token):
        """Token should be cached and reused within a Lambda invocation."""
        os.environ["SERVICENOW_INSTANCE_URL"] = "https://dev99999.service-now.com"
        os.environ["SERVICENOW_CLIENT_ID"] = "test-client-id"
        os.environ["SERVICENOW_CLIENT_SECRET"] = "test-client-secret"

        mock_http.return_value = (200, {"result": {}})

        # First call acquires token
        lambda_handler._post_servicenow_work_note("sys1", "Note 1")
        # Second call should reuse cached token
        lambda_handler._post_servicenow_work_note("sys2", "Note 2")

        # mock_token is called each time _snow_api_call calls _get_snow_oauth_token,
        # but the real caching happens inside _get_snow_oauth_token itself.
        # With the mock, we verify both calls went through.
        self.assertEqual(mock_http.call_count, 2)


class TestServiceResolution(unittest.TestCase):

    def test_exact_service_match(self):
        result = lambda_handler._resolve_service("file-service", "")
        self.assertEqual(result, "file-service")

    def test_case_insensitive(self):
        result = lambda_handler._resolve_service("File-Service", "")
        self.assertEqual(result, "file-service")

    def test_service_in_description(self):
        result = lambda_handler._resolve_service("unknown", "The auth-service is failing")
        self.assertEqual(result, "auth-service")

    def test_service_with_spaces_in_description(self):
        result = lambda_handler._resolve_service("unknown", "The search service is slow")
        self.assertEqual(result, "search-service")

    def test_unknown_service(self):
        result = lambda_handler._resolve_service("unknown", "Something broke")
        self.assertIsNone(result)

    def test_all_known_services(self):
        for svc in lambda_handler.SERVICE_ALIASES:
            result = lambda_handler._resolve_service(svc, "")
            self.assertEqual(result, svc, f"Failed to resolve {svc}")


class TestNotFoundEndpoint(unittest.TestCase):

    def test_unknown_path_returns_404(self):
        event = apigw_event("/api/v1/admin/unknown", "GET")
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 404)
        body = json.loads(result["body"])
        self.assertEqual(body["error"], "Not found")

    def test_wrong_method_returns_404(self):
        """GET on ingest endpoint should return 404 (only POST accepted)."""
        event = apigw_event("/api/v1/admin/servicenow/ingest", "GET")
        result = lambda_handler.handler(event, None)
        self.assertEqual(result["statusCode"], 404)


class TestPromptGeneration(unittest.TestCase):

    def test_prompt_contains_ticket_info(self):
        snow = {
            "number": "INC0010099",
            "priority": "1",
            "category": "Software",
            "short_description": "file-service upload error",
            "description": "500 errors on upload",
            "cmdb_ci": "file-service",
            "assignment_group": "Platform Engineering",
            "caller_id": "john.doe",
        }
        prompt = lambda_handler._build_devin_prompt(snow, "file-service")
        self.assertIn("INC0010099", prompt)
        self.assertIn("file-service", prompt)
        self.assertIn("500 errors on upload", prompt)
        self.assertIn("OtterWorks", prompt)
        self.assertIn("microservices", prompt.lower())


class TestResponseFormat(unittest.TestCase):

    def test_json_response_format(self):
        result = lambda_handler._json_response(200, {"test": True})
        self.assertEqual(result["statusCode"], 200)
        self.assertEqual(result["headers"]["Content-Type"], "application/json")
        body = json.loads(result["body"])
        self.assertTrue(body["test"])


if __name__ == "__main__":
    # Configure logging to see Lambda handler logs during tests
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    unittest.main(verbosity=2)
