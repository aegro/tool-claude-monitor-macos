'use strict';

// Rodando de dentro de uma sessão do claude-auto, o ambiente traz a conta e a pasta dela: os processos dos testes não
// podem herdar isso (com CLAUDE_AUTO_CONTA, o proxy abre preso à conta e ignora a escolha à mão). Cada suíte carrega
// este arquivo antes de tudo.
for (const nome of ['CLAUDE_AUTO_CONTA', 'CLAUDE_CONFIG_DIR', 'CLAUDE_AUTO_CLAUDE_BIN']) delete process.env[nome];
