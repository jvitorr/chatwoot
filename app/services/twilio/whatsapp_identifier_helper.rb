module Twilio::WhatsappIdentifierHelper
  def update_twilio_whatsapp_identifiers
    return unless twilio_channel.whatsapp?

    Whatsapp::IdentifierSyncService.new(contact_inbox: @contact_inbox, contact: @contact).perform(
      bsuid: params[:ExternalUserId].presence || twilio_whatsapp_bsuid_source_id,
      parent_bsuid: params[:ParentExternalUserId],
      username: params[:ProfileUsername].presence || params[:Username]
    )
  end

  def twilio_whatsapp_phone_source?
    params[:From].to_s.match?(/\Awhatsapp:\+\d{1,15}\z/)
  end

  def twilio_whatsapp_bsuid
    params[:ExternalUserId].presence || twilio_whatsapp_bsuid_source_id
  end

  def twilio_whatsapp_display_identifier
    twilio_whatsapp_bsuid.to_s.delete_prefix('whatsapp:').presence
  end

  def twilio_whatsapp_bsuid_source_id
    from = params[:From].to_s
    return from if from.match?(/\Awhatsapp:[A-Z]{2}\.(?:ENT\.)?[A-Za-z0-9]+\z/)
  end

  def find_twilio_contact_inbox(source_id)
    return unless twilio_channel.whatsapp?

    inbox.contact_inboxes.find_by(source_id: source_id) ||
      find_twilio_contact_inbox_by_bsuid
  end

  def twilio_contact_inbox(source_id)
    find_twilio_contact_inbox(source_id) ||
      ::ContactInboxWithContactBuilder.new(
        source_id: source_id,
        inbox: inbox,
        contact_attributes: contact_attributes
      ).perform
  end

  def find_twilio_contact_inbox_by_bsuid
    bsuid = twilio_whatsapp_display_identifier
    return if bsuid.blank?

    inbox.contact_inboxes.find_by(whatsapp_bsuid: bsuid)
  end

  def twilio_whatsapp_source_id_from_bsuid
    bsuid = twilio_whatsapp_display_identifier
    return if bsuid.blank?

    find_twilio_contact_inbox_by_bsuid&.source_id || "whatsapp:#{bsuid}"
  end
end
