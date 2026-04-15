class Whatsapp::WebhookTeardownService
  def initialize(channel)
    @channel = channel
  end

  def perform
    return unless should_teardown_webhook?

    api_client = Whatsapp::FacebookApiClient.new(provider_config['api_key'])

    clear_phone_number_override(api_client)
    clear_legacy_waba_override(api_client)
  rescue StandardError => e
    # before_destroy must never block a channel delete — log and move on.
    Rails.logger.error "[WHATSAPP] Webhook teardown failed for channel #{@channel&.id}: #{e.message}"
  end

  private

  def provider_config
    @channel.provider_config || {}
  end

  def should_teardown_webhook?
    @channel.provider == 'whatsapp_cloud' &&
      provider_config['source'] == 'embedded_signup' &&
      provider_config['api_key'].present? &&
      (provider_config['phone_number_id'].present? || provider_config['business_account_id'].present?)
  end

  def clear_phone_number_override(api_client)
    phone_number_id = provider_config['phone_number_id']
    return if phone_number_id.blank?

    api_client.clear_phone_number_callback_override(phone_number_id)
    Rails.logger.info "[WHATSAPP] Phone-level webhook override cleared for channel #{@channel.id}"
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP] Phone-level webhook clear failed for channel #{@channel.id}: #{e.message}"
  end

  # The WABA-level override_callback_uri is shared across every phone number on
  # the WABA, so we must not clear it while a sibling channel still depends on
  # it. A sibling that has its own phone_number_id is using a phone-level
  # override (which takes precedence over the WABA-level value) and does not
  # depend on the WABA fallback. Only siblings without a phone_number_id are
  # still relying on WABA-level webhooks and should block the clear.
  def clear_legacy_waba_override(api_client)
    waba_id = provider_config['business_account_id']
    return if waba_id.blank?
    return if waba_dependent_sibling_exists?(waba_id)

    api_client.clear_waba_callback_override(waba_id)
    Rails.logger.info "[WHATSAPP] Legacy WABA webhook override cleared for channel #{@channel.id}"
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP] Legacy WABA webhook clear failed for channel #{@channel.id}: #{e.message}"
  end

  def waba_dependent_sibling_exists?(waba_id)
    Channel::Whatsapp
      .where.not(id: @channel.id)
      .exists?([
                 "provider_config ->> 'business_account_id' = ? AND " \
                 "(provider_config ->> 'phone_number_id' IS NULL OR provider_config ->> 'phone_number_id' = '')",
                 waba_id
               ])
  end
end
