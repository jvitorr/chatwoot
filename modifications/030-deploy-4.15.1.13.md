# 030 — Deploy da 4.15.1.13 (automações de Instagram)

**Status:** operacional
**Imagem a publicar:** `joaoftnunes/chatwoot:4.15.1.13-connectei` (`config/app.yml` e `package.json` já em `4.15.1.13`)
**Código desta modificação:** a rake `connectei:instagram:resubscribe` (`lib/tasks/connectei_instagram.rake` →
`app/services/connectei/instagram/resubscriber.rb`, spec `spec/lib/tasks/rake/task_connectei_instagram_resubscribe_spec.rb`)
**Contrato:** `ERP-backend/docs/instagram/contrato-fork-erp.md`

---

## O que entra nesta versão

| Mod | Resumo |
|---|---|
| [023](023-backport-instagram-upstream.md) | Backport de 4 commits de Instagram do upstream (versão da Graph configurável, OAuth novo, postback como mensagem + roteamento por evento, `HUMAN_AGENT` só humano e fora da janela) |
| [024](024-repasse-de-eventos-instagram-ao-erp.md) | Comentário e referral solto repassados ao ERP (HMAC, retry, fila `connectei_instagram`); fim do crash com comentário real; `subscribed_fields` por escopo; `granted_scopes` na mod 003 |
| [025](025-envio-entrada-e-erro-instagram.md) | Quick replies, private reply, limitador por conta, timeout ambíguo ≠ `failed`, erro da Meta estruturado; `ig_event`/payloads/referral na entrada |
| [026](026-endpoints-connectei-instagram.md) | Endpoints `connectei-instagram` (comment-threads, resposta pública, mídia, ice breakers, perfil) |
| [027](027-politica-de-envio-da-automacao.md) | Automação nunca leva `HUMAN_AGENT`; fora de 24h vira `window_closed` sem chamar a Graph |
| [027b](027b-eco-e-idempotencia.md) | Eco adota a mensagem pendente; `POST /messages` idempotente por `flow_effect_key` (todo canal) |
| [028](028-instagram-graph-base-e-renovacao-de-token.md) | `INSTAGRAM_GRAPH_BASE_URL` + timeouts; renovação diária de token |
| [029](029-retry-do-webhook-de-conta-instagram.md) | Webhook de conta com retry para eventos de inbox Instagram |

## Variáveis novas

Todas são lidas **direto do ambiente** — nenhuma passa por `installation_configs`, então a
armadilha da mod 001 (o banco vence a env) **não** se aplica a elas.

| Variável | Padrão | Efeito |
|---|---|---|
| `CONNECTEI_INSTAGRAM_EVENTS_URL` | vazio | URL do receptor do ERP (`…/api/v1/instagram-events`). Vazia: comentário/referral **não** são repassados (o fork registra `info` uma vez e segue normal). |
| `CONNECTEI_INSTAGRAM_EVENTS_SECRET` | vazio | Segredo do HMAC. É o `INSTAGRAM_EVENTS_HMAC_SECRET` do ERP — **o mesmo valor**. Vazio: repasse desligado. |
| `INSTAGRAM_GRAPH_BASE_URL` | `https://graph.instagram.com` | Host da Graph do Instagram. **Em produção, não defina** (ou use o padrão). Existe para o E2E/carga apontarem para um stub. |
| `CONNECTEI_IG_PRIVATE_REPLY_PER_HOUR` | `720` | Teto de private replies por conta do Instagram, janela deslizante de 1h (a Meta aceita 750). |
| `CONNECTEI_IG_SEND_PER_SECOND` | `90` | Teto de envios por segundo por conta do Instagram (a Meta aceita 100). |

Sem variável nova, a 4.15.1.13 roda como a 4.15.1.12 + as correções (sem repasse ao ERP).

## Migration

`20261031120000_add_connectei_granted_scopes_to_channel_instagram.rb`:
`channel_instagram.connectei_granted_scopes string[] NOT NULL DEFAULT '{}'`.

No Postgres 11+ o `ADD COLUMN` com `DEFAULT` constante é só metadado — **não reescreve a
tabela nem trava escrita** de forma perceptível. O código antigo ignora a coluna, então a
ordem "migration antes da imagem" (a do `deploy-portainer.sh`, mod 015) não tem janela ruim.

```bash
./scripts/deploy-portainer.sh            # roda a migration num serviço efêmero e troca a imagem
```

## Ordem do deploy

1. **Fork (esta versão)**, com `CONNECTEI_INSTAGRAM_EVENTS_URL`/`SECRET` **vazios**.
   A fila nova `connectei_instagram` já é servida: todo processo do Sidekiq sobe com
   `-C config/sidekiq.yml` (compose, Procfile, systemd). Com volume alto de comentários, dá
   para dedicar um processo: `bundle exec sidekiq -q connectei_instagram`.
2. **Reinscrição dos canais existentes** (pode ser logo após o passo 1):
   ```bash
   docker compose run --rm rails bundle exec rails connectei:instagram:resubscribe DRY_RUN=1   # só lista
   docker compose run --rm rails bundle exec rails connectei:instagram:resubscribe             # aplica
   # um canal só: … connectei:instagram:resubscribe CHANNEL_IDS=12
   ```
   Saída: uma linha por canal (`fields=…`, `status=ok|failed|error`) e um resumo. `failed`
   com HTTP 400/190 é token inválido — o canal precisa ser reconectado pelo ERP (o PATCH da
   mod 003 já reinscreve). `comments` só aparece em canal com
   `instagram_business_manage_comments` gravado em `connectei_granted_scopes`.
3. **ERP**, com `INSTAGRAM_EVENTS_HMAC_SECRET` configurado e o receptor
   `POST /api/v1/instagram-events` no ar.
4. **Só então** defina `CONNECTEI_INSTAGRAM_EVENTS_URL` e `CONNECTEI_INSTAGRAM_EVENTS_SECRET`
   no fork e recicle os serviços. Por quê esta ordem: o repasse **não** tenta de novo em 4xx —
   um 404 (rota que ainda não existe) perderia o evento. 503 (ERP sem segredo) e 5xx tentam de
   novo por ~35h.
5. **Front.** Os comentários continuam desligados até o App Review: o ERP só pede o escopo
   `instagram_business_manage_comments` com `INSTAGRAM_REQUEST_COMMENTS_SCOPE=true`, e cada
   conta só passa a assinar `comments` quando reconecta (o PATCH grava os `granted_scopes`).

## Como confirmar que a instância está com o fork novo

```bash
# versão
curl -s https://<host>/api | jq .version                      # "4.15.1.13"

# rota nova: inbox inexistente → 404 no formato do contrato (sem token → 401)
curl -s -H "api_access_token: <token>" \
  https://<host>/api/v1/accounts/<account_id>/connectei-instagram/inboxes/0/media
# {"error":{"kind":"not_found",...}}

# coluna nova
psql -c "SELECT id, connectei_granted_scopes FROM channel_instagram LIMIT 5;"
```

Repasse ao ERP, ponta a ponta: com as variáveis do passo 4 definidas, um comentário num post
de uma conta com o escopo gera `Enqueued Connectei::ForwardInstagramEventJob` no log do
Sidekiq e um 202 no ERP. Sem as variáveis, o log mostra **uma vez**
`[CONNECTEI][ig-forward] repasse desativado: …`.

Renovação de token: o cron `connectei_instagram_token_refresh_job` (03:20 UTC) aparece na
aba Cron do Sidekiq; o log diário mostra `[CONNECTEI][ig-token-refresh] N canal(is) …`.

## Rollback

Voltar para `4.15.1.12-connectei` (`./scripts/deploy-portainer.sh --skip-migration`, com a
versão anterior):

- **A coluna fica.** O código antigo a ignora; não rode `db:rollback`.
- **Reduza a inscrição antes ou logo depois.** Os canais reinscritos pela 4.15.1.13 continuam
  assinando `messaging_postbacks`, `messaging_referral` e, onde houver escopo, `comments`. Na
  4.15.1.12, um **comentário real volta a derrubar o lote** do `InstagramEventsJob` (o defeito
  corrigido na mod 024) e os DMs seguintes do mesmo lote se perdem. Na imagem antiga, rode:
  ```bash
  docker compose run --rm rails bundle exec rails runner 'Channel::Instagram.find_each(&:subscribe)'
  ```
  que reinscreve com os 3 campos antigos (`messages message_reactions messaging_seen`).
- O ERP perde: o repasse de comentário/referral, os endpoints `connectei-instagram` (404), a
  idempotência do `POST /messages` (reenvio volta a duplicar), o eco adotado (o "atendente
  fantasma" volta), a política da automação e o retry do webhook de conta do Instagram. Nada
  disso corrompe dado: só desliga as automações de Instagram do lado do ERP.
- Mensagens gravadas com os campos novos (`ig_event`, `external_error_kind`, …) ficam como
  estão — são chaves extras em `content_attributes`, ignoradas pelo código antigo.
