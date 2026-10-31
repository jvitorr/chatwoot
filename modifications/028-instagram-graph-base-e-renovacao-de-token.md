# 028 — Base da Graph do Instagram (`INSTAGRAM_GRAPH_BASE_URL`, timeouts) e renovação diária de token

**Status:** ativo
**Arquivos do core alterados (ganchos de 1 linha, marcados `# [FORK CONNECTEI] modifications/028`):**
`app/models/channel/instagram.rb` (`base_uri` + timeouts no subscribe/unsubscribe),
`app/services/instagram/send_on_instagram_service.rb` (URL + timeouts do envio),
`app/services/instagram/message_text.rb` (`base_uri` + timeout do perfil),
`app/builders/messages/instagram/message_builder.rb` (`base_uri` + timeout da story),
`app/services/instagram/refresh_oauth_token_service.rb` (URL + timeout do refresh),
`app/controllers/concerns/instagram_concern.rb` (URL do OAuth nativo),
`config/schedule.yml` (entrada nova)
**Arquivos novos:** `app/services/connectei/instagram/graph.rb`, `app/jobs/connectei/instagram_token_refresh_job.rb`,
`spec/services/connectei/instagram/graph_spec.rb`, `spec/jobs/connectei/instagram_token_refresh_job_spec.rb`
**Contrato:** `ERP-backend/docs/instagram/contrato-fork-erp.md` §2 (base + timeouts), §5 e §6

---

## O que muda

### 1. Um ponto único para endereço, versão e timeout da Graph

`Connectei::Instagram::Graph` concentra:

| Método/constante | Valor |
|---|---|
| `base_url` | `INSTAGRAM_GRAPH_BASE_URL` (env), padrão `https://graph.instagram.com`, sem barra final |
| `api_version` | `INSTAGRAM_API_VERSION` pelo `GlobalConfigService` (padrão `v22.0`), como o upstream (#14937) |
| `versioned_base_url` | `base_url` + `/` + versão |
| `TIMEOUTS` | `open_timeout: 5`, `read_timeout: 15` |

Todas as chamadas do fork à Graph do **Instagram Login** passam por ele: envio,
subscribe/unsubscribe, perfil do usuário, story mencionada, refresh do token,
OAuth nativo (troca do token e `/me`) e os endpoints novos da mod 026. As
chamadas do Instagram via página do Facebook (`graph.facebook.com`, Koala) não
mudam — não são a Graph do Instagram e o ERP não usa esse canal.

### 2. Renovação diária do token

`Connectei::InstagramTokenRefreshJob`, agendado em `config/schedule.yml`
(`20 3 * * *`, fila `scheduled_jobs`):

- sem argumento, enfileira um job por canal com `expires_at` entre agora e
  10 dias (os já expirados ficam de fora: a Meta não renova token expirado);
- com o id do canal, chama `Instagram::RefreshOauthTokenService#access_token`,
  que só renova quando a Meta aceita (token válido, com mais de 24h e a menos de
  10 dias de expirar) e atualiza `access_token`/`expires_at`;
- registra `info` quando renovou e `warn` quando não (o service engole a falha).

## Por quê

- **Stub no E2E e na carga.** O ambiente local de Instagram (plano §5) sobe um
  stub da Graph. Sem uma base configurável, o fork sempre falaria com a Meta.
- **A env precisa vencer.** `INSTAGRAM_GRAPH_BASE_URL` é lida **direto do
  ambiente**. O caminho usual do fork (`GlobalConfigService.load`) grava o
  primeiro valor em `installation_configs`, e daí em diante o banco vence a env —
  é a armadilha documentada na mod 001. Para um endereço que existe justamente
  para ser trocado por ambiente, isso faria o stub ser ignorado depois do primeiro
  boot. Há spec garantindo que nada é gravado em `installation_configs`.
- **Timeout explícito.** Sem ele o HTTParty usa o padrão de 60s do Net::HTTP: uma
  Graph travada prende uma thread do Sidekiq por um minuto (achado A3). Com
  5s/15s, a falha aparece cedo e a mod 025 classifica o resultado (timeout depois
  do envio vira `delivery_unconfirmed`, nunca `failed`).
- **Renovação ativa.** O upstream só renova o token quando alguma mensagem passa
  pelo canal. Um canal sem tráfego por ~60 dias expira em silêncio e cai em
  "reautorização", e o ERP não guarda o token para renovar sozinho (mod 003).

### Alternativas descartadas

- **`GlobalConfigService.load('INSTAGRAM_GRAPH_BASE_URL', …)`**: ver acima — o
  valor de produção ficaria gravado no banco e o stub nunca seria usado.
- **Timeout também no OAuth nativo (`InstagramConcern#make_api_request`)**: só a
  URL mudou ali. É o fluxo de OAuth da interface do Chatwoot, que o Connectei não
  usa (o ERP faz o OAuth, mod 003), e o spec do upstream compara os argumentos
  exatos da chamada — mudar exigiria editar spec do upstream sem ganho real.
- **Um job único varrendo todos os canais em série**: uma Graph lenta somaria
  15s por canal num job só; o fan-out por canal isola falhas e timeouts.
- **Reaproveitar o refresh preguiçoso** (chamar `channel.access_token` no cron):
  é exatamente o que o job por canal faz — via `RefreshOauthTokenService`, sem
  duplicar a regra de elegibilidade.

## Comportamento num merge de upstream

- Os `base_uri` e as URLs foram trocados por `Connectei::Instagram::Graph…` em
  linhas isoladas. Se o upstream mexer nessas chamadas (nova versão, nova rota),
  fique com a versão dele e **reaplique o gancho**: a URL tem que partir de
  `Connectei::Instagram::Graph.versioned_base_url` (ou `.base_url` para rota sem
  versão) e a chamada tem que levar `**Connectei::Instagram::Graph::TIMEOUTS`.
- Se o upstream criar o próprio helper de base, prefira manter o nosso por cima
  dele **enquanto ele não ler a URL do ambiente** — senão o E2E deixa de funcionar
  sem nenhum erro.
- `config/schedule.yml`: entrada aditiva; conflito só se o upstream editar as
  linhas vizinhas.

## O que verificar depois do merge

```bash
grep -rn "graph.instagram.com" app lib --include='*.rb'   # só pode aparecer em connectei/instagram/graph.rb
grep -rn "modifications/028" app config
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec \
  spec/services/connectei/instagram/graph_spec.rb spec/jobs/connectei/instagram_token_refresh_job_spec.rb \
  spec/services/instagram spec/controllers/concerns/instagram_concern_spec.rb spec/configs/schedule_spec.rb
```

Teste vivo: suba o fork com `INSTAGRAM_GRAPH_BASE_URL=http://<stub>` e envie uma
mensagem num inbox Instagram — o stub tem que registrar o `POST /v22.0/<ig_id>/messages`.
