# claude-auto

Roteador de contas do Claude Code que vem dentro do Monitor Claude. Escolhe a conta com mais folga ao abrir e, quando o limite bate, reabre a mesma sessão em outra conta e manda continuar.

## Contas

`~/.claude` é a conta principal (o id dela fica em `principal` na config). Cada conta extra mora em `~/.claude-accounts/<id>` e roda com `CLAUDE_CONFIG_DIR` apontando para lá. Ficam na conta só a identidade (`.claude.json`), a credencial no Keychain (`Claude Code-credentials-<sha256(dir)[:8]>`) e os caches da org. Settings, hooks, skills, plugins, memória e transcrições são links para `~/.claude`; MCPs e a confiança dos projetos são copiados da principal a cada abertura.

```bash
claude-accounts add <id> [--name N] [--reserve]
claude-accounts login <id>
claude-accounts status | pick | switches | release <id> | sync | env <id> | run <id>
claude-accounts on | off      # o mesmo botão de Configurações → Troca de conta
```

Config em `~/.claude-accounts/config.json`:

| campo | padrão | uso |
| --- | --- | --- |
| `ativo` | `true` | desligado, o `claude-auto` só repassa para o `claude` |
| `principal` | `"principal"` | id da conta que usa o próprio `~/.claude` |
| `rota` | `["principal"]` | contas usadas normalmente; vence a de maior folga |
| `reserva` | `[]` | só entra quando todas da rota estão abaixo de `limites.reserva` |
| `limites.reserva` | `3` | folga (%) abaixo da qual a reserva entra |
| `limites.preventiva` | `5` | folga (%) no fim do turno que dispara a troca preventiva (stream-json) |
| `cacheUsoSegundos` | `60` | idade máxima da leitura de cota antes de consultar de novo |
| `notificar` | `true` | notificação do macOS a cada troca |

Folga é 100% menos o maior uso entre as janelas de 5h e de 7 dias. Conta que bateu o limite fica marcada como esgotada até o horário de renovação.

## Como troca

- **Stream-json (T3 Code, Agent SDK).** O `claude-auto` fica entre o cliente e o `claude`, lendo as mensagens. Num `rate_limit_event` rejeitado ou num erro de conta (autenticação, cobrança), ele segura o erro, encerra o processo, reabre a mesma sessão com `--resume` na próxima conta, repete o `initialize` e os ajustes da sessão e manda continuar. Subagentes e Workflows que estavam rodando entram na mensagem, com a instrução de relançar (Workflow com `resumeFromRunId`). No fim de cada turno, se a folga ficou abaixo de `limites.preventiva`, troca antes de falhar, esperando as tarefas em segundo plano acabarem.
- **Terminal.** Com `alias claude=claude-auto`, a sessão interativa roda dentro de um supervisor com pty (`lib/tui.py`). Quando a tela mostra o aviso de limite (`You've hit your … limit`), ele fecha o processo, reabre a mesma sessão com `--resume` na conta com mais folga e digita a mensagem de continuação. `CLAUDE_AUTO_SEM_SUPERVISOR=1` desliga.
- **T3 abrindo sessão nova numa thread.** Se o T3 manda `--session-id` novo numa thread que já tinha conversa, o `claude-auto` acha a sessão anterior em `~/.t3/userdata/statev2.sqlite` e abre com `--resume=<anterior> --fork-session --session-id=<nova>`: o histórico volta e o id que o T3 espera é mantido.
- **`claude agents` e `-p`** só escolhem a conta ao abrir.

Cada troca vai para `~/.claude-accounts/.estado/trocas.jsonl`, para o log `claude-auto.log` e vira notificação.

## O que ele não faz

- Não intermedia credencial nem usa proxy: cada conta roda o CLI oficial com o próprio login.
- A troca forçada mata o processo; o que estava em segundo plano é relançado, não continuado.
- Os agentes do `claude agents` que já estão rodando não trocam: o daemon executa o binário real.

## Instalar a partir do repositório

O app instala os comandos sozinho. Para usar direto do fonte: `router/install.sh`, que cria os links em `~/.local/bin`. Precisa de Node 18+ e, para o supervisor do terminal, do `python3` do sistema.

## Testes

```bash
node router/test/teste-proxy.js
python3 router/test/teste-tui.py
```
