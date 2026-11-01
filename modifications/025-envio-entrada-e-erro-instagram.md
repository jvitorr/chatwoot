# 025 — Instagram: envio (quick replies, private reply, limitador, timeout), entrada (`ig_event`, payloads, referral) e erro estruturado da Meta

**Status:** ativo
**Arquivos do core alterados (ganchos de 1 linha, marcados `# [FORK CONNECTEI] modifications/025`):**
`app/services/instagram/send_on_instagram_service.rb` (`prepend Connectei::Instagram::SendExtension`),
`app/builders/messages/instagram/base_message_builder.rb` (`prepend Connectei::Instagram::InboundAttributesExtension`),
`app/builders/messages/instagram/message_builder.rb` (`prepend Connectei::Instagram::StoryFetchGuard`)
**Arquivos novos:** `app/services/connectei/instagram/{send_extension,outbound_payload,delivery_outcome,rate_limiter,graph_error,inbound_attributes,inbound_attributes_extension,story_fetch_guard}.rb` + specs
**Contrato:** `ERP-backend/docs/instagram/contrato-fork-erp.md` §3, §4 e §5

---

## O que muda

### Envio (`Instagram::SendOnInstagramService`, Instagram Login)

| O ERP pede | O fork faz |
|---|---|
| `content_type: input_select` + `content_attributes.items: [{title, value}]` | `message.quick_replies = [{content_type: 'text', title: title[0,20], payload: value}]`, no máximo 13 |
| `content_attributes.ig_private_reply.comment_id` | `recipient: { comment_id }`, **sem** `HUMAN_AGENT`; grava `source_id = message_id`; se o `recipient_id` devolvido diferir do `source_id` do contato, grava `ig_private_reply.recipient_id` e registra `warn` |
| qualquer envio | limitador por conta antes da Graph; timeout de 5s/15s (mod 028) |

**Formato no fio** (útil para o stub da Graph do E2E): o corpo continua
`application/x-www-form-urlencoded`, como no upstream (`recipient[id]=…&message[text]=…`).
Private reply vira `recipient[comment_id]=…`. Com quick replies, o parâmetro `message` vai
**inteiro como JSON** (`message={"text":"…","quick_replies":[…]}`): lista de objetos não
sobrevive ao form-encoding do HTTParty (`message[quick_replies][][title]` vira um item por
campo na Graph), e parâmetro de objeto em JSON é formato aceito pela Graph. Quick replies
não são combinadas com private reply (a Meta só documenta texto no private reply).

### Erro da Meta estruturado

Além do `external_error` de sempre (`"código - mensagem"`), a mensagem que falha ganha
`external_error_code`, `external_error_subcode` e `external_error_kind` — **na mesma
escrita** do `failed` (um único `message_updated`; há spec contando). A tabela
(`Connectei::Instagram::GraphError.message_kind`):

| Meta | `external_error_kind` |
|---|---|
| 190 | `token` (e o canal pede reautorização, como antes) |
| 4, 17, 32, 613, 80002 | `rate_limited` |
| 10 / 2534022 | `window_closed` |
| 551; 100 / 2534014 ou 2018001 | `user_unavailable` |
| private reply: 100, 33, ou 10 com subcode | `comment_unavailable` |
| limitador do fork | `rate_limited` (sem chamar a Graph, `external_error_code: null`) |
| o resto | `unknown` |

### Timeout e desfecho ambíguo

- `Net::ReadTimeout`/`WriteTimeout`, `ECONNRESET`, `EPIPE`, `EOFError` (a requisição pode
  ter chegado): a mensagem **continua `sent`** e ganha `delivery_unconfirmed = true` (+
  `delivery_diagnostics`, como na mod 006). Nunca `failed`.
- `Net::OpenTimeout`, conexão recusada, DNS, SSL (com certeza não saiu): `failed` com
  `external_error_kind: unknown`.
- Se, enquanto a Graph respondia, o eco já adotou a mensagem (mod 027b) e gravou o
  `source_id`, nem o timeout nem um erro tardio mudam a mensagem: `source_id` é prova de
  entrega (o princípio da mod 006).

### Limitador por conta

`Connectei::Instagram::RateLimiter`, por `instagram_id`, em Redis:

- `CONNECTEI_IG_SEND_PER_SECOND` (padrão 90) em toda chamada de envio;
- `CONNECTEI_IG_PRIVATE_REPLY_PER_HOUR` (padrão 720) nos private replies, consultado **por
  último** (o slot escasso não é gasto num envio que o limite por segundo recusaria).

Janela **deslizante** (log de timestamps num ZSET), não janela fixa: com janela de relógio,
720 envios às 10:59 e 720 às 11:00 passariam — o dobro do que a Meta aceita numa hora.
Cada aquisição, num MULTI: limpa o que saiu da janela, **adiciona** a própria marca e conta;
acima do teto, retira a marca e recusa. Adicionar antes de contar mantém a decisão correta
sob concorrência sem Lua (o MockRedis dos specs não executa `EVAL`). Redis indisponível
**libera** o envio (falha-aberto) e registra `error`.

### Entrada (`Messages::Instagram::BaseMessageBuilder`)

`content_attributes` de toda mensagem que entra ganha, quando o evento tiver:

| Chave | De onde vem |
|---|---|
| `ig_event` | `story_mention` (anexo `story_mention`), `story_reply` (`reply_to.story`), `share` (anexo `share`/`ig_post`/`ig_reel`/`ig_story`) |
| `quick_reply_payload` | `message.quick_reply.payload` |
| `postback_payload` / `postback_title` | `postback` (que a mod 023 já transforma em mensagem) |
| `referral` | `message.referral`, `postback.referral` ou o `referral` do item — sempre `{ref, source, type, ad_id, ads_context_data}` |

`ig_event` entra no **INSERT** da mensagem, antes de o builder buscar a story na Graph. O
`image_type` do upstream só existe se essa busca der certo; quando ela falhava, a menção
chegava ao ERP como mensagem comum (achado A6).

E o `StoryFetchGuard`: a busca da story roda **dentro** da transação que cria a mensagem.
Uma exceção de transporte (timeout, conexão recusada) ou uma página de erro que não é JSON
(502 de proxy) subia, desfazia a transação e a menção **sumia** — com o marcador junto.
Agora vira "sem dados da story": a mensagem fica, com o anexo e o `ig_event`.

O **download da mídia** também roda na mesma transação (`attach_file`, do upstream). O
arquivo de uma menção ou de uma publicação/reel compartilhado é um link da CDN da Meta que
expira: um 404, uma conexão recusada ou um timeout faziam a menção sumir do mesmo jeito
(achado no E2E local de Instagram, com a mídia fora do ar). O guard agora cobre também
`attach_file` para os tipos `story_mention`, `share`, `ig_post`, `ig_reel` e `ig_story`: o
anexo fica só com o `external_url` e a mensagem — com o `ig_event` e os dados da story —
fica. Mídia que o próprio cliente manda (foto, áudio, vídeo, arquivo) segue o upstream.

## Por quê — e alternativas descartadas

- **`prepend` em vez de editar os métodos do upstream:** cada arquivo do core ganha uma
  linha; toda a lógica mora em `app/services/connectei/instagram/`. Os métodos
  sobrescritos (`message_params`, `merge_human_agent_tag`, `send_message`,
  `process_response`, `external_error`, `handle_error`) chamam `super`.
- **Mandar o corpo inteiro como JSON** (`Content-Type: application/json`) resolveria as
  quick replies, mas mudaria a codificação de toda mensagem do canal e exigiria editar a
  chamada do upstream. O JSON só no parâmetro `message` só muda a mensagem com menu.
- **Gravar o erro estruturado depois do `failed`:** dois `message_updated`, e o primeiro
  chegaria ao ERP sem o `kind`. Por isso os atributos são montados em memória antes do
  `StatusUpdateService`.
- **Janela fixa (INCR + EXPIRE)** ou **Lua**: ver acima.
- **Limitar por conta do Chatwoot** em vez de por conta do Instagram: os limites da Meta
  são por conta profissional do Instagram.
- **Esperar o slot por segundo em vez de falhar:** prenderia a thread do Sidekiq; o
  contrato pede `rate_limited` e o ERP re-admite com slot novo.

## Comportamento num merge de upstream

- Os três `prepend` são linhas isoladas no topo das classes. **Risco médio**: se o upstream
  renomear ou mudar a assinatura de um método sobrescrito (por exemplo `process_response`,
  `external_error`, `message_params` ou `get_story_object_from_source_id`), o `super`
  continua funcionando mas a extensão pode deixar de ser chamada **sem erro nenhum**. Depois
  de todo merge que toque `app/services/instagram/` ou `app/builders/messages/instagram/`,
  rode os specs abaixo — eles falham se a extensão sair do caminho.
- Se o upstream implementar quick replies ou private reply por conta própria, compare com
  esta extensão antes de manter as duas.

## O que verificar depois do merge

```bash
grep -rn "modifications/025" app/services/instagram app/builders/messages/instagram
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec \
  spec/services/instagram/send_on_instagram_service_connectei_spec.rb \
  spec/builders/messages/instagram/message_builder_connectei_spec.rb \
  spec/services/connectei/instagram spec/services/instagram spec/builders/messages
```
