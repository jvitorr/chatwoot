# [FORK CONNECTEI] modifications/024-repasse-de-eventos-instagram-ao-erp.md
#
# Repassa ao ERP um evento do Instagram que não é mensagem (comentário, referral
# solto), montado pelo `Connectei::Instagram::ChangesRouter`.
#
# FILA PRÓPRIA (`connectei_instagram`)
# As filas do Sidekiq têm prioridade estrita (`config/sidekiq.yml`). Num "Reels
# viral" chegam dezenas de comentários por segundo numa conta; em `default` eles
# disputariam o mesmo lugar dos DMs de todas as lojas. Na fila própria, abaixo de
# `default`, o Direct sai primeiro — e a fila pode ganhar um processo dedicado
# (`sidekiq -q connectei_instagram`) sem mexer no resto.
#
# RETRY
# O webhook da Meta já recebeu 200 (o controller responde antes de processar):
# este repasse é a ÚNICA cópia do evento. Por isso 15 tentativas com backoff
# polinomial (~35h) só para erro transitório (rede, timeout, 5xx/408/425/429); o
# 4xx definitivo é registrado pelo serviço e não volta. Esgotadas as 15, a exceção
# sobe para o Sidekiq, que aplica a política padrão e manda o job para a dead set —
# onde ele ainda pode ser reenfileirado à mão.
class Connectei::ForwardInstagramEventJob < ApplicationJob
  queue_as :connectei_instagram

  retry_on Connectei::Instagram::EventForwarder::RetryableError, wait: :polynomially_longer, attempts: 15

  def perform(payload)
    Connectei::Instagram::EventForwarder.new(payload).perform
  rescue Connectei::Instagram::EventForwarder::RetryableError => e
    Rails.logger.warn("[CONNECTEI][ig-forward] tentativa #{executions} falhou: #{e.message}")
    raise
  end
end
