# 029 — Retry do webhook de conta para eventos de inbox Instagram

**Status:** ativo
**Arquivos do core alterados (marcados `# [FORK CONNECTEI] modifications/029`):**
`app/listeners/webhook_listener.rb` (o job do webhook de conta passa a ser escolhido pelo inbox; o inbox é
repassado de `deliver_webhook_payloads`), `lib/webhooks/trigger.rb` (o tipo novo entra na regra de retry da mod 006)
**Arquivos novos:** `app/jobs/connectei/instagram_account_webhook_job.rb`, `app/services/connectei/account_webhook_routing.rb`
+ specs (`spec/jobs/connectei/instagram_account_webhook_job_spec.rb`, `spec/listeners/webhook_listener_instagram_spec.rb`)
**Base:** mod [006](006-webhook-inbox-api-timeout-retry.md)

---

## O problema

O ERP recebe as mensagens do Instagram pelo **webhook de conta** (`account.webhooks`:
`message_created`, `message_updated`, `conversation_created`…). O upstream entrega esse
webhook pelo `WebhookJob` **sem retry**, e o `Webhooks::Trigger` engole a falha: um blip
do ERP perde o evento em silêncio. A mod 006 resolveu isso só para o webhook do **inbox
API** (`Channel::Api`).

No Instagram a perda é de automação: a resposta do cliente ao private reply (o `respondeu`
do fluxo) é um `message_created` — se ele some, o fluxo sai por `sem_resposta` com a pessoa
tendo respondido.

## O que muda

- `WebhookListener#deliver_account_webhooks` recebe o inbox (quando o evento tem um) e pede
  a `Connectei::AccountWebhookRouting.job_for(inbox)` o job e o tipo:
  - inbox `Channel::Instagram` → `Connectei::InstagramAccountWebhookJob` + `:instagram_account_webhook`;
  - qualquer outro inbox, ou evento sem inbox (`contact_created`…) → `WebhookJob` +
    `:account_webhook` — **o comportamento do upstream, preservado**.
- `Webhooks::Trigger`: `RETRYABLE_TRANSPORT_WEBHOOK_TYPES = %i[api_inbox_webhook instagram_account_webhook]`
  — o tipo novo usa **a mesma regra** do inbox API: transporte (timeout, reset, recusa) e
  429/500/502/503/504 levantam `RetryableError`; 4xx e URL bloqueada falham na hora.
- `Connectei::InstagramAccountWebhookJob` é o espelho do `ApiInbox::WebhookJob`: fila
  `medium`, `retry_on RetryableError, wait: :polynomially_longer, attempts: 5` (~6 min),
  `handle_failure` no esgotamento.
- **Nenhum efeito na mensagem.** Para o tipo novo o `Trigger#handle_error` não tem ramo: a
  mensagem do Instagram já foi entregue (ou recebida) pela Meta, e o ERP fora do ar não muda
  isso. Diferente do inbox API, nada vira `failed` nem `delivery_unconfirmed`.
- Reentrega é segura: o ERP é idempotente (SET NX + jobId) e o `X-Chatwoot-Delivery` é o
  mesmo em todas as tentativas; a assinatura (`X-Chatwoot-Timestamp/Signature`) é recalculada
  a cada uma.

## Por quê — e alternativas descartadas

- **Retry em todo webhook de conta:** mudaria a semântica para todas as integrações de todas
  as contas. O escopo mínimo é o canal das automações (o mesmo raciocínio da mod 006).
- **Reaproveitar `:api_inbox_webhook`:** o `handle_error` desse tipo marca a mensagem
  `failed`/`delivery_unconfirmed` — correto para o inbox API (o ERP é quem entrega), errado
  aqui. Por isso um tipo próprio, sem efeito colateral.
- **Mesma política de 5 tentativas da mod 006** (o contrato pede "a mesma política"): cobre
  um deploy/blip do ERP sem segurar o evento por horas.

## Comportamento num merge de upstream

- `webhook_listener.rb` — risco baixo: a assinatura de `deliver_account_webhooks` ganha o
  `inbox` opcional, a chamada em `deliver_webhook_payloads` passa o inbox, e a linha do job
  troca `WebhookJob` pelo par devolvido pelo `AccountWebhookRouting`. Se o upstream mexer
  nesse método, mantenha as três partes.
- `trigger.rb` — **médio/alto** (o mesmo arquivo da mod 006): manter a constante
  `RETRYABLE_TRANSPORT_WEBHOOK_TYPES` e o uso dela em `retryable_api_inbox_error?`.

## O que verificar depois do merge

```bash
grep -rn "modifications/029" app/listeners lib/webhooks
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec \
  spec/jobs/connectei/instagram_account_webhook_job_spec.rb spec/listeners/webhook_listener_instagram_spec.rb \
  spec/listeners/webhook_listener_spec.rb spec/lib/webhooks spec/jobs/api_inbox
```
