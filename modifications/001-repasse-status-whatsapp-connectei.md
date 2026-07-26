# 001 — Repasse de status de mensagem WhatsApp para o ERP Connectei

**Status:** ativo
**Arquivo do core alterado:** `app/services/whatsapp/incoming_message_base_service.rb` (um gancho, ~8 linhas)
**Arquivos novos (não conflitam):** `app/jobs/whatsapp/forward_message_status_to_erp_job.rb`, `app/services/whatsapp/erp_status_forward_service.rb`
**Contraparte no ERP:** `server/api/modules/waba-message/` (ERP-backend)

---

## O problema

O ERP dispara campanhas de WhatsApp **direto na Graph API da Meta**, sem passar pelo Chatwoot. Até esta mudança, ele marcava o envio como "enviado" na resposta HTTP 200 do `POST /messages` — que significa apenas *"a Meta aceitou a requisição e emitiu um `wamid`"*, e não *"a mensagem chegou ao cliente"*.

Quando a Meta desistia da entrega depois (número sem WhatsApp, janela de 24h expirada, template inválido), nada corrigia o registro: o lojista via "Enviada" para uma mensagem que nunca chegou.

A confirmação real existe — a Meta a envia no campo `messages` do webhook, em `statuses[]`, com `sent`/`delivered`/`read`/`failed`. O problema é **quem recebe esse webhook**.

## Por que o Chatwoot precisou entrar nisso

Três fatos que, juntos, não deixam alternativa:

1. **A Meta não tem endpoint de consulta.** Não existe um `GET` para perguntar o status de uma mensagem pelo `wamid`. O status é *push*, e só.

2. **O Chatwoot é o dono do webhook, e se reinscreve sozinho.** `Whatsapp::WebhookSetupService#setup_webhook` chama `subscribe_waba_webhook`, que faz `POST /{waba}/subscribed_apps` com `override_callback_uri` apontando para `#{FRONTEND_URL}/webhooks/whatsapp/#{phone_number}`. Isso roda no embedded signup **e na reautorização do canal**. Repontar o webhook para o ERP na mão seria sobrescrito em silêncio na próxima reautorização — e a falha apareceria como "os status pararam de chegar", sem erro nenhum.

3. **ERP e Chatwoot compartilham o mesmo Meta App.** Isso elimina o caminho mais limpo, que seria o fan-out por app: dois apps distintos inscritos na mesma WABA recebem os mesmos eventos, cada um na sua callback URL. Como o app é o mesmo, um segundo `subscribed_apps` com outra `override_callback_uri` **substituiria** a do Chatwoot — e todo o inbound de atendimento passaria a cair no ERP.

Os dois convivem hoje porque os campos assinados são disjuntos: o Chatwoot assina `messages` + `smb_message_echoes` (`WEBHOOK_DEFAULT_FIELDS`), e o ERP recebe `message_template_*` pela callback do app.

## O que a mudança faz

O `process_statuses` já descartava silenciosamente todo `wamid` que não fosse dele:

```ruby
return unless find_message_by_source_id(status[:id])
```

Esse `nil` **é exatamente o conjunto que interessa**: `wamid` sem `Message` no Chatwoot = mensagem que o Connectei disparou direto na Graph API. O `sent`, o `delivered` e o `failed` das campanhas já chegavam nesta infraestrutura e eram jogados fora.

O gancho troca o descarte por um repasse:

```ruby
unless find_message_by_source_id(status[:id])
  forward_orphan_status_to_erp(status)
  return
end
```

E `forward_orphan_status_to_erp` apenas enfileira — nunca levanta:

```ruby
def forward_orphan_status_to_erp(status)
  Whatsapp::ForwardMessageStatusToErpJob.perform_later([status.to_h])
rescue StandardError => e
  Rails.logger.error "[WHATSAPP][erp-status-forward] enqueue failed: #{e.message}"
end
```

## Decisões que parecem detalhe e não são

### Repassar só o órfão, não todos os status

O critério de propriedade é o próprio banco do Chatwoot. Repassar **todos** os status mandaria ao ERP cada `delivered` e cada `read` de toda conversa de atendimento — uma ordem de grandeza a mais de tráfego para descartar quase tudo.

O filtro de *quais status importam* fica no ERP, de propósito: é regra de negócio dele. Enterrá-la aqui faria "mudar de ideia sobre `delivered`" virar um deploy do Chatwoot.

### Falso órfão é inofensivo — e é contrato

Existe uma corrida conhecida (é o que motiva o `MessageDedupLock` e o `lock_message_source_id!`): a Meta às vezes entrega o `sent` antes de o Chatwoot gravar a mensagem de saída. Nessa janela, uma mensagem **legítima daqui** é classificada como órfã e repassada.

Isso é seguro **porque o ERP descarta `wamid` desconhecido em silêncio**. Não é um efeito colateral tolerado: é requisito explícito do handler do outro lado, e há teste cobrindo. Se alguém mudar o ERP para tratar `wamid` desconhecido como erro, esta corrida vira ruído de alerta.

### Job próprio, e não `POST` inline no `WhatsappEventsJob`

O `WhatsappEventsJob` só trata `LockAcquisitionError` explicitamente; qualquer outra exceção sobe para o Sidekiq, que **reprocessa o job inteiro** — refazendo todo o `process_events`.

Se o repasse fosse inline, uma indisponibilidade do ERP passaria a reprocessar em massa a fila de atendimento, acoplando a saúde do sistema mais crítico à do menos crítico. Com job próprio, o pior caso é a fila `low` acumular repasses até o ERP voltar.

### O repasse é a única cópia do evento

O `Webhooks::WhatsappController#process_payload` responde `head :ok` à Meta **imediatamente**, antes de qualquer processamento. Quando o repasse falha, a Meta já recebeu o 200 e **nunca reenvia**.

Por isso o retry importa: `retry_on ... attempts: 8` com backoff polinomial. E por isso a distinção de erro no service não é decorativa — 5xx e falha de rede levantam (retenta); 4xx registra e não levanta (contrato quebrado, insistir só encheria a fila).

## Autenticação

HMAC-SHA256 sobre `<timestamp>.<corpo>`, no cabeçalho `x-connectei-signature`, formato `t=<epoch>,v1=<hex>`. O timestamp entra no material assinado para que um repasse capturado não possa ser renovado trocando só o `t=`; o ERP recusa fora de uma janela curta.

**Não dá para reencaminhar a assinatura original da Meta.** O HMAC dela é sobre os bytes exatos recebidos, e esses bytes não sobrevivem ao `params.to_unsafe_hash` do controller nem à serialização do ActiveJob — qualquer reserialização muda espaçamento, ordem de chave e escape de unicode.

Consequência assumida: **o limite de confiança do ERP passa a ser o Chatwoot, não a Meta.** Isso já era verdade de fato, já que o Chatwoot é o dono do canal; a mudança apenas torna explícito.

## Configuração

| Variável | Onde | Efeito se ausente |
|---|---|---|
| `CONNECTEI_STATUS_FORWARD_URL` | Chatwoot | Repasse vira **no-op silencioso** (o service retorna cedo) |
| `CONNECTEI_STATUS_FORWARD_SECRET` | Chatwoot | Idem |
| `CHAT_STATUS_FORWARD_SECRET` | ERP | Endpoint responde 503; o Chatwoot registra a recusa |

Os dois segredos precisam ter **o mesmo valor**. Ambas as variáveis do Chatwoot são lidas via `GlobalConfigService.load` com fallback para `ENV`, então dá para configurar pelo Super Admin sem redeploy.

### Contrato de degradação: a feature é acessória

O envio de mensagem é o que importa; a confirmação de status é escrituração. **Nenhuma falha da escrituração pode derrubar ou duplicar um envio.** Isso está travado por teste (`resiliencia-sem-configuracao.unit.test.js` no ERP) e vale para tabela ainda não migrada, banco indisponível e configuração ausente.

| Situação | Comportamento |
|---|---|
| Sem `CONNECTEI_STATUS_FORWARD_*` no Chatwoot | Repasse desligado, **com log em `info`** dizendo qual variável falta. O processamento do webhook segue normal. |
| Sem `CHAT_STATUS_FORWARD_SECRET` no ERP | Endpoint responde **503** e loga. O Chatwoot registra a recusa e o job vai para a dead set após os retries. O resto do ERP não é afetado. |
| Tabela `waba_message` ausente (código antes da migration) | O envio **acontece normalmente** e a linha termina em `SENT`. Só a correlação se perde. |
| Guarda de duplicidade indisponível | **Falha-aberto**: segue o envio, que é o comportamento anterior à feature. Falhar-fechado bloquearia disparos de campanha por causa de uma consulta auxiliar. |
| Expurgo de órfãos falha | Registrado e ignorado; o ciclo de envio continua. Ele roda antes do lote ser enfileirado, então propagar abortaria os disparos. |

O 503 do ERP é deliberado e **não** foi trocado por 200: um lado configurado e o outro não é uma inconsistência que precisa aparecer. Silenciar com 200 esconderia a falta da variável até alguém notar que os status pararam de chegar.

### Armadilha: o banco vence a variável de ambiente

`GlobalConfigService.load(chave, ENV[...])` consulta **`installation_configs` primeiro** e só cai no `ENV` se não houver linha. Uma vez que a chave exista na tabela, **mudar a variável de ambiente não tem efeito nenhum** — o container sobe com a env nova e continua usando o valor antigo do banco, sem aviso.

Isso foi observado na prática: um `rails db:seed` executado com um `.env` de desenvolvimento gravou `CONNECTEI_STATUS_FORWARD_URL` apontando para `localhost`. Depois, subindo o container com a env correta, o repasse continuou tentando `localhost:7979` — que, dentro do container, é o próprio container. O sintoma foi `ERP unreachable: Connection refused`, com o Sidekiq retentando em backoff.

Ao diagnosticar "o repasse não chega", **verifique a tabela antes da env**:

```sql
SELECT name, serialized_value FROM installation_configs WHERE name LIKE 'CONNECTEI%';
```

Para fazer o `ENV` voltar a valer, remova as linhas (ou corrija o valor pelo Super Admin, que é o caminho normal em produção).

Ausência de configuração é degradação silenciosa por escolha: um Chatwoot sem essas variáveis funciona normalmente, só não alimenta o ERP. O preço é que **um deploy que esquece a variável parece saudável** — se os status pararem de chegar, comece por aqui.

## O que verificar depois de um merge de upstream

O gancho fica dentro do `process_statuses`, um método que o upstream altera com frequência (o próprio `update_whatsapp_identifiers_from_status` foi acrescentado na 4.15). **Um merge que resolva o conflito mantendo a versão do upstream remove o repasse sem quebrar nada** — nenhum teste do lado do ERP falha, porque do lado de cá simplesmente não chega evento.

Checklist:

1. `grep -n "forward_orphan_status_to_erp" app/services/whatsapp/incoming_message_base_service.rb` — precisa aparecer **duas vezes** (a chamada dentro do `process_statuses` e a definição do método).
2. O `return unless find_message_by_source_id(...)` **não** pode ter voltado: o `unless/end` com o repasse dentro é que é o correto.
3. Teste vivo: envie um `statuses[]` com um `wamid` que não exista na tabela `messages` e confirme no log do Sidekiq o `Enqueued Whatsapp::ForwardMessageStatusToErpJob`.
4. Teste do ramo negativo — o mais importante: envie um `statuses[]` com um `wamid` **que exista** em `messages` e confirme que **nenhum** job foi enfileirado. Se este falhar, o Chatwoot está repassando toda conversa de atendimento ao ERP.

## Verificação executada (26/07/2026)

End-to-end com Chatwoot 4.15.1 e ERP rodando simultaneamente, em duas montagens:

**A partir do código-fonte** (Rails + Sidekiq via rbenv):

- `POST /webhooks/whatsapp/+55…` com `wamid` órfão → job enfileirado → ERP recebeu → `workflow_schedule` foi de `SENT` para `ERROR` com código `NUMERO_INVALIDO`, e a trilha registrou `SENT` seguido de `PROVIDER_FAILED`.
- Mesmo webhook com `wamid` conhecido → **nenhum** job enfileirado, nenhuma chamada ao ERP, e o Chatwoot atualizou a própria mensagem para `delivered`.
- Contrato HMAC Ruby ↔ TypeScript validado com o serviço real chamando o endpoint real.

**A partir da imagem publicada** (`joaoftnunes/chatwoot:4.15.1-connectei`, containers de Rails e Sidekiq contra Postgres e Redis locais):

- `wamid` órfão → `workflow_schedule` de `SENT` para `ERROR` com `JANELA_EXPIRADA` (código Meta 131047) e trilha `PROVIDER_FAILED`.
- `wamid` conhecido → contadores de job e de repasse inalterados (4 → 4 e 1 → 1), mensagem do Chatwoot atualizada para `delivered`.
- Foi nesta montagem que a armadilha do `installation_configs` apareceu (ver acima).
