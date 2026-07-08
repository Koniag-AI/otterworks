require 'rails_helper'

RSpec.describe DevinSessionService do
  let(:incident) { create(:incident, :servicenow) }

  describe '.create_session' do
    context 'when Devin credentials are configured' do
      before do
        ENV['DEVIN_API_KEY'] = 'test-api-key'
        ENV['DEVIN_ORG_ID'] = 'test-org-id'
      end

      after do
        ENV.delete('DEVIN_API_KEY')
        ENV.delete('DEVIN_ORG_ID')
      end

      it 'creates a Devin session and returns session info' do
        stub_request(:post, "https://api.devin.ai/v3/organizations/test-org-id/sessions")
          .with(
            headers: { 'Authorization' => 'Bearer test-api-key', 'Content-Type' => 'application/json' },
            body: hash_including('prompt')
          )
          .to_return(
            status: 200,
            body: { session_id: 'devin-sess-001', url: 'https://app.devin.ai/sessions/devin-sess-001' }.to_json
          )

        result = described_class.create_session(incident: incident)

        expect(result).to be_present
        expect(result[:session_id]).to eq('devin-sess-001')
        expect(result[:url]).to include('devin-sess-001')
      end

      it 'includes ServiceNow context in the prompt for servicenow incidents' do
        stub = stub_request(:post, "https://api.devin.ai/v3/organizations/test-org-id/sessions")
          .with(body: /ServiceNow Ticket/)
          .to_return(status: 200, body: { session_id: 'x', url: 'y' }.to_json)

        described_class.create_session(incident: incident)
        expect(stub).to have_been_requested
      end

      it 'returns nil on API failure' do
        stub_request(:post, "https://api.devin.ai/v3/organizations/test-org-id/sessions")
          .to_return(status: 500, body: 'Internal Server Error')

        result = described_class.create_session(incident: incident)
        expect(result).to be_nil
      end

      it 'returns nil on network error' do
        stub_request(:post, "https://api.devin.ai/v3/organizations/test-org-id/sessions")
          .to_raise(Errno::ECONNREFUSED)

        result = described_class.create_session(incident: incident)
        expect(result).to be_nil
      end
    end

    context 'when Devin credentials are not configured' do
      before do
        ENV.delete('DEVIN_API_KEY')
        ENV.delete('DEVIN_ORG_ID')
      end

      it 'returns nil without making API calls' do
        result = described_class.create_session(incident: incident)
        expect(result).to be_nil
      end
    end
  end

  describe '.get_session' do
    before do
      ENV['DEVIN_API_KEY'] = 'test-api-key'
      ENV['DEVIN_ORG_ID'] = 'test-org-id'
    end

    after do
      ENV.delete('DEVIN_API_KEY')
      ENV.delete('DEVIN_ORG_ID')
    end

    it 'fetches the session status' do
      stub_request(:get, "https://api.devin.ai/v3/organizations/test-org-id/sessions/sess-123")
        .with(headers: { 'Authorization' => 'Bearer test-api-key' })
        .to_return(
          status: 200,
          body: { status: 'finished', url: 'https://app.devin.ai/sessions/sess-123' }.to_json
        )

      result = described_class.get_session(session_id: 'sess-123')

      expect(result[:status]).to eq('finished')
      expect(result[:url]).to include('sess-123')
    end

    it 'returns nil when session_id is nil' do
      result = described_class.get_session(session_id: nil)
      expect(result).to be_nil
    end

    it 'returns nil on API failure' do
      stub_request(:get, "https://api.devin.ai/v3/organizations/test-org-id/sessions/sess-404")
        .to_return(status: 404, body: 'Not found')

      result = described_class.get_session(session_id: 'sess-404')
      expect(result).to be_nil
    end
  end
end
