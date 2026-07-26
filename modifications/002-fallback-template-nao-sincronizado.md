# 002 — Envio de template ainda não presente no cache de sincronização

**Status:** ativo
**Arquivo do core alterado:** `app/services/whatsapp/template_processor_service.rb` (método `processed_templates_params`)
**Commits:** `0f8cccbfc` (introdução), `43feaa1a8` (ajuste do gate)

---

## O problema

O Chatwoot resolve os parâmetros de um template a partir de `channel.message_templates` — um cache preenchido pelo job periódico de sincronização (`Channels::Whatsapp::TemplatesSyncJob`).

Quando o template **existe e está aprovado na Meta, mas ainda não entrou nesse cache**, o `find_template` devolve `nil` e o comportamento original era simplesmente desistir do envio. Na prática: um template recém-criado só ficava enviável depois que a sincronização periódica rodasse.

Para o fluxo Connectei isso é um bloqueio real — templates são criados e usados no mesmo ciclo de trabalho, e esperar a janela de sync torna a operação imprevisível para o lojista.

## O que a mudança faz

Quando o template não está no cache, passa a confiar nos parâmetros já processados que vieram na requisição, **desde que ela declare explicitamente o formato**:

```ruby
# Template not in the synced cache yet (e.g. just created in Meta). Only
# trust caller-provided enhanced params when the request explicitly carries
# a parameter_format hint, so legacy callers still get the safe nil result.
return if template_params['parameter_format'].blank? || template_params['processed_params'].blank?

process_enhanced_template_params(template, template_params['processed_params'])
```

Note que `template` aqui é `nil` — é intencional. O `process_enhanced_template_params` lida com isso via `resolve_parameter_format`, que cai no `parameter_format` da requisição justamente quando não há template para consultar.

## A sutileza do gate — e por que ela existe

A primeira versão (`0f8cccbfc`) exigia apenas `processed_params`. Isso quebrou uma spec do upstream que cobre o caso "template inexistente", cuja expectativa é receber `nil`.

Não era um teste chato: ele protege o comportamento seguro por padrão. Um chamador antigo, que manda `processed_params` sem declarar formato, **não** deveria ter seus parâmetros enviados às cegas — o formato errado produz uma mensagem malformada para o cliente final, não um erro.

A correção (`43feaa1a8`) foi exigir também `parameter_format`. Ele funciona como um **opt-in explícito**: só quem sabe o que está mandando entra no caminho novo; todo o resto continua recebendo o `nil` seguro do upstream.

> Ao mexer aqui, mantenha as **duas** condições do `return`. Remover a checagem de `parameter_format` "para simplificar" reabre a regressão e faz a spec do upstream falhar — o que, nesse caso, é o sistema funcionando.

## O que verificar depois de um merge de upstream

1. O `return if` precisa checar **`parameter_format` e `processed_params`**, nessa ordem lógica (basta um dos dois em branco para desistir).
2. Rodar `spec/services/whatsapp/template_processor_service_spec.rb` — cobre tanto o caso do template ausente (deve devolver `nil`) quanto o fallback legítimo.
3. Se o upstream reescrever o `processed_templates_params` por completo, reaplique o bloco **depois** do `return` do caminho com template encontrado, nunca antes: o caminho do cache tem prioridade e não deve ser afetado.
