require 'rails_helper'

RSpec.describe ServicenowCallbackService do
  let(:incident) do
    create(:incident, :servicenow,
           servicenow_sys_id: 'test-sys-id',
           servicenow_number: 'INC0010001',
           devin_session_url: 'https://app.devin.ai/sessions/abc')
  end

  let(:oauth_token_body) do
    { 'access_token' => 'mock-oauth-token', 'expires_in' => 1800 }.to_json
  end

  describe '.post_work_note' do
    context 'when ServiceNow credentials are configured' do
      before do
        ENV['SERVICENOW_INSTANCE_URL'] = 'https://test.service-now.com'
        ENV['SERVICENOW_CLIENT_ID'] = 'test-client-id'
        ENV['SERVICENOW_CLIENT_SECRET'] = 'test-client-secret'
        Rails.cache.clear
      end

      after do
        ENV.delete('SERVICENOW_INSTANCE_URL')
        ENV.delete('SERVICENOW_CLIENT_ID')
        ENV.delete('SERVICENOW_CLIENT_SECRET')
        Rails.cache.clear
      end

      it 'acquires an OAuth token and posts a work note to ServiceNow' do
        token_stub = stub_request(:post, "https://test.service-now.com/oauth_token.do")
          .to_return(status: 200, body: oauth_token_body, headers: { 'Content-Type' => 'application/json' })

        patch_stub = stub_request(:patch, "https://test.service-now.com/api/now/table/incident/test-sys-id")
          .with(
            body: hash_including('work_notes' => 'Test note'),
            headers: { 'Authorization' => 'Bearer mock-oauth-token' }
          )
          .to_return(status: 200, body: '{}')

        described_class.post_work_note(incident: incident, message: 'Test note')

        expect(token_stub).to have_been_requested
        expect(patch_stub).to have_been_requested
      end

      it 'caches the OAuth token for subsequent calls' do
        token_stub = stub_request(:post, "https://test.service-now.com/oauth_token.do")
          .to_return(status: 200, body: oauth_token_body, headers: { 'Content-Type' => 'application/json' })

        stub_request(:patch, "https://test.service-now.com/api/now/table/incident/test-sys-id")
          .to_return(status: 200, body: '{}')

        described_class.post_work_note(incident: incident, message: 'First note')
        described_class.post_work_note(incident: incident, message: 'Second note')

        expect(token_stub).to have_been_requested.once
      end

      it 'retries with a fresh token on 401' do
        token_stub = stub_request(:post, "https://test.service-now.com/oauth_token.do")
          .to_return(status: 200, body: oauth_token_body, headers: { 'Content-Type' => 'application/json' })

        stub_request(:patch, "https://test.service-now.com/api/now/table/incident/test-sys-id")
          .to_return(status: 401, body: 'Unauthorized')
          .then.to_return(status: 200, body: '{}')

        described_class.post_work_note(incident: incident, message: 'Test note')

        expect(token_stub).to have_been_requested.twice
      end

      it 'handles ServiceNow API errors gracefully' do
        stub_request(:post, "https://test.service-now.com/oauth_token.do")
          .to_return(status: 200, body: oauth_token_body, headers: { 'Content-Type' => 'application/json' })

        stub_request(:patch, "https://test.service-now.com/api/now/table/incident/test-sys-id")
          .to_return(status: 500, body: 'Internal Server Error')

        expect {
          described_class.post_work_note(incident: incident, message: 'Test note')
        }.not_to raise_error
      end

      it 'handles OAuth token request failure gracefully' do
        stub_request(:post, "https://test.service-now.com/oauth_token.do")
          .to_return(status: 401, body: 'Invalid client credentials')

        expect {
          described_class.post_work_note(incident: incident, message: 'Test note')
        }.not_to raise_error
      end
    end

    context 'when ServiceNow credentials are not configured' do
      before do
        ENV.delete('SERVICENOW_INSTANCE_URL')
        ENV.delete('SERVICENOW_CLIENT_ID')
        ENV.delete('SERVICENOW_CLIENT_SECRET')
      end

      it 'skips the callback' do
        result = described_class.post_work_note(incident: incident, message: 'Test note')
        expect(result).to be_nil
      end
    end

    context 'when incident has no servicenow_sys_id' do
      let(:manual_incident) { create(:incident) }

      it 'skips the callback' do
        ENV['SERVICENOW_INSTANCE_URL'] = 'https://test.service-now.com'
        ENV['SERVICENOW_CLIENT_ID'] = 'test-client-id'
        ENV['SERVICENOW_CLIENT_SECRET'] = 'test-client-secret'

        result = described_class.post_work_note(incident: manual_incident, message: 'Test note')
        expect(result).to be_nil

        ENV.delete('SERVICENOW_INSTANCE_URL')
        ENV.delete('SERVICENOW_CLIENT_ID')
        ENV.delete('SERVICENOW_CLIENT_SECRET')
      end
    end
  end

  describe '.resolve_incident' do
    before do
      ENV['SERVICENOW_INSTANCE_URL'] = 'https://test.service-now.com'
      ENV['SERVICENOW_CLIENT_ID'] = 'test-client-id'
      ENV['SERVICENOW_CLIENT_SECRET'] = 'test-client-secret'
      Rails.cache.clear
    end

    after do
      ENV.delete('SERVICENOW_INSTANCE_URL')
      ENV.delete('SERVICENOW_CLIENT_ID')
      ENV.delete('SERVICENOW_CLIENT_SECRET')
      Rails.cache.clear
    end

    it 'resolves the ServiceNow incident with work notes via OAuth' do
      stub_request(:post, "https://test.service-now.com/oauth_token.do")
        .to_return(status: 200, body: oauth_token_body, headers: { 'Content-Type' => 'application/json' })

      stub = stub_request(:patch, "https://test.service-now.com/api/now/table/incident/test-sys-id")
        .with(
          body: hash_including(
            'state' => '6',
            'close_code' => 'Solved (Permanently)'
          ),
          headers: { 'Authorization' => 'Bearer mock-oauth-token' }
        )
        .to_return(status: 200, body: '{}')

      described_class.resolve_incident(
        incident: incident,
        pr_url: 'https://github.com/org/repo/pull/1',
        summary: 'Fixed the bug'
      )

      expect(stub).to have_been_requested
    end
  end

  describe '.post_update' do
    before do
      ENV['SERVICENOW_INSTANCE_URL'] = 'https://test.service-now.com'
      ENV['SERVICENOW_CLIENT_ID'] = 'test-client-id'
      ENV['SERVICENOW_CLIENT_SECRET'] = 'test-client-secret'
      Rails.cache.clear
    end

    after do
      ENV.delete('SERVICENOW_INSTANCE_URL')
      ENV.delete('SERVICENOW_CLIENT_ID')
      ENV.delete('SERVICENOW_CLIENT_SECRET')
      Rails.cache.clear
    end

    it 'posts a status update to ServiceNow via OAuth' do
      stub_request(:post, "https://test.service-now.com/oauth_token.do")
        .to_return(status: 200, body: oauth_token_body, headers: { 'Content-Type' => 'application/json' })

      stub = stub_request(:patch, "https://test.service-now.com/api/now/table/incident/test-sys-id")
        .with(
          body: hash_including('work_notes'),
          headers: { 'Authorization' => 'Bearer mock-oauth-token' }
        )
        .to_return(status: 200, body: '{}')

      described_class.post_update(
        incident: incident,
        status: 'investigating',
        session_url: 'https://app.devin.ai/sessions/abc'
      )

      expect(stub).to have_been_requested
    end
  end

  describe 'connection error handling' do
    before do
      ENV['SERVICENOW_INSTANCE_URL'] = 'https://test.service-now.com'
      ENV['SERVICENOW_CLIENT_ID'] = 'test-client-id'
      ENV['SERVICENOW_CLIENT_SECRET'] = 'test-client-secret'
      Rails.cache.clear
    end

    after do
      ENV.delete('SERVICENOW_INSTANCE_URL')
      ENV.delete('SERVICENOW_CLIENT_ID')
      ENV.delete('SERVICENOW_CLIENT_SECRET')
      Rails.cache.clear
    end

    it 'handles network errors gracefully' do
      stub_request(:post, "https://test.service-now.com/oauth_token.do")
        .to_raise(Errno::ECONNREFUSED)

      expect {
        described_class.post_work_note(incident: incident, message: 'Test')
      }.not_to raise_error
    end
  end
end
