require 'net/http'
require 'json'
require 'uri'

# Service for interacting with the Devin AI session API.
#
# For ServiceNow incidents, session creation is now handled by the Devin
# Automation (webhook trigger) rather than direct API calls. The
# create_session method is retained for non-ServiceNow flows (Grafana
# alerts, manual incident investigation via admin UI).
class DevinSessionService
  API_HOST = 'https://api.devin.ai'.freeze

  class << self
    def create_session(incident:)
      api_key = ENV.fetch('DEVIN_API_KEY', nil)
      org_id  = ENV.fetch('DEVIN_ORG_ID', nil)
      unless api_key && org_id
        Rails.logger.warn('DEVIN_API_KEY or DEVIN_ORG_ID not set, skipping Devin session creation')
        return nil
      end

      prompt = build_prompt(incident)

      uri = URI("#{API_HOST}/v3/organizations/#{org_id}/sessions")
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{api_key}"
      request['Content-Type'] = 'application/json'
      request.body = { prompt: prompt }.to_json

      response = make_request(uri, request)
      return nil unless response

      body = JSON.parse(response.body)
      {
        session_id: body['session_id'],
        url: body['url']
      }
    rescue StandardError => e
      Rails.logger.error("Devin session creation failed: #{e.message}")
      nil
    end

    def get_session(session_id:)
      api_key = ENV.fetch('DEVIN_API_KEY', nil)
      org_id  = ENV.fetch('DEVIN_ORG_ID', nil)
      return nil unless api_key && org_id && session_id

      uri = URI("#{API_HOST}/v3/organizations/#{org_id}/sessions/#{session_id}")
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{api_key}"

      response = make_request(uri, request)
      return nil unless response

      body = JSON.parse(response.body)
      {
        status: body['status'] || body['status_enum'],
        url: body['url']
      }
    rescue StandardError => e
      Rails.logger.error("Devin session status fetch failed: #{e.message}")
      nil
    end

    private

    def build_prompt(incident)
      servicenow_context = if incident.respond_to?(:source) && incident.source == 'servicenow'
                             <<~SNOW

                               ## ServiceNow Ticket
                               - **Ticket**: #{incident.servicenow_number}
                               - **sys_id**: #{incident.servicenow_sys_id}
                               This incident was auto-created from a ServiceNow bug ticket. After implementing a fix, open a PR. The ServiceNow ticket will be updated automatically with the remediation status and PR link.
                             SNOW
                           else
                             ''
                           end

      <<~PROMPT
        You are investigating an incident in the OtterWorks platform, a collaborative file storage and document editing system (similar to Google Drive + Google Docs) built as a polyglot microservices architecture.

        ## Incident Details
        - **Title**: #{incident.title}
        - **Severity**: #{incident.severity}
        - **Affected Service**: #{incident.affected_service.presence || 'Unknown'}
        - **Description**: #{incident.description}
        #{servicenow_context}
        ## OtterWorks Architecture
        The platform has 11 microservices:
        - API Gateway (Go/Chi, port 8080) - routing, rate limiting, JWT validation
        - Auth Service (Java/Spring Boot, port 8081) - authentication, RBAC
        - File Service (Rust/Actix-Web, port 8082) - file upload/download, S3
        - Document Service (Python/FastAPI, port 8083) - document CRUD, versioning
        - Collaboration Service (Node.js/Socket.io, port 8084) - real-time editing
        - Notification Service (Kotlin/Ktor, port 8086) - event-driven notifications
        - Search Service (Python/Flask, port 8087) - MeiliSearch full-text search
        - Analytics Service (Scala/Akka HTTP, port 8088) - usage analytics
        - Admin Service (Ruby/Rails, port 8089) - admin operations
        - Audit Service (C#/ASP.NET, port 8090) - audit trail
        - Report Service (Java/Spring Boot, port 8091) - report generation

        Services communicate via REST (through API Gateway) and async SNS/SQS events.

        ## Your Task
        Investigate this incident, identify the root cause, and implement a fix. Start by examining the affected service's code and logs. Look for recent changes, error patterns, and configuration issues.
      PROMPT
    end

    def make_request(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 30

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error("Devin API returned #{response.code}: #{response.body}")
        return nil
      end

      response
    end
  end
end
