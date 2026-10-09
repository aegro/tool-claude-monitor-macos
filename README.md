# Monitor Claude

Monitor de barra de menu do macOS para quem usa o Claude Code: os limites de cada conta, a troca automática entre elas quando um limite bate, as sessões com o que cada uma deixou rodando e os acessos que precisam de você. App nativo (SwiftUI + AppKit), sem dependências, 3 MB.

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

O ícone na barra de menu traz a porcentagem da janela de 5h. Um ponto laranja aparece quando algo na aba **Acessos** precisa de você, e a sigla de uma conta aparece ao lado quando as sessões novas não estão abrindo na primeira da fila. Clique para abrir o painel, que tem três abas:

- **Contas**: em que conta as sessões novas abrem, até quando ela aguenta no ritmo atual e quem assume se o limite bater. Embaixo vem a fila, com as janelas de 5h e da semana de cada conta, o marcador do ritmo que a janela sustenta e quando cada uma renova. Passar do marcador significa gastar adiantado. Arraste uma conta para mudar a ordem; abaixo da linha **Reserva** ficam as que só entram quando as outras acabarem. Clique numa conta para ver o detalhe dos limites. Números lidos há mais de 15 minutos dizem quando foram lidos.
- **Sessões**: cada sessão do Claude com a conta em que roda, CPU, memória, tokens (estimativa local) e tudo o que ela abriu, aninhado embaixo dela, inclusive processos reparentados para o launchd que outros monitores mostram soltos. Os Chrome abertos por uma sessão aparecem dentro dela, com o nome do perfil. **Encerrar** derruba um processo, uma subárvore ou a sessão inteira; `⌥` força (SIGKILL).
- **Acessos**: o que precisa de você para o Claude Code seguir funcionando. Entram o login do terminal, as contas sem login, o login dos agentes, os conectores que pedem login *e* que você usou nos últimos 7 dias, versões novas do Claude Code e do Monitor no Homebrew e, com o painel de prontidão do workspace instalado, gcloud, AWS, GitHub e Docker. Conector que pede login sem ter sido usado fica quieto, num resumo.

A engrenagem abre os **Ajustes** (`⌘,`), com as abas Geral, Contas, Integrações e Avançado.

## Manter o Mac desperto

O botão da lua, no topo do painel, replica as duas funções do Vorssaint, no estilo do Amphetamine:

- **Manter desperto**: segura uma power assertion do IOKit (`PreventUserIdleSystemSleep`), o mesmo mecanismo do `caffeinate`. Não pede senha, aceita uma duração (1h, 2h, 4h, 8h ou indefinido) e desliga sozinho ao esgotar.
- **Continuar com a tampa fechada**: usa `pmset disablesleep`, que exige root. Em vez de pedir a senha toda vez, o app instala uma única regra sudoers restrita a exatamente `pmset disablesleep 0|1`, validada com `visudo` e instalada como `root:wheel 0440`, com um prompt de admin na primeira vez. Nenhum outro comando fica liberado. Para remover: `sudo rm /etc/sudoers.d/monitor-claude-clamshell`.

## Trocar de conta sozinho (claude-auto)

Para quem tem mais de uma conta do Claude: o Monitor acompanha todas e, com a troca automática ligada, o `claude-auto` troca de conta sozinho quando o limite bate e a sessão continua de onde parou.

- **Contas lado a lado.** `~/.claude` continua sendo a conta principal. Cada conta extra mora em `~/.claude-accounts/<id>` e roda o CLI oficial com `CLAUDE_CONFIG_DIR` apontando para lá, com o próprio login. Settings, hooks, skills, plugins, memória e transcrições são links para `~/.claude`, então um `--resume` feito em outra conta acha a mesma conversa.
- **A fila.** A ordem das contas é a da fila na aba **Contas**. Com a regra **A do topo primeiro**, as sessões novas abrem na primeira conta enquanto ela tiver folga e, quando ela acaba, na conta da rota com mais folga. Com **A de mais folga**, vale sempre a de mais folga. A reserva só entra quando a rota inteira acabar. Na config do roteador, isso é `rota`, `reserva` e `preferida` (a primeira da fila, na regra do topo). Depois de uma troca, o `claude agents` e o T3 (entre um turno e outro) voltam para a do topo quando ela recupera 20% de folga; uma sessão de terminal já aberta fica na conta atual até o próximo limite.
- **A troca automática.** Liga e desliga no rodapé da aba Contas ou em **Ajustes → Contas**. Desligada, o `claude-auto` só repassa tudo para o `claude`. O app instala `claude-auto` e `claude-accounts` em `~/.local/bin` como links para dentro dele, então o `brew upgrade` atualiza o roteador junto.
- **O aviso.** Cada troca vira uma notificação com o motivo e a hora em que a conta anterior volta: “Trocou para Thomas (Max) — Thomas (Aegro) bateu o limite de 5h. Volta às 18:59.”

### Configurar

1. Em **Ajustes → Contas**, clique **Adicionar conta**. O assistente sugere as contas que você já usou neste Mac, abre o login do Claude no navegador ou numa janela anônima (para quando o navegador já está logado em outra conta), mostra quem entrou e avisa se for a mesma conta e organização de outra que já está na fila.
2. Se você usa o `claude agents`, autorize também os agentes: é uma segunda autorização, da mesma conta.
3. Escolha o lugar na fila: na rota ou na reserva.
4. Em **Ajustes → Integrações**, ligue onde a troca vale:
   - **Terminal:** o app acrescenta ao `~/.zshrc` um bloco que faz o `claude` apontar para o `claude-auto` quando o comando existe. A sessão roda dentro de um supervisor; quando aparece o aviso de limite, ele reabre a mesma sessão com `--resume` na outra conta e manda continuar. Um alias escrito à mão é respeitado e não é editado.
   - **VS Code:** o app aponta `claudeCode.claudeProcessWrapper` para o `claude-auto` no `settings.json` do VS Code, editando o texto no lugar (comentários e formatação ficam). A extensão passa o caminho do próprio `claude` como primeiro argumento, e o roteador usa esse binário.
   - **T3 Code:** em cada instância Claude, binário `~/.local/bin/claude-auto` (o botão copia o caminho) e nenhum home próprio. Em stream-json a troca acontece no meio do turno, e para o T3 é o mesmo processo o tempo todo. `CLAUDE_AUTO_CONTA=<id>` no ambiente da instância fixa a conta de partida.

Cada arquivo que já existia quando o app o editou pela primeira vez ganha ao lado uma cópia `<arquivo>.monitor-claude.bak` com a versão de antes dessa edição; as edições seguintes não mexem nela. Um arquivo que o app cria (um `~/.zshrc` que ainda não existia, por exemplo) não ganha cópia, porque não havia versão anterior para guardar.

O roteador continua tendo a linha de comando, que é o que o assistente roda por baixo:

```bash
claude-accounts add pessoal      # cria ~/.claude-accounts/pessoal com os links para ~/.claude
claude-accounts login pessoal    # login dessa conta no navegador
claude-accounts login pessoal --agents   # login separado, só para o claude agents trocar de conta
claude-accounts status           # folga de cada conta e qual o roteador usaria agora
```

Regras de escolha, o que acontece na troca e os testes estão em [`router/README.md`](router/README.md).

## Como ele funciona

### A credencial é lida, nunca escrita

O token que o app lê do Keychain vive poucas horas, e quem o renova é o Claude Code, dono da entrada `Claude Code-credentials`. O Monitor apenas lê o token para consultar os limites.

Isso é deliberado. A Anthropic rotaciona o refresh token a cada uso, então dois renovadores independentes sobre a mesma credencial disparam a *reuse detection* do servidor, que invalida a família de tokens inteira. Na prática isso quebraria o login do próprio CLI e deixaria o Keychain pedindo senha em loop.

O app relê o Keychain quando o token está perto de vencer, momento em que o CLI já gravou um novo, e usa o token fresco. Se ele estiver vencido e o `claude` não roda há algumas horas, o painel avisa que a sessão expirou até você rodar o `claude` uma vez.

### Quando o login do terminal morre, o app do Claude assume

Só o `claude` no terminal renova esse token. Quem passou a usar o Claude Code pelo app desktop para de renová-lo, e o Monitor ficaria cego por tempo indeterminado.

Existe uma segunda fonte para esse caso. O app desktop consulta o mesmo endpoint a cada cinco minutos e grava o resultado em `plan-usage-history.json`: são os mesmos números do servidor, e nenhuma credencial é envolvida — o token do app é cifrado pelo safeStorage do Electron e o Monitor não encosta nele.

A API continua preferida sempre que o token vale, porque só ela traz as janelas por modelo, o `severity` do servidor e o crédito extra. O feed do app entra quando a API não responde; **Ajustes → Avançado** diz quais fontes estão respondendo e há quanto tempo, e o rodapé da aba Contas diz quando foram lidos os números da conta em uso. O que o feed novo não carrega continua desenhado, apagado, com o último valor e a data em que valia.

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

Com o roteador configurado, o app também lê as credenciais das contas de `~/.claude-accounts` pelo `/usr/bin/security`, consulta o mesmo endpoint com cada uma e lê o cache de leituras do roteador (`.estado/uso.json`), para não repetir uma consulta que ele acabou de fazer. Em `~/.claude-accounts/config.json`, escreve só a fila (`rota`, `reserva`, `preferida`), a chave `ativo` e o nome e a sigla de cada conta (`nome`, `sigla`). O assistente de contas roda os comandos do próprio roteador (`claude-accounts add` e `login`), e o login acontece no navegador, direto com o Claude.

Quando você liga uma integração, o app edita o `~/.zshrc` (só o bloco dele) ou a chave `claudeCode.claudeProcessWrapper` do `settings.json` do VS Code, guardando a versão de antes da primeira edição em `<arquivo>.monitor-claude.bak` quando o arquivo já existia (o que o app cria do zero não tem cópia).

A aba Acessos não gasta tokens nem abre conexões: lê o registro de conectores que pediram login (`~/.claude/mcp-needs-auth-cache.json`), os transcripts dos últimos 7 dias (só os nomes dos conectores usados), o relatório do painel de prontidão (`~/.aeg/dev-readiness/report.json`) e o `brew outdated` com os metadados locais do Homebrew.

O app nunca escreve a sua credencial, nem no Keychain nem em disco. Em `~/Library/Application Support/Farol/` ficam dois arquivos, ambos sem credenciais: `usage-history.json` (porcentagens, horários de reset e o uuid da organização a que cada leitura pertence) e `accounts.json` (o último snapshot de limites por conta, com rótulo e plano).

## Modos de depuração

```bash
BIN="/Applications/Monitor Claude.app/Contents/MacOS/MonitorClaude"
"$BIN" --dump-usage    # o JSON cru de /api/oauth/usage e o parse
"$BIN" --dump-ledger   # tokens do bloco atual, por sessão e por modelo
"$BIN" --dump-tree     # a atribuição de processos e a prova de partição exata
"$BIN" --dump-desktop-feed  # a série do app desktop e o reset derivado dela
"$BIN" --preview       # abre o painel numa janela normal
"$BIN" --preview=settings:integrations   # uma tela numa janela: panel:<aba>, settings:<aba>, wizard:<passo>
"$BIN" --render=panel:accounts tela.png --dark --wait=6   # desenha a tela num PNG, sem janela
```

As abas são `accounts`, `sessions` e `access` no painel e `general`, `accounts`, `integrations` e `advanced` nos Ajustes; os passos do assistente são `choose`, `authorize`, `connected`, `agents`, `place` e `done`. Os modos de prévia não trocam o login dos agentes nem gravam histórico. `MONITOR_CLAUDE_KEYCHAIN_VIA_SECURITY=1` faz o binário de dev ler o Keychain pelo `/usr/bin/security`, sem prompt; `CLAUDE_AUTO_HOME`, `CLAUDE_ACCOUNTS_BIN`, `MONITOR_CLAUDE_ZSHRC`, `MONITOR_CLAUDE_VSCODE_SETTINGS` e `MONITOR_CLAUDE_READINESS_DIR` apontam o app para outras pastas, que é como os testes funcionais rodam.

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
