# [FORK CONNECTEI] modifications/029-retry-do-webhook-de-conta-instagram.md
#
# Qual job entrega o webhook de conta de um evento. Inbox Instagram (Instagram
# Login, o canal das automações do ERP) vai pelo job com retry; todo o resto
# segue o `WebhookJob` do upstream, sem retry — comportamento preservado.
module Connectei::AccountWebhookRouting
  INSTAGRAM_CHANNEL_TYPE = 'Channel::Instagram'.freeze

  module_function

  # [job, webhook_type]
  def job_for(inbox)
    return [Connectei::InstagramAccountWebhookJob, Connectei::InstagramAccountWebhookJob::WEBHOOK_TYPE] if instagram?(inbox)

    [WebhookJob, :account_webhook]
  end

  def instagram?(inbox)
    inbox.respond_to?(:channel_type) && inbox.channel_type == INSTAGRAM_CHANNEL_TYPE
  end
end
