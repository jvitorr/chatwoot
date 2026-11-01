# 027b — O eco não vira "atendente fantasma" e o `POST /messages` é idempotente por `flow_effect_key`

**Status:** ativo
**Arquivos do core alterados (1 linha cada, marcados `# [FORK CONNECTEI] modifications/027b`):**
`app/builders/messages/instagram/base_message_builder.rb` (`prepend Connectei::Instagram::EchoAdoptionExtension`),
`app/controllers/api/v1/accounts/conversations/messages_controller.rb` (`include ConnecteiFlowEffectIdempotency` —
o mesmo controller da mod 007)
**Arquivos novos:** `app/services/connectei/instagram/echo_adoption_extension.rb`,
`app/controllers/concerns/connectei_flow_effect_idempotency.rb` + specs
**Contrato:** `ERP-backend/docs/instagram/contrato-fork-erp.md` §3 (idempotência) e §4 (eco)

---

## (a) Eco adotado

### O problema

Toda mensagem que o fork envia ao Instagram volta como eco (`is_echo`). O upstream só
reconhece o eco pelo `mid` (`find_by(source_id)`), e o controller do webhook atrasa o
processamento do eco em 2s fixos para dar tempo de o envio gravar o `source_id`. Quando a
Graph demora mais que isso — ou o envio cai em timeout e a mensagem fica sem `source_id`
(mod 025) —, o eco chega com um `mid` desconhecido e vira uma **mensagem nova** de saída,
`sender: nil`, `external_echo: true`: exatamente a forma de uma resposta digitada no app do
Instagram. O ERP lê isso como **atendente humano** e pausa a automação (achado A4).

### A correção

Eco com `mid` desconhecido **adota** a mensagem de saída pendente da mesma conversa:

- mesmo `contact_inbox` (o do destinatário do eco);
- `source_id` nulo, não `failed`, não privada;
- criada há no máximo **5 min**;
- **mesmo texto normalizado** (NFC, espaços colapsados) — comparado com o `outgoing_content`
  (o texto que saiu, já com o markdown do canal aplicado) e com o `content` cru.

A adotada ganha o `mid` como `source_id` e perde o `delivery_unconfirmed` (o eco é prova de
entrega); o `update!` publica `message_updated`, então o ERP vê o `source_id` e resolve um
envio ambíguo. Nenhuma mensagem nova nasce. Com duas pendentes de texto igual, o primeiro eco
adota a mais antiga. Sem candidata — **mensagem digitada no app do Instagram** — o
comportamento é o do upstream: vira mensagem humana.

Eco sem texto (só anexo) não é adotado: "texto vazio igual a texto vazio" adotaria anexos
diferentes; segue o upstream.

## (b) `POST /messages` idempotente por `flow_effect_key`

`POST /api/v1/accounts/:id/conversations/:id/messages` com `content_attributes.flow_effect_key`
que **já existe nesta conversa** devolve **200 com a mensagem existente** (o mesmo JSON do
`create`), sem criar e sem enviar ao canal. Vale para **todo canal**. Sem a chave, nada muda.

- A chave é lida nos três formatos que o ERP usa: objeto JSON, campos de formulário
  (`content_attributes[flow_effect_key]`) e string JSON no multipart.
- **Concorrência:** advisory lock transacional em `(conversa, chave)`; a segunda requisição
  espera o COMMIT da primeira e devolve a mensagem dela (spec com duas conexões, vermelho sem
  o lock).
- **Por conversa**, como o ERP gera a chave. Mensagem existente `failed` volta como está:
  para tentar de novo (ex.: depois de `rate_limited`), o ERP precisa de uma **chave nova**.
- A consulta não usa `->> 'flow_effect_key'`: `content_attributes` é `json` com
  `store … coder: JSON`, então o banco guarda uma **string** JSON contendo o objeto, e o
  operador não enxerga a chave. O pré-filtro é textual (só as mensagens da conversa) e a
  igualdade exata é conferida no objeto decodificado. Chave com caractere que o JSON escapa
  (aspas, `\`, `<>&`, controle) ou curinga do `LIKE` pula o pré-filtro e a conversa é varrida
  inteira — mais lento, nunca errado. As chaves do ERP (`flow-outbound:<execução>:<nó>:<n>`)
  ficam no caminho rápido.
- O spec de concorrência roda sem a transação do exemplo e apaga só o que commitou
  (`spec/support/connectei_committed_records.rb`, ver mod 026).

## Por quê — e alternativas descartadas

- **Aumentar a espera fixa de 2s:** só move a janela; qualquer Graph mais lenta (ou o timeout
  de 15s da mod 028) volta a gerar o fantasma, e toda mensagem humana passaria a demorar mais.
- **Marcar o eco pelo texto em qualquer conversa/horário:** colaria eco em mensagem errada.
  Os critérios (mesma conversa, 5 min, pendente, mesmo texto) são o mínimo para não adotar
  uma mensagem que um humano digitou.
- **Idempotência no `Messages::MessageBuilder`:** o builder é usado por muitos caminhos do
  core (bots, automações, e-mail); o controller é a porta do ERP, e a mod 007 já mora ali.
- **Header `Idempotency-Key`** (o ERP também manda um): exigiria guardar as chaves em outro
  lugar; a `flow_effect_key` já está na própria mensagem e é o que o ERP usa para conciliar.

## Comportamento num merge de upstream

- `base_message_builder.rb`: o `prepend` sobrescreve `message_already_exists?`. Se o upstream
  renomear o método ou mudar a dedupe do eco, a adoção para **sem erro** — os specs de
  `message_builder_echo_adoption_spec.rb` falham.
- `messages_controller.rb`: uma linha de `include` no topo; convive com os ganchos da mod 007
  (`update`). O `around_action` usa `if: -> { action_name == 'create' }` e depende de o
  `@conversation` já estar carregado pelo `before_action :conversation` do controller pai.

## O que verificar depois do merge

```bash
grep -rn "modifications/027b" app/builders app/controllers
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec \
  spec/builders/messages/instagram/message_builder_echo_adoption_spec.rb \
  spec/controllers/api/v1/accounts/conversations/messages_controller_flow_effect_spec.rb \
  spec/controllers/api/v1/accounts/conversations/messages_controller_flow_effect_concurrency_spec.rb \
  spec/controllers/api/v1/accounts/conversations/messages_controller_spec.rb
```
