# 024 — Repasse de comentário e referral do Instagram ao ERP (+ fim do crash com comentário real)

**Status:** ativo
**Arquivos do core alterados (ganchos de 1 linha, marcados `# [FORK CONNECTEI] modifications/024`):**
`app/jobs/webhooks/instagram_events_job.rb` (`process_single_entry` e `perform`),
`app/models/channel/instagram.rb` (`subscribed_fields`), `config/sidekiq.yml` (fila nova),
`db/schema.rb` (coluna nova)
**Arquivos do fork alterados:** `app/controllers/api/v1/accounts/instagram/channels_controller.rb` (mod 003: `granted_scopes`)
**Arquivos novos:** `app/services/connectei/instagram/changes_router.rb`, `…/event_payload.rb`, `…/event_forwarder.rb`,
`…/subscribed_fields.rb`, `app/jobs/connectei/forward_instagram_event_job.rb`,
`db/migrate/20261031120000_add_connectei_granted_scopes_to_channel_instagram.rb` + specs
**Specs do upstream ajustados (mudança intencional dos campos assinados):** `spec/factories/channel/channel_instagram.rb`
(o stub do subscribe passa a usar `SubscribedFields.fields_for`), `spec/controllers/instagram/callbacks_controller_spec.rb`
(a URL exata do stub ganha `messaging_postbacks` e `messaging_referral`)
**Contrato:** `ERP-backend/docs/instagram/contrato-fork-erp.md` §1 e §5 · **Receptor no ERP:** `POST /api/v1/instagram-events`

---

## O problema

1. **Comentário real derrubava o lote.** O `Webhooks::InstagramEventsJob` tratava toda
   entrada com `changes` como o evento de teste do painel da Meta
   (`test_event? = entry[:changes].present?`). Um comentário real chegava ao
   `Instagram::TestEventService`, que lê `value[:sender][:id]` — e comentário não tem
   `sender`. O `NoMethodError` subia, o Sidekiq reprocessava o lote inteiro a cada
   tentativa e **os DMs que viessem depois do comentário no mesmo lote nunca eram
   processados** (achado A9).
2. **Comentário e referral solto não tinham destino.** O ERP precisa do comentário para a
   automação "comentário → DM" e do referral solto (`messaging_referral`: clique num link
   `ig.me` com `ref`, ou num anúncio, numa conversa que já existe) para a origem da
   campanha. A Meta entrega os dois só ao fork (uma URL de webhook por app).
3. **O canal não assinava** `messaging_postbacks`, `messaging_referral` nem `comments`.

## O que a mudança faz

### Router antes do teste da Meta

Um gancho de 1 linha no início de `process_single_entry`:

```ruby
return if Connectei::Instagram::ChangesRouter.route(entry) # [FORK CONNECTEI] modifications/024
```

O `ChangesRouter`:

- lê os **dois formatos** que a Meta usa — `entry[].changes[] {field, value}` e
  `entry[] {field, value}` — e devolve `true` (entrada consumida) para evento real;
- repassa `comments`; ignora (com `info`) `live_comments` e qualquer outro campo;
- **devolve `false` para o evento de teste da Meta** (`changes[]` com `field: messages`
  e `sender`/`recipient`), que continua no `TestEventService` com os IDs de teste;
- um `messages` sem `sender` é consumido e ignorado, em vez de quebrar o `TestEventService`;
- encontra referral solto (`messaging[]`/`standby[]` com `referral` e sem `message`/`postback`),
  repassa e devolve `false` — as mensagens da mesma entrada seguem o fluxo normal;
- **nunca levanta**: erro ao montar/enfileirar um evento é registrado (`error` + tracker)
  e o lote continua.

Um segundo gancho, em `perform`, pula o mutex por contato (`IG_MESSAGE_MUTEX`) quando
**nenhuma** entrada do lote tem `messaging`/`standby`. Lote só de comentários não tem
contato: sem isso, toda rajada de comentários da mesma conta disputaria a chave
`IG_MESSAGE_CREATE_LOCK::::<ig_id>` e geraria retries de lock à toa.

### O que é repassado (contrato §1.2)

- `instagram.comment` — `event_id = ig:c:<comment_id>`, `comment_id` de `value.id` ou
  `value.comment_id`, `parent_id` quando é resposta, `created_time` quando vier (senão `null`).
- `instagram.referral` — `event_id = ig:r:<sender_id>:<timestamp>`, com `ref`, `source`,
  `type`, `ad_id` e `ads_context_data` (as cinco chaves sempre presentes).
- `entry_time` é sempre **milissegundos** (a Meta manda segundos em `changes` e ms em
  `messaging`; o corte em 1e11 separa os dois), `received_at` é ISO 8601 UTC.

**Não** é repassado: comentário da própria conta (`from.id == instagram_id`, evita o laço
resposta pública → webhook), evento sem `comment_id`, `live_comments`, e conta sem
`Channel::Instagram` com inbox aqui (o Instagram via página do Facebook não assina comentários).

### Entrega ao ERP

`Connectei::ForwardInstagramEventJob` → `Connectei::Instagram::EventForwarder`:

- `POST CONNECTEI_INSTAGRAM_EVENTS_URL` com `X-Chatwoot-Timestamp` +
  `X-Chatwoot-Signature: sha256=HMAC(CONNECTEI_INSTAGRAM_EVENTS_SECRET, "<ts>.<corpo>")` —
  o esquema do webhook de conta, que o ERP já verifica; o timestamp é recalculado a cada tentativa;
- timeout de 10s, sem seguir redirect;
- 2xx encerra; 5xx/408/425/429, timeout e erro de rede tentam de novo; 401/422 (e demais
  4xx) registram `error` e **não** tentam de novo;
- `retry_on … wait: :polynomially_longer, attempts: 15` (~35h). Esgotado, a exceção chega ao
  Sidekiq, que manda o job para a dead set (reenfileirável à mão);
- fila própria `connectei_instagram`, registrada em `config/sidekiq.yml` **abaixo de `default`**;
- sem URL ou sem segredo o repasse fica desligado: o router nem enfileira, e o fork
  registra `info` uma vez por processo.

### Campos assinados e escopos (contrato §5)

- `subscribed_fields` = `messages message_reactions messaging_seen messaging_postbacks
  messaging_referral`, mais `comments` **somente** se `connectei_granted_scopes` tiver
  `instagram_business_manage_comments`.
- Coluna nova `channel_instagram.connectei_granted_scopes` (`string[]`, padrão `[]`, `NOT NULL`).
- Os endpoints da mod 003 aceitam `granted_scopes` (lista, ou texto separado por vírgula —
  o formato `permissions` do OAuth) no POST e no PATCH e devolvem o valor gravado. No PATCH,
  ausente mantém; presente (inclusive `[]`) substitui. O re-subscribe usa o valor novo.

## Por quê — e alternativas descartadas

- **Pedir `comments` sem o escopo** faz a Meta recusar a inscrição **inteira** — nem os DMs
  chegariam. Por isso o campo depende do escopo persistido no canal, e não de uma flag
  global: cada conta ganha o campo quando reconecta com a permissão aprovada no App Review.
- **POST inline no `InstagramEventsJob`**: uma indisponibilidade do ERP reprocessaria o lote
  de DMs (o mesmo raciocínio da mod 001). Job próprio isola as falhas.
- **Fila `default`/`low`**: as filas têm prioridade estrita. Em `default`, uma rajada de
  comentários disputaria com os DMs de todas as lojas; em `low`, ficaria atrás de todos os
  repasses de status da mod 001. A fila própria também pode ganhar processo dedicado.
- **`x-connectei-signature` (mod 001)**: o ERP não tem receptor para esse esquema.
- **`retry` nativo do Sidekiq (`sidekiq_options retry: 15`)**: nenhum job do fork usa, e o
  `retry_on` do ActiveJob deixa o 4xx definitivo fora do retry e é testável com o adaptador
  de teste. A janela (~35h com 15 tentativas polinomiais) é a mesma ordem de grandeza.
- **`SafeFetch`** (como o `Webhooks::Trigger`): bloqueia endereço privado, e o ERP do E2E
  roda em `localhost`. A URL é configuração do operador, não entrada de usuário.
- **Adicionar `:referral` ao `SUPPORTED_EVENTS`**: mais lógica no core; o router já vê a
  entrada inteira e trata o referral solto sem tocar no laço de mensagens.

## Comportamento num merge de upstream

- `instagram_events_job.rb` — **risco médio**: o upstream mexe nesse job (o #14237 da mod 023
  mexeu). Ao reconciliar, mantenha as duas linhas marcadas: o `return if …route(entry)` tem
  que ser a **primeira** linha de `process_single_entry` (antes do `test_event?`), e o
  `return process_entries(entries) if …without_messaging?(entries)` logo depois de
  `@entries = entries`. Se o upstream passar a tratar `changes` de verdade, compare antes de
  remover: o fork precisa continuar repassando ao ERP.
- `channel/instagram.rb` — 1 linha no `subscribed_fields`.
- `config/sidekiq.yml` — a fila `connectei_instagram` precisa continuar na lista; sem ela o
  job é enfileirado e **nunca roda**, sem erro nenhum.
- Migration/coluna e arquivos novos não conflitam.

## O que verificar depois do merge

```bash
grep -n "modifications/024" app/jobs/webhooks/instagram_events_job.rb app/models/channel/instagram.rb config/sidekiq.yml
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec \
  spec/services/connectei/instagram spec/jobs/connectei spec/jobs/webhooks/instagram_events_job_connectei_spec.rb \
  spec/jobs/webhooks/instagram_events_job_spec.rb spec/models/channel spec/controllers/api/v1/accounts/instagram \
  spec/controllers/instagram/callbacks_controller_spec.rb
```

Teste vivo (o mais importante é o negativo): um lote com **um comentário seguido de um DM**
tem que criar a mensagem do DM e enfileirar um `Connectei::ForwardInstagramEventJob`; o
evento de teste do painel da Meta tem que continuar criando a mensagem `random_text`.
