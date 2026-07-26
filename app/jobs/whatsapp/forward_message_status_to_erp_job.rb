# Repassa ao Connectei (ERP) os eventos de status cujo `wamid` o Chatwoot não
# reconhece.
#
# POR QUE ISSO EXISTE
# A Meta entrega o campo `messages` a UM destino por WABA, e esse destino é o
# Chatwoot: `Whatsapp::WebhookSetupService` assina a WABA programaticamente e
# refaz a inscrição na reautorização, então repontar o webhook para o ERP na mão
# seria sobrescrito em silêncio. ERP e Chatwoot também compartilham o mesmo Meta
# App, o que descarta o fan-out por app (dois apps inscritos na mesma WABA, cada
# um com sua callback URL).
#
# O ERP dispara campanhas direto na Graph API, sem passar pelo Chatwoot. Esses
# `wamid` não têm `Message` correspondente aqui, então o `process_statuses`
# desistia deles no `return unless find_message_by_source_id(...)` — o `sent`, o
# `delivered` e o `failed` das campanhas chegavam e eram descartados. Este job
# entrega esse recorte ao ERP.
#
# ORFANDADE NÃO É ERRO
# Existe uma corrida conhecida (ver `MessageDedupLock` / `lock_message_source_id!`)
# em que a Meta entrega o `sent` antes de o Chatwoot gravar a mensagem de saída.
# Nessa janela, uma mensagem legítima daqui é classificada como órfã e repassada.
# É inofensivo por contrato: o ERP descarta `wamid` desconhecido em silêncio.
#
# JOB PRÓPRIO, DE PROPÓSITO
# Não fica inline no `WhatsappEventsJob`: lá, qualquer exceção reprocessa o job
# inteiro, e o `process_events` refaria todo o processamento do inbound. Uma
# indisponibilidade do ERP passaria a reprocessar em massa a fila de atendimento
# — acoplando a saúde do sistema mais crítico à do menos crítico. Aqui, o pior
# caso é a fila `low` acumular repasses até o ERP voltar.
class Whatsapp::ForwardMessageStatusToErpJob < ApplicationJob
  queue_as :low

  # Só erro de rede e 5xx do ERP levantam `Error` e chegam aqui — são
  # transitórios e valem retentar. Um 4xx (assinatura inválida, corpo
  # malformado) é contrato quebrado: o service registra e não levanta, porque
  # insistir nunca resolveria e só encheria a fila.
  retry_on Whatsapp::ErpStatusForwardService::Error, wait: :polynomially_longer, attempts: 8

  def perform(statuses)
    return if statuses.blank?

    Whatsapp::ErpStatusForwardService.new(statuses).perform
  end
end
