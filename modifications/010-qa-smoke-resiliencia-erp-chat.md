# 010 — QA de resiliência ERP ↔ chat: o que foi testado e o que garante que os clientes não quebram

**Status:** documento de verificação (nenhum arquivo do fork alterado por ele)
**Escopo:** valida as modificações [006](006-webhook-inbox-api-timeout-retry.md), [007](007-source-id-no-update-de-mensagem.md), [008](008-filtro-ruido-scanners-axiom.md) e [009](009-retry-after-no-throttle.md) — e o lado ERP correspondente
**Data da execução:** 2026-08-06 · **Imagem sob teste:** `joaoftnunes/chatwoot:4.15.1.4-connectei`

---

## Por que este documento existe

As modificações 006–009 tocam o caminho por onde passa **toda** mensagem de todos os
tenants: `Webhooks::Trigger`, o listener de webhooks, o controller de mensagens e o
Rack::Attack. O fork é multi-tenant e single-host — um defeito aqui não afeta um cliente,
afeta todos. Este documento registra **as evidências reais** de que a operação atual
(Instagram, WhatsApp e canais de API) continua íntegra, para que quem fizer o próximo
merge de upstream saiba exatamente o que revalidar.

## Ambiente da verificação

| Peça | Onde |
|---|---|
| Fork sob teste | `joaoftnunes/chatwoot:4.15.1.4-connectei` em docker (rails + sidekiq + pgvector + redis) |
| ERP | branch `fix/chat-upstream-resilience`, `.env_test` + env de e2e |
| Provider WhatsApp | stub local (nenhuma mensagem real enviada) |
| Contas | account 1 com dois inboxes `Channel::Api` (um com webhook para o ERP, outro sem) |

Runbook completo e scripts: `ERP-backend/tasks/e2e-chat-resilience.md` e
`ERP-backend/scripts/e2e-chat/`.

## Garantias de NÃO-REGRESSÃO (o ponto crítico para os clientes)

| Garantia | Evidência |
|---|---|
| **Webhook de CONTA continua sem retry** (integrações de cliente: n8n, bots, automações) | Webhook de conta apontado para porta fechada: **exatamente 1 execução** (`Enqueued` + `Performed`, sem reenfileiramento). O `retry_on` vive só no `ApiInbox::WebhookJob`. |
| **Falha de webhook de conta não marca mensagem como `failed`** | Mesma prova: a mensagem permaneceu `status = sent (0)`, `content_attributes` vazio. O `handle_error` só age em `:api_inbox_webhook`. |
| **Criação de contato / conversa / mensagem via API segue funcionando** | 3 casos verdes contra a API real do fork (contato → conversa → mensagem `outgoing`), status 200 e ids retornados. |
| **Canais Instagram / WhatsApp intactos** | Nenhum arquivo desses canais foi tocado. `spec/services/whatsapp`, `spec/models/channel`, `spec/services/messages`, `spec/jobs`, `spec/listeners`, `spec/lib/webhooks`, `spec/controllers/api/v1/accounts/conversations`: **1.194 exemplos, 0 falhas**. |
| **`Messages::StatusUpdateService` inalterado** | A guarda de `source_id` vive no `Trigger`, não no service — o caminho de `failed` legítimo da Meta/Line/Instagram/Twilio continua idêntico (decisão registrada na mod. 006). |
| **Rack::Attack continua protegendo** | Nenhuma safelist adicionada; só o header `Retry-After` foi habilitado. Spec trava o discriminador de `contacts/search` **por conta** (isolamento entre tenants preservado). |

## Comportamentos NOVOS confirmados em ambiente real

| Modificação | Evidência |
|---|---|
| **006 — timeout não marca `failed`** | Webhook apontado para um sink que aceita e nunca responde (`Net::ReadTimeout`): a mensagem ficou **`sent`** com `content_attributes.delivery_unconfirmed = true` e `delivery_diagnostics.error = "Net::ReadTimeout with #<TCPSocket:(closed)>"` — exatamente o erro do incidente da msg 250475. |
| **006 — contraprova (falha determinística)** | Webhook para porta **fechada** (`ECONNREFUSED`): mensagem marcada `failed` com `external_error` de conexão recusada. O fork continua sinalizando falha real. |
| **006 — retry do inbox API** | `ApiInbox::WebhookJob` retenta e entrega quando o ERP volta; sem retry, o evento se perdia em silêncio. |
| **007 — `source_id` no update** | PATCH grava o WAID (`SQL(chat): messages.source_id = 'WAID:…'`); repetir com o mesmo valor é no-op 200; valor divergente responde **422** sem sobrescrever; `status: sent` + `source_id` limpa `external_error`/diagnóstico. |
| **007 — ponta a ponta com o ERP** | Mensagem de agente → webhook → ERP → provider → PATCH de volta: `messages.12996` ficou com `source_id = WAID:E2E000003`, `status = 0`. |
| **008 — ruído de scanner** | `Axiom::LogNoiseFilter` cobre `ActionController::RoutingError`; specs do filtro e do `LogDevice` verdes. |
| **009 — `Retry-After`** | Flag ativa e travada por spec; consumida pelo ERP para reagendar o disparo no instante em que a janela do throttle zera. |

## Defeitos encontrados no QA — todos do lado ERP, nenhum no fork

O QA rodou 90 casos (happy/exception/exotic) contra os dois ambientes. **Zero defeitos no
fork.** Três defeitos foram encontrados **no ERP** e corrigidos antes do fechamento:

1. **Envio de mensagem não participava do circuit breaker** — com o chat fora, cada
   tentativa do atendente segurava 60s. Corrigido (16ms de fast-fail).
2. **Cache pinava a falha** — uma listagem vazia originada de falha de upstream ficava 60s
   no cache. Corrigido (vazio nunca é cacheado).
3. **HTTP 500 em `chatId` não numérico** (`/chats/abc`) — pré-existente, corrigido com o
   guard de fronteira já usado nos outros módulos do ERP.

Resultado final: **0 falhas**, 75 casos verdes, 8 parciais (comportamentos pré-existentes
documentados, nenhum vazamento) e 6 bloqueados por precondição não reproduzível localmente
(inbox WhatsApp Cloud real).

## O que revalidar no próximo merge de upstream

Rodar, nesta ordem, e exigir 0 falhas:

```
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec \
  spec/lib/webhooks spec/jobs spec/listeners spec/services/whatsapp \
  spec/services/messages spec/models/channel spec/lib/axiom spec/initializers \
  spec/controllers/api/v1/accounts/conversations
```

E confirmar manualmente as duas invariantes que nenhum spec sozinho garante:

1. um webhook de **conta** que falha dispara **uma única vez** (sem retry) e **não** altera
   o status da mensagem;
2. um webhook de **inbox API** que sofre `Net::ReadTimeout` deixa a mensagem `sent` com
   `delivery_unconfirmed`, e um que sofre `ECONNREFUSED` a deixa `failed`.
