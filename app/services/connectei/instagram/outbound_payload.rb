# [FORK CONNECTEI] modifications/025-envio-entrada-e-erro-instagram.md
#
# Leitura pura do que o ERP pede numa mensagem de saída do Instagram (contrato
# fork↔ERP §3). Usada pela `Connectei::Instagram::SendExtension` (mod 025) e pela
# política da automação (mod 027).
module Connectei::Instagram::OutboundPayload
  QUICK_REPLY_LIMIT = 13
  QUICK_REPLY_TITLE_LIMIT = 20

  module_function

  # `content_attributes.ig_private_reply.comment_id`, ou nil.
  def private_reply_comment_id(message)
    reply = message.content_attributes['ig_private_reply']
    reply.is_a?(Hash) ? reply.with_indifferent_access[:comment_id].presence&.to_s : nil
  end

  # `input_select` → `quick_replies` da Meta: até 13, título cortado em 20
  # caracteres, `payload` = `value`. O ERP já garante os limites; o corte aqui é
  # só proteção.
  def quick_replies(message)
    return [] unless message.content_type == 'input_select'

    Array(message.items).select { |item| item.is_a?(Hash) }.first(QUICK_REPLY_LIMIT).map do |item|
      item = item.with_indifferent_access
      { content_type: 'text', title: item[:title].to_s[0, QUICK_REPLY_TITLE_LIMIT], payload: item[:value].to_s }
    end
  end

  # Marca da automação do ERP (também a chave de idempotência da mod 027b).
  def flow_effect_key(message)
    message.content_attributes['flow_effect_key'].presence
  end
end
