# [FORK CONNECTEI] modifications/027-politica-de-envio-da-automacao.md
#
# Aplicada com `prepend` em `Instagram::SendOnInstagramService`. Vale para toda
# mensagem da automação do ERP — a que traz `content_attributes.flow_effect_key`:
#
# 1. Nunca leva `HUMAN_AGENT`. A Meta só permite a tag em resposta escrita por
#    humano; o ERP posta como `User`, então o #15932 (mod 023), que olha o tipo do
#    remetente, sozinho não basta.
# 2. Se a última mensagem RECEBIDA da conversa tem mais de 24h (ou não existe), e
#    não é private reply, a Graph não é chamada: a mensagem vira `failed` com
#    `external_error_kind: window_closed`. Enviar daria erro na Meta de qualquer
#    jeito; tentar mesmo assim só gasta cota e expõe o app a enforcement.
#    O private reply tem regra própria (7 dias do comentário, aplicada pela Meta).
#
# É defesa em profundidade: o ERP checa a janela antes de pedir o envio
# (`channel-send-policy`), e o fork confere de novo na hora de enviar.
module Connectei::Instagram::AutomationPolicyExtension
  WINDOW = Conversations::MessageWindowService::MESSAGING_WINDOW_24_HOURS

  private

  def perform_reply
    return block_automation_outside_window if automation_message? && !automation_private_reply? && customer_window_closed?

    super
  end

  def merge_human_agent_tag(params)
    return params if automation_message?

    super
  end

  def automation_message?
    Connectei::Instagram::OutboundPayload.flow_effect_key(message).present?
  end

  def automation_private_reply?
    Connectei::Instagram::OutboundPayload.private_reply_comment_id(message).present?
  end

  def customer_window_closed?
    last_incoming = conversation.messages.incoming.last
    last_incoming.nil? || last_incoming.created_at < WINDOW.ago
  end

  def block_automation_outside_window
    Connectei::Instagram::DeliveryOutcome.new(message).fail!(
      kind: 'window_closed',
      description: 'window_closed - Outside the 24-hour window since the last customer message: automation message not sent'
    )
  end
end
