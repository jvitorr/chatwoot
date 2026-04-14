class Twilio::VoiceTeardownService
  pattr_initialize [:channel!]

  def perform
    delete_twiml_app if channel.twiml_app_sid.present?
    clear_number_webhooks
  ensure
    clear_voice_credentials
  end

  private

  def delete_twiml_app
    twilio_client.applications(channel.twiml_app_sid).delete
  rescue StandardError => e
    Rails.logger.error("TWILIO_VOICE_TEARDOWN_ERROR: #{e.class} #{e.message} phone=#{channel.phone_number} account=#{channel.account_id}")
  end

  def clear_number_webhooks
    numbers = twilio_client.incoming_phone_numbers.list(phone_number: channel.phone_number)
    return if numbers.empty?

    twilio_client
      .incoming_phone_numbers(numbers.first.sid)
      .update(voice_url: '', status_callback: '')
  rescue StandardError => e
    Rails.logger.error("TWILIO_VOICE_TEARDOWN_WEBHOOK_ERROR: #{e.class} #{e.message} phone=#{channel.phone_number} account=#{channel.account_id}")
  end

  def clear_voice_credentials
    channel.update(twiml_app_sid: nil)
  end

  def twilio_client
    @twilio_client ||= if channel.api_key_sid.present? && channel.try(:api_key_secret).present?
                         ::Twilio::REST::Client.new(channel.api_key_sid, channel.api_key_secret, channel.account_sid)
                       else
                         ::Twilio::REST::Client.new(channel.account_sid, channel.auth_token)
                       end
  end
end
