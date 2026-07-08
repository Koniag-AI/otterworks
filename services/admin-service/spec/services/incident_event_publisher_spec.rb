require 'rails_helper'

RSpec.describe IncidentEventPublisher do
  let(:incident) { create(:incident, :servicenow) }

  describe '.incident_created' do
    it 'logs the event when SNS is not configured' do
      expect(Rails.logger).to receive(:info).with(/IncidentEvent.*incident\.created/)

      described_class.incident_created(incident)
    end

    it 'includes incident details in the payload' do
      expect(Rails.logger).to receive(:info) do |msg|
        payload = JSON.parse(msg.sub('IncidentEvent: ', ''))
        expect(payload['event']).to eq('incident.created')
        expect(payload['incident']['id']).to eq(incident.id)
        expect(payload['incident']['source']).to eq('servicenow')
        expect(payload['incident']['servicenow_number']).to eq(incident.servicenow_number)
      end

      described_class.incident_created(incident)
    end

    it 'includes metadata in the payload' do
      expect(Rails.logger).to receive(:info) do |msg|
        payload = JSON.parse(msg.sub('IncidentEvent: ', ''))
        expect(payload['metadata']['extra']).to eq('data')
      end

      described_class.incident_created(incident, metadata: { extra: 'data' })
    end
  end

  describe '.incident_resolved' do
    let(:resolved_incident) { create(:incident, :servicenow, :resolved) }

    it 'publishes a resolved event' do
      expect(Rails.logger).to receive(:info).with(/IncidentEvent.*incident\.resolved/)

      described_class.incident_resolved(resolved_incident)
    end
  end

  describe '.devin_session_started' do
    let(:incident_with_session) { create(:incident, :with_devin_session) }

    it 'publishes a devin session started event' do
      expect(Rails.logger).to receive(:info).with(/IncidentEvent.*devin_session_started/)

      described_class.devin_session_started(incident_with_session)
    end
  end

  describe '.devin_session_completed' do
    it 'publishes a devin session completed event' do
      expect(Rails.logger).to receive(:info).with(/IncidentEvent.*devin_session_completed/)

      described_class.devin_session_completed(incident)
    end
  end

  describe '.publish' do
    it 'publishes a custom event' do
      expect(Rails.logger).to receive(:info).with(/IncidentEvent.*custom\.event/)

      described_class.publish(event: 'custom.event', incident: incident)
    end

    it 'includes a timestamp in the payload' do
      expect(Rails.logger).to receive(:info) do |msg|
        payload = JSON.parse(msg.sub('IncidentEvent: ', ''))
        expect(payload['timestamp']).to be_present
      end

      described_class.publish(event: 'test', incident: incident)
    end
  end
end
