require 'rails_helper'

RSpec.describe Api::V1::Admin::DevinCallbackController, type: :request do
  describe 'POST /api/v1/admin/devin/callback' do
    let!(:incident) do
      create(:incident, :investigating, :with_devin_session)
    end

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('DEVIN_CALLBACK_SECRET', nil).and_return('test-devin-secret')
    end

    let(:valid_headers) { { 'X-Devin-Secret' => 'test-devin-secret' } }

    context 'with a completed session' do
      it 'resolves the incident' do
        post '/api/v1/admin/devin/callback',
             params: { session_id: incident.devin_session_id, status: 'finished' },
             headers: valid_headers,
             as: :json

        expect(response).to have_http_status(:ok)

        incident.reload
        expect(incident.devin_session_status).to eq('finished')
        expect(incident.status).to eq('resolved')
        expect(incident.resolved_at).to be_present
      end
    end

    context 'with a failed session' do
      it 'updates session status but does not resolve' do
        post '/api/v1/admin/devin/callback',
             params: { session_id: incident.devin_session_id, status: 'failed' },
             headers: valid_headers,
             as: :json

        expect(response).to have_http_status(:ok)

        incident.reload
        expect(incident.devin_session_status).to eq('failed')
        expect(incident.status).to eq('investigating')
      end
    end

    context 'with a servicenow-sourced incident' do
      let!(:snow_incident) do
        create(:incident, :servicenow, :investigating, :with_devin_session)
      end

      it 'triggers ServiceNow callback on completion' do
        allow(ServicenowCallbackService).to receive(:resolve_incident)

        post '/api/v1/admin/devin/callback',
             params: {
               session_id: snow_incident.devin_session_id,
               status: 'finished',
               pr_url: 'https://github.com/org/repo/pull/99'
             },
             headers: valid_headers,
             as: :json

        expect(response).to have_http_status(:ok)
        expect(ServicenowCallbackService).to have_received(:resolve_incident)
      end

      it 'posts failure update to ServiceNow on errored status' do
        allow(ServicenowCallbackService).to receive(:post_update)

        post '/api/v1/admin/devin/callback',
             params: { session_id: snow_incident.devin_session_id, status: 'errored' },
             headers: valid_headers,
             as: :json

        expect(response).to have_http_status(:ok)
        expect(ServicenowCallbackService).to have_received(:post_update)
      end
    end

    context 'with missing session_id' do
      it 'returns 400' do
        post '/api/v1/admin/devin/callback',
             params: { status: 'finished' },
             headers: valid_headers,
             as: :json

        expect(response).to have_http_status(:bad_request)
      end
    end

    context 'with non-existent session_id' do
      it 'returns 404' do
        post '/api/v1/admin/devin/callback',
             params: { session_id: 'nonexistent', status: 'finished' },
             headers: valid_headers,
             as: :json

        expect(response).to have_http_status(:not_found)
      end
    end

    context 'with invalid callback secret' do
      it 'returns 401 unauthorized' do
        post '/api/v1/admin/devin/callback',
             params: { session_id: incident.devin_session_id, status: 'finished' },
             headers: { 'X-Devin-Secret' => 'wrong-secret' },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with missing callback secret header' do
      it 'returns 401 unauthorized' do
        post '/api/v1/admin/devin/callback',
             params: { session_id: incident.devin_session_id, status: 'finished' },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when DEVIN_CALLBACK_SECRET is not configured' do
      before do
        allow(ENV).to receive(:fetch).with('DEVIN_CALLBACK_SECRET', nil).and_return(nil)
      end

      it 'allows requests without secret header' do
        post '/api/v1/admin/devin/callback',
             params: { session_id: incident.devin_session_id, status: 'finished' },
             as: :json

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
