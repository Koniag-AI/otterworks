require 'rails_helper'

RSpec.describe DevinSessionPollJob, type: :job do
  describe '#perform' do
    context 'with non-servicenow running sessions' do
      let!(:running_incident) do
        create(:incident, :investigating, :with_devin_session,
               devin_session_status: 'running',
               source: 'grafana')
      end

      it 'polls the Devin API for session status' do
        allow(DevinSessionService).to receive(:get_session)
          .with(session_id: running_incident.devin_session_id)
          .and_return({ status: 'running', url: running_incident.devin_session_url })

        described_class.perform_now

        expect(DevinSessionService).to have_received(:get_session)
      end

      it 'updates incident when session completes' do
        allow(DevinSessionService).to receive(:get_session)
          .and_return({ status: 'finished', url: running_incident.devin_session_url })

        described_class.perform_now

        running_incident.reload
        expect(running_incident.devin_session_status).to eq('finished')
        expect(running_incident.status).to eq('resolved')
        expect(running_incident.resolved_at).to be_present
      end
    end

    context 'with servicenow-sourced running sessions' do
      let!(:snow_incident) do
        create(:incident, :servicenow, :investigating, :with_devin_session,
               devin_session_status: 'running')
      end

      it 'skips servicenow incidents' do
        expect(DevinSessionService).not_to receive(:get_session)

        described_class.perform_now
      end
    end

    context 'with no running sessions' do
      it 'completes without errors' do
        expect { described_class.perform_now }.not_to raise_error
      end
    end
  end
end
