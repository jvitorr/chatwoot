# 017 — Como testar uma feature de chat ponta a ponta local (canal de API + ERP local)

**Status:** ativo — documento operacional
**Arquivos do core alterados:** nenhum
**Risco no merge:** —

---

## Por que existe

Um spec (`bundle exec rspec`) prova que uma query devolve o resultado certo.
Não prova que o **ERP consegue chegar nela** — a tradução de query params, a
validação de data na borda, o mapeamento pro contrato do fork
(`/connectei-conversations/filter`, mod. [012](012-connectei-conversations-filter.md)),
e a tela renderizando o resultado certo. A diferença apareceu na prática ao
validar os filtros `created_from`/`created_to`/`last_activity_from`/
`last_activity_to` da mod. 012: o spec Ruby passava, mas só rodar de ponta a
ponta (chat local → ERP local → navegador) achou que o primeiro acesso ao
chat em modo direto tenta provisionar o agente via **Platform API** — um
caminho que nenhum spec deste repo exercita, porque é responsabilidade do
ERP, não do fork.

Este documento é o "como" do lado do chat. O lado do ERP (banco de teste,
script de wiring, credenciais, passo a passo completo) vive em
[`ERP-backend/tasks/e2e-chat-local-api-channel.md`](../../ERP-backend/tasks/e2e-chat-local-api-channel.md)
— leia os dois juntos.

## Por que canal de API, e por que a stack `axiom`

**Canal de API** (`Channel::Api`) é o único tipo de inbox que não depende de
credencial de provedor externo (Meta, Instagram, WhatsApp Cloud) nem de
callback público alcançável — `account.inboxes.create!(channel:
Channel::Api.create!(account: account))` já é uma inbox funcional. Para testar
uma mudança de **listagem/filtro/query** (não de canal específico), é o menor
setup que ainda exercita o caminho real.

**`docker-compose.axiom.yaml`** (não `docker-compose.yaml`/`.test.yaml`) é a
stack recomendada para isto porque:

- o código roda por **volume montado** (`./:/app`) — uma mudança em
  `app/controllers`/`app/services` fica live sem rebuild de imagem, ao
  contrário de `docker-compose.test.yaml` (`RAILS_ENV=production`, build
  produtivo com assets precompilados);
- a imagem (`chatwoot-rails:development`) normalmente já está em cache local
  (usada para a integração Axiom, mod. [004](004-integracao-axiom.md)), então
  subir é rápido;
- o volume de Postgres é **persistente** entre subidas — um account de teste
  seedado uma vez continua disponível na próxima sessão, sem re-seed.

Portas: rails `3010` (host) → `3000` (container) — de propósito deslocado da
3000 default, que em qualquer setup deste monorepo já está ocupada pelo vite
do `connectei-rca`.

## O que este runbook NÃO é

Não confundir com `ERP-backend/scripts/e2e-chat/` + `ERP-backend/tasks/
e2e-chat-resilience.md` (mod. [010](010-qa-smoke-resiliencia-erp-chat.md)) —
aquele é para teste de **vazão e resiliência** (circuit breaker, retry de
webhook, campanha de 10k mensagens), com uma stack `docker-compose` **dedicada
e descartável** subida do zero a cada rodada. Este aqui é para "essa query/
filtro/coluna nova se comporta certo de ponta a ponta", reaproveitando o que
já está rodando na máquina.

## Passo a passo

Ver o runbook completo (subir o chat, achar/criar account+inbox+agente, gerar
access token, semear conversas com `created_at`/`last_activity_at`
divergentes, subir o ERP contra banco de teste local, ligar o modo direto pra
loja, testar na tela) em
[`ERP-backend/tasks/e2e-chat-local-api-channel.md`](../../ERP-backend/tasks/e2e-chat-local-api-channel.md).

Resumo do lado do chat, para quem só precisa disso:

```bash
cd chatwoot
docker compose -f docker-compose.axiom.yaml up -d rails vite mailhog
docker logs -f chatwoot-axiom-rails-1   # espera "Listening on http://0.0.0.0:3000"

# account/inbox de teste (crie se ainda não existir um — ver runbook do ERP)
docker exec chatwoot-axiom-rails-1 bundle exec rails runner '
Account.all.each { |a| puts "#{a.id} #{a.name}" }
Inbox.all.each { |i| puts "  inbox #{i.id} #{i.name} (#{i.channel_type}) account=#{i.account_id}" }
'

# access token do agente — vira o chatwootToken do ERP (header api_access_token)
docker exec chatwoot-axiom-rails-1 bundle exec rails runner '
puts User.find_by(email: "admin.e2e@connectei.local").access_token.token
'
```

## Armadilhas específicas do lado do chat

- **`ConversationsQuery` (mod. 012) faz `.joins(:contact)` sem `left_join`**:
  uma conversa criada via `Conversation.create!` sem `contact`/`contact_inbox`
  associado simplesmente NÃO aparece na listagem — sem exceção, sem log. Ao
  semear conversas de teste, sempre crie o `Contact`/`ContactInbox` junto (ver
  snippet no runbook do ERP).
- **`api_access_token` ≠ Platform API token**: o header que o ERP usa
  (`chatwoot-api.service.ts`) é o **access token pessoal de um usuário**
  (`user.access_token.token`, Devise Token Auth), obtido por conta/usuário —
  não tem relação com `CHATWOOT_PLATFORM_TOKEN` (autenticação de conta-mãe,
  usada só no provisionamento lazy de atendente-agente e no switch-mode). Os
  dois são fáceis de confundir porque o sintoma de token errado nos dois
  casos é genérico ("Plataforma de chat não configurada no servidor" ou 401).
- **`ENABLE_ACCOUNT_SIGNUP=true`** no `.env` da stack `axiom` permite criar
  conta pela UI (`http://localhost:3010`) em vez de `rails runner`, se
  preferir — mas exige confirmar o e-mail, e o Mailhog (porta 8035) é onde
  esse e-mail cai localmente.
