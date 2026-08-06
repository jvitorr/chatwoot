# Modificações do fork Connectei sobre o Chatwoot

Este fork acompanha o Chatwoot upstream e recebe merges de release periódicos. Toda divergência em relação ao código original do Chatwoot deve estar documentada aqui — **um arquivo por modificação**.

## Por que isto existe

Uma modificação em fork tem um problema que uma feature normal não tem: **ela é reintroduzida a cada sync com o upstream**. Quem resolve o conflito meses depois não estava na conversa que originou a mudança, e o custo de errar é alto — remover um trecho aparentemente redundante pode desligar um fluxo inteiro sem erro nenhum aparecer.

Cada arquivo aqui existe para responder três perguntas a essa pessoa:

1. **O que muda** em relação ao Chatwoot original;
2. **Por que** — incluindo as alternativas descartadas e o motivo;
3. **Como o conflito se comporta** num merge de upstream, e o que verificar depois.

## Índice

| # | Modificação | Arquivos tocados no core | Risco no merge |
|---|---|---|---|
| [001](001-repasse-status-whatsapp-connectei.md) | Repasse de status de mensagem WhatsApp para o ERP Connectei | `app/services/whatsapp/incoming_message_base_service.rb` | **Alto** — o gancho fica dentro de um método que o upstream altera com frequência |
| [002](002-fallback-template-nao-sincronizado.md) | Envio de template ainda não presente no cache de sincronização | `app/services/whatsapp/template_processor_service.rb` | Médio — o método é pequeno, mas a condição é sutil |
| [003](003-rota-registro-instagram.md) | Rota de registro de canal Instagram | `config/routes.rb` + controller novo | Baixo — adição, sem alterar comportamento existente |
| [004](004-integracao-axiom.md) | Integração com Axiom (exceções, logs e traces) | `lib/opentelemetry_config.rb`, `lib/chatwoot_exception_tracker.rb`, `Gemfile` | **Alto** — `opentelemetry_config.rb` foi refatorado de single-provider para multi-provider |
| [005](005-rodar-suite-local.md) | Como rodar a suíte localmente sem falsos positivos | nenhum — documento operacional | — |
| [006](006-webhook-inbox-api-timeout-retry.md) | Webhook do inbox API: retry + falha ambígua não marca `failed` | `lib/webhooks/trigger.rb`, `app/listeners/webhook_listener.rb` | **Médio/alto** — o upstream mexe no `trigger.rb` |
| [007](007-source-id-no-update-de-mensagem.md) | `source_id` no update de mensagem de inbox API (ack do ERP) | `app/controllers/api/v1/accounts/conversations/messages_controller.rb` | Médio |
| [008](008-filtro-ruido-scanners-axiom.md) | Filtro de ruído de scanners no envio de logs ao Axiom | arquivos do fork (mod. 004) | Nulo |
| [009](009-retry-after-no-throttle.md) | `Retry-After` nas respostas 429 do Rack::Attack | `config/initializers/rack_attack.rb` (1 linha) | Baixo |

## Convenção para novas modificações

Nomeie como `NNN-descricao-curta.md`, em ordem de criação, e adicione a linha no índice acima.

Prefira sempre a modificação **aditiva** (arquivo novo) à **invasiva** (edição de arquivo do upstream). Quando a edição invasiva for inevitável, deixe-a mínima: um gancho de uma linha chamando um método próprio, em vez de lógica espalhada. Um `git merge` reconcilia bem uma linha isolada; reconcilia mal um bloco reescrito.

Marque no core, junto do trecho alterado, um comentário apontando para o documento correspondente — o merge acontece no arquivo, não aqui.
