module Whatsapp::IncomingMessageIdentifierHelper
  def set_contact_from_echo
    message = messages_data.first
    source_identifier = outgoing_message_source_identifier(message)
    return if source_identifier.blank?

    @contact_inbox = find_or_create_contact_inbox(
      source_identifier: source_identifier,
      bsuid: message[:to_user_id],
      contact_attributes: contact_attributes_for_identifier(source_identifier, message[:to])
    )
    @contact = @contact_inbox.contact
    update_whatsapp_identifiers(bsuid: message[:to_user_id], parent_bsuid: message[:to_parent_user_id])
  end

  def set_contact_from_message
    contact_params = @processed_params[:contacts]&.first
    return if contact_params.blank?

    source_identifier = incoming_message_source_identifier(contact_params)
    return if source_identifier.blank?

    @contact_inbox = find_or_create_contact_inbox(
      source_identifier: source_identifier,
      bsuid: whatsapp_bsuid(contact_params),
      contact_attributes: contact_attributes_from_contact_params(contact_params, source_identifier)
    )
    @contact = @contact_inbox.contact
    update_inbound_whatsapp_identifiers(contact_params)
    update_contact_with_profile_name(contact_params)
  end

  def update_inbound_whatsapp_identifiers(contact_params)
    update_whatsapp_identifiers(
      bsuid: whatsapp_bsuid(contact_params),
      parent_bsuid: contact_params[:parent_user_id] || messages_data.first[:from_parent_user_id],
      username: contact_params.dig(:profile, :username)
    )
  end

  def find_or_create_contact_inbox(source_identifier:, bsuid:, contact_attributes:)
    source_id = processed_waid(source_identifier)
    existing_contact_inbox = find_contact_inbox_by_source_or_bsuid(source_id, bsuid)
    return existing_contact_inbox if existing_contact_inbox

    ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: contact_attributes
    ).perform
  end

  def find_contact_inbox_by_source_or_bsuid(source_id, bsuid)
    inbox.contact_inboxes.find_by(source_id: source_id) ||
      find_contact_inbox_by_bsuid(bsuid)
  end

  def find_contact_inbox_by_bsuid(bsuid)
    bsuid = normalized_whatsapp_bsuid(bsuid)
    return if bsuid.blank?

    inbox.contact_inboxes.find_by(whatsapp_bsuid: bsuid)
  end

  def whatsapp_bsuid(contact_params)
    contact_params[:user_id] || messages_data.first[:from_user_id]
  end

  def normalized_whatsapp_bsuid(bsuid)
    bsuid.to_s.delete_prefix('whatsapp:').presence
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
