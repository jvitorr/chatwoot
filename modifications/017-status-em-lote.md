# 017 — Status de conversas em lote

`POST /api/v1/accounts/:account_id/connectei-conversation-statuses`

## Por que existe

Até a migração para o modo direto, "aberta" e "fechada" viviam **só no ERP**:
`updateChatWootStatus` gravava o espelho e o ticket e **nunca** chamou este
serviço. Ao virar o modo, o painel passa a ler o status daqui — onde essas
conversas continuam abertas. Uma loja que tinha 20 fechadas volta com 20
abertas na caixa de entrada, no primeiro dia.

A migração precisa então aplicar aqui tudo que o ERP fechou. Uma loja com anos
de histórico tem milhares dessas: uma chamada por conversa em `/toggle_status`
são milhares de idas e voltas HTTP.

## Contrato

```json
POST /api/v1/accounts/2/connectei-conversation-statuses
{ "conversations": [ { "id": 201, "status": "resolved" }, ... ] }

→ { "updated": 12, "unchanged": 3, "failed": [ { "id": 9, "error": "not found in this account" } ] }
```

`id` é o `display_id` — o mesmo que o resto da API usa.

## Decisões

**Passa pelo modelo, não por `update_all`.** Cada conversa é salva pelo
ActiveRecord, como no `toggle_status` oficial, para os invariantes do Chatwoot
continuarem de pé: `resolved_at`, mensagem de atividade, eventos de relatório.
Um `update_all` seria mais rápido e deixaria conversa resolvida **sem**
`resolved_at` — o relatório de tempo de resolução passaria a mentir. O ganho
buscado aqui é o número de requisições, não atalho no domínio.

**`unchanged` é separado de `updated`.** Conversa que já está no alvo não é
salva: reescrever geraria mensagem de atividade e evento de relatório a cada
execução, e a migração existe para poder rodar de novo. Separar os dois também
impede que a segunda execução pareça trabalho novo.

**Teto de 500 por requisição, com erro explícito.** Truncar em silêncio seria o
pior desfecho: o chamador acharia que migrou tudo e metade da caixa voltaria
aberta. Estourando, ele fatia.

**Escopo da conta numa consulta só.** `Current.account.conversations.where(display_id: ids)`
— um `find_by!` por item faria N SELECTs e desfaria metade do ganho. Conversa de
outra conta não aparece e cai em `failed` como não encontrada: o limite de
inquilino é o mesmo do resto da API, não uma checagem nova.

**Falha individual não derruba o lote.** O chamador recebe a lista do que
faltou e repete só isso.
