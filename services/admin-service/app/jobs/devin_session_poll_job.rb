# Polls Devin API for session status updates on active incidents.
#
# ServiceNow-sourced incidents are excluded — their session lifecycle
# is managed by the Devin Automations playbook (which posts work notes
# and resolves incidents directly). This job handles Grafana alerts and
# manually-triggered sessions that still use DevinSessionService.create_session.
class DevinSessionPollJob < ApplicationJob
  queue_as :default

  def perform
    incidents = Incident.where(devin_session_status: 'running')
                        .where.not(devin_session_id: nil)
                        .where.not(source: 'servicenow')

    Rails.logger.info("DevinSessionPollJob: checking #{incidents.count} running session(s) (excluding servicenow)")

    incidents.find_each do |incident|
      poll_session(incident)
    rescue StandardError => e
      Rails.logger.error("DevinSessionPollJob: error polling incident #{incident.id}: #{e.message}")
    end
  end

  private

  def poll_session(incident)
    session_info = DevinSessionService.get_session(session_id: incident.devin_session_id)
    return unless session_info

    new_status = session_info[:status].to_s.downcase
    return if new_status.blank? || new_status == incident.devin_session_status

    Rails.logger.info(
      "DevinSessionPollJob: incident #{incident.id} session status changed " \
      "#{incident.devin_session_status} → #{new_status}"
    )

    incident.update!(devin_session_status: new_status)

    handle_completion(incident) if completed_status?(new_status)
  end

  def completed_status?(status)
    %w[finished completed stopped].include?(status)
  end

  def handle_completion(incident)
    incident.reload
    return if incident.status == 'resolved'

    incident.resolve!
    IncidentEventPublisher.incident_resolved(incident)
    IncidentEventPublisher.devin_session_completed(incident)
  end
end
