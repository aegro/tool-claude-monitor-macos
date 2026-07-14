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

## Instalar (qualquer Mac)

Pré-requisito único: as **ferramentas de linha de comando do Xcode** (trazem o Swift). Se você
nunca instalou:

```sh
xcode-select --install
```

Depois:

```sh
git clone git@github.com:aegro/tool-claude-monitor-macos.git
cd tool-claude-monitor-macos
./scripts/build.sh          # compila, monta o .app, instala em /Aplicativos e assina localmente
open -a "Monitor Claude"
```

Na primeira vez que ele lê os limites, o macOS pergunta se o app pode acessar a entrada
`Claude Code-credentials` do Keychain. Clique em **Sempre Permitir** — é o mesmo token de login
do seu terminal, lido em tempo de execução. Nada sai da máquina, nada é copiado para disco.

Para atualizar: `git pull && ./scripts/build.sh`.

O ícone aparece na barra de menu (um anel com a % da janela de 5h). Clique para abrir o painel;
o botão **⚙ Configurações** ajusta altura do painel, o que a barra mostra e o intervalo de
consulta ao servidor.

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
do seu usuário. A única chamada de rede é para `api.anthropic.com/api/oauth/usage`, o mesmo
endpoint do `/usage`. O histórico de limites é gravado em
`~/Library/Application Support/MonitorClaude/usage-history.json` (só porcentagens e horários de
reset, nunca credenciais).

## Licença

Uso interno Aegro.
