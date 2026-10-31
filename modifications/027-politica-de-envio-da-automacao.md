# 027 — Política de envio da automação no Instagram (sem `HUMAN_AGENT`, sem envio fora da janela)

**Status:** ativo
**Arquivo do core alterado:** `app/services/instagram/send_on_instagram_service.rb` — 1 linha
(`prepend Connectei::Instagram::AutomationPolicyExtension # [FORK CONNECTEI] modifications/027`)
**Arquivo novo:** `app/services/connectei/instagram/automation_policy_extension.rb`, spec
`spec/services/instagram/send_on_instagram_service_automation_policy_spec.rb`
**Contrato:** `ERP-backend/docs/instagram/contrato-fork-erp.md` §3 ("Política da automação")

---

## O que muda

Vale para mensagem da automação do ERP — a que tem `content_attributes.flow_effect_key`
(a marca que o ERP já envia em todo efeito de fluxo) — num inbox Instagram Login:

1. **Nunca leva `HUMAN_AGENT`**, mesmo de remetente `User`, fora da janela e com a flag
   `ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT` ligada.
2. **Fora de 24h desde a última mensagem recebida** (ou sem nenhuma mensagem recebida, o caso
   da conversa aberta pelo `comment-threads` da mod 026), e **não sendo private reply**: a
   Graph não é chamada; a mensagem vira `failed` com `external_error_kind: "window_closed"`,
   `external_error_code/subcode: null` e `external_error: "window_closed - …"`, numa escrita
   só (mesma `DeliveryOutcome` da mod 025).

O private reply fica fora da regra de 24h: ele tem a regra própria de 7 dias do comentário,
que a Meta aplica. Mensagem de atendente (sem `flow_effect_key`) segue as regras do upstream.

## Por quê

- A Meta só permite `HUMAN_AGENT` em resposta **escrita por humano**. O #15932 (mod 023)
  passou a olhar o tipo do remetente, mas o ERP posta pela API com token de **usuário** — para
  o fork, a automação "é" um `User`. Sem esta regra, uma automação fora da janela sairia
  com a tag: violação de política que pode punir o app inteiro.
- Enviar fora da janela dá erro na Meta de qualquer jeito (10/2534022). Não chamar a Graph
  economiza a cota da conta e devolve ao ERP um motivo estável (`window_closed`) em vez de um
  código da Meta.
- É **defesa em profundidade**: o ERP checa a janela antes de pedir o envio
  (`channel-send-policy`), com falha-aberta quando não consegue ler o canal. O fork confere de
  novo na hora em que a mensagem realmente sai.

### Alternativas descartadas

- **Checar no `messages_controller`** (recusar o POST): a mensagem não existiria, e o ERP
  perderia o rastro do efeito (o outbox espera um `message_updated` com o desfecho).
- **Usar `Conversations::MessageWindowService#can_reply?`**: com a flag de `HUMAN_AGENT` ligada
  ela devolve a janela de 7 dias — a de humano, não a da automação.
- **Aplicar também ao Instagram via página do Facebook**: o ERP só usa o Instagram Login.

## Comportamento num merge de upstream

Uma linha de `prepend` no topo da classe. O módulo sobrescreve `perform_reply` (do
`Instagram::BaseSendService`) e `merge_human_agent_tag`. Se o upstream renomear algum dos dois,
a política para de valer **sem erro** — os specs abaixo falham (há prova vermelho→verde:
sem a linha, 3 de 7 falham). Se o upstream implementar política equivalente para bots, compare
antes de remover: ela teria que reconhecer a automação pela `flow_effect_key`, não pelo remetente.

## O que verificar depois do merge

```bash
grep -n "modifications/027" app/services/instagram/send_on_instagram_service.rb
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec \
  spec/services/instagram/send_on_instagram_service_automation_policy_spec.rb spec/services/instagram
```
