'use strict';

// Renews an idle account's expired login through the official CLI (`/usage` is local and spends no model), so the
// refresh token is only ever rotated by Claude Code itself. Skipped while any claude process uses the account's folder.

const fs = require('fs');
const path = require('path');
const { spawn, execFile } = require('child_process');
const contas = require('./contas');

const ARQ_RENOVACOES = path.join(contas.DIR_ESTADO, 'renovacoes.json');
const DIR_TRAVA = path.join(contas.DIR_ESTADO, 'renovar.trava');
const DIR_DE_TRABALHO = path.join(contas.DIR_ESTADO, 'renovar');
const INTERVALO_MS = 30 * 60 * 1000;
const INTERVALO_EM_USO_MS = 5 * 60 * 1000;
const PRAZO_MS = 90 * 1000;
const TRAVA_ANTIGA_MS = 5 * 60 * 1000;

function escaparRegex(texto) {
  return texto.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function processosNoAmbiente(saidaDoPs, dir) {
  const alvo = new RegExp(`(^|\\s)CLAUDE_CONFIG_DIR=${escaparRegex(dir)}/?(\\s|$)`);
  return saidaDoPs
    .split('\n')
    .filter((linha) => alvo.test(linha))
    .map((linha) => Number(linha.trim().split(/\s+/)[0]))
    .filter((pid) => Number.isInteger(pid) && pid > 0 && pid !== process.pid);
}

function vivo(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
}

function sessoesVivasNaPasta(dir) {
  let arquivos = [];
  try {
    arquivos = fs.readdirSync(path.join(dir, 'sessions')).filter((f) => f.endsWith('.json'));
  } catch {
    return [];
  }
  return arquivos
    .map((f) => (contas.lerJson(path.join(dir, 'sessions', f), {}) || {}).pid)
    .filter((pid) => Number.isInteger(pid) && vivo(pid));
}

function lerPs() {
  return new Promise((resolve) => {
    execFile('ps', ['-E', '-ww', '-axo', 'pid=,command='], { maxBuffer: 64 * 1024 * 1024 }, (erro, saida) => {
      resolve(erro ? null : String(saida));
    });
  });
}

async function processosNaPasta(dir) {
  const ps = await lerPs();
  if (ps == null) return null;
  return [...new Set([...processosNoAmbiente(ps, dir), ...sessoesVivasNaPasta(dir)])];
}

function envDaRenovacao(dir) {
  const env = { ...process.env };
  for (const chave of Object.keys(env)) {
    if (chave.startsWith('CLAUDE_CODE_') || chave === 'CLAUDECODE') delete env[chave];
  }
  delete env.CLAUDE_AUTO_CONTA;
  env.CLAUDE_CONFIG_DIR = dir;
  return env;
}

function rodarUsage(dir, { prazoMs = PRAZO_MS } = {}) {
  fs.mkdirSync(DIR_DE_TRABALHO, { recursive: true });
  const args = ['-p', '/usage', '--no-session-persistence', '--strict-mcp-config', '--setting-sources', 'project'];
  return new Promise((resolve) => {
    let filho;
    try {
      filho = spawn(contas.resolverClaude(), args, { cwd: DIR_DE_TRABALHO, env: envDaRenovacao(dir), stdio: ['ignore', 'ignore', 'pipe'] });
    } catch (e) {
      resolve({ ok: false, erro: e.message });
      return;
    }
    let erro = '';
    filho.stderr.on('data', (d) => {
      erro = (erro + d).slice(-400);
    });
    const relogio = setTimeout(() => filho.kill('SIGTERM'), prazoMs);
    filho.on('error', (e) => {
      clearTimeout(relogio);
      resolve({ ok: false, erro: e.message });
    });
    filho.on('close', (codigo, sinal) => {
      clearTimeout(relogio);
      if (sinal) resolve({ ok: false, erro: 'the CLI took too long' });
      else resolve(codigo === 0 ? { ok: true } : { ok: false, erro: erro.trim().split('\n').pop() || `the CLI exited with ${codigo}` });
    });
  });
}

function vencida(credencial, agora) {
  return Boolean(credencial && credencial.accessToken && credencial.expiresAt && credencial.expiresAt <= agora);
}

function tomarTrava() {
  fs.mkdirSync(contas.DIR_ESTADO, { recursive: true });
  try {
    fs.mkdirSync(DIR_TRAVA);
    return true;
  } catch {}
  try {
    if (Date.now() - fs.statSync(DIR_TRAVA).mtimeMs < TRAVA_ANTIGA_MS) return false;
    fs.rmSync(DIR_TRAVA, { recursive: true, force: true });
    fs.mkdirSync(DIR_TRAVA);
    return true;
  } catch {
    return false;
  }
}

function soltarTrava() {
  fs.rmSync(DIR_TRAVA, { recursive: true, force: true });
}

function lerRenovacoes() {
  return contas.lerJson(ARQ_RENOVACOES, {}) || {};
}

async function renovarUma(id, cfg, deps, agora) {
  const dir = contas.dirDaConta(id, cfg);
  const credencial = await deps.lerCredencial(id, cfg);
  if (!vencida(credencial, agora)) return null;
  if (!credencial.refreshToken) return { resultado: 'falhou', erro: 'the stored login has no refresh token' };
  const vivos = await deps.processosNaPasta(dir);
  if (vivos == null) return { resultado: 'falhou', erro: 'could not list the running processes' };
  if (vivos.length) return { resultado: 'em-uso', processos: vivos.length };
  const r = await deps.rodarUsage(dir);
  const depois = await deps.lerCredencial(id, cfg);
  if (depois && depois.expiresAt > Date.now()) return { resultado: 'renovado', ate: depois.expiresAt };
  return { resultado: 'falhou', erro: r.ok ? 'the CLI ran but the token is still expired' : r.erro };
}

async function renovarParadas({ ids = null, forcar = false, deps = {} } = {}) {
  const usar = { lerCredencial: contas.lerCredencial, processosNaPasta, rodarUsage, ...deps };
  if (!tomarTrava()) return { acao: 'ocupado' };
  try {
    const cfg = contas.carregarConfig();
    const agora = Date.now();
    const anteriores = lerRenovacoes();
    const alvos = Object.keys(cfg.contas).filter(
      (id) => !cfg.contas[id].pendente && !contas.usaDirPadrao(id, cfg) && (!ids || ids.includes(id)),
    );
    const feitas = {};
    for (const id of alvos) {
      const anterior = anteriores[id];
      const espera = anterior && anterior.resultado === 'em-uso' ? INTERVALO_EM_USO_MS : INTERVALO_MS;
      if (!forcar && anterior && agora - anterior.em < espera) continue;
      const r = await renovarUma(id, cfg, usar, agora);
      if (!r) continue;
      feitas[id] = { em: Date.now(), ...r };
      if (r.resultado === 'renovado') contas.log(`renovar: login de ${id} renovado pelo CLI até ${new Date(r.ate).toISOString()}`);
      else if (r.resultado === 'falhou') contas.log(`renovar: login de ${id} venceu e não renovou: ${r.erro}`);
    }
    if (Object.keys(feitas).length) contas.escreverJson(ARQ_RENOVACOES, { ...lerRenovacoes(), ...feitas });
    return { acao: 'renovou', contas: feitas };
  } finally {
    soltarTrava();
  }
}

module.exports = {
  ARQ_RENOVACOES,
  INTERVALO_MS,
  processosNoAmbiente,
  processosNaPasta,
  envDaRenovacao,
  renovarParadas,
  lerRenovacoes,
};
