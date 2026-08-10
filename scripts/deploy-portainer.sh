#!/usr/bin/env bash
#
# Atualiza o Chatwoot (fork Connectei) num Swarm gerenciado por Portainer.
#
# Pergunta a URL do Portainer, o token de API e a versão publicada no Docker
# Hub; descobre sozinho o ambiente e os serviços; roda a migration UMA vez num
# serviço efêmero; e só então atualiza os serviços, um a um.
#
# Uso:
#   ./scripts/deploy-portainer.sh                    # interativo
#   ./scripts/deploy-portainer.sh --dry-run          # mostra o plano, não muda nada
#   ./scripts/deploy-portainer.sh --skip-migration   # só troca a imagem
#   ./scripts/deploy-portainer.sh --yes              # não pede confirmação
#
# Também aceita, para uso não interativo (CI):
#   PORTAINER_URL=... PORTAINER_TOKEN=... VERSION=4.15.1.5-connectei ./scripts/deploy-portainer.sh --yes
#
# ---------------------------------------------------------------------------
# Por que o script faz o que faz — cada passo aqui existe por um motivo que já
# mordeu alguém:
#
# 1. Fixa a imagem por DIGEST, não pela tag. Uma tag reescrita (o caso de
#    `latest`) não faz o Swarm puxar nada: ele reusa a imagem que o nó já tem,
#    e o deploy "dá certo" sem trocar uma linha de código.
# 2. Roda a migration ANTES da troca de imagem. Os índices são inertes para o
#    código antigo, então essa ordem nunca tem janela ruim — a inversa tem.
# 3. A migration vai num serviço efêmero (RestartPolicy: none), não num
#    `exec`. Um exec morre junto se o container for reciclado no meio, e
#    rodá-la em cada serviço a executaria três vezes.
# 4. O update do Swarm exige o `version` index atual do serviço. Sem ele a API
#    responde 409 — é a causa nº 1 de "o script falhou e não sei por quê".
# 5. Incrementa `ForceUpdate` para garantir a recriação das tarefas.
# 6. Atualiza um serviço de cada vez, esperando convergir. Como cada um tem 1
#    réplica, atualizar tudo junto derruba o chat inteiro por alguns segundos.
# 7. Atualiza também a DEFINIÇÃO DO STACK, quando o serviço vem de um. Mexer só
#    no serviço deixa o compose guardado no Portainer apontando para a imagem
#    antiga: tudo parece certo, até alguém clicar em "Update the stack" e o
#    ambiente voltar sozinho para a versão anterior. Esse desencontro é
#    silencioso e só aparece semanas depois.
# ---------------------------------------------------------------------------
set -euo pipefail

IMAGE_REPO="${IMAGE_REPO:-joaoftnunes/chatwoot}"
SERVICE_PREFIX="${SERVICE_PREFIX:-chatwoot}"
MIGRATION_SERVICE="connectei_migrate_$$"
# Tetos de espera em SEGUNDOS. O padrão da migration é alto de propósito: em
# produção os índices sobem com CONCURRENTLY sobre uma tabela grande, e o custo
# de esperar demais é zero perto do de desistir cedo.
MIGRATION_TIMEOUT="${MIGRATION_TIMEOUT:-3600}"
SERVICE_TIMEOUT="${SERVICE_TIMEOUT:-600}"
DRY_RUN=false
SKIP_MIGRATION=false
ASSUME_YES=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=true ;;
    --skip-migration) SKIP_MIGRATION=true ;;
    --yes|-y)         ASSUME_YES=true ;;
    --help|-h)        sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "opção desconhecida: $arg" >&2; exit 2 ;;
  esac
done

vermelho() { printf '\033[31m%s\033[0m\n' "$*"; }
verde()    { printf '\033[32m%s\033[0m\n' "$*"; }
amarelo()  { printf '\033[33m%s\033[0m\n' "$*"; }
titulo()   { printf '\n\033[1m%s\033[0m\n' "$*"; }

for dep in curl python3; do
  command -v "$dep" >/dev/null || { vermelho "faltando: $dep"; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --------------------------------------------------------------------------
# Entradas
# --------------------------------------------------------------------------
titulo "Conexão"

if [ -z "${PORTAINER_URL:-}" ]; then
  read -rp "URL do Portainer (ex.: https://portainer.seudominio.com): " PORTAINER_URL
fi
BASE="${PORTAINER_URL%/}"

if [ -z "${PORTAINER_TOKEN:-}" ]; then
  # -s: o token não vai para a tela nem para o histórico
  read -rsp "Token de API (My account → Access tokens): " PORTAINER_TOKEN
  echo
fi

if [ -z "${VERSION:-}" ]; then
  read -rp "Versão no Docker Hub (ex.: 4.15.1.5-connectei): " VERSION
fi

[ -n "$BASE" ] && [ -n "$PORTAINER_TOKEN" ] && [ -n "$VERSION" ] || {
  vermelho "URL, token e versão são obrigatórios"; exit 1;
}

api() { # api <metodo> <caminho> [arquivo-json]
  local metodo="$1" caminho="$2" corpo="${3:-}"
  if [ -n "$corpo" ]; then
    curl -sS -m 180 -X "$metodo" -H "X-API-Key: $PORTAINER_TOKEN" \
      -H 'Content-Type: application/json' --data-binary "@$corpo" "$BASE/api$caminho"
  else
    curl -sS -m 180 -X "$metodo" -H "X-API-Key: $PORTAINER_TOKEN" "$BASE/api$caminho"
  fi
}

# --------------------------------------------------------------------------
# Digest da versão (passo 1 do cabeçalho)
# --------------------------------------------------------------------------
titulo "Imagem"

DIGEST_JSON="$TMP/tag.json"
curl -sS -m 60 "https://hub.docker.com/v2/repositories/$IMAGE_REPO/tags/$VERSION" > "$DIGEST_JSON" || true

DIGEST="$(python3 - "$DIGEST_JSON" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print(''); sys.exit(0)
print(d.get('digest') or '')
PY
)"

if [ -z "$DIGEST" ]; then
  vermelho "não achei a tag '$VERSION' em $IMAGE_REPO no Docker Hub"
  echo "  confira o nome da tag (ex.: 4.15.1.5-connectei) ou defina IMAGE_REPO"
  exit 1
fi

PLATAFORMAS="$(python3 - "$DIGEST_JSON" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
archs=sorted({f"{i.get('os')}/{i.get('architecture')}" for i in d.get('images',[]) if i.get('architecture') not in (None,'unknown')})
print(', '.join(archs))
PY
)"

IMAGE_REF="$IMAGE_REPO:$VERSION@$DIGEST"
echo "  $IMAGE_REPO:$VERSION"
echo "  digest: $DIGEST"
echo "  plataformas: $PLATAFORMAS"

# --------------------------------------------------------------------------
# Ambiente
# --------------------------------------------------------------------------
titulo "Ambiente"

api GET /endpoints > "$TMP/endpoints.json"
python3 - "$TMP/endpoints.json" <<'PY' || { echo; exit 1; }
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print('  resposta inválida do Portainer — URL ou token errados?'); sys.exit(1)
if isinstance(d,dict):
    print('  erro:', d.get('message') or d); sys.exit(1)
for e in d:
    snap=(e.get('Snapshots') or [{}])[0]
    print(f"  id={e['Id']}  {e.get('Name')}  swarm={snap.get('Swarm')}  serviços={snap.get('ServiceCount')}")
PY

ENDPOINT_COUNT="$(python3 -c "import json,sys;print(len(json.load(open('$TMP/endpoints.json'))))")"
if [ "$ENDPOINT_COUNT" = "1" ]; then
  ENDPOINT_ID="$(python3 -c "import json;print(json.load(open('$TMP/endpoints.json'))[0]['Id'])")"
  echo "  → usando o único ambiente: $ENDPOINT_ID"
else
  read -rp "  id do ambiente: " ENDPOINT_ID
fi

# --------------------------------------------------------------------------
# Serviços
# --------------------------------------------------------------------------
titulo "Serviços a atualizar"

api GET "/endpoints/$ENDPOINT_ID/docker/services" > "$TMP/services.json"

python3 - "$TMP/services.json" "$SERVICE_PREFIX" > "$TMP/alvo.txt" <<'PY'
import json,sys
services=json.load(open(sys.argv[1])); prefixo=sys.argv[2]
for s in sorted(services, key=lambda x: x['Spec']['Name']):
    nome=s['Spec']['Name']
    if not nome.startswith(prefixo): continue
    img=s['Spec']['TaskTemplate']['ContainerSpec'].get('Image','')
    print(f"{nome}\t{s['Version']['Index']}\t{img}")
PY

if [ ! -s "$TMP/alvo.txt" ]; then
  vermelho "nenhum serviço começando com '$SERVICE_PREFIX' neste ambiente"
  echo "  ajuste com SERVICE_PREFIX=... se o nome for outro"
  exit 1
fi

while IFS=$'\t' read -r nome versao imagem; do
  printf '  %-40s v=%-8s %s\n' "$nome" "$versao" "${imagem%%@*}"
done < "$TMP/alvo.txt"

# O serviço que serve de molde para a migration (env, rede, volumes iguais).
MOLDE="$(awk -F'\t' 'NR==1{print $1}' "$TMP/alvo.txt")"
for candidato in $(cut -f1 "$TMP/alvo.txt"); do
  case "$candidato" in *api*|*rails*|*web*) MOLDE="$candidato"; break ;; esac
done

# ---------------------------------------------------------------------------
# Stacks que contêm esses serviços (passo 7 do cabeçalho)
# ---------------------------------------------------------------------------
api GET /stacks > "$TMP/stacks.json" 2>/dev/null || echo '[]' > "$TMP/stacks.json"

python3 - "$TMP/stacks.json" "$TMP/alvo.txt" "$ENDPOINT_ID" > "$TMP/stacks-alvo.txt" <<'PY'
import json,sys
try:
    stacks=json.load(open(sys.argv[1]))
except Exception:
    stacks=[]
if not isinstance(stacks,list): stacks=[]
servicos=[l.split('\t')[0] for l in open(sys.argv[2]) if l.strip()]
endpoint=int(sys.argv[3])
for s in stacks:
    if s.get('EndpointId') != endpoint: continue
    nome=s.get('Name','')
    # serviço de stack no Swarm chama-se "<stack>_<serviço>"
    if any(sv.startswith(nome + '_') for sv in servicos):
        print(f"{s['Id']}\t{nome}")
PY

titulo "Plano"
$SKIP_MIGRATION && echo "  1. migration: PULADA (--skip-migration)" \
                || echo "  1. migration num serviço efêmero, molde: $MOLDE"
echo "  2. atualizar os serviços acima para $VERSION (um a um)"
if [ -s "$TMP/stacks-alvo.txt" ]; then
  echo "  3. atualizar a definição dos stacks (senão um redeploy reverte tudo):"
  while IFS=$'\t' read -r sid snome; do echo "       stack $sid — $snome"; done < "$TMP/stacks-alvo.txt"
else
  amarelo "  3. nenhum stack casou com estes serviços — só os serviços serão tocados"
  echo "       (se eles vêm de um stack, o compose guardado ficará defasado)"
fi
echo "  4. conferir convergência"

if $DRY_RUN; then
  amarelo $'\ndry-run: nada foi alterado'
  exit 0
fi

if ! $ASSUME_YES; then
  echo
  read -rp "confirma? (digite: sim) " RESP
  [ "$RESP" = "sim" ] || { amarelo "cancelado"; exit 0; }
fi

# Estado de antes — é isto que permite o rollback exato (imagem e digest que
# cada serviço tinha). Só grava depois do aceite: dry-run não suja o diretório.
ESTADO_ANTES="./portainer-estado-antes-$(date +%Y%m%d-%H%M%S).tsv"
cp "$TMP/alvo.txt" "$ESTADO_ANTES" && echo "  estado de antes salvo em $ESTADO_ANTES"

# --------------------------------------------------------------------------
# 1. Migration (passos 2 e 3 do cabeçalho)
# --------------------------------------------------------------------------
if ! $SKIP_MIGRATION; then
  titulo "Migration"

  api GET "/endpoints/$ENDPOINT_ID/docker/services/$MOLDE" > "$TMP/molde.json"

  python3 - "$TMP/molde.json" "$IMAGE_REF" "$MIGRATION_SERVICE" "$TMP/migrate.json" <<'PY'
import json,sys
molde=json.load(open(sys.argv[1])); imagem=sys.argv[2]; nome=sys.argv[3]; saida=sys.argv[4]
tt=json.loads(json.dumps(molde['Spec']['TaskTemplate']))
cs=tt['ContainerSpec']
cs['Image']=imagem
cs['Command']=None
cs['Args']=['bundle','exec','rails','db:migrate']
tt['RestartPolicy']={'Condition':'none'}   # roda uma vez e para
tt.pop('ForceUpdate',None)
json.dump({'Name':nome,'TaskTemplate':tt,'Mode':{'Replicated':{'Replicas':1}},
           'Labels':{'connectei.purpose':'migration'}}, open(saida,'w'))
PY

  api POST "/endpoints/$ENDPOINT_ID/docker/services/create" "$TMP/migrate.json" > "$TMP/criado.json"
  python3 -c "
import json;d=json.load(open('$TMP/criado.json'))
print('  serviço criado:', d.get('ID') or d)
" || true

  echo "  aguardando… (teto: ${MIGRATION_TIMEOUT}s)"
  ESTADO=""
  INICIO=$SECONDS
  while [ $((SECONDS - INICIO)) -lt "$MIGRATION_TIMEOUT" ]; do
    api GET "/endpoints/$ENDPOINT_ID/docker/tasks?filters=%7B%22service%22%3A%5B%22$MIGRATION_SERVICE%22%5D%7D" > "$TMP/tasks.json"
    ESTADO="$(python3 -c "
import json
t=json.load(open('$TMP/tasks.json'))
print(sorted(t,key=lambda x:x.get('CreatedAt',''))[-1]['Status']['State'] if t else 'pendente')
")"
    case "$ESTADO" in complete|failed|rejected) break ;; esac
    sleep 5
  done

  curl -sS -m 120 -H "X-API-Key: $PORTAINER_TOKEN" \
    "$BASE/api/endpoints/$ENDPOINT_ID/docker/services/$MIGRATION_SERVICE/logs?stdout=1&stderr=1&tail=120" \
    -o "$TMP/migrate.log" || true

  python3 - "$TMP/migrate.log" <<'PY'
import re,sys
try: txt=open(sys.argv[1],'rb').read().decode('utf-8','replace')
except Exception: sys.exit(0)
txt=re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]','',txt)
for l in txt.splitlines():
    if re.search(r'migrat|index|error|ERROR|rake abort', l, re.I):
        print('   ', l.strip())
PY

  # Só remove o serviço se a task chegou a um estado TERMINAL. Apagar um
  # serviço ainda rodando mata a task, e um CREATE INDEX CONCURRENTLY morto no
  # meio deixa o índice INVÁLIDO: o Postgres passa a mantê-lo em toda escrita e
  # nunca o usa em leitura. Em banco pequeno isso nunca acontece — foi por isso
  # que o teto de 5 minutos original passou despercebido no ambiente de teste.
  case "$ESTADO" in
    complete|failed|rejected)
      api DELETE "/endpoints/$ENDPOINT_ID/docker/services/$MIGRATION_SERVICE" >/dev/null || true
      ;;
    *)
      vermelho "  migration ainda em '$ESTADO' após ${MIGRATION_TIMEOUT}s — serviço NÃO removido"
      echo "  Provavelmente é só um índice grande demorando. NÃO apague o serviço"
      echo "  '$MIGRATION_SERVICE' enquanto ele roda: isso abortaria o índice pela"
      echo "  metade. Acompanhe pelo log dele e remova quando terminar."
      echo
      echo "  Índice inválido, se algo morrer no meio:"
      echo "    SELECT indexrelid::regclass, indisvalid FROM pg_index WHERE NOT indisvalid;"
      echo
      echo "  Os serviços NÃO foram atualizados. Rode de novo depois — a migration"
      echo "  é idempotente (if_not_exists)."
      exit 1
      ;;
  esac

  if [ "$ESTADO" != "complete" ]; then
    vermelho "  migration terminou como '$ESTADO' — os serviços NÃO foram atualizados"
    echo "  o log acima diz o motivo. Nada foi trocado; é seguro corrigir e rodar de novo."
    exit 1
  fi
  verde "  migration concluída"
fi

# --------------------------------------------------------------------------
# 2. Atualização dos serviços (passos 4, 5 e 6 do cabeçalho)
# --------------------------------------------------------------------------
titulo "Atualizando serviços"

while IFS=$'\t' read -r nome _ _; do
  api GET "/endpoints/$ENDPOINT_ID/docker/services/$nome" > "$TMP/svc.json"
  VERSAO="$(python3 -c "import json;print(json.load(open('$TMP/svc.json'))['Version']['Index'])")"

  python3 - "$TMP/svc.json" "$IMAGE_REF" "$TMP/upd.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); imagem=sys.argv[2]; saida=sys.argv[3]
spec=s['Spec']
spec['TaskTemplate']['ContainerSpec']['Image']=imagem
# ForceUpdate garante a recriação mesmo se o digest fosse o mesmo
spec['TaskTemplate']['ForceUpdate']=spec['TaskTemplate'].get('ForceUpdate',0)+1
json.dump(spec, open(saida,'w'))
PY

  HTTP="$(curl -sS -o "$TMP/resp.json" -w '%{http_code}' -m 180 -X POST \
    -H "X-API-Key: $PORTAINER_TOKEN" -H 'Content-Type: application/json' \
    --data-binary "@$TMP/upd.json" \
    "$BASE/api/endpoints/$ENDPOINT_ID/docker/services/$nome/update?version=$VERSAO")"

  if [ "$HTTP" != "200" ]; then
    vermelho "  $nome: HTTP $HTTP"
    head -c 400 "$TMP/resp.json"; echo
    echo "  409 aqui costuma ser corrida de version index: rode o script de novo."
    exit 1
  fi

  printf '  %-40s ' "$nome"
  INICIO=$SECONDS
  while [ $((SECONDS - INICIO)) -lt "$SERVICE_TIMEOUT" ]; do
    api GET "/endpoints/$ENDPOINT_ID/docker/services/$nome" > "$TMP/svc.json"
    ESTADO="$(python3 -c "
import json
print((json.load(open('$TMP/svc.json')).get('UpdateStatus') or {}).get('State','-'))
")"
    [ "$ESTADO" = "updating" ] || break
    sleep 4
  done
  verde "$ESTADO"
done < "$TMP/alvo.txt"

# --------------------------------------------------------------------------
# 3. Definição dos stacks (passo 7 do cabeçalho)
# --------------------------------------------------------------------------
if [ -s "$TMP/stacks-alvo.txt" ]; then
  titulo "Atualizando a definição dos stacks"

  while IFS=$'\t' read -r sid snome; do
    api GET "/stacks/$sid" > "$TMP/stack-meta.json"
    api GET "/stacks/$sid/file" > "$TMP/stack-file.json"

    if ! python3 - "$TMP/stack-file.json" "$TMP/stack-meta.json" "$IMAGE_REPO" "$VERSION" "$TMP/stack-put.json" <<'PY'
import json,re,sys
arq=json.load(open(sys.argv[1])); meta=json.load(open(sys.argv[2]))
repo=sys.argv[3]; versao=sys.argv[4]; saida=sys.argv[5]
conteudo=arq.get('StackFileContent','')
# troca qualquer tag/digest do nosso repositório pela versão nova
refs=re.findall(rf'{re.escape(repo)}:[^\s"\']+', conteudo)
if not refs:
    raise SystemExit(4)   # o compose não fala do nosso repositório
novo=re.sub(rf'{re.escape(repo)}:[^\s"\']+', f'{repo}:{versao}', conteudo)
if novo == conteudo:
    raise SystemExit(3)   # nada a trocar — o stack já está na versão
# Env PRECISA ser preservado: um PUT sem ele apaga as variáveis do stack.
json.dump({'StackFileContent': novo, 'Env': meta.get('Env') or [],
           'Prune': False, 'PullImage': True}, open(saida,'w'))
PY
    then
      RC=0
    else
      RC=$?
    fi

    # Distinguir os dois motivos importa: "já está na versão" é sucesso, mas
    # "o compose não cita o repositório" quer dizer que este stack sobe a imagem
    # de outro lugar — e tratar isso como sucesso esconde exatamente o
    # desencontro que o passo 7 existe para evitar.
    case "$RC" in
      0) ;;
      3) echo "  $snome: já estava em $VERSION"; continue ;;
      4) amarelo "  $snome: o compose não referencia $IMAGE_REPO — nada a trocar"
         echo "       confira à mão de onde este stack tira a imagem"
         continue ;;
      *) vermelho "  $snome: falha ao preparar a atualização (rc=$RC)"; continue ;;
    esac

    HTTP="$(curl -sS -o "$TMP/resp.json" -w '%{http_code}' -m 600 -X PUT \
      -H "X-API-Key: $PORTAINER_TOKEN" -H 'Content-Type: application/json' \
      --data-binary "@$TMP/stack-put.json" \
      "$BASE/api/stacks/$sid?endpointId=$ENDPOINT_ID")"

    if [ "$HTTP" = "200" ]; then
      verde "  $snome: definição atualizada"
    else
      vermelho "  $snome: HTTP $HTTP"
      head -c 400 "$TMP/resp.json"; echo
      echo "  os SERVIÇOS já estão na versão nova; só a definição ficou para trás."
      echo "  corrija o compose deste stack pela UI para não reverter num redeploy."
    fi
  done < "$TMP/stacks-alvo.txt"
fi

# --------------------------------------------------------------------------
# 4. Conferência
# --------------------------------------------------------------------------
titulo "Conferência"

api GET "/endpoints/$ENDPOINT_ID/docker/services" > "$TMP/depois.json"
python3 - "$TMP/depois.json" "$SERVICE_PREFIX" "$VERSION" <<'PY'
import json,sys
services=json.load(open(sys.argv[1])); prefixo=sys.argv[2]; versao=sys.argv[3]
falta=[]
for s in sorted(services, key=lambda x: x['Spec']['Name']):
    nome=s['Spec']['Name']
    if not nome.startswith(prefixo): continue
    img=s['Spec']['TaskTemplate']['ContainerSpec'].get('Image','')
    tag=img.split('@')[0].split(':')[-1]
    ok = tag == versao
    print(f"  {'✔' if ok else '✘'} {nome:<40} {tag}")
    if not ok: falta.append(nome)
sys.exit(1 if falta else 0)
PY

# A definição do stack é metade da verdade: serviço novo + compose velho passa
# despercebido até o próximo redeploy reverter tudo.
if [ -s "$TMP/stacks-alvo.txt" ]; then
  while IFS=$'\t' read -r sid snome; do
    api GET "/stacks/$sid/file" > "$TMP/conf-file.json"
    python3 - "$TMP/conf-file.json" "$IMAGE_REPO" "$VERSION" "$snome" <<'PY'
import json,re,sys
f=json.load(open(sys.argv[1])).get('StackFileContent','')
repo, versao, nome = sys.argv[2], sys.argv[3], sys.argv[4]
refs=re.findall(rf'{re.escape(repo)}:[^\s"\']+', f)
ok = all(r.split('@')[0] == f'{repo}:{versao}' for r in refs) and refs
print(f"  {'✔' if ok else '✘'} stack {nome:<34} {', '.join(sorted(set(refs))) or 'sem referência ao repo'}")
PY
  done < "$TMP/stacks-alvo.txt"
fi

# O "✔" acima le o Spec, ou seja: o Swarm ACEITOU a imagem nova. Nao e o
# mesmo que ela estar no ar. Em teste a diferenca some (pull instantaneo, 1
# replica); em producao a imagem e maior e o pull demora, entao sem olhar a task
# o script diria "pronto" com os containers ainda subindo - ou reiniciando em
# laco.
titulo "Tasks em execucao"

api GET "/endpoints/$ENDPOINT_ID/docker/tasks" > "$TMP/tasks-fim.json"
python3 - "$TMP/depois.json" "$TMP/tasks-fim.json" "$SERVICE_PREFIX" "$DIGEST" <<'PYTASK'
import json,sys
services=json.load(open(sys.argv[1])); tasks=json.load(open(sys.argv[2]))
prefixo=sys.argv[3]; digest=sys.argv[4]
nomes={s['ID']: s['Spec']['Name'] for s in services if s['Spec']['Name'].startswith(prefixo)}
pendentes=[]
for sid, nome in sorted(nomes.items(), key=lambda kv: kv[1]):
    minhas=[t for t in tasks if t.get('ServiceID')==sid and t.get('DesiredState')=='running']
    na_nova=[t for t in minhas
             if t.get('Status',{}).get('State')=='running'
             and digest in (t.get('Spec',{}).get('ContainerSpec',{}).get('Image') or '')]
    estados=sorted({t.get('Status',{}).get('State','?') for t in minhas}) or ['sem task']
    marca='\u2714' if na_nova else '\u2718'
    print(f"  {marca} {nome:<40} {', '.join(estados)}")
    if not na_nova: pendentes.append(nome)
if pendentes:
    print()
    print('  SEM task rodando na imagem nova: ' + ', '.join(pendentes))
    print('  Pull em andamento explica isso nos primeiros minutos. Se persistir,')
    print('  leia o log do servico: a imagem trocou, mas o processo nao subiu.')
PYTASK

titulo "Pronto"
cat <<EOF
  Imagem em uso: $IMAGE_REPO:$VERSION
  Digest:        $DIGEST

  Verifique o endpoint novo (note os COLCHETES em inbox_ids[] — sem eles o
  Rails fica só com o último valor e o quadro sai escopado num canal só):

    curl -s -o /dev/null -w '%{http_code}\\n' \\
      -H "api_access_token: <token>" \\
      "https://<host>/api/v1/accounts/<id>/dashboard-attendants?inbox_ids[]=<inbox>"

  200 → o ERP passa a usar o caminho escalável sozinho, sem reiniciar nada.
  404 → a imagem antiga ainda está no ar; o painel segue pelo caminho legado.

  Rollback: rode este script de novo informando a versão anterior. O estado
  de antes ficou salvo no .tsv gerado no diretório atual.
EOF
