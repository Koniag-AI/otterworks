class IncidentEventPublisher
  class << self
    def publish(event:, incident:, metadata: {})
      payload = build_payload(event, incident, metadata)

      if sns_configured?
        publish_to_sns(payload)
      else
        log_event(payload)
      end
    end

    def incident_created(incident, metadata: {})
      publish(event: 'incident.created', incident: incident, metadata: metadata)
    end

    def incident_resolved(incident, metadata: {})
      publish(event: 'incident.resolved', incident: incident, metadata: metadata)
    end

    def incident_closed(incident, metadata: {})
      publish(event: 'incident.closed', incident: incident, metadata: metadata)
    end

    def devin_session_started(incident, metadata: {})
      publish(event: 'incident.devin_session_started', incident: incident, metadata: metadata)
    end

    def devin_session_completed(incident, metadata: {})
      publish(event: 'incident.devin_session_completed', incident: incident, metadata: metadata)
    end

    private

    def build_payload(event, incident, metadata)
      {
        event: event,
        timestamp: Time.current.iso8601,
        incident: {
          id: incident.id,
          title: incident.title,
          severity: incident.severity,
          status: incident.status,
          source: incident.source,
          affected_service: incident.affected_service,
          devin_session_id: incident.devin_session_id,
          devin_session_status: incident.devin_session_status,
          servicenow_number: incident.servicenow_number
        },
        metadata: metadata
      }
    end

    def sns_configured?
      ENV['AWS_SNS_TOPIC_ARN'].present?
    end

    def publish_to_sns(payload)
      require 'aws-sdk-sns' unless defined?(Aws::SNS)

      topic_arn = ENV.fetch('AWS_SNS_TOPIC_ARN', nil)
      endpoint = ENV.fetch('SNS_ENDPOINT', nil)

      unless topic_arn
        Rails.logger.info("IncidentEventPublisher: SNS topic ARN not configured, logging event instead")
        return log_event(payload)
      end

      client_opts = { region: ENV.fetch('AWS_REGION', 'us-east-1') }
      client_opts[:endpoint] = endpoint if endpoint

      begin
        client = Aws::SNS::Client.new(client_opts)
        client.publish(
          topic_arn: topic_arn,
          message: payload.to_json,
          subject: "OtterWorks: #{payload[:event]}"
        )
        Rails.logger.info("IncidentEventPublisher: published #{payload[:event]} for incident #{payload[:incident][:id]}")
      rescue StandardError => e
        Rails.logger.error("IncidentEventPublisher: SNS publish failed: #{e.message}")
        log_event(payload)
      end
    rescue LoadError
      Rails.logger.warn("IncidentEventPublisher: aws-sdk-sns not available, logging event")
      log_event(payload)
    end

    def log_event(payload)
      Rails.logger.info("IncidentEvent: #{payload.to_json}")
    end
  end
end
