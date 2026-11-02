# 024 — Campanhas nativas do chat desligadas em todas as contas

**Status:** ativo
**Arquivos do core alterados:** `config/features.yml` (só o `enabled` da entrada `campaigns`), `db/schema.rb` (só a linha de versão)
**Arquivos novos:** `app/services/connectei/disable_native_campaigns.rb`, `db/migrate/20261102120000_disable_native_campaigns_for_connectei_accounts.rb`, `spec/services/connectei/disable_native_campaigns_spec.rb`, `spec/enterprise/services/connectei/disable_native_campaigns_spec.rb`
**Entra junto com:** o sync [023](023-sync-4.19.1.md) (4.19.1.1)

---

## O que muda

A feature de conta `campaigns` (campanhas nativas do chat: SMS, WhatsApp e as
campanhas "ongoing" do widget) fica **desligada**:

1. **Em todas as contas existentes.** A migration `20261102120000` chama
   `Connectei::DisableNativeCampaigns#perform`, que zera o bit de `feature_campaigns`
   em `accounts.feature_flags` com aritmética de bits, em lotes de 1000:
   ```sql
   UPDATE accounts SET feature_flags = feature_flags & ~CAST(<bit> AS bigint)
    WHERE feature_flags & <bit> <> 0
   ```
   O bit e a coluna vêm de `Account.flag_mapping` (FlagShihTzu) em tempo de execução,
   nunca fixos no código. Nenhum outro bit muda, nem em `feature_flags` nem em
   `feature_flags_ext_1`. É `update_all`, sem callbacks: os callbacks de `Account`
   (`clear_unread_conversation_counts_cache`, `resume_delayed_automations`) dependem de
   outras features, não de `campaigns`.
2. **No default das contas novas.** O mesmo serviço grava `enabled: false` na entrada
   `campaigns` de `InstallationConfig ACCOUNT_LEVEL_FEATURE_DEFAULTS`, que é o que
   `Featurable#enable_default_features` (before_create) lê. As outras entradas e a ordem
   guardada ficam como estão. Se a linha não existir, ela é criada a partir de
   `config/features.yml`, como o `ConfigLoader` faria. Se existir sem a entrada
   `campaigns`, a entrada é acrescentada no fim, uma vez só.
3. **Na instalação nova.** `config/features.yml` passa a ter `enabled: false` em
   `campaigns` (ver "Por que o `features.yml` também muda").

O serviço é idempotente: a segunda execução não altera nenhuma linha. O `down` da
migration não faz nada, de propósito: não queremos religar automaticamente.

Para religar numa conta específica (não previsto), use o super admin, na tela da conta,
feature "Campaigns". Isso não é desfeito por deploy: a migration roda uma vez só.

## Por que

O Connectei nunca usa campanha nativa. Quem dispara campanha é o ERP, direto na Graph
API do WhatsApp, e por isso a mensagem não existe no chat: o status que a Meta devolve
é de um wamid "órfão" (sem `Message` e sem `CampaignRecipient`).

Na 4.19, `Enterprise::Whatsapp::IncomingMessageBaseService#process_statuses` enfileira
`Campaigns::UpdateRecipientStatusJob` para todo status órfão `delivered`/`read`/`failed`
quando `account.feature_enabled?(:campaigns)`. O job espera o `CampaignRecipient`
aparecer, com até 5 tentativas na fila `low` do Sidekiq. Como o recipient nunca vai
existir, cada status de cada disparo do ERP vira um job inútil, repetido 5 vezes, na
mesma fila das campanhas e de outros trabalhos de fundo. Num disparo de 10 mil mensagens
são até ~150 mil execuções (3 status × 5 tentativas × 10 mil).

Com a feature desligada, o `return unless inbox.account.feature_enabled?(:campaigns)`
do próprio upstream corta o enfileiramento. O repasse do status ao ERP (mod.
[001](001-repasse-status-whatsapp-connectei.md)) não depende da feature e continua
igual. A spec `spec/enterprise/services/connectei/disable_native_campaigns_spec.rb`
prova as duas coisas.

## Por que o `features.yml` também muda

Só a migration não cobre a instalação nova. O `db:chatwoot_prepare`
(`lib/tasks/db_enhancements.rake`), usado no ambiente local e no e2e, faz numa base
vazia: `load_schema` → `db:seed` → `db:migrate`.

- O `load_schema` marca todas as migrations como executadas (versão do `schema.rb`),
  então a `20261102120000` **nunca roda** nessa base.
- O `db/seeds.rb` chama `ConfigLoader.new.process`, que cria
  `ACCOUNT_LEVEL_FEATURE_DEFAULTS` a partir do `features.yml`, e depois cria as contas
  de exemplo.

Sem a mudança no `features.yml`, a instalação nova nasceria com `campaigns` ligado.

A mudança é segura frente aos avisos do próprio arquivo ("nunca reordenar, remover ou
trocar a coluna"): a posição da entrada define o bit, e ela não muda. O `enabled` é só o
valor default. O upstream também troca defaults assim.

Interação com o `ConfigLoader` (roda depois de todo `db:migrate`, com
`reconcile_only_new: true`):

- Linha existente: se o valor guardado for igual ao do `features.yml`, nada acontece.
  Se for diferente, ele faz `(guardado + features.yml).uniq { name }`, e a entrada
  guardada vence. Então ele **não** religa o default que a migration desligou, nem se um
  sync futuro resolver o `features.yml` de volta para `enabled: true`. A spec cobre esse
  caso com um `features.yml` temporário que diz `true` (contexto "when a later sync
  resolves config/features.yml back to campaigns enabled: true"): com
  `reconcile_only_new: true` o default fica `false`; com `reconcile_only_new: false` ele
  volta a `true`, o que mostra que a spec distingue os dois modos.
- Linha inexistente: cria a partir do `features.yml`, já com `false`.
- Nada no repositório chama `ConfigLoader` com `reconcile_only_new: false` fora das specs.

## Alternativas descartadas

- **Só editar o `features.yml`.** Não muda instalação existente (o `ConfigLoader` mantém
  a entrada guardada) nem conta existente.
- **Rodar o desligamento a cada `db:migrate`** (gancho no rake, depois do
  `ConfigLoader`). Desfaria em todo deploy um religamento feito de propósito no super
  admin, e acrescentaria um gancho num rake do upstream.
- **Tirar o `return unless feature_enabled?` ou o enfileiramento em
  `incoming_message_base_service.rb`.** Edição invasiva num arquivo que o upstream
  muda com frequência, e o bug de origem é a feature estar ligada sem uso.
- **Bit fixo na migration.** A posição depende da ordem do `features.yml`. O upstream
  usa `Account.flag_mapping` (`20261014152259_enable_mobile_voice_push_for_all_accounts.rb`),
  e esta modificação faz o mesmo.
- **`account.disable_features!` conta a conta.** Funciona, mas carrega cada conta e
  dispara callbacks sem necessidade. O `update_all` em lote faz o mesmo numa query por
  lote.

## Efeitos colaterais conhecidos

Com `campaigns` desligado numa conta:

- O menu de campanhas some do painel.
- O widget não exibe campanhas "ongoing" (`api/v1/widget/campaigns_controller.rb`).
- Campanha `one_off` agendada não dispara: `Campaign#trigger!` sai cedo.
- O histórico e a análise de campanha de WhatsApp ficam bloqueados.
- **Exceção:** uma campanha de WhatsApp que **já está em `processing`** continua enviando.
  `Whatsapp::OneoffCampaignService#perform` valida a feature, mas `perform_batch` (os
  lotes seguintes, via `Campaigns::SendWhatsappBatchJob`) não valida. O
  `Campaigns::RecoverWhatsappCampaignsJob` também reenfileira campanhas `processing`
  paradas sem olhar a feature.

## Pré-checagem do deploy (somente leitura)

Antes do deploy, confirme que nenhuma conta usa campanha nativa:

```sql
SELECT account_id, campaign_type, campaign_status, count(*)
  FROM campaigns
 GROUP BY 1, 2, 3;
```

- **Vazio:** segue o deploy.
- **Com linhas:** confira com o suporte se a conta usa a campanha. `campaign_type`:
  0 = `ongoing` (widget), 1 = `one_off`. `campaign_status`: 0 = `active`,
  1 = `completed`, 2 = `processing`. Uma `one_off` de WhatsApp em `processing` (2)
  continua enviando depois do deploy (ver acima). Se precisar parar, trate-a antes.

## Como o conflito se comporta no próximo sync

- **`config/features.yml`:** conflito só se o upstream mexer nas linhas da entrada
  `campaigns`. Resolva mantendo `enabled: false` e o comentário `[FORK CONNECTEI]`, e
  aceitando o resto do upstream (`display_name`, `help_url`, entradas novas no fim). Se o
  upstream **remover ou mover** a entrada, ele quebrou a própria regra do arquivo. Pare e
  investigue antes de resolver.
- **`db/schema.rb`:** a linha de versão conflita sempre que o upstream tiver migration
  nova. Fique com a **maior** versão. Se o upstream tiver migration com timestamp maior
  que `20261102120000`, a nossa continua sendo aplicada normalmente (o Rails roda por
  ausência em `schema_migrations`, não por ordem).
- **Serviço, migration e specs:** arquivos só do fork, sem conflito.
- **Se o upstream mudar a forma de checar a feature** (outra flag, outro nome) no
  enfileiramento de `Campaigns::UpdateRecipientStatusJob`, a spec enterprise desta
  modificação fica vermelha. Não apague a spec: veja qual é o novo gate e desligue-o
  também.

## O que verificar

Depois do deploy:

```sql
-- contas com campanhas ligadas: tem que dar 0
-- (substitua <bit> pelo valor de Account.flag_mapping['feature_flags'][:feature_campaigns])
SELECT count(*) FROM accounts WHERE feature_flags & <bit> <> 0;
```

```ruby
# rails console: tem que devolver false
InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS').value.find { |f| f['name'] == 'campaigns' }['enabled']
Account.where("feature_flags & #{Account.flag_mapping['feature_flags'][:feature_campaigns]} <> 0").count # => 0
```

- Depois de um disparo do ERP, a fila `low` não recebe `Campaigns::UpdateRecipientStatusJob`.
- O ERP continua recebendo os status (`Whatsapp::ForwardMessageStatusToErpJob`, mod. 001).
- Uma conta criada pela Platform API nasce sem `campaigns`.

## Testes

- `spec/services/connectei/disable_native_campaigns_spec.rb` (core, roda no CI):
  - as contas existentes perdem o bit;
  - os outros bits ficam intactos nas duas colunas;
  - a segunda execução é idempotente;
  - o default é atualizado preservando as outras entradas e a ordem;
  - a linha é criada quando falta, e a entrada é acrescentada uma vez quando falta;
  - o `ConfigLoader` não religa o default;
  - uma conta nova nasce sem `campaigns`;
  - o `features.yml` vem com `false`.
- `spec/enterprise/services/connectei/disable_native_campaigns_spec.rb` (o CI apaga
  `spec/enterprise`; rode local):
  - com a feature ligada, o status órfão enfileira o job (linha de base);
  - depois do `perform`, não enfileira mais;
  - o repasse ao ERP continua.
