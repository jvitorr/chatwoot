# 012 — `connectei-conversations/filter`: listagem do painel resolvida no banco

**Status:** ativo
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.10-connectei`
**Arquivos do core alterados:** `config/routes.rb` (bloco de rota, junto da modificação 011)
**Arquivos novos:** `app/controllers/api/v1/accounts/connectei_conversations_controller.rb`, `app/services/connectei/conversations_query.rb`, `app/services/connectei/conversation_sql.rb`, `db/migrate/20260810120000_add_connectei_conversation_listing_indexes.rb`, `spec/controllers/api/v1/accounts/connectei_conversations_controller_spec.rb`
**Risco no merge:** Baixo para o código (tudo aditivo) — **atenção ao índice** (ver seção final)

---

## O que muda

Endpoint novo:

```
POST /api/v1/accounts/:account_id/connectei-conversations/filter
```

Corpo (todos os campos opcionais):

| Campo | Efeito |
|---|---|
| `inbox_ids[]` | Canais (múltiplos). Canal de outra conta ⇒ **422**, nunca lista vazia |
| `status` | `open` / `pending` / `resolved` / `snoozed` / `all` |
| `unassigned` | `true` ⇒ só sem atendente (a aba "Pendentes" do ERP é `status=open` + `unassigned=true`) |
| `assignee_ids[]` | Atendentes (múltiplos) |
| `labels[]` | Etiquetas com semântica **E** (a conversa precisa ter todas) |
| `exclude_labels[]` | Etiquetas que **excluem** a conversa (é como o ERP esconde grupos) |
| `display_ids[]` | Deep-link por id de conversa |
| `q` | Busca na **identidade do contato**: nome, e-mail, telefone e `identifier` (o handle da rede social) |
| `sort_by` | `last_activity_at_asc|desc`, `created_at_asc|desc`. **`last_activity_at_*` ordena pela data da última mensagem real** (a mesma de `last_message`), não pela coluna `conversations.last_activity_at` — ver [021](021-ordenacao-por-ultima-mensagem.md) |
| `created_from`, `created_to` | Intervalo de **entrada do lead**: a conversa foi aberta na janela **e** é a primeira conversa desse contato na conta. Contato que já tinha falado antes fica de fora, mesmo abrindo conversa nova hoje. Mesma regra do lead analytics (mod. 019). `YYYY-MM-DD`; `from` = início do dia, `to` = fim do dia. Formato inválido ⇒ **422** |
| `last_activity_from`, `last_activity_to` | Intervalo de **interação do chat**: `EXISTS` de mensagem humana (`incoming`/`outgoing`, sem nota privada) em `messages` dentro da janela. Não usa `last_activity_at` — essa coluna guarda só a ÚLTIMA mensagem e apagava quem falou dentro da janela e voltou a falar depois. Conversa sem nenhuma mensagem não tem interação. Mesmo formato/boundary de `created_from`/`created_to` |
| `pinned_display_ids[]` | Conversas fixadas — sobem para o topo **na ordenação**, não por recorte |
| `page`, `per_page` | Paginação (`per_page` até 100) |

Resposta: `meta` (`all_count` coerente com os filtros, `page`, `per_page`, `total_pages`) e `payload[]` com contato, etiquetas, `unread_count` e `last_message` já embutidos.

## Por que

O `/conversations/filter` oficial resolve parte dos filtros, mas deixa quatro buracos — e o cliente tapava cada um **em memória, sobre a página de 25 itens que acabou de receber**. Isso não é detalhe de implementação: um filtro aplicado depois da paginação simplesmente devolve resultado errado assim que existe mais de uma página.

| Buraco no upstream | O que o cliente fazia | O que passa a acontecer |
|---|---|---|
| Ordenação fixa em `last_activity_at DESC` (`Conversations::FilterService#conversations`) — `sort_by` é ignorado | Reordenava a página recebida | `ORDER BY` no banco |
| `name`, `phone_number` **não são atributos válidos** (respondem 422; ver `lib/filters/filter_keys.yml`) e o serviço não faz JOIN com `contacts` | Chamava `/contacts/search` e depois filtrava por `contact_id` — 2 chamadas | `q` único, com `ILIKE` sobre os campos do contato numa consulta só |
| Conversas fixadas são conceito do ERP | Buscava os fixados à parte e concatenava no topo | `CASE WHEN display_id IN (...) THEN 0 ELSE 1 END` como primeira chave do `ORDER BY` |
| `all_count` conta linhas que o cliente esconde depois (ex.: grupos) e custa **3 COUNTs** | Exibia total impreciso no rodapé | `exclude_labels` entra no `WHERE`; total sai de um `COUNT` sobre a mesma relação |

Além disso o payload já traz `unread_count` (subconsulta correlacionada) e `last_message` (`LEFT JOIN LATERAL`), que antes exigiriam uma chamada por conversa.

### Por que endpoint novo em vez de estender o oficial

O `README` deste diretório pede modificação **aditiva** sempre que possível. Estender `Conversations::FilterService` significaria mexer num serviço que o dashboard do próprio Chatwoot usa, com risco de regressão silenciosa e conflito garantido a cada sync. O endpoint novo custa um arquivo de rota e não toca nenhum caminho existente.

### Detalhes que não são óbvios

- **`last_activity_at_*` não ordena pela coluna de mesmo nome.** `conversations.last_activity_at` é bumpada por qualquer mensagem, inclusive as de atividade (`message_type = 2`: resolvida, etiqueta, atribuição). A sidebar do ERP exibe a data da última mensagem **real** (`last_message.created_at`), então uma resolução em lote colocava no topo dezenas de conversas mostrando data de duas semanas atrás. O `ORDER BY` usa `COALESCE(connectei_last_message.created_at, conversations.last_activity_at)` — o mesmo campo exibido. O nome do parâmetro foi mantido para não quebrar o contrato com o ERP. Ver [021](021-ordenacao-por-ultima-mensagem.md).

- **A busca é por PESSOA, não por texto da conversa.** A primeira versão varria também o conteúdo das mensagens, e o resultado foi ruim de um jeito que só aparece com dado real: mensagem de grupo chega com o nome de quem enviou em **negrito** no início do texto, então procurar alguém trazia todo grupo em que essa pessoa já falou — mais toda conversa em que alguém a mencionou. Na loja piloto, buscar "Amanda" devolvia 12 conversas das quais 2 eram dela. Os campos são os mesmos quatro do `contacts_controller` do core (`name`, `email`, `phone_number`, `identifier`), então o resultado bate com a busca de contatos do próprio Chatwoot. Se a busca em conteúdo voltar, precisa ser parâmetro próprio (`q_content`), nunca misturada.
- **Fixadas como ordenação, não como recorte**: se fossem concatenadas depois, sumiriam da página 2 em diante.
- **Visibilidade por papel no `WHERE`**: agente comum vê o próprio quadro e a fila sem dono; administrador vê tudo. Filtrar isso na resposta deixaria vazar contagem.
- **`ILIKE '%termo%'`** usa os índices GIN trigram que já existem em `contacts (name, email, phone_number, identifier)` e em `messages (content)`.

## Índices adicionados

`db/migrate/20260810120000_add_connectei_conversation_listing_indexes.rb`:

- `(account_id, inbox_id, last_activity_at DESC)` — **não existia nenhum índice em `last_activity_at`**, apesar de ser a ordenação padrão da listagem, inclusive a do `/conversations/filter` oficial. Cada página pedia um sort completo do conjunto filtrado;
- `(account_id, status, assignee_id)` — o quadro por atendente sem filtro de canal (modificação 011). O índice existente `(account_id, inbox_id, status, assignee_id)` só serve com `inbox_id` no `WHERE`.

Ambos com `algorithm: :concurrently` e `if_not_exists`, seguindo o padrão do repositório (ex.: `20250805160307_add_notifications_performance_index.rb`).

## Comportamento no merge de upstream

- **Código**: sem conflito esperado — os arquivos são novos e não há monkey patch. O único ponto compartilhado é o bloco de rotas (ver modificação 011).
- **Índice**: se um sync trouxer uma migration do upstream que crie índice equivalente em `last_activity_at`, o `if_not_exists` evita erro, mas vale remover o nosso para não manter índice duplicado (custo de escrita).
- **Enum de status**: `Conversation.statuses` é lido para traduzir `status`. Renomeação no upstream quebra o filtro — o spec cobre `open`/`resolved`/`pending`.

Após um sync, rode `bundle exec rspec spec/controllers/api/v1/accounts/connectei_conversations_controller_spec.rb` (16 exemplos, incluindo busca por contato, busca por conteúdo sem duplicar, etiqueta E, exclusão de etiqueta, fixadas no topo e paginação).

## Consumo pelo ERP (validado localmente)

O proxy do ERP tenta primeiro este endpoint e, ao receber **404**, cai no
caminho legado e memoiza a ausência por 5 minutos — assim uma instância que
ainda não recebeu o fork continua servindo o painel, e passa a usar o caminho
escalável sozinha assim que o deploy sobe, sem reiniciar o ERP.

Verificado num E2E com o Rails deste fork rodando local (18 verificações,
todas verdes): abas de situação, filtro de canal/etiqueta/atendente, busca por
nome e por conteúdo, ordenação nos dois sentidos, paginação com total coerente,
preview e não-lidas embutidos no item, quadro do dashboard, hidratação do board
por ids e isolamento de canal de outra loja. Na mesma rodada, a instância de
teste **sem** o fork foi exercitada e caiu no caminho legado sem quebrar.

Uma armadilha que o E2E pegou e vale registrar: cliente HTTP que serializa
array sem colchetes (`inbox_ids=1&inbox_ids=2`) faz o Rails ficar **só com o
último valor** — o quadro sai escopado num canal só, sem erro nenhum. Os
parâmetros de canal precisam ir como `inbox_ids[]`.
