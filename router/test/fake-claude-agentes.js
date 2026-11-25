#!/usr/bin/env node
'use strict';

const fs = require('fs');

const [comando, alvo] = process.argv.slice(2);
const registrar = (evento) => fs.appendFileSync(process.env.FAKE_AGENTES_LOG, JSON.stringify(evento) + '\n');

if (comando === 'agents') {
  process.stdout.write(fs.readFileSync(process.env.FAKE_AGENTES, 'utf8'));
  process.exit(0);
}
if (comando === 'respawn') {
  registrar({ evento: 'respawn', agente: alvo });
  process.exit(0);
}
if (comando === 'attach') {
  let recebido = '';
  process.stdout.write('attached\n');
  if (process.stdin.isTTY) process.stdin.setRawMode(true);
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (pedaco) => {
    if (pedaco.includes('\x1a')) process.exit(0);
    recebido += pedaco;
    if (!pedaco.includes('\r')) return;
    const texto = recebido.replace(/\r/g, '');
    registrar({ evento: 'continuar', agente: alvo, texto });
    const entrada = { type: 'user', timestamp: new Date().toISOString(), message: { role: 'user', content: texto } };
    fs.appendFileSync(process.env.FAKE_TRANSCRIPT, JSON.stringify(entrada) + '\n');
    recebido = '';
  });
  process.on('SIGTERM', () => process.exit(0));
  setTimeout(() => process.exit(0), 15000);
  return;
}
process.exit(1);
