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

function inicioDoProcesso(pid) {
  return new Promise((resolve) => {
    execFile('ps', ['-o', 'lstart=', '-p', String(pid)], { env: { ...process.env, LC_ALL: 'C' } }, (erro, saida) =>
      resolve(erro ? null : String(saida).trim()),
    );
  });
}

const normalizarInicio = (texto) => String(texto || '').replace(/\s+/g, ' ').trim();

async function sessoesVivasNaPasta(dir, inicio = inicioDoProcesso) {
  let arquivos = [];
  try {
    arquivos = fs.readdirSync(path.join(dir, 'sessions')).filter((f) => f.endsWith('.json'));
  } catch {
    return [];
  }
  const vivas = [];
  for (const f of arquivos) {
    const sessao = contas.lerJson(path.join(dir, 'sessions', f), {}) || {};
    if (!Number.isInteger(sessao.pid) || !vivo(sessao.pid)) continue;
    if (sessao.procStart) {
      const real = await inicio(sessao.pid);
      if (real != null && normalizarInicio(real) !== normalizarInicio(sessao.procStart)) continue;
    }
    vivas.push(sessao.pid);
  }
  return vivas;
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
  return [...new Set([...processosNoAmbiente(ps, dir), ...(await sessoesVivasNaPasta(dir))])];
}

function envDaRenovacao(dir) {
  const env = { ...process.env };
  for (const chave of Object.keys(env)) {
    if (chave.startsWith('CLAUDE_CODE_') || chave === 'CLAUDECODE') delete env[chave];
  }
  delete env.CLAUDE_AUTO_CONTA;
  delete env.ANTHROPIC_API_KEY;
  delete env.ANTHROPIC_AUTH_TOKEN;
  env.CLAUDE_CONFIG_DIR = dir;
  return env;
}

function rodarUsage(dir, { prazoMs = PRAZO_MS, treguaMs = 5000, comando = null } = {}) {
  fs.mkdirSync(DIR_DE_TRABALHO, { recursive: true });
  const args = ['-p', '/usage', '--no-session-persistence', '--strict-mcp-config', '--setting-sources', 'project'];
  return new Promise((resolve) => {
    let filho;
    try {
      filho = spawn(comando || contas.resolverClaude(), args, { cwd: DIR_DE_TRABALHO, env: envDaRenovacao(dir), stdio: ['ignore', 'ignore', 'pipe'], detached: true });
    } catch (e) {
      resolve({ ok: false, erro: e.message });
      return;
    }
    let erro = '';
    filho.stderr.on('data', (d) => {
      erro = (erro + d).slice(-400);
    });
    let fim = false;
    let saiuCom = null;
    let relogioDoFecho = null;
    let relogioDoKill = null;
    const terminar = (resultado) => {
      if (fim) return;
      fim = true;
      clearTimeout(relogio);
      clearTimeout(relogioDoFecho);
      clearTimeout(relogioDoKill);
      filho.stderr.destroy();
      resolve(resultado);
    };
    let estourou = false;
    const pelaSaida = () => {
      if (estourou) terminar({ ok: false, erro: 'the CLI took too long' });
      else if (saiuCom === 0) terminar({ ok: true });
      else terminar({ ok: false, erro: erro.trim().split('\n').pop() || `the CLI exited with ${saiuCom}` });
    };
    const sinalizar = (sinal) => {
      try {
        process.kill(-filho.pid, sinal);
      } catch {}
    };
    const relogio = setTimeout(() => {
      estourou = true;
      sinalizar('SIGTERM');
      relogioDoKill = setTimeout(() => {
        sinalizar('SIGKILL');
        terminar({ ok: false, erro: 'the CLI took too long' });
      }, treguaMs);
    }, prazoMs);
    filho.on('error', (e) => terminar({ ok: false, erro: e.message }));
    filho.on('exit', (codigo, sinal) => {
      saiuCom = sinal ? sinal : codigo;
      if (sinal) {
        sinalizar('SIGKILL');
        terminar({ ok: false, erro: 'the CLI took too long' });
        return;
      }
      relogioDoFecho = setTimeout(() => {
        sinalizar('SIGTERM');
        pelaSaida();
      }, 1000);
    });
    filho.on('close', () => {
      if (saiuCom != null) pelaSaida();
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

function tocarTrava() {
  const agora = new Date();
  try {
    fs.utimesSync(DIR_TRAVA, agora, agora);
  } catch {}
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
      tocarTrava();
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
  sessoesVivasNaPasta,
  inicioDoProcesso,
  rodarUsage,
  envDaRenovacao,
  renovarParadas,
  lerRenovacoes,
};
