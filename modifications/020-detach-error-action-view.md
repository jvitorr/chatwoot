# 020 — `ActionView` fora do `use_all`: fim do `DetachError` no contexto do OpenTelemetry

**Status:** ativo
**Arquivos do core alterados:** nenhum — `lib/opentelemetry_config.rb` já é arquivo do fork (mod. [004](004-integracao-axiom.md))
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.10-connectei`

---

## O problema

Com `AXIOM_TRACE_RAILS=true`, o log de produção repetia sem parar, várias linhas
no mesmo milissegundo:

```
E, [...] ERROR -- : OpenTelemetry error: calls to detach should match corresponding calls to attach.
```

Não é mensagem cosmética. O OpenTelemetry guarda o contexto ativo numa **pilha
por Fiber** (`opentelemetry-api/lib/opentelemetry/context.rb`, `Fiber.attr_accessor
:opentelemetry_context`). O token devolvido por `attach` é literalmente a
**profundidade da pilha** naquele instante:

```ruby
def attach(context)
  s = stack; s.push(context); s.size   # token = profundidade
end

def detach(token)
  calls_matched = (token == s.size)    # a pilha mudou de altura no meio?
  OpenTelemetry.handle_error(...) unless calls_matched
  s.pop                                # ... e desempilha assim mesmo
end
```

O erro significa que, na hora do `detach`, a pilha estava noutra altura — por
`attach` sem `detach`, por detaches fora de ordem, ou por attach num Fiber e
detach noutro.

Como o `pop` acontece de qualquer jeito e nenhuma exceção sobe, **nada quebra na
aplicação**: requisição não falha, job não morre. Foi por isso que ficou tanto
tempo passando. O que quebra é o **trace**: pilha desbalanceada emparenta span no
lugar errado e vaza contexto para trabalho posterior, que passa a herdar um trace
que não é dele. Ou seja, corrompe exatamente o dado que a instrumentação existe
para produzir — e ainda enterra o log em ERROR.

## Como o culpado foi encontrado

O erro reproduz local com o canal de API (runbook da mod. [017](017-e2e-local-canal-api.md)),
com `ENABLE_AXIOM_TRACES` + `AXIOM_TRACE_RAILS` ligados e o `AXIOM_DOMAIN`
apontado para um sumidouro (`127.0.0.1:9`), para nada ser ingerido de verdade.

Backtrace sozinho não bastava: ele mostrava `SpanSubscriber#finish`, que é
genérico. O que fechou o diagnóstico foi um `OpenTelemetry.error_handler`
temporário somado a um `prepend` em `SpanSubscriber#finish` gravando o **nome do
evento** de notificação. Uma rajada de 8 mensagens pela API deu:

```
17  render_partial.action_view
 9  render_template.action_view
 5  sidekiq / active_job   (consequência: a pilha já estava torta)
```

`opentelemetry-instrumentation-action_view` cria spans a partir de
`ActiveSupport::Notifications` via `SpanSubscriber`, que faz `Context.attach` no
start e `detach` no finish. O fanout de notificações **não garante** que os
finishes cheguem na ordem inversa dos starts, e as views jbuilder da API — que
aninham parciais em coleção — expõem isso a cada render.

Os quatro gems que usam esse subscriber são `action_mailer`, `action_view`,
`active_model_serializers` e `active_storage`. Dos quatro, mailer e storage já
estavam desligados; a medição isolou o `action_view` e absolveu o
`active_model_serializers`.

## O que muda

Uma entrada em `UNSUPPORTED_INSTRUMENTATIONS` (`lib/opentelemetry_config.rb`),
o mesmo mecanismo que o fork já usa desde a mod. 004:

```ruby
'OpenTelemetry::Instrumentation::ActionView' => { enabled: false },
```

Entra pelo mesmo portão das outras três, mas por motivo diferente, e isso está
comentado no código: ActionMailer, ActionPack e ActiveStorage estão ali porque
**quebram o boot** no Rails 7.1; ActionView quebra o **contexto**.

## Alternativas descartadas

- **Silenciar o `DetachError` no error handler**: some o ruído e o trace continua
  torto. Esconde o sintoma de um dado que se pretende usar para decidir coisas.
- **Desligar `AXIOM_TRACE_RAILS`**: resolve, mas joga fora toda a instrumentação
  de Rails junto — ActiveRecord, Faraday, Sidekiq, ActiveJob — para consertar uma
  única instrumentação.
- **Corrigir o gem**: o desbalanceamento é aresta conhecida do
  opentelemetry-ruby com contexto fiber-local; monkey-patch em gem de terceiro é
  dívida que reaparece a cada bump.

## O que se perde

O span de render de template e de parcial. `ActionPack`, o irmão de camada, já
estava desligado antes desta modificação, então a granularidade dentro da
requisição não muda na prática. Seguem instrumentados — 16 no total, conferido em
runtime — ActiveRecord, ActiveJob, ActiveSupport, Sidekiq, Faraday, Net::HTTP,
Redis, ConcurrentRuby, AwsSdk, entre outros.

## Comportamento no merge de upstream

Nulo. `lib/opentelemetry_config.rb` é arquivo exclusivo do fork (mod. 004); o
upstream não tem esse arquivo nem essa lista.

## Validação

Local, canal de API, com o **handler padrão do SDK** (sem o probe no caminho,
para o log ser o mesmo de produção):

| | antes | depois |
|---|---|---|
| `DetachError` no rails | 26 | **0** |
| `DetachError` no sidekiq | 5 | **0** |
| carga | 8 mensagens | 15 mensagens + 12 listagens |
| jobs processados pelo sidekiq | — | 53 |

Conferido também que a correção não foi "desligar tudo": 16 instrumentações
seguem instaladas e `ActionView` é a única nova ausente.

```bash
docker exec chatwoot-axiom-rails-1 bundle exec rails runner '
list = OpenTelemetry::Instrumentation.registry.instance_variable_get(:@instrumentation) || []
inst = list.map { |i| i.respond_to?(:instance) ? i.instance : i }
on = inst.select { |i| i.respond_to?(:installed?) && i.installed? }.map { |i| i.name.to_s }
puts "instaladas=#{on.size} action_view=#{on.grep(/ActionView/).any?}"
'
```

## Nota operacional: o 404 do dataset de traces

Enquanto isto era investigado, apareceu no mesmo log um erro **não relacionado**:

```
OpenTelemetry error: OTLP exporter received http.code=404 for uri='https://api.axiom.co/v1/traces'
OpenTelemetry error: Unable to export N spans
```

Causa: `AXIOM_TRACES_DATASET=chatwoot-traces` apontava para um dataset que **não
existia** na org do Axiom — todo batch de spans voltava 404 e era descartado. Não
é bug de código; o dataset foi criado (19/08/2026) e o erro cessou sem redeploy,
já que a variável de ambiente sempre esteve certa.

Fica o registro porque o sintoma engana: 404 é dataset inexistente, 401 é token
inválido. Para separar os dois sem mexer na aplicação:

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://api.axiom.co/v1/traces \
  -H "Authorization: Bearer $AXIOM_API_TOKEN" \
  -H "X-Axiom-Dataset: $AXIOM_TRACES_DATASET" \
  -H "Content-Type: application/json" -d '{"resourceSpans":[]}'
```

Corpo com `resourceSpans` vazio não ingere nada, então serve como teste de
configuração em produção.
