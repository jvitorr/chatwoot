class Whatsapp::WebhookTeardownService
  def initialize(channel)
    @channel = channel
  end

  def perform
    return unless should_teardown_webhook?

    access_token = @channel.provider_config['api_key']
    api_client = Whatsapp::FacebookApiClient.new(access_token)

    # Each clear is isolated so a failure on the phone-level clear
    # still allows the legacy WABA-level fallback to run, and vice versa.
    clear_phone_number_override(api_client)
    clear_legacy_waba_override(api_client)
  end

  private

  def should_teardown_webhook?
    whatsapp_cloud_provider? && embedded_signup_source? && webhook_config_present?
  end

  def whatsapp_cloud_provider?
    @channel.provider == 'whatsapp_cloud'
  end

  def embedded_signup_source?
    @channel.provider_config['source'] == 'embedded_signup'
  end

  def webhook_config_present?
    @channel.provider_config['phone_number_id'].present? &&
      @channel.provider_config['api_key'].present?
  end

  def clear_phone_number_override(api_client)
    phone_number_id = @channel.provider_config['phone_number_id']
    api_client.clear_phone_number_callback_override(phone_number_id)
    Rails.logger.info "[WHATSAPP] Phone number webhook override cleared for channel #{@channel.id}"
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP] Phone number webhook override clear failed for channel #{@channel.id}: #{e.message}"
  end

  # Legacy channels (pre phone-number-level override) were configured with a
  # WABA-level override_callback_uri. Clearing only the phone-level override
  # would leave that stale URL in place, so clear it as a best-effort fallback.
  def clear_legacy_waba_override(api_client)
    waba_id = @channel.provider_config['business_account_id']
    return if waba_id.blank?

    api_client.clear_waba_callback_override(waba_id)
    Rails.logger.info "[WHATSAPP] Legacy WABA webhook override cleared for channel #{@channel.id}"
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP] Legacy WABA webhook override clear failed for channel #{@channel.id}: #{e.message}"
  end
end
