class Twilio::IncomingMessageService
  include ::FileTypeHelper
  include ::DownloadedFileTracking
  include ::Twilio::AttachmentHandling

  pattr_initialize [:params!]

  def perform
    with_downloaded_files do
      return if twilio_channel.blank?

      set_contact
      set_conversation
      @message = @conversation.messages.build(
        content: message_body,
        account_id: @inbox.account_id,
        inbox_id: @inbox.id,
        message_type: :incoming,
        sender: @contact,
        source_id: params[:SmsSid]
      )
      attach_files
      attach_location if location_message?
      @message.save!
    end
  end

  private

  def twilio_channel
    @twilio_channel ||= ::Channel::TwilioSms.find_by(messaging_service_sid: params[:MessagingServiceSid]) if params[:MessagingServiceSid].present?
    if params[:AccountSid].present? && params[:To].present?
      @twilio_channel ||= ::Channel::TwilioSms.find_by(account_sid: params[:AccountSid],
                                                       phone_number: params[:To])
    end
    log_channel_not_found if @twilio_channel.blank?
    @twilio_channel
  end

  def log_channel_not_found
    Rails.logger.warn(
      '[TWILIO] Incoming message channel lookup failed ' \
      "account_sid=#{params[:AccountSid]} " \
      "to=#{params[:To]} " \
      "messaging_service_sid=#{params[:MessagingServiceSid]} " \
      "sms_sid=#{params[:SmsSid]}"
    )
  end

  def inbox
    @inbox ||= twilio_channel.inbox
  end

  def account
    @account ||= inbox.account
  end

  def phone_number
    twilio_channel.sms? ? params[:From] : params[:From].gsub('whatsapp:', '')
  end

  def normalized_phone_number
    return phone_number unless twilio_channel.whatsapp?

    Whatsapp::PhoneNumberNormalizationService.new(inbox).normalize_and_find_contact_by_provider("whatsapp:#{phone_number}", :twilio)
  end

  def formatted_phone_number
    TelephoneNumber.parse(phone_number).international_number
  end

  def message_body
    params[:Body]&.delete("\u0000")
  end

  def set_contact
    source_id = twilio_channel.whatsapp? ? normalized_phone_number : params[:From]

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: contact_attributes
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    # Update existing contact name if ProfileName is available and current name is just phone number
    update_contact_name_if_needed
  end

  def conversation_params
    {
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: additional_attributes
    }
  end

  def set_conversation
    # if lock to single conversation is disabled, we will create a new conversation if previous conversation is resolved
    @conversation = if @inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations.where
                                    .not(status: :resolved).last
                    end
    return if @conversation

    @conversation = ::Conversation.create!(conversation_params)
  end

  def contact_attributes
    {
      name: contact_name,
      phone_number: phone_number,
      additional_attributes: additional_attributes
    }
  end

  def contact_name
    params[:ProfileName].presence || formatted_phone_number
  end

  def additional_attributes
    if twilio_channel.sms?
      {
        from_zip_code: params[:FromZip],
        from_country: params[:FromCountry],
        from_state: params[:FromState]
      }
    else
      {}
    end
  end

  def update_contact_name_if_needed
    return if params[:ProfileName].blank?
    return if @contact.name == params[:ProfileName]

    # Only update if current name exactly matches the phone number or formatted phone number
    return unless contact_name_matches_phone_number?

    @contact.update!(name: params[:ProfileName])
  end

  def contact_name_matches_phone_number?
    @contact.name == phone_number || @contact.name == formatted_phone_number
  end
end
