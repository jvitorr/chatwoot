# 008 — Filtro de ruído de scanners no envio de logs ao Axiom

**Status:** ativo
**Arquivos do core alterados:** `lib/axiom/log_device.rb` (2 linhas no `#write` — arquivo do próprio fork, modificação 004)
**Arquivos novos (aditivos):** `lib/axiom/log_noise_filter.rb` + specs
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.3-connectei`

---

## O problema

~687 eventos `level=fatal`/dia no dataset `chatwoot` do Axiom eram `ActionController::RoutingError` de bots varrendo o servidor (`/wp-includes/...`, `*.php`, `/.env`). O middleware de exceções (`AxiomCaptureExceptions`) **já ignorava** RoutingError — o ruído entrava pelo caminho dos **logs**: o `ActionDispatch::DebugExceptions` loga RoutingError em FATAL, e o broadcast (`Rails.logger.broadcast_to(Axiom.logger)`) enviava tudo. Isso envenena qualquer alerta baseado em severidade e consome cota de ingestão.

## O que muda

`Axiom::LogNoiseFilter.noise?(event)` casa o padrão `ActionController::RoutingError (No route matches` na mensagem do evento; o `Axiom::LogDevice#write` descarta o evento **antes** do buffer, logo após a guarda de reentrância — sem I/O, respeitando a invariante do `write` (documentada na modificação 004). O access log do proxy continua registrando os 404 de scanner.

Filtra-se **todo** RoutingError (não só paths `/wp-*`): 404 de rota não é defeito da aplicação — mesma filosofia do ignore list do middleware.

## Comportamento no merge de upstream

Risco **nulo**: os dois arquivos são do fork (modificação 004); o upstream não os conhece.

## Validação

```kusto
['chatwoot'] | where level == "fatal" and message contains "ActionController::RoutingError"
| summarize count() by bin(_time, 1d)   // baseline ~687/dia; meta: 0
```
