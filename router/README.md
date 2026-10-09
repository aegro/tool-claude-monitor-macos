# claude-auto

Roteador de contas do Claude Code que vem dentro do Monitor Claude. Escolhe a conta com mais folga ao abrir e, quando o limite bate, reabre a mesma sessão em outra conta e manda continuar.

## Contas

`~/.claude` é a conta principal (o id dela fica em `principal` na config). Cada conta extra mora em `~/.claude-accounts/<id>` e roda com `CLAUDE_CONFIG_DIR` apontando para lá. Ficam na conta só a identidade (`.claude.json`), a credencial no Keychain (`Claude Code-credentials-<sha256(dir)[:8]>`) e os caches da org. Settings, hooks, skills, plugins, memória e transcrições são links para `~/.claude`; MCPs e a confiança dos projetos são copiados da principal a cada abertura.

```bash
claude-accounts add <id> [--name N] [--reserve]
claude-accounts login <id>
claude-accounts status | pick | switches | release <id> | sync | env <id> | run <id>
claude-accounts on | off      # o mesmo botão de Troca automática do Monitor
```

Config em `~/.claude-accounts/config.json`:

| campo | padrão | uso |
| --- | --- | --- |
| `ativo` | `true` | desligado, o `claude-auto` só repassa para o `claude` |
| `principal` | `"principal"` | id da conta que usa o próprio `~/.claude` |
| `rota` | `["principal"]` | contas usadas normalmente; vence a de maior folga |
| `reserva` | `[]` | só entra quando todas da rota estão abaixo de `limites.reserva` |
| `preferida` | nenhuma | conta usada primeiro sempre que tem folga; veja [Conta preferida](#conta-preferida). A fila do Monitor grava aqui a primeira da rota na regra “A do topo primeiro” e tira a chave na “A de mais folga” |
| `contas.<id>.nome` | o id | nome da conta nas notificações, no `status` e no Monitor |
| `contas.<id>.sigla` | iniciais do nome | duas letras que o Monitor mostra no avatar e na barra de menu; o roteador não usa |
| `limites.reserva` | `3` | folga (%) abaixo da qual a reserva entra e a preferida deixa de ser escolhida |
| `limites.preventiva` | `5` | folga (%) abaixo da qual a troca preventiva dispara (stream-json no fim do turno; `claude agents` só enquanto o ritmo de uso é desconhecido) |
| `limites.horizonteMinutos` | `2` | minutos à frente que o `claude agents` projeta a folga pelo ritmo de uso |
| `limites.margem` | `2` | folga (%) projetada no horizonte que dispara a troca preventiva do `claude agents`; com a folga já nesse valor, troca sempre |
| `limites.voltar` | `20` | folga (%) que a preferida precisa recuperar para as sessões voltarem para ela |
| `cacheUsoSegundos` | `60` | idade máxima da leitura de cota antes de consultar de novo |
| `notificar` | `true` | notificação do macOS a cada troca |

`claude-accounts`, a troca dos agentes e os Ajustes do Monitor só mudam `config.json` e o `.claude.json` do slot (`~/.claude.json`) dentro de uma trava `<arquivo>.lock`, o mesmo diretório que o Claude Code usa para o `.claude.json`, e releem o arquivo dentro dela. Trava sem atividade há mais de 10 s é tratada como abandonada; trava ocupada por mais de alguns segundos faz a mudança desistir com erro, sem gravar. Arquivo com JSON inválido não é sobrescrito.

Folga é 100% menos o maior uso entre as janelas de 5h e de 7 dias. Conta que bateu o limite fica marcada como esgotada até o horário de renovação.

## Como troca

- **Stream-json (T3 Code, Agent SDK).** O `claude-auto` fica entre o cliente e o `claude`, lendo as mensagens. Num `rate_limit_event` rejeitado ou num erro de conta (autenticação, cobrança), ele segura o erro, encerra o processo, reabre a mesma sessão com `--resume` na próxima conta, repete o `initialize` e os ajustes da sessão e manda continuar. Subagentes e Workflows que estavam rodando entram na mensagem, com a instrução de relançar (Workflow com `resumeFromRunId`). No fim de cada turno, se a folga ficou abaixo de `limites.preventiva`, troca antes de falhar, esperando as tarefas em segundo plano acabarem.
- **Terminal.** Com `alias claude=claude-auto`, a sessão interativa roda dentro de um supervisor com pty (`lib/tui.py`). Quando a tela mostra o aviso de limite (`You've hit your … limit`), ele fecha o processo, reabre a mesma sessão com `--resume` na conta com mais folga e digita a mensagem de continuação. `CLAUDE_AUTO_SEM_SUPERVISOR=1` desliga.
- **VS Code.** Com `claudeCode.claudeProcessWrapper` apontando para o `claude-auto` (o Monitor grava isso em Ajustes → Integrações), a extensão roda `claude-auto <claude da extensão> <argumentos>`. Um primeiro argumento que é um caminho absoluto para um executável chamado `claude` vira o binário a usar (`CLAUDE_AUTO_CLAUDE_BIN`) e sai da lista de argumentos; se esse caminho é o próprio `claude-auto`, ele só sai da lista. O resto segue como no stream-json.
- **T3 abrindo sessão nova numa thread.** Se o T3 manda `--session-id` novo numa thread que já tinha conversa, o `claude-auto` acha a sessão anterior em `~/.t3/userdata/statev2.sqlite` e abre com `--resume=<anterior> --fork-session --session-id=<nova>`: o histórico volta e o id que o T3 espera é mantido.
- **`claude agents`.** Veja a seção abaixo.
- **`-p`** só escolhe a conta ao abrir.

Em stream-json, cada `rate_limit_event` que o `claude` emite (os números de limite lidos dos cabeçalhos da resposta) vai para `~/.claude-accounts/.estado/ao-vivo/<conta>.json`, com `usado` em porcentagem e `renovaEm` em ms por janela (`five_hour`, `seven_day`). O Monitor lê esses arquivos antes de consultar o `/usage`.

Cada troca vai para `~/.claude-accounts/.estado/trocas.jsonl`, para o log `claude-auto.log` e vira notificação, com o nome das contas, o motivo e a hora em que a anterior volta: “Trocou para Thomas (Max)” e “Thomas (Aegro) bateu o limite de 5h. Volta às 18:59.” A volta para a preferida diz “Voltou para …”, e a troca dos agentes acrescenta “Os agentes seguiram junto.”

## Troca no `claude agents`

O daemon dos agentes sempre usa o login de `~/.claude`. Cada conta extra precisa de um login só para agentes, separado do login do terminal:

```bash
claude-accounts login <nome> --agents   # navegador; use janela anônima se já estiver logado em outra conta
claude-accounts agents                  # login de agentes de cada conta e onde os agentes rodam
```

A troca acontece antes do limite. A cada checagem (cerca de 30 s, com algum agente em segundo plano), o Monitor guarda a leitura de uso da conta dos agentes e mede o ritmo, em pontos percentuais por minuto, da janela que limita (5h ou 7 dias) pelas leituras dos últimos 10 minutos; leituras de antes de uma renovação da janela são descartadas. Quando a folga projetada para daqui a `limites.horizonteMinutos` (folga menos ritmo vezes horizonte) chega a `limites.margem`, ou a folga já está nesse valor, o login de `~/.claude` troca para a conta da rota com mais folga, ou para a da reserva com mais folga se nenhuma da rota servir. Só serve uma conta com login de agentes, mais folga que a atual e folga que, no mesmo ritmo, não dispararia a troca de novo; a preferida não tem prioridade aqui, só na volta. Sem conta que sirva, as outras contas só são consultadas de novo depois de 5 minutos, enquanto a dos agentes for a mesma. Com os padrões, uma conta gastando 4 pontos por minuto troca com 10% de folga e uma gastando pouco troca com 2%. Sem ritmo conhecido (menos de duas leituras, ou menos de 2 minutos entre a primeira e a última), vale a regra fixa: folga abaixo de `limites.preventiva`. Os agentes ociosos são reiniciados na conta nova na hora; o que está no meio de um turno não é interrompido e muda quando ficar ocioso. A conta anterior não é marcada como esgotada, e folga desconhecida não dispara a troca.

O endpoint de uso costuma responder 429 quando o próprio Claude Code também o consulta, e aí o router fica sem leituras novas. Por isso, com a troca ligada, o Monitor publica em `~/.claude-accounts/.estado/ritmo.json`, a cada checagem, o ritmo que ele mede para a conta de `~/.claude` na janela que limita, junto com o uso que ele conhece e quando o leu. O ritmo e o uso vêm só das leituras que ele mesmo faz da API com o login de `~/.claude`, e o ritmo só das feitas depois da última vez em que outro login esteve no slot: o arquivo do app desktop identifica só a organização, e duas contas na mesma organização têm limites separados. Quando não dá para publicar (leitura da API falhando, uso vindo do app desktop ou ritmo ainda sem leituras suficientes), ele apaga o arquivo. Se o arquivo tem até 2 minutos e é da conta que está no slot, a troca preventiva usa esse ritmo no lugar do medido pelas leituras do router e projeta a folga a partir da leitura mais nova, a do router ou a do Monitor: folga menos ritmo vezes os minutos desde essa leitura. Quando a mais nova é a do Monitor, a folga de partida é a menor entre a dele e a da última leitura do router, para que a outra janela continue contando; se a leitura do router mostra que a janela do Monitor renovou depois da leitura dele, o uso do Monitor é descartado. Sem o arquivo, com ele velho ou de outra conta, vale a regra de antes. Depois de uma troca preventiva, a volta para a conta que saiu só considera uma leitura dela feita depois da troca, ou uma em que a janela que limitava já renovou.

Um login que não cabe no `security -i` (cerca de 4 KB) é recusado, com uma exceção: o item do slot (`Claude Code-credentials`) é gravado em argv com `security add-generic-password`, porque o próprio Claude Code grava esse mesmo item assim quando ele passa do limite, então não há exposição nova; os logins guardados de cada conta continuam recusados.

Se um turno gasta o resto da folga antes disso, vale a troca por limite: o Monitor troca o login de `~/.claude` para a conta com mais folga (ou usa a que já entrou pela troca preventiva), reinicia o agente e manda continuar. Conta sem login de agentes não entra na troca.

Quando a troca muda o login de `~/.claude`, `principal` passa a ser a conta que entrou. A anterior segue na rota do terminal e do T3 pelo próprio diretório, `~/.claude-accounts/<id>`, com o login que tiver ali. Sem login nesse diretório, a troca avisa (log e notificação) e `claude-accounts status` e os Ajustes mostram `claude-accounts login <id>` no lugar do e-mail, em vez de a conta sumir da escolha sem explicação.

Antes de carregar o login guardado de uma conta em `~/.claude`, a troca confere o access token dele no perfil da API, sem renovar nada: o router nunca renova token, porque a cópia guardada divide o refresh token com os processos `claude` que ainda estão vivos, e dois renovadores do mesmo token disparam a *reuse detection* e derrubam a família inteira. Se o access token já venceu (pelo `expiresAt`), ou vence em menos de cinco minutos, a API não é consultada e o login é carregado normalmente, porque o Claude Code o renova no primeiro uso com o refresh token; um refresh token morto aparece ali como pedido de novo login. A folga de cinco minutos evita que um relógio adiantado confunda token velho com token revogado. Ela vale só para o login que vai entrar; para descobrir de quem é o login que já está no slot, a troca usa o vencimento exato, para não cair na conta declarada em `~/.claude.json` sem necessidade. Um 403 é tratado como falta de resposta (costuma ser bloqueio de rede, não de credencial). Token recusado (401) ou de outra conta: o login não é carregado, a conta fica marcada como precisando de `claude-accounts login <id> --agents` (aparece em `claude-accounts agents` e nos Ajustes), uma notificação avisa uma vez e a conta sai da troca até o novo login; na troca por limite, a próxima conta é tentada na hora. Sem resposta da API, na troca por limite essa conta é pulada e a próxima é tentada; se nenhuma servir, nada é trocado, o aviso diz que a conferência não respondeu e a próxima checagem tenta de novo.

A troca guarda uma impressão (hash) do refresh token que está em `~/.claude` no início e relê o item antes de guardar o login da conta que sai. A cópia guardada e o slot novo saem dessa mesma leitura, e logo antes de carregar o login novo o item tem que estar idêntico a ela. Se ele mudou no meio (o Claude Code renovou o login), nada é carregado e a próxima checagem tenta de novo. Se a gravação parece ter falhado, a troca relê o item: com o login novo lá (mesmo já renovado pelo Claude Code), ela segue e atualiza `~/.claude.json` e a principal; sem ele, o item só volta ao texto anterior quando ainda contém o que a troca gravou.

## Conta preferida

`preferida` na config. No Monitor, é a primeira conta da fila na regra **A do topo primeiro**; a regra **A de mais folga** remove a chave. Ela é escolhida sempre que está logada, não está esgotada e tem folga de pelo menos `limites.reserva`; fora isso vale a conta com mais folga, como sem preferida.

- **Sessão nova** (terminal, T3 e `-p`) começa nela.
- **`claude agents`**: o login de `~/.claude` é um só para todos os agentes, então ele só volta para a preferida pela regra de volta. A cada 5 minutos, sem agente parado por limite, e a cada `claude agents`/`--bg`, a preferida é conferida; mudar a primeira da fila ou a regra no Monitor dispara a conferência na hora. Se ela não está esgotada, está logada e voltou a ter `limites.voltar` de folga, o login de `~/.claude` volta para ela e os agentes ociosos são reiniciados nela. Agente no meio de um turno não é interrompido: muda quando ficar ocioso. Precisa do login de agentes da preferida.
- **T3 e stream-json**: no fim de um turno, sem subagente nem Workflow rodando, confere a mesma regra no máximo uma vez por minuto e volta como na troca preventiva, sem mensagem de continuação. Instância com `CLAUDE_AUTO_CONTA` fica na conta pedida.
- **Terminal já aberto** não volta: fica na conta atual até o próximo limite.

## O que ele não faz

- Não intermedia credencial nem usa proxy: cada conta roda o CLI oficial com o próprio login.
- A troca forçada mata o processo; o que estava em segundo plano é relançado, não continuado.

## Instalar a partir do repositório

O app instala os comandos sozinho. Para usar direto do fonte: `router/install.sh`, que cria os links em `~/.local/bin`. Precisa de Node 18+ e, para o supervisor do terminal, do `python3` do sistema.

## Testes

```bash
node router/test/teste-proxy.js
node router/test/teste-agentes.js
python3 router/test/teste-tui.py
```
