# == Schema Information
#
# Table name: channel_whatsapp
#
#  id                             :bigint           not null, primary key
#  message_templates              :jsonb
#  message_templates_last_updated :datetime
#  phone_number                   :string           not null
#  provider                       :string           default("default")
#  provider_config                :jsonb
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#  account_id                     :integer          not null
#
# Indexes
#
#  index_channel_whatsapp_on_phone_number  (phone_number) UNIQUE
#

class Channel::Whatsapp < ApplicationRecord
  include Channelable
  include Reauthorizable

  self.table_name = 'channel_whatsapp'
  EDITABLE_ATTRS = [:phone_number, :provider, { provider_config: {} }].freeze

  # default at the moment is 360dialog lets change later.
  PROVIDERS = %w[default whatsapp_cloud].freeze
  before_validation :ensure_webhook_verify_token

  validates :provider, inclusion: { in: PROVIDERS }
  validates :phone_number, presence: true, uniqueness: true
  validate :validate_provider_config

  after_create :sync_templates
  before_destroy :teardown_webhooks
  after_commit :setup_webhooks, on: :create, if: :should_auto_setup_webhooks?

  def name
    'Whatsapp'
  end

  # Mirrors Channel::TwilioSms#voice_enabled? so the call subsystem can duck-type across providers.
  # Meta's Calling API is only available via the embedded-signup whatsapp_cloud flow —
  # 360dialog (default provider) and manual whatsapp_cloud setups can't reach the call APIs.
  def voice_enabled?
    provider == 'whatsapp_cloud' &&
      provider_config['source'] == 'embedded_signup' &&
      provider_config['calling_enabled'].present? &&
      account.feature_enabled?('channel_voice')
  end

  def provider_service
    if provider == 'whatsapp_cloud'
      Whatsapp::Providers::WhatsappCloudService.new(whatsapp_channel: self)
    else
      Whatsapp::Providers::Whatsapp360DialogService.new(whatsapp_channel: self)
    end
  end

  # Queries Meta for the WABA-level calling status and caches it on
  # provider_config. Returns the cached payload (e.g. { 'status' => 'ENABLED' })
  # or nil if the channel can't reach the calling settings endpoint.
  def refresh_calling_status!
    return nil unless provider == 'whatsapp_cloud' && provider_service.respond_to?(:fetch_calling_status)

    calling = provider_service.fetch_calling_status
    return nil if calling.blank?

    update!(provider_config: provider_config.merge(
      'waba_calling_status' => calling['status'],
      'waba_calling_status_synced_at' => Time.current.iso8601,
      'waba_calling' => calling
    ))
    calling
  end

  # End-to-end voice enablement for a WhatsApp Cloud inbox: toggles calling on
  # at Meta, re-runs webhook setup so the `calls` field is subscribed, and
  # flips the local `calling_enabled` flag. Raises on Meta failure so callers
  # can surface the error verbatim.
  def enable_voice_calling!
    raise 'Voice calling is only supported on whatsapp_cloud channels' unless provider == 'whatsapp_cloud'

    provider_service.update_calling_status('ENABLED')
    Whatsapp::WebhookSetupService.new(self, provider_config['business_account_id'], provider_config['api_key']).register_callback
    update!(provider_config: provider_config.merge('calling_enabled' => true))
    refresh_calling_status!
  end

  def mark_message_templates_updated
    # rubocop:disable Rails/SkipsModelValidations
    update_column(:message_templates_last_updated, Time.zone.now)
    # rubocop:enable Rails/SkipsModelValidations
  end

  delegate :send_message, to: :provider_service
  delegate :send_template, to: :provider_service
  delegate :sync_templates, to: :provider_service
  delegate :media_url, to: :provider_service
  delegate :api_headers, to: :provider_service

  def setup_webhooks
    perform_webhook_setup
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP] Webhook setup failed: #{e.message}"
    prompt_reauthorization!
  end

  private

  def ensure_webhook_verify_token
    provider_config['webhook_verify_token'] ||= SecureRandom.hex(16) if provider == 'whatsapp_cloud'
  end

  def validate_provider_config
    errors.add(:provider_config, 'Invalid Credentials') unless provider_service.validate_provider_config?
  end

  def perform_webhook_setup
    business_account_id = provider_config['business_account_id']
    api_key = provider_config['api_key']

    Whatsapp::WebhookSetupService.new(self, business_account_id, api_key).perform
  end

  def teardown_webhooks
    Whatsapp::WebhookTeardownService.new(self).perform
  end

  def should_auto_setup_webhooks?
    # Only auto-setup webhooks for whatsapp_cloud provider with manual setup
    # Embedded signup calls setup_webhooks explicitly in EmbeddedSignupService
    provider == 'whatsapp_cloud' && provider_config['source'] != 'embedded_signup'
  end
end
