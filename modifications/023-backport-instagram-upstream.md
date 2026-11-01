# 023 — Backport de Instagram do upstream (4 commits)

**Status:** ativo
**Tipo:** cherry-pick (`git cherry-pick -x`) de commits do `chatwoot/chatwoot@develop`, sem edição manual
**Arquivos do core alterados:** `app/jobs/webhooks/instagram_events_job.rb`, `app/models/channel/instagram.rb`,
`app/controllers/concerns/instagram_concern.rb`, `app/controllers/api/v1/accounts/instagram/authorizations_controller.rb`,
`app/services/instagram/base_send_service.rb`, `app/services/instagram/send_on_instagram_service.rb`,
`app/services/instagram/messenger/send_on_instagram_service.rb`, `app/services/facebook/send_on_facebook_service.rb`
**Arquivo novo (vindo do upstream):** `app/services/facebook/human_agent_tag_helpers.rb`
**Contraparte no ERP:** automações de Instagram (`flow-runtime`, `instagram-comment`) — ver `ERP-backend/docs/instagram/contrato-fork-erp.md`

---

## O que muda

Quatro correções de Instagram que o upstream publicou depois da 4.15.1 e que as
modificações 024–029 pressupõem. Entraram **na ordem abaixo**, cada uma como um
commit próprio com o `(cherry picked from commit …)` no corpo:

| Upstream | PR | O que faz |
|---|---|---|
| `b8118784c` | #14937 | A versão da Graph do Instagram deixa de ser `v22.0` fixa e passa a vir de `INSTAGRAM_API_VERSION` (installation config, padrão `v22.0`). Cria o `base_uri` privado em `Channel::Instagram`. |
| `aaf984868` | #15575 | O OAuth do Instagram Business Login passa a usar `https://www.instagram.com/oauth/authorize` com `force_reauth` (a Meta descontinuou o fluxo antigo, que mostrava "página indisponível" antes do login). |
| `87007a849` | #14237 | `postback` (ice breaker, botão) vira mensagem recebida com o título como texto, e o tipo do evento passa a ser avaliado **item a item**. |
| `359c4d4ce` | #15932 | `HUMAN_AGENT` só é aplicado a resposta de `User` (humano) **e** fora da janela de 24h. Centralizado em `Facebook::HumanAgentTagHelpers`. |

Os quatro aplicaram sem conflito sobre a 4.15.1.12: nenhum toca arquivo das
modificações 001–022.

## Por que

O fork está na 4.15.1 e o upstream na 4.19 (Rails 7.2). O merge completo é um
projeto à parte, com risco próprio; as automações de Instagram precisavam só
destes quatro pontos:

- **#14237 corrige um defeito que derrubava lote.** O `event_name` era memorizado
  com `@event_name ||=`: o tipo do **primeiro** evento do lote valia para todos.
  Um lote com `read` seguido de `message` mandava a mensagem para o
  `ReadStatusService` e ela sumia. Com postback e referral entrando (mods 024/025),
  lotes mistos ficam comuns — sem esta correção a perda seria rotina.
- **#15932 é pré-requisito da mod 027.** Antes dele, com a flag
  `ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT` ligada, **toda** mensagem saía com
  `HUMAN_AGENT`, inclusive a da automação — violação de política da Meta que pode
  punir o app inteiro. Ele sozinho não basta, porque o ERP posta como `User`; a
  027 fecha o resto.
- **#14937 e #15575** são a base para a mod 028 (`INSTAGRAM_GRAPH_BASE_URL`) e o
  equivalente do lado do fork ao OAuth novo que o ERP adotou.

### Alternativas descartadas

- **Merge do upstream até a 4.19:** traz Rails 7.2 e centenas de mudanças sem
  relação com Instagram. Fica como dívida registrada, fora desta entrega.
- **Reescrever as correções à mão:** o cherry-pick preserva o patch idêntico ao
  do upstream, e é isso que faz o merge futuro ser trivial (ver abaixo).

## Comportamento num merge de upstream

Quando o fork finalmente fizer merge de um upstream que **já contém** estes
commits, o git vê o mesmo patch dos dois lados e normalmente resolve sozinho.
O que pode conflitar são as linhas que as modificações seguintes alteraram por
cima destes commits:

- `Channel::Instagram#subscribe`/`#base_uri` — mods 024 (campos assinados) e 028
  (`INSTAGRAM_GRAPH_BASE_URL`);
- `Instagram::SendOnInstagramService#send_message` — mods 025 (timeout) e 028 (URL base);
- `Webhooks::InstagramEventsJob#process_single_entry`/`#perform` — mod 024 (gancho do router).

Nesses casos, fique com a versão do upstream e **reaplique os ganchos marcados
com `# [FORK CONNECTEI]`** — cada documento da 024–028 diz qual linha é.

## O que verificar depois do merge

```bash
grep -n "SUPPORTED_EVENTS" app/jobs/webhooks/instagram_events_job.rb   # tem que incluir :postback
grep -n "@event_name ||=" app/jobs/webhooks/instagram_events_job.rb    # NÃO pode aparecer
grep -n "human_agent_tag_applicable?" app/services/instagram/send_on_instagram_service.rb
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec \
  spec/controllers/concerns/instagram_concern_spec.rb \
  spec/controllers/api/v1/accounts/instagram/authorizations_controller_spec.rb \
  spec/jobs/webhooks/instagram_events_job_spec.rb spec/services/instagram \
  spec/services/facebook/send_on_facebook_service_spec.rb
```

Verificação desta entrega: os specs acima rodaram verdes logo após os quatro
cherry-picks (83 exemplos, 0 falhas).
