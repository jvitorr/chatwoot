# 003 — Rota de registro de canal Instagram sem redirect OAuth

**Status:** ativo
**Arquivo do core alterado:** `config/routes.rb` (uma linha)
**Arquivo novo:** `app/controllers/api/v1/accounts/instagram/channels_controller.rb`
**Commits:** `81aa28013` (introdução), `43feaa1a8` (refatoração para o rubocop)

---

## O problema

O caminho nativo para conectar um Instagram é o `Instagram::CallbacksController`, que depende do **redirect de OAuth** passar pelo `/instagram/callback` do próprio Chatwoot. Isso obriga o usuário a completar o fluxo dentro da interface do Chatwoot.

O Connectei faz o OAuth por conta própria — a aplicação externa conduz a autorização, troca o `code` por um token de longa duração, e chega ao fim do fluxo já com as credenciais na mão. Faltava uma porta para entregar essas credenciais ao Chatwoot.

## O que a mudança faz

Uma linha em `config/routes.rb`, dentro do namespace que já existia:

```ruby
namespace :instagram do
  resource :authorization, only: [:create]
  # [FORK CONNECTEI] Ver modifications/003-rota-registro-instagram.md
  resources :channels, only: [:create, :update]   # <- adicionado
end
```

> A linha nasceu como `resource :channels, only: [:create]` (singular) no commit `81aa28013` e virou `resources ... [:create, :update]` quando o PATCH de renovação de credenciais entrou. Ao procurá-la depois de um merge, **busque por `:channels`** — buscar pela forma antiga dá falso negativo.

E um controller novo que espelha o que o `CallbacksController#create_channel_with_inbox` faz, mas recebendo os tokens prontos:

- `POST /api/v1/accounts/:account_id/instagram/channels` — cria `Channel::Instagram` + `Inbox` a partir de credenciais já obtidas.
- `PATCH /api/v1/accounts/:account_id/instagram/channels/:id` — substitui `access_token` e `expires_at` de um canal existente, limpa a flag de reautorização e reinscreve o webhook. Serve para renovar credenciais **sem** criar canal duplicado.

Os erros são traduzidos para respostas de API em vez de estourar: canal já conectado devolve `422` com mensagem explícita, em vez do `RecordNotUnique` cru.

## Risco de merge: baixo

É a modificação mais segura das três. A alteração no core é **puramente aditiva** — uma linha dentro de um `namespace` existente — e não muda comportamento nenhum do Chatwoot. Toda a lógica mora em arquivo novo, que o upstream nunca vai tocar.

O conflito realista é o `config/routes.rb` divergir por mudanças vizinhas. Se acontecer, basta reintroduzir a linha `resource :channels, only: [:create]` no namespace `:instagram`.

## O que verificar depois de um merge de upstream

1. `grep -n ":channels" config/routes.rb` dentro do bloco `namespace :instagram` — sem fixar `resource`/`resources`, que já mudou uma vez.
2. Se o upstream reorganizar o fluxo de OAuth do Instagram (troca de versão da Graph API, mudança nos campos de `provider_config`), o controller **não** acompanha sozinho — ele espelha manualmente o `CallbacksController`. Compare os dois quando houver mudança ali.
