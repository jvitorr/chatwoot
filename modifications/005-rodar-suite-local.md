# 005 — Como rodar a suíte de testes localmente sem falsos positivos

**Status:** ativo
**Arquivos do core alterados:** nenhum — este documento é só operacional

---

## Por que existe

Rodar `bundle exec rspec` na máquina local produz falhas que **não existem no CI** e não têm nada a ver com o código. Perder tempo depurando essas falhas é fácil: elas parecem regressões legítimas, com mensagens plausíveis, e apontam para arquivos do upstream que ninguém tocou.

Três divergências entre a máquina local e o CI explicam todas elas.

## 1. `.env` vaza para o ambiente de teste

`config/application.rb` chama `Dotenv::Rails.load`, que carrega `.env` em **todos** os ambientes, inclusive `test`. O CI (`.github/workflows/run_foss_spec.yml`) **não cria `.env`** — nenhum passo copia o `.env.example`.

Consequência prática: qualquer variável no seu `.env` local entra nos testes.

O caso mais traiçoeiro é `FRONTEND_URL`. Com `FRONTEND_URL=http://localhost:3010` (ou qualquer host diferente do host da requisição de teste), quatro specs quebram assim:

```
ActionController::Redirecting::UnsafeRedirectError:
  Unsafe redirect to "http://localhost:3010/integrations/slack/contact.png"
# spec/controllers/slack_uploads_controller_spec.rb
```

Nada a ver com o controller — o redirect saiu para outro host porque a env mudou.

`POSTGRES_DATABASE` é o segundo. No `config/database.yml` o bloco `test:` lê `ENV.fetch('POSTGRES_DATABASE', 'chatwoot_test')` **diretamente**, sem sufixo. Se o seu `.env` aponta para o banco de desenvolvimento, os specs rodam contra ele — e um banco semeado quebra dezenas de testes que assumem tabelas vazias, tipicamente com `PG::UniqueViolation` em `installation_configs`.

> Cuidado ao rodar tarefas de banco: `rails db:drop` com o `.env` carregado derruba o banco que estiver em `POSTGRES_DATABASE`, não o de teste. Passe `POSTGRES_DATABASE=chatwoot_test` explicitamente.

## 2. Timezone

Os runners do GitHub rodam em **UTC**. Numa máquina em horário de Brasília, specs que dependem de janelas de data falham silenciosamente — a asserção simplesmente conta zero:

```
V2::Reports::LabelSummaryBuilder ... counts multiple resolution events
  expected: 2
       got: 0
```

## 3. Código enterprise

O workflow FOSS remove o enterprise antes de rodar:

```yaml
- name: Strip enterprise code
  run: |
    rm -rf enterprise
    rm -rf spec/enterprise
```

Na verdade **nenhum workflow deste repositório roda `spec/enterprise`** — as únicas menções em `.github/workflows/` são `rm -rf`. Localmente eles rodam.

E dois deles exigem uma `FRONTEND_URL` que **contradiz** a dos specs FOSS:

| Specs | Precisam de |
|---|---|
| `spec/controllers/slack_uploads_controller_spec.rb` (4 exemplos) | `FRONTEND_URL` vazio (ou igual ao host da requisição) |
| `spec/enterprise/models/account_saml_settings_spec.rb`, `spec/enterprise/mailers/devise_mailer_spec.rb` | `FRONTEND_URL=http://localhost:3000` |

Não existe valor único que deixe os dois grupos verdes na mesma invocação. Isso é uma inconsistência do upstream, não do fork, e no CI nunca aparece porque os enterprise nunca rodam. Para cobrir tudo, rode em duas passadas (comandos abaixo).

> Não "conserte" isso editando os specs do upstream. Eles são reintroduzidos no próximo sync e o conflito volta.

## Como rodar

**Backend**, replicando o CI (passada 1 — tudo menos os enterprise de SAML):

```bash
eval "$(rbenv init -)"
TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test \
  bundle exec rspec
# esperado: 2 falhas, ambas em spec/enterprise (SAML) — ver passada 2
```

Passada 2, para os enterprise de SAML:

```bash
TZ=UTC FRONTEND_URL=http://localhost:3000 POSTGRES_DATABASE=chatwoot_test \
  bundle exec rspec spec/enterprise/models/account_saml_settings_spec.rb \
                    spec/enterprise/mailers/devise_mailer_spec.rb
```

As duas passadas juntas cobrem a suíte inteira em verde.

Preparar o banco de teste do zero (note o `POSTGRES_DATABASE` explícito):

```bash
RAILS_ENV=test DISABLE_DATABASE_ENVIRONMENT_CHECK=1 POSTGRES_DATABASE=chatwoot_test \
  bundle exec rails db:drop db:create db:schema:load
```

**Frontend**:

```bash
pnpm install
TZ=UTC ./node_modules/.bin/vitest --no-watch --no-cache --no-coverage
```

Rode o frontend **no host**, não dentro do container. Com os workers padrão (um por CPU) o vitest é morto por falta de memória dentro do Docker — o sintoma é `exit 137` e uma execução parcial, que sem olhar o código de saída passa por "tudo verde". Sempre confira a contagem de arquivos no sumário (`Test Files 357 passed (357)`) em vez de confiar na ausência de falhas.

## Antes de acusar uma regressão

Compare contra o `master` limpo num worktree separado, com o **mesmo banco e a mesma env**:

```bash
git worktree add /tmp/cw-baseline origin/master
cd /tmp/cw-baseline && TZ=UTC FRONTEND_URL= POSTGRES_DATABASE=chatwoot_test bundle exec rspec <specs>
```

Se a contagem de falhas bater, o problema não é seu.
