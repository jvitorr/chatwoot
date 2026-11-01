# [FORK CONNECTEI] modifications/025-envio-entrada-e-erro-instagram.md
#
# Extensão do envio do Instagram Login (`Instagram::SendOnInstagramService`),
# aplicada com um `prepend` de uma linha. Contrato fork↔ERP §3 e §4.
#
# - Menu: `content_type: input_select` vira `quick_replies` (OutboundPayload).
# - Private reply: `content_attributes.ig_private_reply.comment_id` troca o
#   destinatário para `{ comment_id }`, sem HUMAN_AGENT. A janela de 24h não se
#   aplica (mod 027); a Meta aplica os 7 dias do comentário.
# - Limitador por conta (Connectei::Instagram::RateLimiter) logo antes da Graph.
# - Erro da Meta estruturado: `external_error_code`, `external_error_subcode` e
#   `external_error_kind`, gravados NA MESMA escrita do `failed` (um único
#   `message_updated` chega ao ERP com tudo).
# - Timeout depois do envio vira `delivery_unconfirmed`, nunca `failed`.
module Connectei::Instagram::SendExtension
  class RateLimited < StandardError
    attr_reader :decision

    def initialize(decision)
      @decision = decision
      super("rate_limited - Connectei #{decision.limit_name} limit reached for this Instagram account (retry in #{decision.retry_after}s)")
    end
  end

  # A requisição pode ter chegado à Meta: só a resposta não voltou.
  AMBIGUOUS_ERRORS = [Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNRESET, Errno::EPIPE, IOError].freeze
  # A conexão nem abriu: com certeza não saiu.
  NOT_SENT_ERRORS = [
    Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError, OpenSSL::SSL::SSLError
  ].freeze
  LOG_PREFIX = '[CONNECTEI][ig-send]'.freeze

  private

  def message_params
    params = super
    if private_reply?
      params[:recipient] = { comment_id: private_reply_comment_id }
    elsif quick_replies.present?
      # Lista de objetos não sobrevive ao form-encoding do HTTParty
      # (`message[quick_replies][][title]` vira um item por campo na Graph). O
      # `message` vai inteiro como JSON, formato que a Graph aceita em parâmetro
      # de objeto.
      params[:message] = params[:message].merge(quick_replies: quick_replies).to_json
    end
    params
  end

  def merge_human_agent_tag(params)
    return params if private_reply?

    super
  end

  def send_message(message_content)
    acquire_rate_limits!(message_content)
    super
  end

  def process_response(response, message_content)
    return keep_adopted_delivery(response) if failed_response?(response) && delivery_outcome.delivered_elsewhere?

    annotate_private_reply_recipient(response) if message_content.dig(:recipient, :comment_id).present?
    super
  end

  def external_error(response)
    details = Connectei::Instagram::GraphError.details(response)
    kind = Connectei::Instagram::GraphError.message_kind(details[:code], details[:subcode], private_reply: private_reply?)
    delivery_outcome.assign_error_attributes(kind: kind, code: details[:code], subcode: details[:subcode])
    super
  end

  def handle_error(error)
    case error
    when RateLimited
      delivery_outcome.fail!(kind: 'rate_limited', description: error.message)
    when *AMBIGUOUS_ERRORS
      delivery_outcome.unconfirmed!(error)
    when *NOT_SENT_ERRORS
      delivery_outcome.fail!(kind: 'unknown', description: "#{error.class} - #{error.message}")
    else
      super
    end
  end

  def delivery_outcome
    @delivery_outcome ||= Connectei::Instagram::DeliveryOutcome.new(message)
  end

  def private_reply_comment_id
    return @private_reply_comment_id if defined?(@private_reply_comment_id)

    @private_reply_comment_id = Connectei::Instagram::OutboundPayload.private_reply_comment_id(message)
  end

  def private_reply?
    private_reply_comment_id.present?
  end

  def quick_replies
    @quick_replies ||= Connectei::Instagram::OutboundPayload.quick_replies(message)
  end

  # A Meta devolve o IGSID de quem recebeu. Se ele não for o `source_id` do
  # contato, o `from.id` do comentário e o IGSID do Direct divergiram (premissa
  # que só uma conta real confirma): registra para o vínculo poder ser corrigido.
  def annotate_private_reply_recipient(response)
    return if failed_response?(response)

    returned = response.parsed_response['recipient_id'].to_s
    expected = contact.get_source_id(inbox.id).to_s
    return if returned.blank? || returned == expected

    reply = message.content_attributes['ig_private_reply'].to_h.merge('recipient_id' => returned)
    message.content_attributes = message.content_attributes.merge('ig_private_reply' => reply)
    Rails.logger.warn("#{LOG_PREFIX} private reply message_id=#{message.id}: recipient_id #{returned} difere do source_id #{expected}")
  end

  # O teto escasso (private reply por hora) é consultado por último, para não
  # gastar o slot dele num envio que o limite por segundo recusaria.
  def acquire_rate_limits!(message_content)
    limiter = Connectei::Instagram::RateLimiter.new(channel.instagram_id)
    decision = limiter.acquire_send
    decision = limiter.acquire_private_reply if decision.allowed? && message_content.dig(:recipient, :comment_id).present?
    raise RateLimited, decision unless decision.allowed?
  end

  def failed_response?(response)
    parsed = response.parsed_response
    !response.success? || !parsed.is_a?(Hash) || parsed['error'].present?
  end

  # `source_id` gravado enquanto a Graph respondia (eco adotado, mod 027b) é prova
  # de entrega: um erro tardio não pode virar `failed` (mesmo princípio da mod 006).
  def keep_adopted_delivery(response)
    Rails.logger.warn("#{LOG_PREFIX} message_id=#{message.id}: Graph devolveu erro (#{response.code}) mas a mensagem " \
                      'já tem source_id (eco adotado); mantida como enviada')
    nil
  end
end
