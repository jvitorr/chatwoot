module Enterprise::Messages::MessageBuilder
  private

  def message_type
    return @message_type if @message_type == 'incoming' && voice_call_inbox? && @params[:content_type] == 'voice_call'

    super
  end

  def voice_call_inbox?
    twilio_voice_inbox? || whatsapp_call_inbox?
  end

  def twilio_voice_inbox?
    inbox = @conversation.inbox
    inbox.channel_type == 'Channel::TwilioSms' && inbox.channel.voice_enabled?
  end

  def whatsapp_call_inbox?
    inbox = @conversation.inbox
    inbox.channel_type == 'Channel::Whatsapp' && inbox.channel.provider_config['calling_enabled']
  end
end
