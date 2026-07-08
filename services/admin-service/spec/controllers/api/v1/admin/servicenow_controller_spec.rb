require 'rails_helper'

RSpec.describe Api::V1::Admin::ServicenowController, type: :request do
  let(:webhook_secret) { 'test-servicenow-secret' }
  let(:secret_header) { { 'X-ServiceNow-Secret' => webhook_secret } }

  before do
    ENV['SERVICENOW_WEBHOOK_SECRET'] = webhook_secret
  end

  after do
    ENV.delete('SERVICENOW_WEBHOOK_SECRET')
  end

  describe 'POST /api/v1/admin/servicenow/ingest' do
    let(:valid_payload) do
      {
        source: 'servicenow',
        incident: {
          sys_id: 'abc123def456',
          number: 'INC0010042',
          short_description: 'File upload returns 500',
          description: 'Users report intermittent 500 errors when uploading files',
          priority: '1',
          category: 'Software',
          subcategory: 'Operating System',
          assignment_group: 'Platform Engineering',
          assigned_to: 'Jane Doe',
          caller_id: 'John Smith',
          cmdb_ci: 'file-service',
          state: '1',
          sys_created_on: '2026-05-18 22:00:00'
        }
      }
    end

    context 'with valid payload' do
      it 'creates an incident and returns 201' do
        expect {
          post '/api/v1/admin/servicenow/ingest', params: valid_payload, headers: secret_header, as: :json
        }.to change(Incident, :count).by(1)

        expect(response).to have_http_status(:created)
        body = JSON.parse(response.body)
        expect(body['incident_id']).to be_present
        expect(body['servicenow_number']).to eq('INC0010042')
        expect(body['devin_automation']).to be true

        incident = Incident.last
        expect(incident.source).to eq('servicenow')
        expect(incident.servicenow_sys_id).to eq('abc123def456')
        expect(incident.servicenow_number).to eq('INC0010042')
        expect(incident.severity).to eq('critical')
        expect(incident.affected_service).to eq('file-service')
        expect(incident.status).to eq('open')
      end

      it 'does not call DevinSessionService or ServicenowCallbackService' do
        expect(DevinSessionService).not_to receive(:create_session)
        expect(ServicenowCallbackService).not_to receive(:post_work_note)

        post '/api/v1/admin/servicenow/ingest', params: valid_payload, headers: secret_header, as: :json

        expect(response).to have_http_status(:created)
      end
    end

    context 'with missing incident object' do
      it 'returns 400' do
        post '/api/v1/admin/servicenow/ingest', params: { source: 'servicenow' }, headers: secret_header, as: :json

        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)['error']).to match(/Missing incident/)
      end
    end

    context 'with missing sys_id' do
      it 'returns 400' do
        payload = valid_payload.deep_dup
        payload[:incident].delete(:sys_id)

        post '/api/v1/admin/servicenow/ingest', params: payload, headers: secret_header, as: :json

        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)['error']).to match(/Missing sys_id/)
      end
    end

    context 'with duplicate servicenow_sys_id' do
      before do
        create(:incident, :servicenow, servicenow_sys_id: 'abc123def456')
      end

      it 'skips creation and returns existing incident' do
        expect {
          post '/api/v1/admin/servicenow/ingest', params: valid_payload, headers: secret_header, as: :json
        }.not_to change(Incident, :count)

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body['skipped']).to be true
        expect(body['reason']).to eq('duplicate')
      end
    end

    context 'with invalid webhook secret' do
      it 'returns 401' do
        post '/api/v1/admin/servicenow/ingest',
             params: valid_payload,
             headers: { 'X-ServiceNow-Secret' => 'wrong-secret' },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with no webhook secret configured' do
      before do
        ENV.delete('SERVICENOW_WEBHOOK_SECRET')
      end

      it 'allows the request through' do
        post '/api/v1/admin/servicenow/ingest', params: valid_payload, as: :json

        expect(response).to have_http_status(:created)
      end
    end
  end

  describe 'POST /api/v1/admin/servicenow/resolve' do
    let!(:incident) do
      create(:incident, :servicenow, :investigating, :with_devin_session,
             servicenow_sys_id: 'resolve-sys-id')
    end

    context 'with valid sys_id' do
      it 'resolves the incident' do
        allow(ServicenowCallbackService).to receive(:resolve_incident)

        post '/api/v1/admin/servicenow/resolve',
             params: { sys_id: 'resolve-sys-id', pr_url: 'https://github.com/org/repo/pull/42' },
             headers: secret_header,
             as: :json

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body['status']).to eq('resolved')

        incident.reload
        expect(incident.status).to eq('resolved')
        expect(incident.resolved_at).to be_present
        expect(incident.devin_session_status).to eq('completed')

        expect(ServicenowCallbackService).to have_received(:resolve_incident)
      end
    end

    context 'with missing sys_id' do
      it 'returns 400' do
        post '/api/v1/admin/servicenow/resolve', params: {}, headers: secret_header, as: :json

        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)['error']).to match(/Missing sys_id/)
      end
    end

    context 'with non-existent sys_id' do
      it 'returns 404' do
        post '/api/v1/admin/servicenow/resolve',
             params: { sys_id: 'nonexistent' },
             headers: secret_header,
             as: :json

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
