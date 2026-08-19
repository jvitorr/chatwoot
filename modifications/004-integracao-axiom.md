# 004 — Integração com Axiom (exceções, logs e traces)

**Status:** ativo
**Commit:** `ca93c0053`
**Arquivos do core alterados:** `lib/chatwoot_exception_tracker.rb` (uma linha), `lib/opentelemetry_config.rb` (refatoração), `Gemfile` + `Gemfile.lock`, `.env.example`, `package.json` + `config/app.yml` (bump de versão para `4.15.1.1`)
**Arquivos novos (aditivos):** `lib/axiom.rb`, `lib/axiom/`, `lib/axiom_capture_exceptions.rb`, `app/jobs/axiom/ingest_job.rb`, `config/initializers/axiom.rb`, `spec/support/axiom_env.rb`, `docker-compose.axiom.yaml`
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.1-connectei` (e `latest`), `linux/amd64`

---

## O problema

A observabilidade do Chatwoot é fragmentada e cada peça vai para um lugar diferente:

- **Erros** → Sentry, com um único ponto de entrada (`ChatwootExceptionTracker`, ~45 call sites).
- **Logs** → texto puro no stdout. Sem shipper: morrem no stdout do container.
- **Traces** → `lib/opentelemetry_config.rb` existe, mas é *hardcoded para Langfuse* e cobre só spans de LLM/Captain.

O objetivo foi ter um destino único — a [Axiom](https://axiom.co) — para os três, seguindo o padrão que o próprio Chatwoot já usa para APM: gate por variável de ambiente, opt-in, e **completamente inerte quando desligado**. Sem `AXIOM_API_TOKEN`, nenhum arquivo novo é sequer carregado.

Sentry e Axiom coexistem: cada um tem seu gate independente e os dois podem rodar juntos.

## O que a mudança faz

### Exceções

Três caminhos de captura, para chegar perto do que o Sentry cobre:

1. **Chamadas explícitas** — uma linha em `ChatwootExceptionTracker#capture_exception` cobre os ~45 call sites existentes.
2. **`AxiomCaptureExceptions`** (Rack) — toda exceção não tratada em qualquer request.
3. **Error handler do Sidekiq** — toda falha de job.

O envio é assíncrono via `Axiom::IngestJob` (fila `low`). O evento leva stacktrace estruturado em frames, contexto de request (URL, params filtrados, IP, user agent, request_id), contexto de account/user, contexto do job e um `fingerprint` para agrupar ocorrências do mesmo defeito.

### Logs

`Axiom::LogDevice` bufferiza e `Axiom::Logger` emite Hash estruturado. Anexado via `Rails.logger.broadcast_to`, sem tocar no logger de stdout existente. Tem **switch próprio** (`ENABLE_AXIOM_LOGS`), separado do token: dá para adotar exceções e traces primeiro e ligar os logs depois.

Três propriedades do `LogDevice` que não são detalhe de implementação — cada uma existe para evitar um problema concreto em produção:

**`#write` nunca faz I/O.** Ele roda em threads de request e de job. Uma versão anterior entregava de forma síncrona ao encher o buffer, o que colocava a latência (e as quedas) da Axiom dentro do caminho da requisição: até 5s de timeout a cada 100 linhas. Hoje o `write` só enfileira e sinaliza a thread de background, que faz todo o envio. Medido com o endpoint em buraco negro: 500 writes em **0,88 ms**.

**Buffer com teto (`MAX_BUFFER`).** Se a Axiom ficar fora, o buffer para de crescer e descarta os eventos mais antigos. O descarte é silencioso de propósito — ver o item seguinte.

**Guarda de reentrância.** O `IngestClient` registra falhas com `Rails.logger.warn`. Como esse logger é justamente o que está sendo transmitido para a Axiom, uma falha de envio geraria um evento que volta para o buffer, que falha de novo — realimentação. A thread de entrega marca `Thread.current[:axiom_delivering]` e o `write` ignora qualquer evento emitido nesse intervalo.

> Ao mexer aqui, mantenha o `write` livre de I/O. "Simplificar" entregando direto no `write` recria exatamente o problema de latência que motivou este desenho, e ele não aparece em teste — só sob carga, ou quando a Axiom degrada.

### Traces

`OpentelemetryConfig` deixou de ser single-provider. Axiom tem precedência quando `ENABLE_AXIOM_TRACES` está ligado; senão cai no caminho Langfuse, **inalterado**.

---

## Ordem de adoção em produção

Os três recursos têm switches independentes justamente para não obrigar a ligar tudo de uma vez. Cada etapa é verificável antes da seguinte:

| Etapa | Variáveis | O que passa a acontecer |
|---|---|---|
| 1. Exceções | `AXIOM_API_TOKEN`, `AXIOM_DATASET` | Exceções não tratadas, falhas de job e os call sites do `ChatwootExceptionTracker` |
| 2. Traces | `+ ENABLE_AXIOM_TRACES` (e `AXIOM_TRACE_RAILS` para além dos spans de LLM) | Spans exportados via OTLP, com sampling de 0.1 |
| 3. Logs | `+ ENABLE_AXIOM_LOGS` (e `AXIOM_LOG_LEVEL`) | Logs da aplicação transmitidos junto do stdout |

Só a etapa 1 depende do token; as outras duas exigem a flag correspondente. Remover a variável desliga a etapa sem tocar nas demais.

---

## As três armadilhas que custaram caro

Estas não são detalhes de estilo. Cada uma foi descoberta com o sistema rodando, depois de uma versão aparentemente correta não funcionar.

### 1. O middleware precisa ficar ABAIXO do `DebugExceptions`

A primeira versão inseriu o middleware após `ActionDispatch::ShowExceptions`, espelhando o `Sentry::Rails::CaptureExceptions`. **Não capturou nada.**

O `ActionDispatch::DebugExceptions` rescata a exceção e renderiza a página de erro **sem re-levantar**. Qualquer middleware acima dele nunca vê a exceção. É exatamente por isso que o sentry-rails tem *dois* middlewares: o `RescuedExceptionInterceptor` fica abaixo do `DebugExceptions` justamente para interceptar o raise cru.

```ruby
Rails.application.config.app_middleware.insert_after(
  ActionDispatch::DebugExceptions, AxiomCaptureExceptions
)
```

> Trocar `DebugExceptions` por `ShowExceptions` "para alinhar com o Sentry" desliga a captura automática **em silêncio** — nenhum erro aparece, os eventos só param de chegar.

### 2. Nada sob `lib/` é autoloadable durante os initializers

Neste app, no momento em que `config/initializers/*` roda, o Zeitwerk ainda tem **zero diretórios registrados** — nem `lib/`, nem `app/`. E o stack de middleware é construído antes disso.

Por isso `AxiomCaptureExceptions`:

- vive em `lib/axiom_capture_exceptions.rb`, **fora** do namespace `Axiom`;
- é carregado com `require` explícito no initializer;
- é excluído do Zeitwerk com `Rails.autoloaders.main.ignore`.

Ele só referencia `Axiom::Reporter` em *tempo de request*, quando o autoload já funciona.

> Mover essa classe para `lib/axiom/capture_exceptions.rb` "por consistência de namespace" quebra o boot com `uninitialized constant Axiom`. O `require` explícito e o `ignore` andam juntos: sem o `ignore`, o Zeitwerk reclama do arquivo já carregado.

O gate do initializer lê `ENV['AXIOM_API_TOKEN']` direto, e não `Axiom.enabled?`, pelo mesmo motivo.

### 3. O path de ingest documentado pela Axiom está errado

O [guia oficial da Axiom para Rails](https://axiom.co/docs/guides/send-logs-from-ruby-on-rails) documenta `POST /v1/ingest/<dataset>`. A API real responde `404 {"code":404,"message":"path /v1/ingest/chatwoot was not found"}`.

O correto é:

```
POST https://api.axiom.co/v1/datasets/<dataset>/ingest
```

Traces usam `POST /v1/traces` com header `X-AXIOM-DATASET`, e esse sim bate com a documentação.

> Um 404 no ingest também acontece quando **o dataset não existe** na conta. A mensagem distingue os dois casos: `"path ... not found"` é URL errada, `"dataset not found"` é dataset inexistente.

---

## Outras decisões que não são óbvias no código

**`Axiom::Reporter` existe para não duplicar no Sentry.** Se o middleware Rack chamasse `ChatwootExceptionTracker`, o Sentry receberia cada exceção duas vezes — uma pelo middleware dele, outra pelo nosso. O `Reporter` é o caminho Axiom-only; o `ChatwootExceptionTracker` continua sendo o caminho que alimenta os dois.

**O `Axiom::IngestJob` é pulado no handler do Sidekiq.** Reportar a falha de um IngestJob enfileiraria outro IngestJob — laço de realimentação.

**Sampling de traces tem default duplo.** `AXIOM_TRACES_SAMPLE_RATE` cai em `0.1` com `AXIOM_TRACE_RAILS` ligado (auto-instrumentação emite um span por query — foram 5057 spans em poucos minutos de desenvolvimento) e `1.0` sem ele, quando só spans de LLM fluem e o volume é baixo. Implementado via `OTEL_TRACES_SAMPLER`/`_ARG` com `||=`, então um valor definido pelo operador sempre vence.

**`UNSUPPORTED_INSTRUMENTATIONS` não é preciosismo.** As instrumentações de `ActionMailer`, `ActionPack` e `ActiveStorage` do `opentelemetry-instrumentation-all` **levantam durante o install** no Rails 7.1 e enchem o boot de stacktrace. Ficam desligadas. Vale revisitar num upgrade de Rails.

`ActionView` entrou na mesma lista depois, por outro motivo: ela não quebra o boot, quebra o **contexto** — `attach`/`detach` desbalanceados a cada render de parcial, poluindo o log com `DetachError` e emparentando span errado. Diagnóstico e medição na modificação [020](020-detach-error-action-view.md).

**`spec/support/axiom_env.rb` neutraliza as `AXIOM_*` na suíte inteira.** O Dotenv carrega `.env` em todos os ambientes, inclusive test. Sem isso, qualquer dev com Axiom configurado localmente vê a suíte ficar vermelha. Specs que precisam da integração ligada optam por ela via `with_modified_env`.

---

## O que verificar depois de um merge de upstream

### `lib/opentelemetry_config.rb` — **risco alto**

É o único arquivo do core que foi *refatorado*, não apenas anotado. Se o upstream mexer nele, o merge vai conflitar de verdade.

1. `resolve_provider` precisa continuar dando **precedência ao Axiom**, com fallback para o Langfuse e no-op quando nenhum está configurado.
2. O caminho Langfuse (`langfuse_exporter_config`) deve permanecer **byte a byte equivalente** ao do upstream — endpoint `/api/public/otel/v1/traces`, auth Basic, header `x-langfuse-ingestion-version`.
3. `install_sampler` só pode agir quando o provider é `:axiom`. O Langfuse não deve ganhar sampling.
4. Rodar `spec/lib/opentelemetry_config_spec.rb` — tem um exemplo dedicado a garantir que o caminho Langfuse não regrediu.

### `lib/chatwoot_exception_tracker.rb` — risco baixo

Uma linha isolada (`Axiom::Reporter.report(...)`) ao lado da linha do Sentry. Reconcilia bem. Confirme só que ela sobreviveu.

### `config/initializers/axiom.rb` — aditivo, mas frágil por natureza

Não conflita (arquivo novo), mas depende de detalhes internos do Rails: a posição do `DebugExceptions` no stack e o momento em que o autoloader é configurado. **Num upgrade de Rails, revalide as armadilhas 1 e 2** — as duas podem quebrar em silêncio.

### Verificação de ponta a ponta

Com `AXIOM_API_TOKEN` configurado:

```bash
# middleware presente e na posição certa (deve vir logo após DebugExceptions)
bundle exec rails runner "mw=Rails.application.middleware.map(&:name); \
  puts mw.index('AxiomCaptureExceptions').to_i - mw.index('ActionDispatch::DebugExceptions').to_i"  # => 1

# exceção explícita
bundle exec rails runner "ChatwootExceptionTracker.new(StandardError.new('smoke')).capture_exception"
```

E confirmar no explorer da Axiom:

```
['chatwoot'] | where isnotnull(service) | order by _time desc
```

O gate desligado também é parte do contrato: rodar sem nenhuma `AXIOM_*` e confirmar **zero requisições de rede**. A integração precisa ser inerte por padrão para todo self-hosted.
