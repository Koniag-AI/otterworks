require 'sidekiq'
require 'sidekiq-scheduler'

Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch('REDIS_URL', "redis://#{ENV.fetch('REDIS_HOST', 'localhost')}:#{ENV.fetch('REDIS_PORT', 6379)}/0") }

  config.on(:startup) do
    schedule_file = Rails.root.join('config', 'sidekiq_schedule.yml')
    if File.exist?(schedule_file)
      Sidekiq.schedule = YAML.load_file(schedule_file)
      SidekiqScheduler::Scheduler.instance.reload_schedule!
    end
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch('REDIS_URL', "redis://#{ENV.fetch('REDIS_HOST', 'localhost')}:#{ENV.fetch('REDIS_PORT', 6379)}/0") }
end
