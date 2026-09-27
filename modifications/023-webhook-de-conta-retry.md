# 023 — Webhook de conta: retry em falha transitória (ERP fora do ar ou 503)

**Status:** ativo
**Arquivos do core alterados:** `lib/webhooks/trigger.rb` (guarda de retry para `:account_webhook`), `app/jobs/webhook_job.rb` (`retry_on` + log por tentativa)
**Arquivos novos (aditivos):** nenhum — só specs estendidos (`spec/lib/webhooks/trigger_spec.rb`, `spec/jobs/webhook_job_spec.rb`)
**Imagem publicada:** ainda não publicada
**Estende:** [006](006-webhook-inbox-api-timeout-retry.md) — mesma classificação e mesma política de retry

---

## O problema

O ERP recebe os eventos do chat (`message_created`, `message_updated`, `conversation_*`) por um **webhook de conta**: o próprio ERP o cadastra via `POST /api/v1/accounts/:id/webhooks`, e o `WebhookListener#deliver_account_webhooks` entrega cada evento por `WebhookJob` com `webhook_type = :account_webhook`.

A 006 deu retry ao inbox API e ao agent bot, mas deixou o webhook de conta com o comportamento do upstream: qualquer falha ia para `handle_failure` (só log), e o `WebhookJob` não tinha `retry_on`. Nos dois casos em que o ERP fica fora por pouco tempo, o evento se perdia para sempre:

1. **Deploy/restart do ERP**: `connection refused` ou timeout. Caso verificado ao vivo: o log do Sidekiq mostrava `Exception: Invalid webhook URL ... Failed to open TCP connection` seguido de `Performed WebhookJob ... done`, e a RetrySet estava vazia.
2. **503 deliberado**: o controller do ERP responde 503 quando Redis ou a fila estão fora, justamente para o Chatwoot tentar de novo (`chatWoot.controller.ts`: "503 → Chatwoot retries"). O Chatwoot não tentava.

Consequência no produto: a mensagem que o cliente mandou durante a janela nunca chega ao ERP. A IA não a vê, e a régua de "sem resposta" dispara contra um cliente que respondeu.

## O que muda

### Classificação (`lib/webhooks/trigger.rb`)

- Novo `retryable_account_webhook_error?`, com a **mesma** regra do `retryable_api_inbox_error?` da 006. As duas pontas são o mesmo consumidor (o ERP):
  - **retry**: transporte (`SafeFetch::FetchError`, que cobre open/read timeout, DNS e SSL; `Errno::ECONNREFUSED`; `Errno::ECONNRESET`; `Errno::EPIPE`; `IOError`) e HTTP `429/500/502/503/504` (`RETRYABLE_API_INBOX_STATUSES`);
  - **falha na hora**: 4xx explícito e URL inválida ou bloqueada (`InvalidUrlError` / `UnsafeUrlError`).
- O `execute` passa a consultar `retryable_error?`, que reúne os três predicados (agent bot, inbox API, conta). Cada um continua guardado pelo próprio `webhook_type`, então agent bot e inbox API não mudam.
- No esgotamento, `handle_failure` com `:account_webhook` faz o mesmo de antes: só loga `Exception: Invalid webhook URL ...` e nunca mexe no status da mensagem (o `case` do `handle_error` não tem ramo para conta).

### Retry (`app/jobs/webhook_job.rb`)

- `retry_on Webhooks::Trigger::RetryableError, wait: :polynomially_longer, attempts: 5` no próprio `WebhookJob` (o job que o listener já enfileira). É a política da 006: ~3s, 18s, 83s e 258s, cerca de **6 min** de janela, mais jitter e o tempo de cada tentativa.
- No esgotamento, o bloco chama `Webhooks::Trigger#handle_failure` com a exceção final. O job termina sem relançar, então não cai na retry nativa do Sidekiq (25 tentativas ao longo de ~21 dias).
- Cada tentativa que falha loga `[WebhookJob] account_webhook attempt N failed <erro> event=... id=... delivery_id=...`. O log só sai para `:account_webhook`; as subclasses logam as próprias tentativas.
- **Payload e `delivery_id` idênticos em todas as tentativas**: o `retry_on` reenfileira o **mesmo** job com os **mesmos** argumentos. O payload é o retrato do momento do evento, não é recalculado. Assim o dedupe do ERP (`computeDedupKey`: `event|account|conversation|message.id|updated_at`, com TTL de 24h) colapsa uma reentrega que chegue depois de um sucesso "perdido". `X-Chatwoot-Timestamp` e a assinatura são recalculados a cada tentativa, então um consumidor que exija timestamp recente aceita a reentrega.
- **Subclasses intactas**: `AgentBots::WebhookJob` (3 tentativas, 3s, fila `high`) e `ApiInbox::WebhookJob` (006) declaram o próprio `retry_on` para a mesma exceção. O `ActiveSupport::Rescuable` procura os handlers do último declarado para o primeiro, e o da subclasse é declarado depois do herdado, então ele vence. `spec/jobs/agent_bots/webhook_job_spec.rb` (espera exatamente 3 execuções) é a prova.

### Escopo que vem junto (aceito)

`AutomationRules::ActionService` (ação "enviar webhook"), `Macros::ExecutionService` e o `InstallationWebhookListener` também enfileiram o `WebhookJob` base, e sem `webhook_type` (portanto `:account_webhook` por default). Eles ganham o mesmo retry limitado. É a mesma semântica de entrega, "pelo menos uma vez" e com teto de 5 tentativas, e o custo é baixo. O spec `applies the same bounded retry to callers that omit the webhook type` fixa esse comportamento.

## Alternativas descartadas

- **Subclasse dedicada (`AccountWebhooks::WebhookJob`) enfileirada pelo listener**, como na 006: o Trigger decide o retry pelo `webhook_type`, e automação, macro e webhook de instalação usam o mesmo `:account_webhook` pelo job base. Um `RetryableError` escaparia desse job sem `retry_on` e cairia na retry nativa do Sidekiq (25 tentativas, ~21 dias, sem `handle_failure`). Evitar isso exigiria um `webhook_type` novo, mais invasivo que um `retry_on` no job base.
- **Retry só no 503** (o sinal explícito do ERP): o incidente real era `connection refused` durante deploy.
- **Janela maior (`attempts: 8`, como o forward job da 001)**: a pedido, a política é a mesma da 006. Se deploys do ERP passarem de ~6 min, esta é a alavanca (ver "Trade-offs").

## Trade-offs aceitos

- **Ordem**: um evento reentregue pode chegar depois de eventos posteriores. Chegar tarde é melhor que se perder. No ERP, quem depender de "última mensagem" deve usar `created_at`/`updated_at` do payload, não a ordem de chegada.
- **Retrato antigo**: um `message_updated`/`conversation_updated` reentregue minutos depois carrega o estado do momento do evento. Se um evento mais novo já tiver sido aplicado, uma projeção "último que chega vence" pode regredir. O dedupe não pega isso, porque o `updated_at` é diferente. É o mesmo trade-off que a 006 já aceitou para o inbox API.
- **Carga com ERP travado (não recusando)**: cada tentativa segura uma thread da fila `medium` por até `WEBHOOK_TIMEOUT`, e agora são até 5 tentativas por evento. `connection refused` falha na hora. Vale acompanhar a latência da fila `medium` num incidente longo.
- **Janela de ~6 min**: uma queda mais longa ainda perde eventos, agora com rastro: `Stopped retrying WebhookJob ...` (ActiveJob, nível error) seguido de `Exception: Invalid webhook URL ...`.
- **Fora da lista de transporte**: `Errno::EHOSTUNREACH` e `Errno::ENETUNREACH` não fazem retry, igual à 006. Pela internet pública, com balanceador na frente do ERP, o deploy aparece como refused/timeout/502/503. Se o ERP passar a ser alcançado por rede interna (docker/overlay), vale incluí-los em `transport_error?`, e isso vale para as duas modificações.

## Comportamento no merge de upstream

- `lib/webhooks/trigger.rb`: risco **médio/alto**, o mesmo arquivo da 006. Manter `retryable_error?` (chamado pelo `execute`) e `retryable_account_webhook_error?`.
- `app/jobs/webhook_job.rb`: risco **médio**. Arquivo pequeno, que o upstream raramente toca. Se o upstream adicionar o próprio `retry_on` no `WebhookJob`, reconciliar para um só e conferir que as subclasses continuam declarando o delas: é a ordem de declaração que garante que agent bot e inbox API mantêm a própria política.
- Specs: `trigger_spec.rb` e `webhook_job_spec.rb` são do upstream com blocos do fork marcados `[FORK CONNECTEI] modifications/023`.

## O que verificar depois do merge

```bash
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec \
  spec/lib/webhooks/trigger_spec.rb spec/jobs/webhook_job_spec.rb \
  spec/jobs/api_inbox spec/jobs/agent_bots spec/listeners/webhook_listener_spec.rb
```

Sem Postgres/Redis locais livres, dá para subir um par descartável sem tocar nos containers existentes (as demais armadilhas estão na [005](005-rodar-suite-local.md)):

```bash
docker run -d --name cw-spec-pg -e POSTGRES_HOST_AUTH_METHOD=trust -p 127.0.0.1:5462:5432 pgvector/pgvector:pg16
docker run -d --name cw-spec-redis -p 127.0.0.1:6412:6379 redis:alpine
export POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=5462 POSTGRES_DATABASE=chatwoot_test REDIS_URL=redis://127.0.0.1:6412
RAILS_ENV=test DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bundle exec rails db:create db:schema:load
TZ=UTC FRONTEND_URL= bundle exec rspec <specs acima>
docker rm -f cw-spec-pg cw-spec-redis
```

## Deploy

- Sem migration e sem config nova. Basta imagem nova nos serviços `rails` e `sidekiq` (quem executa o job é o `sidekiq`), via [015](015-script-de-deploy-portainer.md).
- Jobs já enfileirados antes do deploy são compatíveis (mesma classe, mesmos argumentos) e ganham o retry na próxima execução.
- Continua valendo o passo da 006: `WEBHOOK_TIMEOUT=15` no super admin.
- Num incidente, as reentregas ficam na **ScheduledSet** do Sidekiq (o `retry_on` do ActiveJob reagenda o job), não na RetrySet.

## Validação

Local, ponta a ponta (runbook [017](017-e2e-local-canal-api.md)): derrubar o ERP local, mandar uma mensagem como cliente, subir o ERP de novo em menos de ~6 min e conferir que o `message_created` chega ao ERP (log do ingest) com o mesmo `X-Chatwoot-Delivery` das tentativas que falharam.

Produção (Axiom):

```kusto
['chatwoot'] | where message contains "[WebhookJob] account_webhook attempt"
| summarize count() by bin(_time, 1h)        // tentativas: picos só em deploy/incidente do ERP
['chatwoot'] | where message contains "Stopped retrying WebhookJob"
| summarize count() by bin(_time, 1d)        // eventos realmente perdidos (esgotaram 5 tentativas): meta ~0
['chatwoot'] | where message contains "Exception: Invalid webhook URL" and message contains "Failed to open TCP connection"
| summarize count() by bin(_time, 1d)        // agora só aparece no esgotamento
```
