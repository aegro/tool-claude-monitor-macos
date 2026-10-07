'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');
const contas = require('./contas');
const { Proxy } = require('./proxy');
const { valorDaFlag, temFlag } = require('./args');
const { retomarThreadT3 } = require('./t3');
const agentes = require('./agentes');

const SUBCOMANDOS_SEM_CONTA = new Set([
  'auth', 'mcp', 'plugin', 'plugins', 'doctor', 'update', 'install', 'config', 'setup-token', 'migrate-installer',
]);

const SUBCOMANDOS_SEM_SUPERVISOR = new Set(['agents', 'attach', 'logs', 'stop', 'rm', 'daemon', 'remote-control']);
const SUBCOMANDOS_DO_DAEMON = new Set(['agents', 'attach', 'logs', 'stop', 'kill', 'rm', 'respawn', 'daemon']);
const FLAGS_DE_SESSAO = ['--resume', '-r', '--session-id', '--continue', '-c'];

function supervisionavel(args) {
  if (process.env.CLAUDE_AUTO_SEM_SUPERVISOR || !process.stdin.isTTY || !process.stdout.isTTY) return false;
  if (args[0] && !args[0].startsWith('-') && SUBCOMANDOS_SEM_SUPERVISOR.has(args[0])) return false;
  return !args.some((a) => ['-p', '--print', '--bg', '--background'].includes(a) || a.startsWith('--print='));
}

function rodarSupervisionado(conta, args, python) {
  const final = FLAGS_DE_SESSAO.some((f) => temFlag(args, f)) ? args : [...args, '--session-id', crypto.randomUUID()];
  const configuracao = {
    bin: contas.resolverClaude(),
    args: final,
    conta,
    env: {},
    contas: path.resolve(__dirname, '..', 'bin', 'claude-accounts'),
    log: contas.ARQ_LOG,
  };
  const filho = spawn(python, [path.join(__dirname, 'tui.py')], {
    env: { ...contas.envDaConta(conta), CLAUDE_AUTO_TUI: JSON.stringify(configuracao) },
    stdio: 'inherit',
  });
  for (const sinal of ['SIGTERM', 'SIGHUP']) process.on(sinal, () => filho.kill(sinal));
  process.on('SIGINT', () => {});
  filho.on('error', (e) => {
    process.stderr.write(`claude-auto: ${e.message}\n`);
    process.exit(127);
  });
  filho.on('exit', (codigo, sinal) => process.exit(codigo ?? (sinal ? 1 : 0)));
}

function contaFixada() {
  const cfg = contas.carregarConfig();
  const pedida = process.env.CLAUDE_AUTO_CONTA;
  if (pedida && cfg.contas[pedida]) return pedida;
  const dirPedido = process.env.CLAUDE_CONFIG_DIR;
  if (dirPedido) {
    const id = Object.keys(cfg.contas).find((c) => contas.dirDaConta(c, cfg) === dirPedido.replace(/\/+$/, ''));
    if (id) return id;
  }
  return null;
}

async function contaParaAbrir() {
  const fixada = contaFixada();
  if (fixada && !contas.lerEsgotadas()[fixada]) return { conta: fixada, folga: null, fixada: true };
  try {
    const escolha = await contas.escolher();
    return { conta: escolha.escolhida || contas.principal(), folga: escolha.folga };
  } catch (e) {
    contas.log(`direto: falha ao escolher conta (${e.message}); usando principal`);
    return { conta: contas.principal(), folga: null };
  }
}

async function rodarDireto(args) {
  const semConta = SUBCOMANDOS_SEM_CONTA.has(args[0]) || args.some((a) => ['--version', '-v', '--help', '-h'].includes(a));
  const { conta, folga, fixada } = semConta ? { conta: contaFixada() || contas.principal() } : await contaParaAbrir();
  if (!semConta) {
    try {
      contas.prepararConta(conta);
    } catch (e) {
      contas.log(`direto: preparar conta ${conta} falhou: ${e.message}`);
    }
    contas.log(`direto: abrindo na conta ${conta}${fixada ? ' (fixada)' : ` (folga ${folga ?? '?'})`}: ${args.slice(0, 6).join(' ')}`);
  }
  if (!semConta && supervisionavel(args)) {
    const python = contas.python3();
    if (python) return rodarSupervisionado(conta, args, python);
    contas.log('direto: sem python3 utilizável; abrindo sem supervisor de terminal');
  }
  const filho = spawn(contas.resolverClaude(), args, { env: contas.envDaConta(conta), stdio: 'inherit' });
  for (const sinal of ['SIGTERM', 'SIGHUP']) process.on(sinal, () => filho.kill(sinal));
  process.on('SIGINT', () => {});
  filho.on('error', (e) => {
    process.stderr.write(`claude-auto: ${e.message}\n`);
    process.exit(127);
  });
  filho.on('exit', (codigo, sinal) => process.exit(codigo ?? (sinal ? 1 : 0)));
}

function doDaemon(args) {
  if (args[0] && !args[0].startsWith('-') && SUBCOMANDOS_DO_DAEMON.has(args[0])) return true;
  return args.some((a) => a === '--bg' || a === '--background');
}

async function abrirNoSlot(args) {
  try {
    await agentes.prepararSlot();
  } catch (e) {
    contas.log(`agentes: preparar a conta dos agentes falhou: ${e.message}`);
  }
  contas.log(`agentes: abrindo ${args.slice(0, 4).join(' ')} na conta ${agentes.contaNoSlot()}`);
  const filho = spawn(contas.resolverClaude(), args, { env: agentes.envDoSlot(), stdio: 'inherit' });
  for (const sinal of ['SIGTERM', 'SIGHUP']) process.on(sinal, () => filho.kill(sinal));
  process.on('SIGINT', () => {});
  filho.on('error', (e) => {
    process.stderr.write(`claude-auto: ${e.message}\n`);
    process.exit(127);
  });
  filho.on('exit', (codigo, sinal) => process.exit(codigo ?? (sinal ? 1 : 0)));
}

function repassar(args) {
  const filho = spawn(contas.resolverClaude(), args, { stdio: 'inherit' });
  for (const sinal of ['SIGTERM', 'SIGHUP', 'SIGINT']) process.on(sinal, () => filho.kill(sinal));
  filho.on('error', (e) => {
    process.stderr.write(`claude-auto: ${e.message}\n`);
    process.exit(127);
  });
  filho.on('exit', (codigo, sinal) => process.exit(codigo ?? (sinal ? 1 : 0)));
}

async function main() {
  if (contas.carregarConfig().ativo === false) return repassar(process.argv.slice(2));
  const args = retomarThreadT3(process.argv.slice(2));
  if (doDaemon(args)) return abrirNoSlot(args);
  if (valorDaFlag(args, '--input-format') !== 'stream-json') return rodarDireto(args);
  const fixada = contaFixada();
  await new Proxy(args, { contaInicial: fixada && !contas.lerEsgotadas()[fixada] ? fixada : null }).iniciar();
}

main().catch((e) => {
  contas.log(`erro fatal: ${e.stack || e.message}`);
  process.stderr.write(`claude-auto: ${e.message}\n`);
  process.exit(1);
});
