# 006 — Webhook do inbox API: retry + classificação de falha ambígua

**Status:** ativo
**Arquivos do core alterados:** `lib/webhooks/trigger.rb` (classificador + RetryableError para api_inbox), `app/listeners/webhook_listener.rb` (1 linha — job novo)
**Arquivos novos (aditivos):** `app/jobs/api_inbox/webhook_job.rb`, specs correspondentes
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.4-connectei`

---

## O problema

O ERP (Brasil) e este Chatwoot (Hetzner/EUA) conversam pela internet pública. ~362×/dia o POST de webhook do inbox API (`Channel::Api`) morria em `Net::ReadTimeout` (timeout de 5s), com duas consequências graves:

1. **Falso `failed`**: o `Webhooks::Trigger` fazia `rescue StandardError` e marcava a mensagem como `failed` com `external_error: "Net::ReadTimeout..."` — mesmo quando a mensagem **já tinha sido entregue** no WhatsApp. Caso real: msg 250475, `source_id: "WAID:3EB0F9230B5FA4253A1D33"`, marcada `failed`, e a cliente respondeu **citando** a mensagem. O atendente vê ❌ e reenvia, duplicando o envio para o cliente.
2. **Evento perdido em silêncio**: o `WebhookJob` não tinha `retry_on` nenhum e o `Trigger` engolia a exceção — do ponto de vista do Sidekiq o job "deu certo". Mensagens podiam simplesmente não chegar ao ERP.

## O que muda

### Classificação ambíguo vs definitivo (`lib/webhooks/trigger.rb`)

- `AMBIGUOUS_TRANSPORT_CAUSES` (`Net::ReadTimeout`, `Errno::ECONNRESET`, `Errno::EPIPE`, `IOError` — `EOFError` é subclasse) + fragmentos de mensagem equivalentes. Nesses casos a requisição **pode ter sido recebida e processada** — só a resposta não voltou. O veredicto anda pela cadeia de `cause` (o `SafeFetch::FetchError` preserva a causa) com fallback por substring.
- `update_message_status`: falha ambígua **ou `source_id` presente** (WAID = evidência de entrega) → `record_delivery_unconfirmed` em vez de `failed`. Grava `content_attributes['delivery_unconfirmed'] = true` + `delivery_diagnostics` via **`update_columns`** — de propósito, para não disparar `MESSAGE_UPDATED` (eco de webhook para o endpoint que acabou de falhar) nem ActionCable.
- `Net::OpenTimeout`, DNS (`SocketError`), SSL, URL bloqueada e 4xx explícito continuam marcando `failed` — a conexão nunca abriu ou o destino rejeitou; não há ambiguidade.
- **Zero mudança de UI**: sem `failed`/`external_error`, o Vue renderiza a mensagem como `sent` (estado mais provável de ser verdadeiro). `delivery_unconfirmed` é diagnóstico para operadores (SQL/Axiom).

### Retry (`app/jobs/api_inbox/webhook_job.rb` + gancho no Trigger)

- `retryable_api_inbox_error?`: transporte (FetchError/ECONNREFUSED/ECONNRESET/EPIPE/IOError) e HTTP 429/500/502/503/504 levantam `RetryableError` quando `webhook_type == :api_inbox_webhook`.
- Novo `ApiInbox::WebhookJob < WebhookJob` (espelho exato de `AgentBots::WebhookJob`): `retry_on RetryableError, wait: :polynomially_longer, attempts: 5` (~3s, 18s, 83s, 258s ≈ 6 min de janela). No esgotamento, o bloco chama `handle_failure(error)`, que aplica a classificação acima.
- `webhook_listener.rb#deliver_api_inbox_webhooks` passa a enfileirar o job novo (1 linha).
- `:account_webhook` fica **intacto** (sem retry — comportamento upstream preservado; o `raise` é guardado por `webhook_type`).
- Redelivery é segura: o ERP é idempotente por `chatwootMessageId` (jobId determinístico no BullMQ + tabela `bot_chat_message`).

## Alternativas descartadas

- **Retry generalizado no `WebhookJob`**: mudaria a semântica de webhooks de conta para todas as integrações — escopo mínimo escolhido.
- **Guarda de `source_id` no `Messages::StatusUpdateService`**: o service tem 10+ call sites (Line/Instagram/TikTok/Twilio/Email) onde `failed` com `source_id` presente é legítimo (a Meta envia failed real com WAID). No Trigger o contexto é inequívoco.
- **Mudar `WEBHOOK_TIMEOUT` default no `config/installation_config.yml`**: inócuo — a linha já existente na tabela `installation_configs` de produção vence o YAML. A mudança é operacional (abaixo).
- **`attempts: 8` como o forward job da modificação 001**: aqui há um humano esperando o desfecho do envio; ~6 min cobre blip/deploy sem segurar o veredicto por horas.

## Trade-off aceito

Uma mensagem realmente não-entregue por falha ambígua persistente fica `sent` + `delivery_unconfirmed` (não ❌). Falso-`sent` raro (só após 5 tentativas) é melhor que 362 falsos-`failed`/dia. Fase 2 opcional: indicador sutil no `Message.vue` para `delivery_unconfirmed`.

## Comportamento no merge de upstream

- `lib/webhooks/trigger.rb` — risco **médio/alto**: o upstream mexe nesse arquivo (RetryableError/agent bot são recentes). Ao reconciliar, manter: as constantes `AMBIGUOUS_*`/`RETRYABLE_API_INBOX_STATUSES`, o `|| retryable_api_inbox_error?(e)` no `execute`, e o bloco `ambiguous_delivery_error?/record_delivery_unconfirmed`.
- `app/listeners/webhook_listener.rb` — 1 linha, risco baixo.
- Job e specs são aditivos.

## O que verificar depois do merge

```
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec \
  spec/lib/webhooks/trigger_spec.rb spec/jobs/api_inbox spec/listeners/webhook_listener_spec.rb
```

## Passo operacional pós-deploy

No super admin (app_config), setar `WEBHOOK_TIMEOUT=15` (default efetivo hoje: 5s — apertado demais para o RTT Brasil↔EUA). Confirmar no console: `GlobalConfig.clear_cache; GlobalConfig.get_value('WEBHOOK_TIMEOUT')`.

## Validação (queries)

```sql
-- failed por timeout deve ir a zero (baseline ~362/dia)
SELECT count(*) FROM messages
WHERE status = 3 AND content_attributes::text LIKE '%Net::ReadTimeout%'
  AND updated_at > now() - interval '1 day';

-- delivery_unconfirmed deve ser raro (só esgotamento de 5 tentativas)
SELECT count(*) FROM messages
WHERE content_attributes->>'delivery_unconfirmed' = 'true'
  AND updated_at > now() - interval '1 day';
```

```kusto
['chatwoot'] | where message contains "Exception: Invalid webhook URL" and message contains "Net::ReadTimeout"
| summarize count() by bin(_time, 1d)   // meta: ~0
['chatwoot'] | where message contains "[ApiInbox::WebhookJob] attempt"
| summarize count() by bin(_time, 1h)   // visibilidade das tentativas
```
