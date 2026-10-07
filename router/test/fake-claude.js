#!/usr/bin/env node
'use strict';

const fs = require('fs');
const crypto = require('crypto');

const args = process.argv.slice(2);
const conta = process.env.CLAUDE_AUTO_CONTA || 'desconhecida';
const limitadas = (process.env.FAKE_LIMITADAS || '').split(',').filter(Boolean);
const valor = (nome) => {
  const a = args.find((x) => x.startsWith(`${nome}=`));
  return a ? a.slice(nome.length + 1) : null;
};
const sessao = valor('--session-id') || valor('--resume') || crypto.randomUUID();

function registrar(evento) {
  fs.appendFileSync(process.env.FAKE_LOG, JSON.stringify({ pid: process.pid, conta, ...evento }) + '\n');
}
function emitir(msg) {
  process.stdout.write(JSON.stringify({ session_id: sessao, uuid: crypto.randomUUID(), ...msg }) + '\n');
}

registrar({ evento: 'inicio', args });
process.on('SIGTERM', () => {
  registrar({ evento: 'sigterm' });
  process.exit(143);
});

let resto = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (pedaco) => {
  resto += pedaco;
  let i;
  while ((i = resto.indexOf('\n')) >= 0) {
    const linha = resto.slice(0, i);
    resto = resto.slice(i + 1);
    if (linha.trim()) tratar(JSON.parse(linha));
  }
});
process.stdin.on('end', () => {
  registrar({ evento: 'stdin_fim' });
  setTimeout(() => process.exit(0), 50);
});

function tratar(msg) {
  registrar({ evento: 'stdin', msg });
  if (msg.type === 'control_request') {
    emitir({ type: 'control_response', response: { subtype: 'success', request_id: msg.request_id, response: {} } });
    return;
  }
  if (msg.type !== 'user') return;
  const texto = JSON.stringify(msg.message.content);
  emitir({ type: 'system', subtype: 'init', model: 'fake', tools: [] });
  if (texto.includes('LANCE_TAREFAS')) {
    emitir({
      type: 'assistant',
      parent_tool_use_id: null,
      message: { role: 'assistant', content: [
        { type: 'tool_use', id: 'toolu_agente', name: 'Agent', input: { description: 'pesquisar contratos', subagent_type: 'general-purpose', prompt: 'p' } },
        { type: 'tool_use', id: 'toolu_wf', name: 'Workflow', input: { script: 'export const meta = { name: "revisao" }' } },
      ] },
    });
    emitir({ type: 'user', parent_tool_use_id: null, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_wf', content: 'Workflow launched. Run ID: wf_abc123def. Task: t1' }] } });
    emitir({ type: 'system', subtype: 'task_started', task_id: 't1', tool_use_id: 'toolu_wf', description: 'revisao', task_type: 'local_workflow', workflow_name: 'revisao' });
    emitir({ type: 'system', subtype: 'task_started', task_id: 't2', tool_use_id: 'toolu_agente', description: 'pesquisar contratos', task_type: 'local_agent', subagent_type: 'general-purpose' });
  }
  if (process.env.FAKE_PEDIR_PERMISSAO) {
    emitir({ type: 'control_request', request_id: `perm-${process.pid}`, request: { subtype: 'can_use_tool', tool_name: 'Bash', input: {} } });
  }
  if (limitadas.includes(conta)) {
    emitir({ type: 'rate_limit_event', rate_limit_info: { status: 'rejected', rateLimitType: 'five_hour', resetsAt: Math.floor(Date.now() / 1000) + 3600 } });
    emitir({ type: 'assistant', parent_tool_use_id: null, error: 'rate_limit', message: { role: 'assistant', content: [{ type: 'text', text: "You've hit your limit" }] } });
    emitir({ type: 'result', subtype: 'success', is_error: true, result: "You've hit your limit", queued_turn_count: 0 });
    return;
  }
  emitir({ type: 'assistant', parent_tool_use_id: null, message: { role: 'assistant', content: [{ type: 'text', text: `ok de ${conta}` }] } });
  emitir({ type: 'result', subtype: 'success', is_error: false, result: `ok de ${conta}`, queued_turn_count: 0 });
}
