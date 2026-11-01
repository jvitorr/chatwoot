# 026 — Endpoints `connectei-instagram`: comment-threads, resposta pública, mídia, ice breakers e perfil

**Status:** ativo
**Arquivos do core alterados (1 linha cada, marcados `# [FORK CONNECTEI] modifications/026`):**
`config/routes.rb` (bloco Connectei), `app/builders/messages/instagram/base_message_builder.rb`
(`prepend Connectei::Instagram::ThreadLockExtension`), `app/services/instagram/message_text.rb`
(`prepend Connectei::Instagram::PendingProfileExtension`)
**Arquivos novos:** `app/controllers/api/v1/accounts/connectei_instagram_controller.rb`,
`app/services/connectei/instagram/{comment_thread_service,thread_lock,thread_lock_extension,graph_client,ice_breakers,pending_profile_extension}.rb` + specs
**Contrato:** `ERP-backend/docs/instagram/contrato-fork-erp.md` §2

---

## O que muda

Base: `/api/v1/accounts/:account_id/connectei-instagram/inboxes/:inbox_id` — autenticação
pelo `api_access_token` de usuário (token de bot não entra: o controller não está em
`BOT_ACCESSIBLE_ENDPOINTS`).

| Endpoint | Graph | Resposta |
|---|---|---|
| `POST comment-threads` `{igsid, username, comment_id}` | — (não chama a Graph) | `{conversation_id (display_id), conversation_status, contact_id, contact_inbox_id, source_id, created}` |
| `POST comments/:comment_id/replies` `{message}` | `POST /{comment_id}/replies?message=…` (passa pelo limitador por segundo) | `{id}` |
| `GET comments/:comment_id/replies` | `GET /{comment_id}/replies?fields=id,text,from,timestamp&limit=50` | `{data: [{id, text, from, timestamp}]}` — **só as respostas da própria conta** (`from.id == channel.instagram_id`): o ERP usa a releitura para saber se a resposta pública DELE saiu, e um comentário de outra pessoa com o mesmo texto não pode contar como entrega |
| `GET media?limit=24&after=…` | `GET /me/media?fields=…` | `{data, paging: {after}}` — `after` só quando há `paging.next` |
| `GET media/:media_id` | `GET /{media_id}?fields=…` | o objeto |
| `GET/PUT/DELETE ice-breakers` | `GET/POST/DELETE /me/messenger_profile` (`platform=instagram`, `locale=default`) | `{ice_breakers: [{question, payload}]}` |
| `GET users/:igsid` | `GET /{igsid}?fields=name,username,is_user_follow_business,is_business_follow_user` | os cinco campos |

**Isolamento:** o inbox precisa ser da conta, `Channel::Instagram` e acessível ao usuário
(administrador ou membro do inbox). Fora disso: **404** `not_found` — a mesma resposta para
"não existe" e "não é seu". Os ids do caminho (`comment_id`, `media_id`, `igsid`) só aceitam
`[0-9A-Za-z_-]`: eles vão para a URL da Graph. Canal marcado para reautorização responde
403 `reauthorization_required` **sem** chamar a Graph.

**Erros (§2.1):** `{ "error": { kind, code, subcode, message, retry_after } }`, com a tabela
de `Connectei::Instagram::GraphError.endpoint_error` (mod 025): 4/17/32/613/80002 → 429
`rate_limited` (+ `Retry-After`, lido do `x-business-use-case-usage` da Meta quando vier,
senão 60s); 190 → 403 `reauthorization_required` (e o canal pede reconexão); 230 → 409
`consent_required`; 100/33 → 404 `not_found`; 10/2xx → 403 `permission_denied`; 1, 2 ou HTTP
5xx → 503 `unavailable`; entrada inválida → 422 `invalid`. Timeout **depois** de enviar numa
escrita → 504 `ambiguous`; numa leitura → 503 `unavailable`. Conexão que nem abriu → 503.

### `comment-threads` em detalhe

- **Locks** (`Connectei::Instagram::ThreadLock`): espera o `IG_MESSAGE_CREATE_LOCK` do
  `(igsid, instagram_id)` — o mesmo mutex do `Webhooks::InstagramEventsJob`, até 5s (o do job
  dura 3s) — e, dentro da transação, pega `pg_advisory_xact_lock` em `(inbox_id, igsid)`.
  O builder de mensagens do Instagram pega **o mesmo advisory lock** antes de procurar/criar
  a conversa (`ThreadLockExtension`). Quem chega depois espera o COMMIT do primeiro e enxerga
  a conversa dele. Mutex que não libera → 503 `unavailable` com `retry_after: 1`.
- **Contato:** encontrado pelo `source_id` (não é tocado) ou criado com nome = username,
  `social_instagram_user_name` e `social_profiles.instagram` = username e
  `connectei_profile_pending = true`.
- **Conversa:** o mesmo critério do builder (`lock_to_single_conversation` reaproveita a mais
  recente, mesmo resolvida; sem a trava, a mais recente não resolvida). Sem nenhuma, cria com
  status **`pending`**. Nunca muda o status de uma existente; nunca cria mensagem.
- A resposta é montada **depois do COMMIT**: o `display_id` vem de trigger do banco e só é
  carregado no `after_create_commit` da conversa.

### Perfil no primeiro DM

`PendingProfileExtension` (em `Instagram::MessageText`): o upstream só busca o User Profile
quando o `contact_inbox` não existe — e o do comment-threads já existe. No primeiro DM
**recebido** (eco não conta) de um contato com `connectei_profile_pending`, o fork busca o
perfil, grava os `social_instagram_*` como o upstream, troca o nome provisório (= username)
pelo nome do perfil — só se ninguém mexeu nele — e apaga a marca. Falha (consentimento,
rede) mantém a marca para o próximo DM e nunca impede a mensagem.

## Por quê — e alternativas descartadas

- **Por que o fork expõe a Graph:** o token fica no fork (o ERP faz o OAuth mas não guarda,
  mod 003), e toda DM precisa nascer no fork para o eco não virar "atendente humano". O ERP
  pede; o fork chama a Graph com o token do canal.
- **Só o mutex do Redis** (como o job do upstream): ele é um amortecedor de 3s — o job,
  depois de 3 tentativas, processa **sem** o lock. Um comentário e um DM simultâneos da mesma
  pessoa abririam duas conversas, e com `lock_to_single_conversation` a segunda nunca some.
  O advisory lock dentro da transação é o que garante; há spec de concorrência real (duas
  conexões) provando os dois sentidos, vermelho sem o lock.
- **Buscar o User Profile no comment-threads:** a Meta recusa (230) o perfil de quem nunca
  mandou DM — exatamente o caso de quem só comentou.
- **403 para inbox de outra conta:** confirmaria que o inbox existe. 404 para tudo.
- **Rotas com `scope 'connectei-instagram/inboxes/:inbox_id'`:** dentro do bloco de
  `resources :accounts` o Rails põe o prefixo da conta depois do escopo; `resources … member`
  com `param: :inbox_id` gera o caminho certo.

## Comportamento num merge de upstream

- `config/routes.rb`: bloco aditivo junto das outras rotas Connectei (011, 012, 019).
- Os dois `prepend` são linhas isoladas. **Risco médio** no `ThreadLockExtension`: ele
  sobrescreve `set_conversation_based_on_inbox_config`; se o upstream renomear esse método, o
  lock deixa de valer **sem erro** — o spec de concorrência falha. O `PendingProfileExtension`
  sobrescreve `create_message` de `Instagram::MessageText`.
- O controller espelha a lógica de conversa do builder do upstream; se o upstream mudar o
  critério (`find_or_build_for_multiple_conversations`), compare com
  `CommentThreadService#existing_conversation`.

## O que verificar depois do merge

```bash
grep -n "connectei_instagram" config/routes.rb
grep -rn "modifications/026" app/builders app/services/instagram
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec \
  spec/controllers/api/v1/accounts/connectei_instagram_controller_spec.rb \
  spec/services/connectei/instagram/comment_thread_service_spec.rb \
  spec/services/instagram/message_text_pending_profile_spec.rb
```

O `comment_thread_service_spec.rb` roda **sem** a transação do exemplo (concorrência de
verdade) e, no fim, apaga **só as linhas que o próprio exemplo commitou**
(`spec/support/connectei_committed_records.rb`: retrato do maior `id` de cada tabela antes,
DELETE acima dele depois). Apagar a tabela inteira quebrava specs que commitam dados no
carregamento do arquivo (o blob do `slack_uploads_controller_spec.rb`), e TRUNCATE ainda
reinicia as sequências — chaves que o MockRedis guarda por id passariam a valer para
registros novos.
