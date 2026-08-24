# 021 — `connectei-conversations/filter`: ordenação pela última mensagem real

**Status:** ativo
**Arquivos do core alterados:** nenhum — só `app/services/connectei/conversations_query.rb` (arquivo do fork, mod. [012](012-connectei-conversations-filter.md))
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.11-connectei`

---

## O que muda

`sort_by=last_activity_at_desc|asc` passa a ordenar por

```sql
COALESCE(connectei_last_message.created_at, conversations.last_activity_at)
```

em vez de `conversations.last_activity_at`. `connectei_last_message` é o `LEFT JOIN LATERAL`
que a 012 já fazia para o preview: última mensagem com `message_type IN (0, 1)`
(incoming/outgoing) e `private = false`. Conversa sem nenhuma mensagem real cai na
coluna.

## Por que

`conversations.last_activity_at` é bumpada pelo `Message#set_conversation_activity`
em **toda** mensagem, inclusive as de atividade (`message_type = 2`: "marcada como
resolvida", etiqueta, atribuição). A sidebar do ERP exibe a data da última mensagem
real (`last_message.created_at`). Os dois divergem sempre que a última coisa que
aconteceu na conversa foi uma atividade.

O caso que apareceu em produção: uma resolução em lote de ~50 conversas de 10–12/08
gerou uma mensagem de atividade em cada uma. No banco elas viraram as "mais recentes"
e ocuparam a página 1 — mostrando "10/08" na sidebar, abaixo de conversas de hoje.
O painel do ERP reordena as páginas carregadas pelo campo exibido, então a lista
ficava intercalada e parecia quebrada.

Ordenar pelo **mesmo campo que a sidebar mostra** elimina a divergência. O nome
`last_activity_at_*` foi mantido para não mudar o contrato com o ERP
(`chat-direct/conversations?sortBy=`).

### Alternativas descartadas

- **Trocar o campo exibido para `last_activity_at`** — a hora da sidebar passaria a
  ser a da resolução/etiqueta, não a da última conversa. Pior para o atendente.
- **Reordenar no cliente** — só reordena a página carregada; com paginação no banco
  por outro critério, o item "certo" está em outra página. É exatamente o bug.

## Custo

O `ORDER BY` deixa de usar o índice `(account_id, inbox_id, last_activity_at DESC)`
da 012 para a ordenação: o Postgres filtra pelos índices, resolve o LATERAL por linha
(índice `(conversation_id, account_id, message_type, created_at)` de `messages`) e
ordena o conjunto filtrado em memória. Para o volume de uma loja (centenas a poucos
milhares de conversas por inbox) é irrelevante; se um dia aparecer no Axiom como
lento, o caminho é materializar `last_message_at` em `conversations` via callback —
não voltar à coluna.

## No merge de upstream

Nenhum arquivo do core é tocado; o conflito só existiria se o upstream criasse
`app/services/connectei/`, o que não vai acontecer. Depois do sync, rodar:

```bash
bundle exec rspec spec/controllers/api/v1/accounts/connectei_conversations_controller_spec.rb
```

O exemplo `sorts by the last REAL message, ignoring activity messages that bump
last_activity_at` é a regressão desta modificação.
