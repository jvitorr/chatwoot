module Enterprise::Api::V1::Accounts::InboxesController
  def inbox_attributes
    super + ee_inbox_attributes
  end

  # Surfaces the live WABA-level calling status for a WhatsApp Cloud inbox so
  # the Calls settings page can warn admins when Meta hasn't enabled calling
  # on the phone number. Returns 'UNKNOWN' if we can't query Meta.
  def whatsapp_calling_status
    channel = @inbox.channel
    return render json: { status: 'UNSUPPORTED' }, status: :ok unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'

    calling = channel.refresh_calling_status!
    render json: { status: calling&.dig('status') || 'UNKNOWN', calling: calling }
  end

  # One-shot enablement: flips calling on at Meta, re-subscribes the webhook
  # so `calls` is included, and sets calling_enabled in provider_config.
  def enable_whatsapp_calling
    channel = @inbox.channel
    return render_could_not_create_error('Not a WhatsApp Cloud inbox') unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'

    calling = channel.enable_voice_calling!
    render json: { status: calling&.dig('status') || 'ENABLED', calling: calling }
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def ee_inbox_attributes
    [auto_assignment_config: [:max_assignment_limit]]
  end

  private

  def allowed_channel_types
    super + ['voice']
  end

  def channel_type_from_params
    return Channel::TwilioSms if permitted_params[:channel][:type] == 'voice'

    super
  end

  def account_channels_method
    return Current.account.twilio_sms if permitted_params[:channel][:type] == 'voice'

    super
  end

  def create_channel
    return create_voice_channel if permitted_params[:channel][:type] == 'voice'

    super
  end

  def get_channel_attributes(channel_type)
    attrs = super
    attrs += [:voice_enabled, :api_key_sid, :api_key_secret] if channel_type == 'Channel::TwilioSms' && @inbox&.channel&.medium == 'sms'
    attrs
  end

  def create_voice_channel
    raise Pundit::NotAuthorizedError unless Current.account.feature_enabled?('channel_voice')

    voice_params = params.require(:channel).permit(
      :phone_number, :provider,
      provider_config: [:account_sid, :auth_token, :api_key_sid, :api_key_secret]
    )
    config = voice_params[:provider_config] || {}

    Current.account.twilio_sms.create!(
      phone_number: voice_params[:phone_number],
      account_sid: config[:account_sid],
      auth_token: config[:auth_token],
      api_key_sid: config[:api_key_sid],
      api_key_secret: config[:api_key_secret],
      medium: :sms,
      voice_enabled: true
    )
  end
end
