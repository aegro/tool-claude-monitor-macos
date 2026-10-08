'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const contas = require('./contas');
const { valorDaFlag, temFlag, semFlagsDeSessao } = require('./args');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BANCO_T3 = process.env.CLAUDE_AUTO_T3_DB || path.join(os.homedir(), '.t3', 'userdata', 'statev2.sqlite');

function sqlite() {
  for (const candidato of ['/usr/bin/sqlite3', '/opt/homebrew/bin/sqlite3', 'sqlite3']) {
    if (candidato === 'sqlite3' || fs.existsSync(candidato)) return candidato;
  }
  return 'sqlite3';
}

function consultar(sql) {
  const saida = execFileSync(sqlite(), ['-readonly', '-json', BANCO_T3, sql], {
    encoding: 'utf8',
    timeout: 5000,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  return saida.trim() ? JSON.parse(saida) : [];
}

function sessoesDaMesmaThread(sessionId) {
  return consultar(`
    SELECT json_extract(p.payload_json, '$.nativeThreadRef.nativeId') AS sessao, p.updated_at AS atualizado
    FROM orchestration_v2_projection_provider_threads p
    WHERE p.thread_id = (
      SELECT thread_id FROM orchestration_v2_projection_provider_threads
      WHERE json_extract(payload_json, '$.nativeThreadRef.nativeId') = '${sessionId}' LIMIT 1
    )
    ORDER BY p.updated_at DESC`);
}

function dirDoProjeto(cwd) {
  return path.join(contas.DIR_PRINCIPAL, 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'));
}

function transcricaoExiste(cwd, sessionId) {
  return fs.existsSync(path.join(dirDoProjeto(cwd), `${sessionId}.jsonl`));
}

function esperar(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function retomarThreadT3(args, cwd = process.cwd()) {
  if (process.env.CLAUDE_AUTO_SEM_RETOMADA_T3 || !fs.existsSync(BANCO_T3)) return args;
  const nova = valorDaFlag(args, '--session-id');
  if (!nova || !UUID.test(nova) || temFlag(args, '--resume') || temFlag(args, '-r') || temFlag(args, '--continue')) return args;
  if (temFlag(args, '--no-session-persistence') || transcricaoExiste(cwd, nova)) return args;
  try {
    let linhas = [];
    for (let tentativa = 0; tentativa < 4 && !linhas.length; tentativa++) {
      if (tentativa) esperar(300);
      linhas = sessoesDaMesmaThread(nova);
    }
    const anterior = linhas.find((l) => l.sessao && l.sessao !== nova && UUID.test(l.sessao) && transcricaoExiste(cwd, l.sessao));
    if (!anterior) return args;
    contas.log(`t3: thread com sessão nova ${nova}; retomando o histórico de ${anterior.sessao}`);
    return [...semFlagsDeSessao(args), `--resume=${anterior.sessao}`, '--fork-session', `--session-id=${nova}`];
  } catch (e) {
    contas.log(`t3: consulta ao banco do T3 falhou: ${e.message}`);
    return args;
  }
}

module.exports = { retomarThreadT3, dirDoProjeto };
