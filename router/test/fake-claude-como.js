#!/usr/bin/env node
'use strict';

// O `claude -p` que o `claude-accounts as` abre, no contrato dele: o pedido chega como texto pela entrada padrão (não
// stream-json, que é o do fake-claude.js). Grava o que recebeu em COMO_FAKE_SAIDA e sai com COMO_FAKE_CODIGO, ou se
// mata com COMO_FAKE_SINAL.
const fs = require('fs');

let pedido = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => {
  pedido += d;
});
process.stdin.on('end', () => {
  fs.writeFileSync(
    process.env.COMO_FAKE_SAIDA,
    JSON.stringify({ pedido, args: process.argv.slice(2), configDir: process.env.CLAUDE_CONFIG_DIR, conta: process.env.CLAUDE_AUTO_CONTA }),
  );
  if (process.env.COMO_FAKE_SINAL) process.kill(process.pid, process.env.COMO_FAKE_SINAL);
  else process.exit(Number(process.env.COMO_FAKE_CODIGO || 0));
});
