# [FORK CONNECTEI] modifications/026-endpoints-connectei-instagram.md
#
# Aplicada com `prepend` em `Instagram::MessageText` (Instagram Login).
#
# O contato criado pelo `comment-threads` nasce sem User Profile (a Meta só
# libera o perfil de quem já mandou DM) e com `connectei_profile_pending = true`.
# O fluxo do upstream só busca o perfil quando o `contact_inbox` NÃO existe — e
# para esse contato ele já existe. Aqui, no primeiro DM recebido dele, o perfil é
# buscado, gravado como o upstream grava (`social_instagram_*`), o nome provisório
# (= username) troca pelo nome do perfil e a marca sai.
#
# Falha na busca (consentimento, rede) mantém a marca para o próximo DM e nunca
# impede a mensagem de ser criada.
module Connectei::Instagram::PendingProfileExtension
  PENDING_KEY = 'connectei_profile_pending'.freeze

  private

  def create_message
    refresh_connectei_pending_profile
    super
  end

  def refresh_connectei_pending_profile
    contact = connectei_pending_contact
    return if contact.nil?

    profile = fetch_instagram_user(@contact_inbox.source_id)
    apply_connectei_profile(contact, profile) if profile.present? && profile['username'].present?
  rescue StandardError => e
    Rails.logger.warn("[CONNECTEI][ig-profile] perfil pendente do contato #{@contact_inbox&.contact_id} não atualizado: #{e.class}: #{e.message}")
  end

  # Só DM recebido (no eco a pessoa ainda não escreveu, e a Meta nega o perfil).
  def connectei_pending_contact
    return if agent_message_via_echo?

    contact = @contact_inbox&.contact
    contact if contact&.additional_attributes.to_h[PENDING_KEY]
  end

  def apply_connectei_profile(contact, profile)
    attributes = contact.additional_attributes.to_h
    provisional_name = attributes['social_instagram_user_name']
    updates = { additional_attributes: attributes.merge(build_instagram_attributes(profile).deep_stringify_keys).except(PENDING_KEY) }
    # Só troca o nome se ninguém mexeu nele desde o comment-threads.
    updates[:name] = profile['name'].presence || profile['username'] if contact.name.blank? || contact.name == provisional_name
    contact.update!(updates)
    ::Avatar::AvatarFromUrlJob.perform_later(contact, profile['profile_pic']) if profile['profile_pic'].present? && !contact.avatar.attached?
  end
end
