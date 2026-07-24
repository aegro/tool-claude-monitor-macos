# tool-claude-monitor-macos

Monitor de recursos para a barra de menu do macOS, focado em **quanto o Claude Code está
consumindo** — em processos e em tokens/limites — não em dinheiro. App nativo (SwiftUI +
AppKit), sem dependências, ~3 MB.

Feito para quem roda **muitos terminais e várias sessões do Claude ao mesmo tempo** e precisa
saber, de relance: quem está pesando na máquina, quanto ainda cabe no limite de 5h da conta,
e onde estão os processos (Docker, java, Chrome) que uma sessão abriu e deixou soltos.

## O que ele mostra

- **Limites da conta**, vindos do servidor (o mesmo dado do comando `/usage`): a janela de 5h
  e a semanal, cada uma com um marcador do **ritmo que a janela sustenta**. Passar do marcador
  significa gastar adiantado; o app projeta quando o limite acaba versus quando ele reseta.
- **Tokens da janela atual**, por sessão e por modelo, com a evolução em barras de 5 min.
- **Claude na máquina**: cada sessão com CPU, memória e tudo que ela abriu **aninhado embaixo
  dela** — inclusive processos reparentados para o launchd que outros monitores mostram soltos.
  Os Chrome abertos por uma sessão aparecem dentro dela, com o nome do perfil.
- **Encerrar** qualquer processo, subárvore ou sessão inteira (com tudo que ela subiu), via
  hover ou menu de contexto. `⌥` força (SIGKILL).

## Manter o Mac desperto

Réplica das duas funções do Vorssaint (estilo Amphetamine), no topo do painel:

- **Manter desperto** — segura uma power assertion do IOKit (`PreventUserIdleSystemSleep`), o
  mesmo mecanismo do `caffeinate`. Sem senha. Aceita uma **duração** (1h/2h/4h/8h/indefinido);
  ao esgotar, desliga sozinho.
- **Continuar com a tampa fechada** — usa `pmset disablesleep`, que exige root. Em vez de pedir
  a senha toda vez, instala **uma única regra sudoers restrita** — limitada a exatamente
  `pmset disablesleep 0|1`, validada com `visudo` e instalada como `root:wheel 0440` — com um
  prompt de admin na primeira vez. Depois disso, alternar não pede mais senha. Mesmo mecanismo e
  mesmo escopo do Vorssaint; nenhum outro comando fica liberado. Para remover:
  `sudo rm /etc/sudoers.d/monitor-claude-clamshell`.

## Instalar (qualquer Mac)

Pré-requisito único: as **ferramentas de linha de comando do Xcode** (trazem o Swift). Se você
nunca instalou:

```sh
xcode-select --install
```

Depois, **uma vez só por usuário** (a identidade fica no login Keychain, não na máquina), crie a identidade local que assina o app — é ela que faz o
macOS lembrar do "Sempre Permitir" entre builds (assinatura ad-hoc não tem identidade durável,
então o prompt do Keychain voltaria a cada build e, em versões recentes do macOS, a cada
leitura): **Acesso às Chaves** → menu **Assistente de Certificado → Criar um Certificado…** →
nome `Aegro Local Dev` · tipo de identidade **Raiz autoassinada** · tipo de certificado
**Assinatura de código**. Se quiser outro nome, passe `IDENTITY="…" ./scripts/build.sh`.

```sh
git clone git@github.com:aegro/tool-claude-monitor-macos.git
cd tool-claude-monitor-macos
./scripts/build.sh          # compila, monta o .app, instala em /Applications e assina com a identidade local
open -a "Monitor Claude"
```

Dois prompts únicos na primeira vez, ambos com **Sempre Permitir**: o `codesign` pede para usar
a chave privada do certificado ao assinar, e, quando o app lê os limites, o macOS pergunta se
ele pode acessar a entrada `Claude Code-credentials` do Keychain (digite a senha do Keychain
antes de clicar) — é o mesmo token de login do seu terminal, lido em tempo de execução. Como a
identidade de assinatura é estável, essas permissões sobrevivem a rebuilds.

Para atualizar: `git pull && ./scripts/build.sh`.

O ícone aparece na barra de menu (um anel com a % da janela de 5h). Clique para abrir o painel;
o botão **⚙ Configurações** ajusta altura do painel, o que a barra mostra e o intervalo de
consulta ao servidor.

## Leitura da credencial (somente leitura)

O token de acesso que o app lê do Keychain vive poucas horas. **Quem renova é o Claude Code**,
dono da entrada `Claude Code-credentials`; o app só **lê** o token para consultar os limites —
nunca escreve nem renova.

Isso é deliberado. O refresh token da Anthropic é rotacionado a cada uso: dois renovadores
independentes (o CLI e este app) sobre a mesma credencial disparam a *reuse detection* do
servidor, que invalida a **família de tokens inteira** — quebrando o login do próprio CLI e
deixando o Keychain pedindo senha em loop. Por isso a renovação fica só com o CLI, que é o dono
do item.

Na prática: o app relê o Keychain quando o token está perto de vencer (o CLI já gravou um novo
lá) e usa o token fresco. Se ele estiver vencido e você não roda o `claude` há muito tempo, o
painel mostra "token recusado" até você abrir o terminal uma vez — é o CLI que mantém a
credencial viva, não o monitor.

## Por que não confiar nos tokens locais

Os transcripts em `~/.claude/projects/**/*.jsonl` **subcontam** input e output em 100–174×: o
Claude Code grava esses campos a partir de eventos de streaming e nunca os finaliza
([anthropics/claude-code#28197](https://github.com/anthropics/claude-code/issues/28197), fechada
como *not planned*). Só os campos de cache são exatos. Por isso os **limites vêm sempre do
servidor** (`GET /api/oauth/usage`); os tokens locais servem só para comparar sessões entre si e
desenhar a evolução, sempre rotulados como estimativa.

## Como ele liga um processo à sessão certa

O `ppid` mente: qualquer coisa reparentada para o launchd (um worker que virou daemon, um app
aberto via LaunchServices, o stack do Docker) perde a linhagem e aparece solto embaixo do shell.

O ambiente não mente — é copiado no `exec` e sobrevive à morte do pai. O Claude Code carimba
`CLAUDE_CODE_SESSION_ID` (o mesmo UUID de `~/.claude/sessions/<pid>.json`) em tudo que gera.
O dono de cada processo é resolvido em ordem de confiança: é uma sessão conhecida → ambiente
nomeia a sessão → ambiente nomeia o job → ancestral resolve → "processo responsável" do
LaunchServices resolve. O resultado é uma **partição exata**: cada processo cai em um único
balde, nada é contado duas vezes nem perdido (`monitor-claude --dump-tree` verifica isso a cada
varredura).

## Modos de linha de comando (debug)

```sh
BIN="/Applications/Monitor Claude.app/Contents/MacOS/MonitorClaude"
"$BIN" --dump-usage    # o JSON cru de /api/oauth/usage e o parse
"$BIN" --dump-ledger   # tokens do bloco atual, por sessão e por modelo
"$BIN" --dump-tree     # a atribuição de processos + a prova de partição exata
"$BIN" --preview       # abre o painel numa janela normal (desenvolvimento)
```

## Privacidade

Lê o Keychain (o token OAuth do seu login), os arquivos em `~/.claude/` e a tabela de processos
do seu usuário. Fala com **um único endpoint**, da própria Anthropic e nenhum a mais:
`api.anthropic.com/api/oauth/usage` (o mesmo do `/usage`). O token de acesso só é enviado nesse
GET, como Bearer; nada mais sai da máquina.

O app **nunca escreve** a sua credencial — nem no Keychain, nem em disco: só lê o token (a
renovação é responsabilidade do Claude Code). O histórico de limites vai para
`~/Library/Application Support/MonitorClaude/usage-history.json` (só porcentagens e horários de
reset, nunca credenciais).

## Licença

Uso interno Aegro.
