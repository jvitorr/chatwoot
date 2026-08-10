# 015 — `scripts/deploy-portainer.sh`: atualização do Chatwoot via Portainer

**Status:** ativo
**Arquivos do core alterados:** nenhum
**Arquivos novos:** `scripts/deploy-portainer.sh`
**Risco no merge:** Nulo — arquivo novo, fora da árvore do upstream

---

## O que faz

Pergunta a URL do Portainer, o token de API e a versão publicada no Docker Hub;
descobre o ambiente e os serviços sozinho; roda a migration; atualiza os
serviços; atualiza a definição dos stacks; e confere o resultado.

```bash
./scripts/deploy-portainer.sh                  # interativo
./scripts/deploy-portainer.sh --dry-run        # mostra o plano, não muda nada
./scripts/deploy-portainer.sh --skip-migration # só troca a imagem
./scripts/deploy-portainer.sh --yes            # sem confirmação (CI)
```

Não interativo: `PORTAINER_URL`, `PORTAINER_TOKEN`, `VERSION`. Ajuste
`IMAGE_REPO` e `SERVICE_PREFIX` se o repositório ou o nome dos serviços mudar.
O token é lido com `read -s` — não vai para a tela nem para o histórico.

## As sete decisões, e o que cada uma evita

Cada passo do script existe porque a alternativa óbvia falha de um jeito
silencioso — o pior tipo de falha de deploy, porque parece sucesso.

1. **Fixa a imagem por digest**, resolvido no Docker Hub a partir da tag. Uma
   tag reescrita (o caso de `latest`) não faz o Swarm puxar nada: ele reusa a
   imagem que o nó já tem e o deploy "dá certo" sem trocar uma linha de código.
2. **Migration antes da troca de imagem.** Os índices são inertes para o código
   antigo, então essa ordem nunca tem janela ruim; a inversa tem.
3. **Migration num serviço efêmero** (`RestartPolicy: none`), não num `exec`.
   Um exec morre junto se o container for reciclado no meio, e rodá-la em cada
   serviço a executaria três vezes. O molde é o serviço de API, então as
   variáveis, a rede e os volumes são idênticos aos de produção.
4. **Manda o `version` index no update.** Sem ele a API do Swarm responde 409 —
   a causa nº 1 de "o script falhou e não sei por quê".
5. **Incrementa `ForceUpdate`**, garantindo a recriação das tarefas.
6. **Um serviço de cada vez**, esperando convergir. Com 1 réplica por serviço,
   atualizar tudo junto derruba o chat inteiro por alguns segundos.
7. **Atualiza também a definição do stack.** Mexer só no serviço deixa o
   compose guardado no Portainer apontando para a imagem antiga: tudo parece
   certo, até alguém clicar em "Update the stack" e o ambiente voltar sozinho
   para a versão anterior. Foi exatamente o que aconteceu no primeiro deploy da
   4.15.1.5 — os três serviços subiram, os três stacks continuaram dizendo
   4.15.1.4, e o desencontro só apareceu porque alguém perguntou.

O `PUT` do stack **preserva o `Env`**: um PUT sem ele apaga as variáveis do
stack. A conferência final valida os dois lados — serviço e definição —
justamente porque um sem o outro é meia verdade.

## Falhas tratadas

- Tag inexistente no Docker Hub → para antes de tocar em qualquer coisa.
- Token inválido → a listagem de ambientes já denuncia (`Invalid JWT token`).
- Migration que não conclui → **os serviços não são atualizados**; o log é
  impresso e nada foi trocado, então é seguro corrigir e rodar de novo.
- `409` no update → mensagem explicando que é corrida de `version` index.
- Falha só no stack → avisa que os serviços já estão na versão nova e que a
  definição precisa ser corrigida na UI para não reverter num redeploy.

O estado de antes (serviço, `version` index e digest) é gravado num `.tsv` no
diretório atual — é o que permite o rollback exato. Só é escrito **depois** do
aceite, para o `--dry-run` não sujar nada. O padrão está no `.gitignore`.

## Rollback

Rodar o script de novo informando a versão anterior. Os índices criados pela
migration podem ficar: são inertes para o código antigo, e derrubá-los só custa
recriar depois.

---

## Revisão para produção (2026-08-10)

O script nasceu contra o `chat-test`, e três suposições vieram do tamanho
daquele ambiente. Corrigidas antes do primeiro uso em produção.

### 1. Teto de espera da migration matava o índice pela metade

O laço original esperava `60 × 5s` = 5 minutos e, **fora do `if`**, apagava o
serviço efêmero. No teste (22 MB, 117 conversas) a migration terminava na hora.
Em produção os dois índices sobem com `CREATE INDEX CONCURRENTLY` sobre uma
tabela grande e podem passar disso — e aí o script apagava o serviço com o
índice em construção. Matar um `CONCURRENTLY` no meio deixa o índice
**inválido**: o Postgres o mantém em toda escrita e nunca o usa em leitura.

Agora o teto é `MIGRATION_TIMEOUT` (1 h por padrão) e a remoção do serviço só
acontece em estado **terminal**. Se estourar, o script diz para não apagar o
serviço, mostra a consulta de índice inválido e sai sem tocar nos serviços —
rodar de novo é seguro, a migration é `if_not_exists`.

### 2. A conferência olhava o desejado, não o que está no ar

O `✔` lia `Spec.TaskTemplate.ContainerSpec.Image`, que é o que o Swarm
**aceitou**. Com pull instantâneo isso equivale ao que roda; com imagem maior,
não. Foi acrescentada uma conferência de **tasks**: só marca `✔` quando existe
task em `running` com o digest novo. Pega inclusive o caso pior — task
`running`, porém ainda na imagem antiga.

### 3. "Já estava na versão" era dito também quando o compose não cita o repo

A troca no compose usa regex sobre `IMAGE_REPO`. Sem nenhuma ocorrência, o
resultado é idêntico à entrada, e o script concluía "já estava em X". São
coisas diferentes: a segunda quer dizer que o stack tira a imagem de outro
lugar. Agora os dois casos têm códigos de saída distintos e mensagens
distintas.

### O que só o ambiente responde

`SERVICE_PREFIX` (padrão `chatwoot`), quantidade de endpoints e o casamento
`<stack>_<serviço>` dependem de como produção foi nomeada. `--dry-run` faz
só chamadas GET e imprime exatamente isso, sem alterar nada — é o primeiro
passo em qualquer ambiente novo.
