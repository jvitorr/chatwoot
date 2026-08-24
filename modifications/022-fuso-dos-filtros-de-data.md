# 022 — `connectei-conversations/filter`: fuso horário dos filtros de data

**Status:** ativo
**Arquivos do core alterados:** nenhum — só o controller e o service do fork (mod. [012](012-connectei-conversations-filter.md))
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.11-connectei`

---

## O que muda

O endpoint aceita `timezone` (nome IANA). `created_from`/`created_to` e
`last_activity_from`/`last_activity_to` continuam datas puras (`YYYY-MM-DD`), mas
o "dia inteiro" passa a ser resolvido nesse fuso:

```ruby
Date.iso8601(value).in_time_zone(ActiveSupport::TimeZone[params[:timezone]] || Time.zone)
```

Sem `timezone` o comportamento é o anterior (UTC). Valor desconhecido responde 422 —
cair para UTC em silêncio devolveria o bug sem nenhum sinal.

## Por que

`Time.zone` do Chatwoot é UTC. `created_from=created_to=2026-08-24` virava
`24/08 00:00Z → 24/08 23:59Z`, que em São Paulo é **23/08 21:00 → 24/08 20:59**. O
filtro "chats de hoje" do painel trazia conversas de ontem à noite e escondia as de
hoje depois das 21h.

A 019 já tinha resolvido o mesmo problema para o `lead-analytics` mandando instantes
UTC prontos (`start_at`/`end_at`). Aqui o contrato de datas puras é mantido (o ERP e
o front já o usam) e o fuso viaja como parâmetro — a mesma convenção `timezone` da 019.

## Quem manda o fuso

O ERP (`chat-direct/conversations`) repassa `timezone` do query string, validado com
`Intl.DateTimeFormat`, default `America/Sao_Paulo`; o front envia o fuso do navegador
(`Intl.DateTimeFormat().resolvedOptions().timeZone`).

## No merge de upstream

Nenhum arquivo do core. Regressão coberta em
`spec/controllers/api/v1/accounts/connectei_conversations_controller_spec.rb`
(`created_from/created_to resolved in the requested timezone`).
