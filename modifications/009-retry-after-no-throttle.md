# 009 — `Retry-After` nas respostas 429 do Rack::Attack

**Status:** ativo
**Arquivos do core alterados:** `config/initializers/rack_attack.rb` (1 linha)
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.4-connectei`

---

## O problema

No incidente da campanha 1004 (03/08/2026), o ERP disparou ~2,7 buscas de contato/s contra `/api/v1/accounts/:id/contacts/search`, cujo throttle é **100/min por account** (`RATE_LIMIT_CONTACT_SEARCH`). O Rack::Attack bloqueou 293 chamadas com 429 — **sem header `Retry-After`** (rack-attack 6.x só o inclui com a flag ligada). Sem o header, o ERP não tem como reagendar com o valor real.

> Nota: o diagnóstico original supunha throttle "por IP, global para todos os tenants". O código mostra o contrário — o discriminador de `contacts/search` é o `account_id` (isolamento entre tenants já existe; coberto por spec para não regredir). O bloqueio do incidente foi a conta 24 estourando o próprio limite.

## O que muda

`Rack::Attack.throttled_response_retry_after_header = true` — a resposta 429 passa a incluir `Retry-After` (segundos até a janela zerar), permitindo ao ERP (T12 do plano de campanha) reagendar o job de disparo com precisão.

## Alternativas descartadas

- **Safelist do IP do ERP**: removeria a proteção por completo; o throttle do lado do ERP (BullMQ limiter) + `Retry-After` resolvem sem abrir mão dela.
- **Migrar o discriminador para token**: desnecessário — já é por account.

## Comportamento no merge de upstream

1 linha isolada junto da config de cache do inicializador; risco baixo. Spec em `spec/initializers/rack_attack_spec.rb` falha se a flag sumir.

## Validação

```kusto
['chatwoot'] | where message contains "Rack::Attack"
| summarize count() by bin(_time, 10s)   // durante campanha: meta 0 bloqueios
```
