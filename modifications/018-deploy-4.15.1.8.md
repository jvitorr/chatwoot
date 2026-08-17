# 018 — Deploy da 4.15.1.8

**Status:** operacional (não altera código)
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.8-connectei` (e `latest`), `linux/amd64` + `linux/arm64`

---

## O que entra nesta versão

`connectei-conversations/filter` (modificação [012](012-connectei-conversations-filter.md))
ganha quatro parâmetros novos: `created_from`/`created_to` (intervalo de
**criação** do chat — primeiro contato do lead) e `last_activity_from`/
`last_activity_to` (intervalo de **interação** — qualquer atividade na
janela). São os filtros por trás dos botões "Criação" e "Interação" do painel
do ERP no modo direto. Aditivo, sem migration: os dois campos filtrados
(`conversations.created_at`, `conversations.last_activity_at`) já existem e já
têm índice via a migration da modificação 012.

Também entra o endpoint novo `connectei-lead-analytics/filter` (modificação
[019](019-connectei-lead-analytics.md)) — agregação de leads novo × recorrente
por canal e série temporal, consumido por `GET /api/v1/analytics/leads(/channels)`
no ERP. Aditivo, sem migration.

Verificado ponta a ponta local antes de publicar — runbook em
[017](017-e2e-local-canal-api.md) / `ERP-backend/tasks/e2e-chat-local-api-channel.md`.

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

Voltar para `4.15.1.7-connectei`: os dois filtros novos somem (o ERP
simplesmente para de enviar `createdFrom`/`createdTo`/`lastActivityFrom`/
`lastActivityTo` no corpo da chamada nativa quando o usuário não os define —
nada quebra, os botões da UI continuam existindo mas passam a não ter efeito
até a imagem nova voltar). Nenhum índice para derrubar.

`GET /api/v1/analytics/leads(/channels)` do ERP responde `404` do fork
(`connectei-lead-analytics/filter` ausente) — o ERP não tem fallback para
essa rota (diferente do `connectei-conversations/filter`, que tem caminho
legado): a tela de analytics fica indisponível até a imagem nova voltar. Sem
índice/dado para derrubar.
