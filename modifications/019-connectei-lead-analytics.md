# 019 — `connectei-lead-analytics/filter`: agregação de leads (novo × recorrente) por canal e série temporal

**Status:** ativo
**Arquivos do core alterados:** `config/routes.rb` (bloco de rota, junto das modificações 011/012)
**Arquivos novos:** `app/controllers/api/v1/accounts/connectei_lead_analytics_controller.rb`, `app/services/connectei/lead_analytics_query.rb`
**Risco no merge:** Baixo — tudo aditivo, sem migration

---

## O que muda

Endpoint novo:

```
POST /api/v1/accounts/:account_id/connectei-lead-analytics/filter
```

Corpo:

| Campo | Obrigatório | Efeito |
|---|---|---|
| `inbox_ids[]` | Não | Canais (múltiplos). Vazio = todos os inboxes da conta — **o ERP nunca manda vazio de propósito** (ver Consumo pelo ERP) |
| `start_at`, `end_at` | Sim | Instantes ISO 8601 UTC (`YYYY-MM-DDTHH:mm:ss.sssZ`) — o boundary do fuso já vem calculado do lado do ERP |
| `granularity` | Não (default `month`) | `day` \| `week` \| `month` — tamanho do bucket da série temporal |
| `timezone` | Não (default UTC) | IANA (ex. `America/Sao_Paulo`) — usado só para o corte dos buckets, não para o filtro em si (esse já chega em UTC) |

Resposta:

```json
{
  "summary": { "total_leads": 10, "new_leads": 3, "returning_leads": 7 },
  "by_channel": [
    { "channel_id": 2, "channel_name": "Canal API E2E", "channel_type": "Channel::Api",
      "total_leads": 7, "new_leads": 2, "returning_leads": 5 }
  ],
  "time_series": [
    { "bucket_start": "2026-08-01T03:00:00.000Z", "bucket_end": "2026-08-31T02:59:59.999Z",
      "total_leads": 10, "new_leads": 3, "returning_leads": 7 }
  ]
}
```

`channel_type` sai **cru** (`Channel::Api`, `Channel::Whatsapp`, ...) — a tradução para o
vocabulário do contrato público do ERP (`whatsapp`/`instagram`/`facebook`/`site`/`telefone`/`outros`)
é responsabilidade do ERP (nunca vazar nome de classe do provedor pro cliente final).

## Por que

O ERP precisava de "quantos leads novos × recorrentes por canal, numa janela de datas,
com série temporal para o gráfico" — uma agregação que não existe em nenhuma API oficial do
Chatwoot (o dashboard nativo conta conversas, não contatos distintos classificados por
primeiro contato). Endpoint novo pela mesma razão da modificação 012: estender
`Conversations::FilterService` ou qualquer serviço do core arriscaria regressão silenciosa
a cada sync.

### Definição de "lead" e de "novo" × "recorrente"

- **Lead do período**: `contacts.id` distinto com pelo menos uma **mensagem humana**
  (`message_type` incoming/outgoing, não nota interna, não evento de sistema) num inbox do
  filtro, dentro de `[start_at, end_at]`. Mensagem, não `conversations.last_activity_at`
  (que a modificação 012 usa para "atividade") — aqui o sinal é especificamente "o lead
  interagiu", e `last_activity_at` também sobe em mudança de status sem mensagem nenhuma.
- **Novo** × **recorrente**: decidido pelo primeiro `conversations.created_at` do contato —
  **GLOBAL, em todos os inboxes da conta**, nunca só nos inboxes do filtro. Um lead que veio
  pelo Instagram em janeiro e voltou pelo WhatsApp em agosto é recorrente mesmo filtrando só
  WhatsApp. Efeito prático: `by_channel` soma pode passar de `summary.total_leads` (um lead
  ativo em dois canais na mesma janela conta uma vez em cada linha de `by_channel`) — mesma
  filosofia de métrica de atividade, não de estoque, que a série temporal já assume.
- **Série temporal**: um lead ativo em dois buckets diferentes (ex. mensagem em junho E em
  julho) aparece nos dois — a classificação novo/recorrente é fixa por todo o período
  consultado (não recalculada por bucket), só a presença no bucket muda.

### Por que `start_at`/`end_at` em vez de `start_date`/`end_date` + timezone

Ao contrário da modificação 012 (`created_from`/`created_to`, datas puras — o dia inteiro no
fuso do banco), aqui o ERP calcula o boundary exato (`00:00:00` do dia inicial / `23:59:59.999`
do dia final, no fuso pedido pelo cliente) e manda o instante UTC já resolvido. O `timezone` no
corpo entra só para os buckets da série temporal (onde o corte "começo do mês" depende do fuso),
não para o filtro `WHERE`. Decisão: resolver fuso uma vez do lado do ERP evita duplicar a lógica
de IANA timezone em Ruby E em TypeScript para o boundary — só a bucketização (que já precisa
rodar em Ruby, contra o banco) repete a resolução de fuso.

## Consumo pelo ERP (validado localmente)

Módulo `lead-analytics` (`ERP-backend/server/api/modules/lead-analytics/`), endpoints
`GET /api/v1/analytics/leads` e `GET /api/v1/analytics/leads/channels`. Só lojas em modo
direto — o serviço rejeita explicitamente (`CHAT_NOT_DIRECT_MODE`) lojas em modo espelho, já
que não há como responder sem chamar este endpoint.

**Tenant**: o ERP NUNCA manda `inbox_ids` vazio — o vazio deste endpoint significa "todos os
inboxes da CONTA", e a conta pode ser compartilhada entre lojas (mesmo racional da modificação
012/`list-direct-conversations.service.ts`). Sem filtro do cliente, o ERP resolve o universo
como "todos os canais que a loja tem vinculado localmente" antes de chamar este endpoint.

Verificado E2E local (runbook
[`ERP-backend/tasks/e2e-chat-local-api-channel.md`](../../ERP-backend/tasks/e2e-chat-local-api-channel.md)):
lead recorrente com primeiro contato fora da janela mas mensagem dentro dela é corretamente
separado de um lead novo criado dentro da janela; filtro por canal; granularidade `day`/`month`
com corte de fuso (`America/Sao_Paulo`, offset −03:00 refletido nos buckets); todos os erros de
validação do contrato do ERP (`INVALID_DATE_RANGE`, `DATE_RANGE_TOO_LARGE`,
`GRANULARITY_TOO_FINE`, `INVALID_CHANNEL_ID`, `TOO_MANY_CHANNEL_IDS`) passando pela chamada real.

## Comportamento no merge de upstream

Mesma análise da modificação 012: sem conflito esperado (arquivos novos), único ponto
compartilhado é o bloco de rotas.
