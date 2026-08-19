# 018 — Deploy da 4.15.1.10

**Status:** operacional (não altera código)
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.10-connectei` (e `latest`), `linux/amd64` + `linux/arm64`

---

## O que entra nesta versão

`connectei-conversations/filter` (modificação [012](012-connectei-conversations-filter.md))
ganha quatro parâmetros novos: `created_from`/`created_to` (intervalo de
**entrada do lead**) e `last_activity_from`/`last_activity_to` (intervalo de
**interação**). São os filtros por trás dos botões "Novos leads" e "Interação"
do painel do ERP no modo direto. Aditivo, sem migration: o recorte de entrada
usa `index_conversations_on_contact_id` e o de interação usa
`(conversation_id, account_id, message_type, created_at)` de `messages` — os
dois já existem no core.

"Entrada do lead" = a conversa foi aberta na janela **E** é a primeira
conversa desse contato na conta. Contato recorrente — chat resolvido que volta
a falar meses depois, abrindo conversa nova — NÃO aparece no filtro de hoje,
que era justamente o defeito relatado. É a mesma regra que o lead analytics
(mod. 019) usa para classificar novo × recorrente, então lista e gráfico
contam a mesma coisa.

Duas leituras foram descartadas: `conversations.created_at` sozinho (traz
conversa nova de contato antigo) e `contacts.created_at` (importação em massa
e disparo ativo carimbam cadastro sem ninguém ter chegado).

"Interação" é `EXISTS` de mensagem humana em `messages` dentro da janela, e
não um recorte sobre `conversations.last_activity_at`: aquela coluna guarda
só a última mensagem, então conversa com mensagem em 02/08 e 03/08 sumia da
janela 01–05/08 por ter falado de novo em 19/08. Efeito colateral aceito:
conversa sem nenhuma mensagem (aberta por API/agente e nunca respondida) não
aparece em nenhuma janela de interação — não houve interação.

Também entra o endpoint novo `connectei-lead-analytics/filter` (modificação
[019](019-connectei-lead-analytics.md)) — agregação de leads novo × recorrente
por canal e série temporal, consumido por `GET /api/v1/analytics/leads(/channels)`
no ERP. Aditivo, sem migration.

Entra também a modificação [020](020-detach-error-action-view.md): `ActionView`
sai do `use_all` do OpenTelemetry. Sem ela, cada render de parcial desbalanceava
a pilha de contexto e o log de produção recebia
`calls to detach should match corresponding calls to attach` sem parar — com o
efeito silencioso de emparentar span errado. Só tem efeito com
`AXIOM_TRACE_RAILS` ligado.

Verificado ponta a ponta local antes de publicar — runbook em
[017](017-e2e-local-canal-api.md) / `ERP-backend/tasks/e2e-chat-local-api-channel.md`.
Suítes verdes nas duas passadas da [005](005-rodar-suite-local.md) (7310 exemplos
no rspec, 357 arquivos no vitest).

> **A tag `4.15.1.9-connectei` existe no Docker Hub e não deve ser usada.** Ela
> foi publicada em 19/08/2026 e substituída no mesmo dia, antes de qualquer
> deploy, pela 4.15.1.10 — que é a mesma coisa mais a correção da 020. Nenhum
> ambiente chegou a rodar a .9.

## Deploy

Sem migration nesta versão — troca de imagem basta. Via o script de deploy
(modificação [015](015-script-de-deploy-portainer.md)):

```bash
./scripts/deploy-portainer.sh --skip-migration
```

## Como confirmar que a instância está com o fork novo

```bash
curl -s -X POST -H "api_access_token: <token>" -H "Content-Type: application/json" \
  -d '{"inbox_ids":[<inbox_id>],"created_from":"2026-01-01","created_to":"2026-01-01"}' \
  "https://<host>/api/v1/accounts/<account_id>/connectei-conversations/filter"
```

Um `200` sozinho não distingue as duas versões: instância antiga simplesmente
ignora `created_from`/`created_to` (não estão em `permitted_params`) e devolve
tudo sem filtrar — sem erro nenhum. O teste que realmente distingue as duas é
semear (ou usar) uma conversa fora do intervalo pedido e conferir se ela SOME
do `payload` da resposta — só a instância nova filtra de verdade.

## Rollback

Voltar para `4.15.1.7-connectei`: os dois filtros novos somem, e o
`DetachError` da modificação 020 volta a poluir o log (barulho, sem quebrar
requisição). Além disso: (o ERP
simplesmente para de enviar `createdFrom`/`createdTo`/`lastActivityFrom`/
`lastActivityTo` no corpo da chamada nativa quando o usuário não os define —
nada quebra, os botões da UI continuam existindo mas passam a não ter efeito
até a imagem nova voltar). Nenhum índice para derrubar.

`GET /api/v1/analytics/leads(/channels)` do ERP responde `404` do fork
(`connectei-lead-analytics/filter` ausente) — o ERP não tem fallback para
essa rota (diferente do `connectei-conversations/filter`, que tem caminho
legado): a tela de analytics fica indisponível até a imagem nova voltar. Sem
índice/dado para derrubar.
