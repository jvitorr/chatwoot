# 007 — `source_id` no update de mensagem de inbox API

**Status:** ativo
**Arquivos do core alterados:** `app/controllers/api/v1/accounts/conversations/messages_controller.rb`
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.3-connectei`

---

## O problema

O ERP envia a mensagem ao WhatsApp (via provider) **depois** que o Chatwoot dispara o webhook do inbox API. O WAID (`source_id`) só existe no ERP — e a API do Chatwoot não permitia gravá-lo depois da criação (`PATCH .../messages/:id` só aceitava `status` e `external_error`). Resultado: toda mensagem de agente ficava `sent` com `source_id: null`, e um `failed` falso por timeout de webhook (ver modificação 006) nunca podia ser corrigido pelo ERP.

## O que muda

`PATCH /api/v1/accounts/:account_id/conversations/:conversation_id/messages/:id` (restrito a inbox API pelo guard `ensure_api_inbox` já existente) passa a aceitar `source_id`:

- **Contrato**: `{ status?, external_error?, source_id? }`.
- Sem `source_id` prévio → grava. Mesmo valor → no-op idempotente. Valor **divergente** do existente → **422** `source_id already set with a different value` (falha alto; não sobrescreve evidência de entrega — divergência é bug do integrador).
- Ao gravar `source_id`, limpa `delivery_unconfirmed`/`delivery_diagnostics` (WAID recebido = entrega confirmada). Com `status: 'sent'` junto, o `StatusUpdateService` já zera `external_error` — é o caminho de **revive** de um `failed` falso.
- `StatusUpdateService` só é chamado quando `status` está presente (antes, com status ausente, já era no-op via `valid_status_transition?` — comportamento preservado; agora permite update só de `source_id`).

### Eco e anti-loop

O `update!` dispara `message_updated` → webhook ao ERP. O payload inclui `source_id` (`message.rb#push_event_data`) e o ERP descarta eventos com `source_id` iniciando em `WAID:` — um único eco, sem laço.

## Alternativas descartadas

- **Estender `Messages::StatusUpdateService`**: tem 10+ call sites de canais cuja semântica é só transição de status; `source_id` é preocupação do endpoint de reconciliação do ERP. Update direto no controller, mínimo.
- **Permitir sobrescrever `source_id` divergente**: mascararia bug de mapeamento no ERP e poderia destruir a referência usada em citações (`in_reply_to_external_id`).

## Comportamento no merge de upstream

`messages_controller.rb` — risco médio: o upstream mexe no controller. Manter: `:source_id` no `permit`, `source_id_conflict?`/`apply_source_id` e a chamada condicional ao `StatusUpdateService`. Specs do bloco `with source_id in the payload` cobrem tudo.

## O que verificar depois do merge

```
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec \
  spec/controllers/api/v1/accounts/conversations/messages_controller_spec.rb
```

## Consumidor

ERP-backend: fila BullMQ `chat-ack` (worker faz o PATCH com `status: 'sent'` + `source_id`) + cron de reconciliação a cada 10 min (corrige `failed`/`source_id` null das últimas 2h contra o registro local do WAID).
