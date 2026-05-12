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

  def twilio_whatsapp_bsuid_source_id
    from = params[:From].to_s
    return from if from.match?(/\Awhatsapp:[A-Z]{2}\.(?:ENT\.)?[A-Za-z0-9]+\z/)
  end
end
