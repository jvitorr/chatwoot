# [FORK CONNECTEI] modifications/025-envio-entrada-e-erro-instagram.md
#
# Atributos que o fork grava em `content_attributes` de toda mensagem que ENTRA
# pelo Instagram, lidos do item `messaging` cru da Meta (contrato fork↔ERP §4):
#
#   ig_event                  "story_mention" | "story_reply" | "share"
#   quick_reply_payload       toque em quick reply
#   postback_payload/_title   postback (ice breaker, botão) — mod 023 (#14237)
#   referral                  { ref, source, type, ad_id, ads_context_data }
#
# `ig_event` é o marcador ESTÁVEL do tipo de evento: entra no INSERT da mensagem,
# antes de qualquer chamada à Graph. O `image_type` do upstream só é gravado
# depois que a busca da story dá certo — quando ela falha, a menção chegava ao ERP
# como mensagem comum e o texto gerado pelo servidor casava gatilhos de palavra.
module Connectei::Instagram::InboundAttributes
  SHARE_ATTACHMENT_TYPES = %w[share ig_post ig_reel reel ig_story].freeze

  module_function

  def extract(messaging)
    messaging = messaging.to_h.with_indifferent_access
    message = hash_at(messaging, :message)
    postback = hash_at(messaging, :postback)

    {
      ig_event: ig_event(message),
      quick_reply_payload: hash_at(message, :quick_reply)[:payload].presence,
      postback_payload: postback[:payload].presence,
      postback_title: postback[:title].presence,
      referral: referral(message[:referral] || postback[:referral] || messaging[:referral])
    }.compact
  end

  def ig_event(message)
    types = Array(message[:attachments]).filter_map { |attachment| attachment.to_h.with_indifferent_access[:type].presence&.to_s }
    return 'story_mention' if types.include?('story_mention')
    return 'story_reply' if hash_at(message, :reply_to)[:story].present?

    'share' if types.intersect?(SHARE_ATTACHMENT_TYPES)
  end

  def referral(raw)
    return unless raw.is_a?(Hash) && raw.present?

    Connectei::Instagram::EventPayload.referral_attributes(raw)
  end

  def hash_at(source, key)
    value = source[key]
    value.is_a?(Hash) ? value.with_indifferent_access : {}.with_indifferent_access
  end
end
