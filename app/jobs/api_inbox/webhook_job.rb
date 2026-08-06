# [FORK CONNECTEI] modifications/006-webhook-inbox-api-timeout-retry.md
# Retry dedicado para webhooks de inbox API (Channel::Api). O upstream dispara
# esses webhooks pelo WebhookJob generico, sem retry: um blip de rede perdia o
# evento em silencio e marcava a mensagem como failed. Espelha o formato de
# AgentBots::WebhookJob. Redelivery e segura: o consumidor (ERP) e idempotente
# por chatwootMessageId.
class ApiInbox::WebhookJob < WebhookJob
  queue_as :medium

  # ~3s, 18s, 83s, 258s -> janela total de ~6 min. Ha um humano esperando o
  # desfecho do envio; mais que isso vira ruido, menos que isso nao cobre um
  # deploy/blip do consumidor.
  retry_on Webhooks::Trigger::RetryableError, wait: :polynomially_longer, attempts: 5 do |job, error|
    url, payload, webhook_type = job.arguments
    kwargs = job.arguments.last.is_a?(Hash) ? job.arguments.last : {}
    Webhooks::Trigger.new(url, payload, webhook_type || :api_inbox_webhook, secret: kwargs[:secret],
                                                                            delivery_id: kwargs[:delivery_id]).handle_failure(error)
  end

  def perform(url, payload, webhook_type = :api_inbox_webhook, secret: nil, delivery_id: nil)
    super(url, payload, webhook_type, secret: secret, delivery_id: delivery_id)
  rescue Webhooks::Trigger::RetryableError => e
    Rails.logger.warn("[ApiInbox::WebhookJob] attempt #{executions} failed #{e.message} event=#{payload[:event]} message_id=#{payload[:id]}")
    raise
  end
end
