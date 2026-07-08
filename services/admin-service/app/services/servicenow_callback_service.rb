require 'net/http'
require 'json'
require 'uri'

class ServicenowCallbackService
  class << self
    def post_work_note(incident:, message:)
      return unless callable?(incident)

      update_incident(incident, work_notes: message)
    end

    def resolve_incident(incident:, pr_url: nil, summary: nil)
      return unless callable?(incident)

      work_note = "Devin AI Remediation Complete\n"
      work_note += "PR: #{pr_url}\n" if pr_url
      work_note += "Summary: #{summary}\n" if summary
      work_note += "Session: #{incident.devin_session_url}" if incident.devin_session_url

      update_incident(
        incident,
        work_notes: work_note,
        state: '6',
        close_code: 'Solved (Permanently)',
        close_notes: "Auto-resolved by Devin AI. #{pr_url ? "PR: #{pr_url}" : ''}"
      )
    end

    def post_update(incident:, status:, pr_url: nil, session_url: nil, summary: nil)
      return unless callable?(incident)

      work_note = "Devin AI Update — Status: #{status}\n"
      work_note += "PR: #{pr_url}\n" if pr_url
      work_note += "Session: #{session_url}\n" if session_url
      work_note += "Details: #{summary}" if summary

      update_incident(incident, work_notes: work_note)
    end

    private

    def callable?(incident)
      return false unless incident.servicenow_sys_id.present?

      instance_url = servicenow_instance_url(incident)
      credentials_present = ENV['SERVICENOW_INSTANCE_URL'].present? || instance_url.present?
      client_id_present = ENV['SERVICENOW_CLIENT_ID'].present?
      client_secret_present = ENV['SERVICENOW_CLIENT_SECRET'].present?

      unless credentials_present && client_id_present && client_secret_present
        Rails.logger.info(
          "ServiceNow callback skipped for incident #{incident.id}: " \
          "missing credentials (instance=#{credentials_present}, " \
          "client_id=#{client_id_present}, client_secret=#{client_secret_present})"
        )
        return false
      end

      true
    end

    def servicenow_instance_url(incident)
      incident.servicenow_instance_url.presence || ENV.fetch('SERVICENOW_INSTANCE_URL', nil)
    end

    def fetch_oauth_token(base_url)
      cache_key = "servicenow_oauth_token:#{base_url}"
      cached = Rails.cache.read(cache_key)
      return cached if cached.present?

      token_uri = URI("#{base_url.chomp('/')}/oauth_token.do")
      request = Net::HTTP::Post.new(token_uri)
      request['Content-Type'] = 'application/x-www-form-urlencoded'
      request.body = URI.encode_www_form(
        grant_type: 'client_credentials',
        client_id: ENV.fetch('SERVICENOW_CLIENT_ID'),
        client_secret: ENV.fetch('SERVICENOW_CLIENT_SECRET')
      )

      http = Net::HTTP.new(token_uri.host, token_uri.port)
      http.use_ssl = token_uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 15

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error("ServiceNow OAuth token request failed: #{response.code} #{response.body}")
        raise "ServiceNow OAuth token request failed: #{response.code}"
      end

      body = JSON.parse(response.body)
      access_token = body['access_token']
      expires_in = (body['expires_in'] || 1800).to_i

      Rails.cache.write(cache_key, access_token, expires_in: [expires_in - 60, 60].max)
      access_token
    end

    def invalidate_oauth_token(base_url = nil)
      if base_url
        Rails.cache.delete("servicenow_oauth_token:#{base_url}")
      else
        Rails.cache.delete_matched('servicenow_oauth_token:*')
      end
    end

    def update_incident(incident, fields)
      base_url = servicenow_instance_url(incident)
      return unless base_url

      uri = URI("#{base_url.chomp('/')}/api/now/table/incident/#{incident.servicenow_sys_id}")

      2.times do |attempt|
        token = fetch_oauth_token(base_url)
        request = Net::HTTP::Patch.new(uri)
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'
        request['Authorization'] = "Bearer #{token}"
        request.body = fields.to_json

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 10
        http.read_timeout = 15

        response = http.request(request)

        if response.code == '401' && attempt == 0
          Rails.logger.warn("ServiceNow API returned 401 — refreshing OAuth token and retrying")
          invalidate_oauth_token(base_url)
          next
        end

        unless response.is_a?(Net::HTTPSuccess)
          Rails.logger.error(
            "ServiceNow callback failed for #{incident.servicenow_number}: " \
            "#{response.code} #{response.body}"
          )
        end

        return response
      end
    rescue StandardError => e
      Rails.logger.error("ServiceNow callback error: #{e.message}")
      nil
    end
  end
end
