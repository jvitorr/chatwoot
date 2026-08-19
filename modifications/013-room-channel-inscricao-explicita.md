# 013 — `RoomChannel`: inscrição que confirma ou rejeita, nunca silencia

**Status:** ativo
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.10-connectei`
**Arquivos do core alterados:** `app/channels/room_channel.rb` (rescue + resolução de usuário/conta)
**Arquivos novos:** nenhum — specs adicionados ao `spec/channels/room_channel_spec.rb` existente
**Risco no merge:** Médio — o arquivo é pequeno, mas o upstream mexe nele; o `rescue` fica no fim do `subscribed`

---

## O que muda

Três coisas, todas no `RoomChannel`:

1. **`subscribed` passa a rejeitar explicitamente** quando não consegue identificar quem está assinando (`ActiveRecord::RecordNotFound` ⇒ `reject`).
2. **Token de agente basta para assinar**: sem `user_id`, o upstream assume que o token é de contato; agora, se nenhum `ContactInbox` casar, procura-se um `User` pelo mesmo token.
3. **`account_id` vira opcional para agente de conta única** — continua sendo respeitado quando enviado.

## Por que

Este é o achado que motivou a modificação. Em produção, o painel do ERP assinava o canal com `{channel: 'RoomChannel', pubsub_token: <token do agente>}` e **nunca recebia resposta**: nem `confirm_subscription`, nem `reject_subscription`. O socket ficava aberto recebendo `ping` a cada 3s — parecendo saudável — enquanto nenhum evento de domínio chegava. O painel degradava para polling sem que nada no cliente indicasse falha.

A causa está na combinação de dois comportamentos:

- `RoomChannel#current_user` trata `params[:user_id].blank?` como "é um contato" e faz `ContactInbox.find_by!(pubsub_token:)`. Para um token de **agente** isso levanta `RecordNotFound`;
- `ActionCable::Connection::Subscriptions#execute_command` envolve o `subscribe` num `rescue Exception` que chama `@connection.rescue_with_handler(e)`. Como a aplicação **não registra nenhum `rescue_from`**, o resultado é uma linha de `logger.error` e mais nada. O frame de confirmação nunca sai, e o frame de rejeição também não — porque `reject_subscription` só é avaliado **depois** de `subscribed` retornar sem erro.

Ou seja: qualquer falha de identificação vira silêncio, e silêncio é indistinguível de "ainda conectando" para o cliente. Um cliente correto não tem como se recuperar, porque não há evento nenhum para reagir.

O `rescue` explícito transforma isso num `reject_subscription`, que é acionável: o cliente sabe que a credencial não serve e pode renová-la.

Os itens 2 e 3 removem a causa mais comum dessa falha. O `pubsub_token` já é único e secreto — é ele que autoriza o stream (`stream_from pubsub_token`). Exigir `user_id` e `account_id` junto não acrescenta segurança: são identificadores públicos, e quem tem o token já teria como descobri-los. Torná-los opcionais deixa o contrato do cliente mínimo (`{channel, pubsub_token}`) sem afrouxar nada.

### Alternativas descartadas

- **`rescue_from` na `ApplicationCable::Connection`**: pega a exceção, mas nesse ponto não há mais referência à subscription para rejeitar — daria para fechar a conexão inteira, o que é pior (derruba todas as outras subscriptions do mesmo socket).
- **Deixar o cliente inferir por timeout**: foi o comportamento acidental que existia. Inferir ausência de confirmação exige um temporizador arbitrário em cada cliente e não distingue "credencial inválida" de "rede lenta".
- **Só documentar que `account_id` e `user_id` são obrigatórios**: resolveria o caso conhecido, mas manteria o silêncio para todos os outros (token revogado, usuário removido da conta, conta suspensa).

## Comportamento no merge de upstream

O upstream mexe neste arquivo com alguma frequência (presença, streams). O que verificar depois de um sync:

1. o `rescue ActiveRecord::RecordNotFound` continua **no `subscribed`** — se o upstream reescrever o método, o rescue é a primeira coisa a se perder no merge, e a regressão é invisível (volta o silêncio);
2. `current_user` continua com o fallback `ContactInbox ... || User.find_by!(pubsub_token:)`;
3. `resolve_user_account` continua sendo chamado no lugar de `accounts.find(params[:account_id])`.

Os specs cobrem os três pontos: `bundle exec rspec spec/channels/room_channel_spec.rb` (6 exemplos, sendo 4 desta modificação — inclusive um que exige `be_rejected` para token inexistente).

> Nota de teste: no `ActionCable::Channel::TestCase` a exceção **propaga** em vez de ser engolida, ao contrário do runtime. Um spec que apenas esperasse `raise_error` passaria mesmo com o bug em produção — por isso os specs verificam `be_rejected`/`be_confirmed`, que é o que o cliente realmente observa.
