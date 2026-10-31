# [FORK CONNECTEI] modifications/025-envio-entrada-e-erro-instagram.md
#
# Como o fork registra o desfecho de um envio do Instagram que não terminou num
# `message_id` da Graph (contrato fork↔ERP §4). Usada pelo envio (mod 025) e
# pela política da automação (mod 027).
#
# - `fail!`: `failed` + `external_error` + `external_error_code/subcode/kind`, numa
#   única escrita — um único `message_updated` chega ao ERP com tudo.
# - `unconfirmed!`: timeout DEPOIS do envio. A mensagem fica `sent` e ganha
#   `delivery_unconfirmed = true`: ela pode ter chegado, e `failed` faria o atendente
#   (ou o ERP) reenviar e duplicar.
# - Nos dois casos, `source_id` já gravado no banco (o eco adotou a mensagem
#   enquanto a Graph respondia, mod 027b) é prova de entrega e vence.
class Connectei::Instagram::DeliveryOutcome
  LOG_PREFIX = '[CONNECTEI][ig-send]'.freeze

  def initialize(message)
    @message = message
  end

  def delivered_elsewhere?
    @message.source_id.blank? && Message.where(id: @message.id).where.not(source_id: [nil, '']).exists?
  end

  # Só em memória: quem chama persiste junto com o status.
  def assign_error_attributes(kind:, code: nil, subcode: nil)
    @message.content_attributes = @message.content_attributes.merge(
      'external_error_code' => code, 'external_error_subcode' => subcode, 'external_error_kind' => kind
    )
  end

  def fail!(kind:, description:)
    if delivered_elsewhere?
      Rails.logger.warn("#{LOG_PREFIX} message_id=#{@message.id}: #{description}; já tem source_id, mantida como enviada")
      return false
    end

    assign_error_attributes(kind: kind)
    Messages::StatusUpdateService.new(@message, 'failed', description).perform
    Rails.logger.warn("#{LOG_PREFIX} message_id=#{@message.id} falhou: #{description}")
    true
  end

  def unconfirmed!(error)
    @message.reload
    return false if @message.source_id.present?

    @message.update!(content_attributes: @message.content_attributes.merge(
      'delivery_unconfirmed' => true,
      'delivery_diagnostics' => { 'error' => "#{error.class}: #{error.message}", 'at' => Time.current.iso8601 }
    ))
    Rails.logger.warn("#{LOG_PREFIX} message_id=#{@message.id}: entrega não confirmada (#{error.class})")
    true
  end
end
