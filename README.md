# Monitor Claude

Monitor de barra de menu do macOS que mostra quanto o Claude Code está consumindo: limites da conta, tokens da janela atual e os processos que cada sessão deixou rodando. App nativo (SwiftUI + AppKit), sem dependências, 3 MB.

Feito para quem roda vários terminais e várias sessões ao mesmo tempo, e precisa saber de relance quanto ainda cabe na janela de 5h, quem está pesando na máquina e onde foram parar o Docker, o java e o Chrome que uma sessão abriu.

## Instalar

### Homebrew (recomendado)

```bash
brew tap aegro/tap
brew install --cask monitor-claude
```

Para atualizar depois:

```bash
brew upgrade --cask monitor-claude
```

O cask entrega o mesmo `.app` assinado e notarizado publicado em [Releases](https://github.com/aegro/tool-claude-monitor-macos/releases), e acompanha cada versão nova automaticamente.

### Download manual

Baixe o `.zip` mais recente em [Releases](https://github.com/aegro/tool-claude-monitor-macos/releases), descompacte e arraste **Monitor Claude.app** para `/Applications`. Abra com `open -a "Monitor Claude"`.

### O prompt do Keychain na primeira vez

Ao abrir pela primeira vez, o macOS pergunta uma única vez se o app pode ler a entrada `Claude Code-credentials`, que guarda o token de login do seu terminal. Digite a senha do Keychain e clique **Sempre Permitir**.

Como o app é assinado com o Developer ID da Aegro, que tem Team ID estável, essa permissão gruda de vez e não volta a perguntar nem depois de atualizar. Esse primeiro prompt é inevitável: quem cria o item é o Claude Code, não o Monitor, então o app não tem como se pré-autorizar.

### Compilar do fonte (desenvolvimento)

O pré-requisito único são as ferramentas de linha de comando do Xcode, que trazem o Swift:

```bash
xcode-select --install
```

O `build.sh` assina com uma identidade local. Crie-a uma vez por usuário no **Acesso às Chaves**, em **Assistente de Certificado → Criar um Certificado…**, com nome `Aegro Local Dev`, identidade **Raiz autoassinada** e certificado **Assinatura de código**. Para usar outro nome, passe `IDENTITY="…" ./scripts/build.sh`.

```bash
git clone git@github.com:aegro/tool-claude-monitor-macos.git
cd tool-claude-monitor-macos
./scripts/build.sh   # compila, monta o .app, instala em /Applications e assina
./scripts/test.sh    # roda a suíte (funciona sem o Xcode completo)
```

O build de dev pede dois prompts na primeira vez, ambos com **Sempre Permitir**: o `codesign` pede a chave privada do certificado, e o macOS pergunta pelo acesso ao Keychain. Diferente do release notarizado, a identidade autoassinada não tem Team ID, então o prompt do Keychain pode voltar a cada relaunch. É o preço de compilar localmente.

## O que o painel mostra

O ícone na barra de menu traz a porcentagem da janela de 5h. Clique para abrir o painel; o botão **⚙ Configurações** ajusta a altura, o que a barra exibe e o intervalo de consulta ao servidor.

- **Limites da conta**, vindos do servidor (o mesmo dado do comando `/usage`): a janela de 5h e as semanais, cada uma com um marcador do ritmo que a janela sustenta. Passar do marcador significa gastar adiantado, e o app projeta quando o limite acaba contra quando ele reseta.
- **Várias contas**: a conta ativa aparece com o detalhe completo ao vivo; as demais viram uma faixa-resumo clicável que expande na última leitura de cada uma. Uma conta entra na lista depois de você usá-la no `claude` pelo menos uma vez.
- **Tokens da janela atual**, por sessão e por modelo, com a evolução em barras de 5 minutos.
- **Claude na máquina**: cada sessão com CPU, memória e tudo que ela abriu aninhado embaixo dela, inclusive processos reparentados para o launchd que outros monitores mostram soltos. Os Chrome abertos por uma sessão aparecem dentro dela, com o nome do perfil.
- **Encerrar** qualquer processo, subárvore ou sessão inteira, via hover ou menu de contexto. `⌥` força (SIGKILL).

## Manter o Mac desperto

O topo do painel replica as duas funções do Vorssaint, no estilo do Amphetamine:

- **Manter desperto**: segura uma power assertion do IOKit (`PreventUserIdleSystemSleep`), o mesmo mecanismo do `caffeinate`. Não pede senha, aceita uma duração (1h, 2h, 4h, 8h ou indefinido) e desliga sozinho ao esgotar.
- **Continuar com a tampa fechada**: usa `pmset disablesleep`, que exige root. Em vez de pedir a senha toda vez, o app instala uma única regra sudoers restrita a exatamente `pmset disablesleep 0|1`, validada com `visudo` e instalada como `root:wheel 0440`, com um prompt de admin na primeira vez. Nenhum outro comando fica liberado. Para remover: `sudo rm /etc/sudoers.d/monitor-claude-clamshell`.

## Como ele funciona

### A credencial é lida, nunca escrita

O token que o app lê do Keychain vive poucas horas, e quem o renova é o Claude Code, dono da entrada `Claude Code-credentials`. O Monitor apenas lê o token para consultar os limites.

Isso é deliberado. A Anthropic rotaciona o refresh token a cada uso, então dois renovadores independentes sobre a mesma credencial disparam a *reuse detection* do servidor, que invalida a família de tokens inteira. Na prática isso quebraria o login do próprio CLI e deixaria o Keychain pedindo senha em loop.

O app relê o Keychain quando o token está perto de vencer, momento em que o CLI já gravou um novo, e usa o token fresco. Se ele estiver vencido e o `claude` não roda há algumas horas, o painel avisa que a sessão expirou até você rodar o `claude` uma vez.

### Quando o login do terminal morre, o app do Claude assume

Só o `claude` no terminal renova esse token. Quem passou a usar o Claude Code pelo app desktop para de renová-lo, e o Monitor ficaria cego por tempo indeterminado.

Existe uma segunda fonte para esse caso. O app desktop consulta o mesmo endpoint a cada cinco minutos e grava o resultado em `plan-usage-history.json`: são os mesmos números do servidor, e nenhuma credencial é envolvida — o token do app é cifrado pelo safeStorage do Electron e o Monitor não encosta nele.

A API continua preferida sempre que o token vale, porque só ela traz as janelas por modelo, o `severity` do servidor e o crédito extra. O feed do app entra quando a API não responde, e a faixa de procedência no topo da seção diz, o tempo todo, quais fontes estão respondendo e há quanto tempo. O que o feed novo não carrega continua desenhado, apagado, com o último valor e a data em que valia.

Os dois horários de reset que o app não grava são reconstruídos, e a reconstrução se identifica com `≈`. O semanal avança um âncora periódico que a API deu; o da sessão sai da série — a queda do percentual quando a janela vira, ou, quando o uso é baixo demais para haver queda, a primeira leitura não-zero depois de um zero. Sem âncora confiável, o reset fica vazio: um reset errado envenenaria o marcador de ritmo, o outlook e o eixo do gráfico.

### Os limites vêm do servidor, não dos tokens locais

Os transcripts em `~/.claude/projects/**/*.jsonl` subcontam input e output em 100 a 174 vezes, porque o Claude Code grava esses campos a partir de eventos de streaming e nunca os finaliza ([anthropics/claude-code#28197](https://github.com/anthropics/claude-code/issues/28197), fechada como *not planned*). Só os campos de cache são exatos.

Por isso os limites vêm sempre do servidor — de `GET /api/oauth/usage` ou, quando o login do terminal caiu, da leitura que o app desktop fez desse mesmo endpoint. Os tokens locais servem para comparar sessões entre si e desenhar a evolução, sempre rotulados como estimativa.

### Como um processo é ligado à sessão certa

O `ppid` mente: qualquer coisa reparentada para o launchd, como um worker que virou daemon ou o stack do Docker, perde a linhagem e aparece solta embaixo do shell.

O ambiente não mente, porque é copiado no `exec` e sobrevive à morte do pai. O Claude Code carimba `CLAUDE_CODE_SESSION_ID` em tudo que gera, o mesmo UUID de `~/.claude/sessions/<pid>.json`. O dono de cada processo sai de uma ordem de confiança: é uma sessão conhecida, o ambiente nomeia a sessão, o ambiente nomeia o job, um ancestral resolve, ou o “processo responsável” do LaunchServices resolve.

O resultado é uma partição exata: cada processo cai em um único balde, nada é contado duas vezes nem perdido. O modo `--dump-tree` verifica isso a cada varredura.

## Privacidade

O app lê o Keychain, os arquivos em `~/.claude/`, o histórico de uso que o app desktop do Claude grava em `~/Library/Application Support/Claude/`, e a tabela de processos do seu usuário. Ele fala com um único endpoint, `api.anthropic.com/api/oauth/usage`, o mesmo do comando `/usage`. O token sai da máquina apenas nesse GET, como Bearer.

O app nunca escreve a sua credencial, nem no Keychain nem em disco. Em `~/Library/Application Support/Farol/` ficam dois arquivos, ambos sem credenciais: `usage-history.json` (porcentagens, horários de reset e o uuid da organização a que cada leitura pertence) e `accounts.json` (o último snapshot de limites por conta, com rótulo e plano).

## Modos de depuração

```bash
BIN="/Applications/Monitor Claude.app/Contents/MacOS/MonitorClaude"
"$BIN" --dump-usage    # o JSON cru de /api/oauth/usage e o parse
"$BIN" --dump-ledger   # tokens do bloco atual, por sessão e por modelo
"$BIN" --dump-tree     # a atribuição de processos e a prova de partição exata
"$BIN" --dump-desktop-feed  # a série do app desktop e o reset derivado dela
"$BIN" --preview       # abre o painel numa janela normal
```

## Publicar um release (mantenedores)

O app distribuído é assinado com um **Developer ID Application** da conta Apple Developer da Aegro e notarizado pela Apple. É isso que faz o “Sempre Permitir” grudar para qualquer usuário. O release oficial roda só no CI, e a chave privada nunca sai dos secrets do repositório.

Publicar é empurrar uma tag `v*`:

```bash
git tag v1.2.0
git push origin v1.2.0
```

O workflow [`release.yml`](.github/workflows/release.yml) compila, assina, notariza, grampeia e publica o `.app` como GitHub Release, com a versão saindo da tag (`v1.2.0` vira `1.2.0`). Em seguida ele dispara o bump do cask no tap [aegro/homebrew-tap](https://github.com/aegro/homebrew-tap), que entrega a versão nova ao `brew upgrade`.

Os secrets ficam em **Settings → Secrets and variables → Actions** e são configurados uma vez:

| Secret | O que é |
|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | o certificado *Developer ID Application* exportado como `.p12` e passado por `base64` |
| `DEVELOPER_ID_CERT_PASSWORD` | a senha definida ao exportar o `.p12` |
| `APPLE_ID` | Apple ID (e-mail) da conta usada na notarização |
| `APPLE_TEAM_ID` | o Team ID (10 caracteres) da conta Apple Developer |
| `APPLE_APP_SPECIFIC_PASSWORD` | uma [app-specific password](https://support.apple.com/102654) da Apple ID, para o `notarytool` |

O [`scripts/release.sh`](scripts/release.sh) é o mesmo script que o CI roda e aceita os mesmos valores por variável de ambiente (`SIGN_IDENTITY`, `AC_APPLE_ID`, `AC_TEAM_ID`, `AC_PASSWORD`). Rodá-lo localmente serve para depurar a assinatura, não para publicar: o artefato que os usuários recebem sai sempre do CI.

## Licença

Uso interno Aegro.
