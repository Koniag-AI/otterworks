FactoryBot.define do
  factory :incident do
    title { Faker::Lorem.sentence(word_count: 5) }
    description { Faker::Lorem.paragraph(sentence_count: 3) }
    severity { 'high' }
    status { 'open' }
    source { 'manual' }
    affected_service { 'file-service' }

    trait :servicenow do
      source { 'servicenow' }
      servicenow_sys_id { SecureRandom.hex(16) }
      servicenow_number { "INC#{rand(1_000_000..9_999_999)}" }
    end

    trait :grafana do
      source { 'grafana' }
    end

    trait :investigating do
      status { 'investigating' }
    end

    trait :resolved do
      status { 'resolved' }
      resolved_at { Time.current }
    end

    trait :with_devin_session do
      devin_session_id { SecureRandom.uuid }
      devin_session_url { "https://app.devin.ai/sessions/#{SecureRandom.uuid}" }
      devin_session_status { 'running' }
    end
  end
end
