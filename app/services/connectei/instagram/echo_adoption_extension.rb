# [FORK CONNECTEI] modifications/027b-eco-e-idempotencia.md
#
# Aplicada com `prepend` em `Messages::Instagram::BaseMessageBuilder`.
#
# O PROBLEMA ("atendente fantasma")
# Toda mensagem que o fork envia volta como eco (`is_echo`). O upstream só
# reconhece o eco pelo `mid` (`find_by(source_id)`), e o controller do webhook
# espera 2s fixos para dar tempo de o envio gravar o `source_id`. Quando a Graph
# demora mais que isso (ou o envio cai em timeout, mod 025), o eco chega com um
# `mid` que ninguém conhece e vira uma mensagem NOVA de saída, `sender: nil`,
# `external_echo: true` — exatamente a forma de "resposta digitada no app do
# Instagram". O ERP lê isso como atendente humano e pausa a automação.
#
# A CORREÇÃO
# Eco com `mid` desconhecido ADOTA a mensagem de saída pendente da mesma conversa
# (contrato fork↔ERP §4): mesmo `contact_inbox`, `source_id` nulo, criada há no
# máximo 5 min, não `failed`, mesmo texto normalizado. A adotada ganha o `mid` como
# `source_id` (prova de entrega: o `delivery_unconfirmed` sai) e nenhuma mensagem
# nova nasce. Sem candidata, o comportamento é o do upstream: o que foi digitado no
# app do Instagram continua virando mensagem humana.
module Connectei::Instagram::EchoAdoptionExtension
  ADOPTION_WINDOW = 5.minutes
  MAX_CANDIDATES = 20

  private

  def message_already_exists?
    super || adopt_pending_outgoing_message
  end

  def adopt_pending_outgoing_message
    return false unless @outgoing_echo

    text = normalized_echo_text(message_content)
    return false if text.blank? || message_identifier.blank?

    contact_inbox = @inbox.contact_inboxes.find_by(source_id: message_source_id)
    return false if contact_inbox.nil?

    candidate = pending_outgoing_messages(contact_inbox).find { |pending| same_text?(pending, text) }
    candidate.present? && adopt_echo!(candidate)
  end

  def pending_outgoing_messages(contact_inbox)
    Message.joins(:conversation)
           .where(conversations: { contact_inbox_id: contact_inbox.id })
           .where(inbox_id: @inbox.id, message_type: :outgoing, private: false, source_id: nil)
           .where.not(status: :failed)
           .where('messages.created_at >= ?', ADOPTION_WINDOW.ago)
           .reorder('messages.created_at ASC, messages.id ASC')
           .limit(MAX_CANDIDATES)
  end

  # O eco traz o texto que saiu (`outgoing_content`, já com o markdown do canal
  # aplicado); compara com ele e com o `content` cru.
  def same_text?(pending, text)
    [pending.outgoing_content, pending.content].any? { |candidate_text| normalized_echo_text(candidate_text) == text }
  end

  def normalized_echo_text(text)
    text.to_s.unicode_normalize(:nfc).gsub(/\s+/, ' ').strip
  end

  def adopt_echo!(candidate)
    adopted = false
    candidate.with_lock do
      next if candidate.source_id.present?

      candidate.update!(
        source_id: message_identifier,
        content_attributes: candidate.content_attributes.except('delivery_unconfirmed', 'delivery_diagnostics')
      )
      adopted = true
    end
    Rails.logger.info("[CONNECTEI][ig-echo] eco #{message_identifier} adotou a mensagem #{candidate.id} (sem mensagem humana nova)") if adopted
    adopted
  end
end
