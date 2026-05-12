module Whatsapp::IncomingMessageIdentifierHelper
  def set_contact_from_echo
    message = messages_data.first
    source_identifier = outgoing_message_source_identifier(message)
    return if source_identifier.blank?

    @contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: processed_waid(source_identifier),
      inbox: inbox,
      contact_attributes: contact_attributes_for_identifier(source_identifier, message[:to])
    ).perform
    @contact = @contact_inbox.contact
    update_whatsapp_identifiers(bsuid: message[:to_user_id], parent_bsuid: message[:to_parent_user_id])
  end

  def set_contact_from_message
    contact_params = @processed_params[:contacts]&.first
    return if contact_params.blank?

    source_identifier = incoming_message_source_identifier(contact_params)
    return if source_identifier.blank?

    @contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: processed_waid(source_identifier),
      inbox: inbox,
      contact_attributes: contact_attributes_from_contact_params(contact_params, source_identifier)
    ).perform
    @contact = @contact_inbox.contact
    update_inbound_whatsapp_identifiers(contact_params)
    update_contact_with_profile_name(contact_params)
  end

  def update_inbound_whatsapp_identifiers(contact_params)
    update_whatsapp_identifiers(
      bsuid: contact_params[:user_id] || messages_data.first[:from_user_id],
      parent_bsuid: contact_params[:parent_user_id] || messages_data.first[:from_parent_user_id],
      username: contact_params.dig(:profile, :username)
    )
  end

  def incoming_message_source_identifier(contact_params)
    contact_params[:wa_id].presence ||
      messages_data.first[:from].presence ||
      contact_params[:user_id].presence ||
      messages_data.first[:from_user_id].presence
  end

  def outgoing_message_source_identifier(message)
    message[:to].presence || message[:to_user_id].presence
  end

  def contact_attributes_from_contact_params(contact_params, source_identifier)
    contact_attributes_for_identifier(
      contact_params.dig(:profile, :name).presence || source_identifier,
      contact_params[:wa_id].presence || messages_data.first[:from].presence
    )
  end

  def contact_attributes_for_identifier(name, phone_identifier)
    phone_number = whatsapp_phone_number(phone_identifier)
    return { name: name } if phone_number.blank?

    formatted_phone_number = "+#{phone_number}"
    display_name = name == phone_identifier ? formatted_phone_number : name
    { name: display_name, phone_number: formatted_phone_number }
  end

  def whatsapp_phone_number(identifier)
    identifier = identifier.to_s
    return if identifier.blank?
    return unless identifier.match?(/\A\d{1,15}\z/)

    identifier
  end

  def update_whatsapp_identifiers(bsuid: nil, parent_bsuid: nil, username: nil)
    Whatsapp::IdentifierSyncService.new(contact_inbox: @contact_inbox, contact: @contact).perform(
      bsuid: bsuid,
      parent_bsuid: parent_bsuid,
      username: username
    )
  end

  def update_whatsapp_identifiers_from_status(status)
    contact_inbox = @message&.conversation&.contact_inbox
    return if contact_inbox.blank?

    Whatsapp::IdentifierSyncService.new(contact_inbox: contact_inbox, contact: contact_inbox.contact).perform(
      bsuid: status[:recipient_user_id],
      parent_bsuid: status[:recipient_parent_user_id]
    )
  end
end
