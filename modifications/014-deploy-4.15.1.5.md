# 014 — Deploy da 4.15.1.5

**Status:** operacional (não altera código)
**Imagem publicada:** `joaoftnunes/chatwoot:4.15.1.5-connectei` (e `latest`), `linux/amd64` + `linux/arm64`

---

## O que entra nesta versão

Primeira imagem com as modificações [011](011-dashboard-attendants.md),
[012](012-connectei-conversations-filter.md) e
[013](013-room-channel-inscricao-explicita.md) — os dois endpoints agregados do
painel Connectei e a inscrição explícita no `RoomChannel`.

As três são **aditivas**: nenhuma rota, tela ou comportamento existente do
Chatwoot muda. Uma instância nesta versão continua servindo o dashboard próprio
do Chatwoot exatamente como antes.

## Passo obrigatório: a migration de índices

A 012 traz `20260810120000_add_connectei_conversation_listing_indexes.rb`, que
cria dois índices em `conversations`. Ela é `disable_ddl_transaction!` com
`algorithm: :concurrently` — ou seja, **não trava a tabela**, e pode rodar com a
aplicação no ar.

```bash
docker compose run --rm rails bundle exec rails db:migrate
```

Dois pontos que costumam morder:

- `CREATE INDEX CONCURRENTLY` **não pode rodar dentro de transação**. Se o seu
  wrapper de deploy envolve a migration num `BEGIN`, ela falha. O
  `disable_ddl_transaction!` já cuida disso pelo Rails; o cuidado é com script
  externo.
- Se a migration for interrompida no meio, o Postgres deixa um índice
  **inválido** para trás. Ele não é usado e não quebra nada, mas também não
  ajuda. Verifique e, se houver, derrube e rode de novo:
  ```sql
  SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
  ```

Em conta grande a criação leva alguns minutos por índice. Enquanto ela não
roda, os endpoints novos **funcionam**, só que sem o índice de
`last_activity_at` — que é justamente o gargalo que a 012 existe para resolver.

## Como confirmar que a instância está com o fork

```bash
# versão
curl -s https://<host>/api/v1/accounts/<id>/... -H "api_access_token: <token>"

# o teste que importa: a rota nova responde (≠ 404)
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "api_access_token: <token>" \
  "https://<host>/api/v1/accounts/<id>/dashboard-attendants?inbox_ids[]=<inbox>"
```

`200` ⇒ o ERP passa a usar o caminho escalável sozinho, sem reiniciar nada.
`404` ⇒ a imagem antiga ainda está no ar; o ERP segue no caminho legado e o
painel continua funcionando (é exatamente o fallback que a 012 documenta).

Note os **colchetes** em `inbox_ids[]`. Sem eles o Rails fica só com o último
valor — foi a armadilha que o E2E do ERP pegou.

## Rollback

Voltar a imagem para `4.15.1.4-connectei` basta: o ERP detecta o 404 e cai no
caminho legado em até 5 minutos, sem intervenção. Os índices podem ficar — são
inertes para o código antigo, e derrubá-los só custa recriar depois.
