# [FORK CONNECTEI] modifications/029-retry-do-webhook-de-conta-instagram.md
#
# Webhook de CONTA (`account.webhooks`, o que entrega `message_created`/
# `message_updated` ao ERP) para eventos de inbox Instagram, com retry.
#
# O upstream entrega o webhook de conta pelo `WebhookJob` sem retry, e o
# `Webhooks::Trigger` engole a falha: um blip do ERP perde o evento em silêncio.
# No Instagram isso é perda de automação — a resposta do cliente ao private reply
# (o `respondeu` do fluxo) é um `message_created` que nunca mais volta.
#
# Mesma política da mod 006 (`ApiInbox::WebhookJob`): transporte e 429/5xx
# levantam `RetryableError`, 5 tentativas com backoff polinomial (~6 min). No
# esgotamento o `handle_failure` só registra: para o tipo `:instagram_account_webhook`
# o Trigger não mexe na mensagem (ela não é do ERP — já foi entregue ao Instagram).
# Reentrega é segura: o ERP é idempotente (SET NX + jobId) e o `X-Chatwoot-Delivery`
# se repete nas tentativas.
class Connectei::InstagramAccountWebhookJob < WebhookJob
  queue_as :medium

  WEBHOOK_TYPE = :instagram_account_webhook

  retry_on Webhooks::Trigger::RetryableError, wait: :polynomially_longer, attempts: 5 do |job, error|
    url, payload, webhook_type = job.arguments
    kwargs = job.arguments.last.is_a?(Hash) ? job.arguments.last : {}
    Webhooks::Trigger.new(url, payload, webhook_type || WEBHOOK_TYPE, secret: kwargs[:secret],
                                                                      delivery_id: kwargs[:delivery_id]).handle_failure(error)
  end

  def perform(url, payload, webhook_type = WEBHOOK_TYPE, secret: nil, delivery_id: nil)
    super(url, payload, webhook_type, secret: secret, delivery_id: delivery_id)
  rescue Webhooks::Trigger::RetryableError => e
    Rails.logger.warn("[Connectei::InstagramAccountWebhookJob] attempt #{executions} failed #{e.message} " \
                      "event=#{payload[:event]} message_id=#{payload[:id]}")
    raise
  end
end
