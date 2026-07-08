Rails.application.routes.draw do
  # Health check (excluded from JWT auth)
  get '/health', to: 'health#show'
  get '/metrics', to: 'health#metrics'

  # Admin API
  namespace :api do
    namespace :v1 do
      namespace :admin do
        # User Management
        resources :users, only: %i[index show update destroy] do
          member do
            put :suspend
            put :activate
          end
        end

        # System Health
        get 'health/services', to: 'health#services'

        # Feature Flags
        resources :features, only: %i[index show create update destroy]

        # System Configuration
        resources :config, only: %i[index show update]

        # Audit Log Viewer
        resources :audit_logs, only: %i[index show], path: 'audit-logs'

        # Storage Quotas
        get 'quotas/:user_id', to: 'quotas#show', as: :quota
        put 'quotas/:user_id', to: 'quotas#update'

        # System Metrics
        get 'metrics/summary', to: 'metrics#summary'

        # Announcements
        resources :announcements, only: %i[index show create update destroy]

        # Incidents (Automated Incident Response)
        resources :incidents, only: %i[index show create update destroy] do
          member do
            post :trigger_session
          end
        end

        # Bulk Operations
        post 'bulk/users', to: 'bulk#users'

        # Chaos injection (demo/workshop use — protected by X-Chaos-Secret header)
        post  'chaos', to: 'chaos#trigger'
        delete 'chaos', to: 'chaos#reset'

        # Settings
        get 'settings/auto_investigate', to: 'settings#auto_investigate'
        put 'settings/auto_investigate', to: 'settings#update_auto_investigate'

        # Grafana alert webhook (no JWT — protected by X-Alert-Secret header)
        post 'alerts/ingest', to: 'alerts#ingest'

        # ServiceNow webhook (no JWT — protected by X-ServiceNow-Secret header)
        post 'servicenow/ingest', to: 'servicenow#ingest'
        post 'servicenow/resolve', to: 'servicenow#resolve'

        # Devin session callback (no JWT — called by Devin platform)
        post 'devin/callback', to: 'devin_callback#callback'
      end
    end
  end
end
