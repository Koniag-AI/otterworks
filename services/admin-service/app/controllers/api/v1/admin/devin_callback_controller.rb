module Api
  module V1
    module Admin
      class DevinCallbackController < ApplicationController
        before_action :verify_devin_secret

        # POST /api/v1/admin/devin/callback
        def callback
          session_id = params[:session_id].to_s
          status = params[:status].to_s.downcase

          if session_id.blank?
            return render json: { error: 'Missing session_id' }, status: :bad_request
          end

          if status.blank?
            return render json: { error: 'Missing status' }, status: :bad_request
          end

          incident = Incident.find_by(devin_session_id: session_id)
          unless incident
            return render json: { error: 'Incident not found for session' }, status: :not_found
          end

          incident.update!(
            devin_session_status: status,
            devin_session_url: params[:url].to_s.presence || incident.devin_session_url
          )

          if %w[finished completed stopped].include?(status)
            incident.reload
            unless incident.status == 'resolved'
              incident.resolve!
              IncidentEventPublisher.incident_resolved(incident)
              IncidentEventPublisher.devin_session_completed(incident)

              if incident.source == 'servicenow'
                ServicenowCallbackService.resolve_incident(
                  incident: incident,
                  pr_url: params[:pr_url].to_s.presence,
                  summary: params[:summary].to_s.presence || 'Devin session completed'
                )
              end
            end
          elsif %w[failed errored].include?(status) && incident.source == 'servicenow'
            ServicenowCallbackService.post_update(
              incident: incident,
              status: "Devin session #{status}",
              session_url: incident.devin_session_url,
              summary: params[:summary].to_s.presence || "Session ended with status: #{status}"
            )
          end

          render json: { incident_id: incident.id, status: incident.status, devin_session_status: status }
        end

        private

        def verify_devin_secret
          expected = ENV.fetch('DEVIN_CALLBACK_SECRET', nil)
          return if expected.nil?

          provided = request.headers['X-Devin-Secret'].to_s
          return if provided.present? && ActiveSupport::SecurityUtils.secure_compare(provided, expected)

          render json: { error: 'Unauthorized' }, status: :unauthorized
        end
      end
    end
  end
end
