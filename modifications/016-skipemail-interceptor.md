# 016 — `skipemail`: nenhuma mensagem sai para endereço de identidade do ERP

**Status:** ativo
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.9-connectei`
**Arquivos do core alterados:** nenhum
**Arquivos novos:** `lib/connectei/skip_email_interceptor.rb`, `config/initializers/connectei_skip_email.rb`, `spec/lib/connectei/skip_email_interceptor_spec.rb`
**Risco no merge:** Nulo — interceptor registrado num initializer próprio

---

## O que muda

Qualquer e-mail cujo destinatário contenha `skipemail` não é entregue. Se a
mensagem tem destinatários mistos, os marcados saem da lista e os legítimos
recebem normalmente; se não sobra nenhum, a entrega é cancelada.

## Por que

O ERP provisiona cada atendente com um endereço determinístico —
`store_<loja>_<funcionário>_skipemail@connectei.com` — que é **chave de
identidade, não caixa postal**. O atendente nunca abre o painel deste provedor:
o gerenciamento é 100% no ERP.

Antes disso, a identidade usava o e-mail real da pessoa, e três coisas
aconteciam:

1. **Disparo em massa.** Toda filiação de agente nasce com
   `email_conversation_assignment` ligado (`app/models/account_user.rb`), e o
   ERP atribui conversa o tempo todo — a migração de uma loja transfere a fila
   inteira de uma vez. Cada atribuição virava um e-mail para o funcionário.
2. **Porta de entrada.** Com `:recoverable` ativo no Devise, "esqueci minha
   senha" entrega o link na caixa real da pessoa, e ela ganha o painel do
   provedor inteiro — furando o "gerenciamento só pelo ERP".
3. **Identidade defasada.** Quem trocava de e-mail no cadastro ficava com o
   antigo aqui, e num recadastro nasceria um usuário novo, deixando as
   conversas velhas presas no anterior.

O endereço sintético resolve os três. Este interceptor fecha o que sobra: **o
domínio `connectei.com` tem MX**, então sem ele cada notificação viraria um
bounce contra um servidor real. Bounce em série desgasta a reputação do domínio
de envio, e o preço disso é pago pelas mensagens que importam — as que vão para
o cliente final.

## Por que um interceptor, e não filtro nos mailers

`ActionMailer` tem um ponto de estrangulamento único para toda saída. Filtrar
mailer a mailer resolveria os de hoje e deixaria o próximo descoberto — e o
upstream adiciona mailers com frequência. O interceptor também não toca nenhum
arquivo do core: é um arquivo em `lib/` e um initializer, então o merge de
upstream não tem onde conflitar.

## Detalhes que não são óbvios

- **Destinatário misto entrega para os legítimos.** Cancelar a mensagem inteira
  porque um dos destinatários é sintético faria o cliente final perder o
  e-mail. O spec cobre esse caso explicitamente.
- **Cópia e cópia oculta também são limpas** — um agente em `bcc` receberia
  igual.
- **Comparação em minúsculas**: o endereço pode chegar normalizado de formas
  diferentes conforme o caminho.
- **`lib/` exige o namespace declarado**: o arquivo é carregado por `require`,
  fora do autoload do Zeitwerk, então `module Connectei; end` precisa vir antes
  da classe.

## Comportamento no merge de upstream

Sem conflito esperado: nenhum arquivo do core é tocado. Se o upstream passar a
registrar interceptors próprios, os dois convivem — o Rails aplica todos em
cadeia.

Depois de um sync, rode
`bundle exec rspec spec/lib/connectei/skip_email_interceptor_spec.rb` (6
exemplos, incluindo o de destinatário misto).

## O que este guarda NÃO resolve

Ele impede a saída, não o trabalho: o provedor continua criando a notificação e
enfileirando o job de e-mail a cada atribuição. Desligar
`email_conversation_assignment` no provisionamento eliminaria esse custo — vale
como próximo passo, não como pré-requisito.

E não fecha o acesso por SSO: `POST /platform/api/v1/users/{id}/login` gera link
de entrada para qualquer usuário. Quem tem o token de plataforma tem a
instância — esse token é chave-mestra e precisa ser tratado como tal.
