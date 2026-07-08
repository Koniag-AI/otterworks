class IncidentSerializer < ActiveModel::Serializer
  attributes :id, :title, :description, :severity, :status, :affected_service,
             :devin_session_id, :devin_session_url, :devin_session_status,
             :reporter_id, :resolved_at, :active, :source,
             :servicenow_sys_id, :servicenow_number,
             :created_at, :updated_at

  def active
    object.active?
  end
end
