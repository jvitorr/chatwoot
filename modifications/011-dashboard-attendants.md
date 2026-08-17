# 011 — `dashboard-attendants`: quadro de atendimento agregado para o ERP

**Status:** ativo
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.8-connectei`
**Arquivos do core alterados:** `config/routes.rb` (5 linhas de rota)
**Arquivos novos:** `app/controllers/api/v1/accounts/dashboard_attendants_controller.rb`, `spec/controllers/api/v1/accounts/dashboard_attendants_controller_spec.rb`
**Risco no merge:** Baixo — adição isolada; o único ponto de conflito é o bloco de rotas

---

## O que muda

Endpoint novo:

```
GET /api/v1/accounts/:account_id/dashboard-attendants
```

Parâmetros (todos opcionais):

| Param | Default | Efeito |
|---|---|---|
| `inbox_ids[]` | todos | Escopo de canais. É o grão de isolamento quando **uma conta atende várias lojas do ERP** |
| `conversations_per_agent` | 20 (máx. 50) | Quantas conversas abertas devolver por atendente |

Resposta: `meta`, `totals`, `agents[]` (com `counts` por status e a fatia de conversas abertas, cada uma com contato e etiquetas) e `unassigned` (a fila sem dono).

## Por que

O painel `/chat/dashboard` do ERP precisa de duas coisas que a API pública não entrega juntas: **contagem por atendente** e **as conversas abertas de cada um**. Antes desta modificação o ERP montava isso assim:

- varria `POST /conversations/filter` até **8 páginas** (200 conversas) e agrupava por atendente **em memória**;
- disparava **2 chamadas por atendente** (`open` e `resolved`) para os contadores da tela de atendentes.

Com 10 atendentes isso é 28 chamadas HTTP para desenhar uma tela — e o agrupamento em memória fica errado assim que a operação passa do teto de páginas: o quadro simplesmente perde conversas, sem erro nenhum.

Agora é **uma chamada** e **3 queries fixas**, independentemente do número de atendentes ou de conversas:

1. `GROUP BY assignee_id` com `COUNT(*) FILTER (WHERE status = ...)` — um roundtrip para todos os contadores;
2. `ROW_NUMBER() OVER (PARTITION BY assignee_id ORDER BY last_activity_at DESC)` — a fatia por atendente sai **limitada do banco**, não cortada depois;
3. carga dos usuários da conta (`includes(:account_users)`) para nome/e-mail/avatar, sem N+1 por conversa.

O índice `conv_acid_inbid_stat_asgnid_idx` — `(account_id, inbox_id, status, assignee_id)`, que já existia no upstream — cobre exatamente o acesso do item 1 quando `inbox_ids` é informado. Para o caso sem filtro de canal, a modificação 012 adiciona `(account_id, status, assignee_id)`.

### Alternativas descartadas

- **`GET /api/v2/accounts/:id/live_reports/grouped_conversation_metrics`** (já existe no upstream): agrupa por `assignee_id`, mas dispara **3 queries** (uma por métrica), **não aceita filtro de inbox** — inutilizável quando a conta serve várias lojas — e devolve só contagens, sem as conversas que o quadro precisa exibir.
- **`V2::Reports::AgentSummaryBuilder`**: é métrica de tempo sobre `reporting_events` (tempo de resposta, resolução). Responde outra pergunta.
- **Estender o `/conversations/filter`**: seria invasivo num serviço que o dashboard do próprio Chatwoot usa, e o formato de resposta (lista paginada) não é o de um quadro agregado.

### Autorização — decisão deliberada

Não usa `authorize :report, :view?` (o padrão dos relatórios, que exige administrador). Em vez de negar, **o escopo acompanha o papel**:

- administrador da conta → operação inteira;
- agente comum → o próprio quadro **mais a fila sem dono** (que é o que ele pode puxar), com `meta.scope = "self"`.

Assim o endpoint serve tanto o painel do gestor quanto o do atendente, sem exigir que o ERP guarde um token de administrador. Um canal de outra conta em `inbox_ids` responde **422 explícito**, nunca lista vazia — lista vazia esconderia erro de configuração.

## Comportamento no merge de upstream

O conflito possível é em `config/routes.rb`, no bloco `scope module: :accounts`. Se o upstream adicionar rotas vizinhas, o merge resolve por proximidade — mantenha as duas linhas `resources :dashboard_attendants` e `resources :connectei_conversations` (modificação 012) juntas, com o comentário que as marca.

Depois de um sync, verifique:

1. `bundle exec rspec spec/controllers/api/v1/accounts/dashboard_attendants_controller_spec.rb` (8 exemplos);
2. que `Conversation.statuses` continua com as chaves `open`/`pending`/`resolved` — o controller monta o `COUNT FILTER` a partir desse enum, então uma mudança de nome quebra a contagem em silêncio (o spec pega);
3. que `Current.account_user` segue disponível no `BaseController` — é o que decide o escopo por papel.
