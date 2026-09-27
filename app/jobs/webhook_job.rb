class WebhookJob < ApplicationJob
  queue_as :medium

  # [FORK CONNECTEI] modifications/023-webhook-de-conta-retry.md
  # O webhook de conta e o canal de eventos do ERP. Sem retry, um deploy/restart
  # do ERP (connection refused/timeout) ou um 503 deliberado (Redis fora) perdia
  # a mensagem do cliente para sempre. Mesma politica do inbox API (006):
  # ~3s, 18s, 83s, 258s -> janela total de ~6 min. O retry reenfileira o MESMO
  # job (mesmos argumentos): payload e delivery_id identicos, entao o dedupe do
  # ERP (id da mensagem) mantem a reentrega idempotente.
  # AgentBots::WebhookJob e ApiInbox::WebhookJob declaram o proprio retry_on
  # para a mesma excecao; o handler declarado por ultimo (o da subclasse) vence,
  # entao a politica deles nao muda.
  retry_on Webhooks::Trigger::RetryableError, wait: :polynomially_longer, attempts: 5 do |job, error|
    url, payload, webhook_type, kwargs = job.arguments
    webhook_type = :account_webhook unless webhook_type.is_a?(Symbol)
    kwargs = {} unless kwargs.is_a?(Hash)
    Webhooks::Trigger.new(url, payload, webhook_type, secret: kwargs[:secret], delivery_id: kwargs[:delivery_id]).handle_failure(error)
  end

  #  There are 3 types of webhooks, account, inbox and agent_bot
  def perform(url, payload, webhook_type = :account_webhook, secret: nil, delivery_id: nil)
    Webhooks::Trigger.execute(url, payload, webhook_type, secret: secret, delivery_id: delivery_id)
  rescue Webhooks::Trigger::RetryableError => e
    # [FORK CONNECTEI] modifications/023: so o webhook de conta loga aqui; as
    # subclasses (agent bot, inbox API) logam as proprias tentativas.
    log_retry_attempt(e, payload, delivery_id) if webhook_type == :account_webhook
    raise
  end

  private

  def log_retry_attempt(error, payload, delivery_id)
    Rails.logger.warn(
      "[WebhookJob] account_webhook attempt #{executions} failed #{error.message} " \
      "event=#{payload[:event]} id=#{payload[:id]} delivery_id=#{delivery_id}"
    )
  end
end
