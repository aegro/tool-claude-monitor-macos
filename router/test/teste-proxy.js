#!/usr/bin/env node
'use strict';

const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, execFileSync } = require('child_process');

// O Proxy e as contas carregados neste processo leem e gravam aqui, nunca no ~/.claude-accounts de quem roda.
const HOME_EM_PROCESSO = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-auto-proxy-'));
process.env.CLAUDE_AUTO_HOME = HOME_EM_PROCESSO;

const RAIZ = path.resolve(__dirname, '..');
const FAKE = path.join(__dirname, 'fake-claude.js');

function ambiente({ contas = ['principal', 'segunda'], limitadas = '', uso = null, esgotadas = null, config = {}, extra = {} } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-auto-teste-'));
  const home = path.join(dir, 'contas');
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(path.join(home, '.estado'), { recursive: true });
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(home, 'config.json'), JSON.stringify({
    contas: Object.fromEntries(contas.map((c) => [c, { nome: c[0].toUpperCase() + c.slice(1) }])),
    rota: contas,
    reserva: [],
    notificar: false,
    ...config,
  }));
  if (uso) fs.writeFileSync(path.join(home, '.estado', 'uso.json'), JSON.stringify(uso));
  if (esgotadas) fs.writeFileSync(path.join(home, '.estado', 'esgotadas.json'), JSON.stringify(esgotadas));
  fs.writeFileSync(path.join(bin, 'security'), '#!/bin/sh\necho \'{"claudeAiOauth":{"accessToken":"x","expiresAt":1,"subscriptionType":"max"}}\'\n', { mode: 0o755 });
  const log = path.join(dir, 'fake.log');
  fs.writeFileSync(log, '');
  const casa = path.join(dir, 'casa');
  fs.mkdirSync(path.join(casa, '.claude'), { recursive: true });
  return {
    dir,
    casa,
    home,
    log,
    env: {
      ...process.env,
      HOME: casa,
      PATH: `${bin}:${process.env.PATH}`,
      CLAUDE_AUTO_HOME: home,
      CLAUDE_AUTO_CLAUDE_BIN: FAKE,
      CLAUDE_AUTO_T3_DB: path.join(dir, 'sem-t3.sqlite'),
      FAKE_LOG: log,
      FAKE_LIMITADAS: limitadas,
      ...extra,
    },
  };
}

function iniciar(amb, args, cwd) {
  const filho = spawn(path.join(RAIZ, 'bin', 'claude-auto'), ['--output-format', 'stream-json', '--verbose', '--input-format', 'stream-json', ...args], {
    env: amb.env,
    cwd: cwd || amb.dir,
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  const recebidas = [];
  const esperas = [];
  let resto = '';
  filho.stdout.setEncoding('utf8');
  filho.stdout.on('data', (pedaco) => {
    resto += pedaco;
    let i;
    while ((i = resto.indexOf('\n')) >= 0) {
      const msg = JSON.parse(resto.slice(0, i));
      resto = resto.slice(i + 1);
      recebidas.push(msg);
      for (const e of [...esperas]) {
        if (e.condicao(msg)) {
          esperas.splice(esperas.indexOf(e), 1);
          e.resolve(msg);
        }
      }
    }
  });
  const saida = new Promise((resolve) => filho.on('exit', (codigo) => resolve(codigo)));
  return {
    filho,
    recebidas,
    saida,
    enviar: (msg) => filho.stdin.write(JSON.stringify(msg) + '\n'),
    esperar: (condicao, ms = 15000) =>
      new Promise((resolve, reject) => {
        const ja = recebidas.find(condicao);
        if (ja) return resolve(ja);
        const t = setTimeout(() => reject(new Error('tempo esgotado esperando mensagem')), ms);
        esperas.push({ condicao, resolve: (m) => (clearTimeout(t), resolve(m)) });
      }),
  };
}

const usuario = (texto) => ({ type: 'user', message: { role: 'user', content: [{ type: 'text', text: texto }] }, parent_tool_use_id: null, session_id: '' });
const pedido = (id, request) => ({ type: 'control_request', request_id: id, request });
const lerLog = (amb) => fs.readFileSync(amb.log, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
const lerTrocas = (amb) => {
  const arq = path.join(amb.home, '.estado', 'trocas.jsonl');
  return fs.existsSync(arq) ? fs.readFileSync(arq, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : [];
};
const esperarMs = (ms) => new Promise((r) => setTimeout(r, ms));

async function trocaForcadaNoMeioDoTurno() {
  const amb = ambiente({ limitadas: 'principal', extra: { FAKE_PEDIR_PERMISSAO: '1' } });
  const sessao = crypto.randomUUID();
  const s = iniciar(amb, ['--permission-prompt-tool', 'stdio', `--session-id=${sessao}`]);
  s.enviar(pedido('init-1', { subtype: 'initialize', appendSystemPrompt: 'x' }));
  await s.esperar((m) => m.type === 'control_response' && m.response.request_id === 'init-1');
  s.enviar(pedido('modo-1', { subtype: 'set_permission_mode', mode: 'acceptEdits' }));
  s.enviar(usuario('LANCE_TAREFAS'));
  const resultado = await s.esperar((m) => m.type === 'result');
  const permissaoAntiga = s.recebidas.find((m) => m.type === 'control_request' && m.request.subtype === 'can_use_tool');
  s.enviar({ type: 'control_response', response: { subtype: 'success', request_id: permissaoAntiga.request_id, response: { behavior: 'allow' } } });
  await esperarMs(300);
  s.filho.stdin.end();
  const codigo = await s.saida;

  assert.strictEqual(resultado.is_error, false, 'o host não deve ver o erro de limite');
  assert.strictEqual(resultado.result, 'ok de segunda');
  assert.ok(!s.recebidas.some((m) => m.type === 'rate_limit_event'), 'rate_limit_event rejeitado não pode vazar');
  assert.ok(!s.recebidas.some((m) => m.type === 'assistant' && m.error), 'erro de conta não pode vazar');
  assert.ok(!s.recebidas.some((m) => m.type === 'control_response' && String(m.response.request_id).startsWith('claude-auto-')), 'resposta interna vazou');
  assert.strictEqual(s.recebidas.filter((m) => m.type === 'control_response' && m.response.request_id === 'init-1').length, 1);
  assert.ok(s.recebidas.some((m) => m.type === 'control_cancel_request' && m.request_id === permissaoAntiga.request_id), 'pedido de permissão pendente deve ser cancelado');
  assert.strictEqual(codigo, 0);

  const log = lerLog(amb);
  const inicios = log.filter((e) => e.evento === 'inicio');
  assert.deepStrictEqual(inicios.map((e) => e.conta), ['principal', 'segunda']);
  assert.ok(inicios[0].args.includes(`--session-id=${sessao}`));
  assert.ok(inicios[1].args.includes(`--resume=${sessao}`), 'segunda conta deve retomar a mesma sessão');
  assert.ok(!inicios[1].args.some((a) => a.startsWith('--session-id')));
  const stdinSegunda = log.filter((e) => e.evento === 'stdin' && e.pid === inicios[1].pid).map((e) => e.msg);
  assert.strictEqual(stdinSegunda[0].request.subtype, 'initialize');
  assert.ok(stdinSegunda[0].request_id.startsWith('claude-auto-'));
  assert.strictEqual(stdinSegunda[0].request.appendSystemPrompt, 'x');
  assert.strictEqual(stdinSegunda[1].request.subtype, 'set_permission_mode');
  assert.strictEqual(stdinSegunda[1].request.mode, 'acceptEdits');
  const continuacao = stdinSegunda.find((m) => m.type === 'user');
  const texto = continuacao.message.content[0].text;
  assert.ok(/Continue exatamente de onde parou/.test(texto));
  assert.ok(texto.includes('resumeFromRunId: "wf_abc123def"'), texto);
  assert.ok(texto.includes('Subagente "pesquisar contratos" (general-purpose)'), texto);
  assert.ok(!stdinSegunda.some((m) => m.type === 'control_response'), 'resposta atrasada para o processo antigo não pode chegar ao novo');

  const trocas = lerTrocas(amb);
  assert.strictEqual(trocas.length, 1);
  assert.deepStrictEqual([trocas[0].de, trocas[0].para, trocas[0].motivo, trocas[0].sessao, trocas[0].interrompidas], ['principal', 'segunda', 'five_hour', sessao, 2]);
  const esgotadas = JSON.parse(fs.readFileSync(path.join(amb.home, '.estado', 'esgotadas.json'), 'utf8'));
  assert.ok(esgotadas.principal && esgotadas.principal.ate > Date.now() + 3500 * 1000);
}

function leitura(usado) {
  const agora = Date.now();
  return { ok: true, ms: 1, verificadoEm: agora, uso: { cinco: { usado, renovaEm: agora + 3600e3 }, sete: { usado: 10, renovaEm: agora + 86400e3 }, janelas: [] } };
}

const esgotadaPorUmaHora = () => ({ ate: Date.now() + 3600e3, motivo: 'five_hour', em: Date.now() });

async function trocaPreventivaNoFimDoTurno() {
  const amb = ambiente({ uso: { principal: leitura(30), segunda: leitura(80) } });
  const sessao = crypto.randomUUID();
  const s = iniciar(amb, [`--session-id=${sessao}`]);
  s.enviar(pedido('init-1', { subtype: 'initialize' }));
  await s.esperar((m) => m.type === 'control_response');
  fs.writeFileSync(path.join(amb.home, '.estado', 'uso.json'), JSON.stringify({ principal: leitura(97), segunda: leitura(80) }));
  s.enviar(usuario('oi'));
  const primeiro = await s.esperar((m) => m.type === 'result');
  assert.strictEqual(primeiro.result, 'ok de principal');
  for (let i = 0; i < 40 && lerTrocas(amb).length === 0; i++) await esperarMs(100);
  s.enviar(usuario('de novo'));
  const segundo = await s.esperar((m) => m.type === 'result' && m !== primeiro);
  s.filho.stdin.end();
  await s.saida;

  assert.strictEqual(segundo.result, 'ok de segunda');
  const trocas = lerTrocas(amb);
  assert.strictEqual(trocas.length, 1);
  assert.strictEqual(trocas[0].motivo, 'preventiva');
  const log = lerLog(amb);
  const inicios = log.filter((e) => e.evento === 'inicio');
  assert.ok(inicios[1].args.includes(`--resume=${sessao}`));
  const usuariosSegunda = log.filter((e) => e.evento === 'stdin' && e.pid === inicios[1].pid && e.msg.type === 'user');
  assert.strictEqual(usuariosSegunda.length, 1, 'troca preventiva não manda mensagem de continuação');
  assert.ok(JSON.stringify(usuariosSegunda[0].msg).includes('de novo'));
}

async function voltaParaAPreferidaEntreTurnos() {
  const amb = ambiente({
    uso: { principal: leitura(30), segunda: leitura(10) },
    esgotadas: { principal: esgotadaPorUmaHora() },
    config: { preferida: 'principal' },
  });
  const sessao = crypto.randomUUID();
  const s = iniciar(amb, [`--session-id=${sessao}`]);
  s.enviar(pedido('init-1', { subtype: 'initialize' }));
  await s.esperar((m) => m.type === 'control_response');
  fs.writeFileSync(path.join(amb.home, '.estado', 'esgotadas.json'), '{}');
  s.enviar(usuario('oi'));
  const primeiro = await s.esperar((m) => m.type === 'result');
  assert.strictEqual(primeiro.result, 'ok de segunda');
  for (let i = 0; i < 40 && lerTrocas(amb).length === 0; i++) await esperarMs(100);
  s.enviar(usuario('de novo'));
  const segundo = await s.esperar((m) => m.type === 'result' && m !== primeiro);
  s.filho.stdin.end();
  await s.saida;

  assert.strictEqual(segundo.result, 'ok de principal');
  const trocas = lerTrocas(amb);
  assert.strictEqual(trocas.length, 1);
  assert.deepStrictEqual([trocas[0].de, trocas[0].para, trocas[0].motivo], ['segunda', 'principal', 'preferida']);
  const inicios = lerLog(amb).filter((e) => e.evento === 'inicio');
  assert.deepStrictEqual(inicios.map((e) => e.conta), ['segunda', 'principal']);
  assert.ok(inicios[1].args.includes(`--resume=${sessao}`));
  const usuariosPrincipal = lerLog(amb).filter((e) => e.evento === 'stdin' && e.pid === inicios[1].pid && e.msg.type === 'user');
  assert.strictEqual(usuariosPrincipal.length, 1, 'a volta não manda mensagem de continuação');
  assert.ok(JSON.stringify(usuariosPrincipal[0].msg).includes('de novo'));
}

async function naoVoltaAbaixoDoLimiteDeVoltaNemAntesDeUmMinuto() {
  const amb = ambiente({
    uso: { principal: leitura(85), segunda: leitura(10) },
    esgotadas: { principal: esgotadaPorUmaHora() },
    config: { preferida: 'principal' },
  });
  const s = iniciar(amb, [`--session-id=${crypto.randomUUID()}`]);
  s.enviar(pedido('init-1', { subtype: 'initialize' }));
  await s.esperar((m) => m.type === 'control_response');
  fs.writeFileSync(path.join(amb.home, '.estado', 'esgotadas.json'), '{}');
  s.enviar(usuario('oi'));
  const primeiro = await s.esperar((m) => m.type === 'result');
  await esperarMs(1000);
  assert.strictEqual(lerTrocas(amb).length, 0, 'folga de 15% não basta para voltar');
  fs.writeFileSync(path.join(amb.home, '.estado', 'uso.json'), JSON.stringify({ principal: leitura(30), segunda: leitura(10) }));
  s.enviar(usuario('de novo'));
  const segundo = await s.esperar((m) => m.type === 'result' && m !== primeiro);
  await esperarMs(1000);
  s.filho.stdin.end();
  await s.saida;

  assert.strictEqual(segundo.result, 'ok de segunda');
  assert.strictEqual(lerTrocas(amb).length, 0, 'a volta só é checada uma vez por minuto');
}

async function naoVoltaComTarefaEmSegundoPlano() {
  const amb = ambiente({
    uso: { principal: leitura(30), segunda: leitura(10) },
    esgotadas: { principal: esgotadaPorUmaHora() },
    config: { preferida: 'principal' },
  });
  const s = iniciar(amb, [`--session-id=${crypto.randomUUID()}`]);
  s.enviar(pedido('init-1', { subtype: 'initialize' }));
  await s.esperar((m) => m.type === 'control_response');
  fs.writeFileSync(path.join(amb.home, '.estado', 'esgotadas.json'), '{}');
  s.enviar(usuario('LANCE_TAREFAS'));
  const resultado = await s.esperar((m) => m.type === 'result');
  await esperarMs(1000);
  s.filho.stdin.end();
  await s.saida;

  assert.strictEqual(resultado.result, 'ok de segunda');
  assert.strictEqual(lerTrocas(amb).length, 0, 'não volta com subagente ou workflow rodando');
}

async function sessaoAbertaVaiParaAContaEscolhidaNoFimDoTurno() {
  const amb = ambiente({ uso: { principal: leitura(10), segunda: leitura(30) } });
  const sessao = crypto.randomUUID();
  const s = iniciar(amb, [`--session-id=${sessao}`]);
  s.enviar(pedido('init-1', { subtype: 'initialize' }));
  await s.esperar((m) => m.type === 'control_response');
  s.enviar(usuario('oi'));
  const primeiro = await s.esperar((m) => m.type === 'result');
  assert.strictEqual(primeiro.result, 'ok de principal');
  // "Usar esta agora" na segunda, com a sessão aberta e parada: ela vai junto, no fim do turno seguinte.
  const cfg = JSON.parse(fs.readFileSync(path.join(amb.home, 'config.json'), 'utf8'));
  fs.writeFileSync(path.join(amb.home, 'config.json'), JSON.stringify({ ...cfg, fixada: 'segunda' }));
  s.enviar(usuario('de novo'));
  const segundo = await s.esperar((m) => m.type === 'result' && m !== primeiro);
  for (let i = 0; i < 40 && lerTrocas(amb).length === 0; i++) await esperarMs(100);
  s.enviar(usuario('mais uma'));
  const terceiro = await s.esperar((m) => m.type === 'result' && m !== primeiro && m !== segundo);
  s.filho.stdin.end();
  await s.saida;

  assert.strictEqual(segundo.result, 'ok de principal');
  assert.strictEqual(terceiro.result, 'ok de segunda');
  const trocas = lerTrocas(amb);
  assert.strictEqual(trocas.length, 1);
  assert.deepStrictEqual([trocas[0].de, trocas[0].para, trocas[0].motivo], ['principal', 'segunda', 'escolhida']);
  const inicios = lerLog(amb).filter((e) => e.evento === 'inicio');
  assert.ok(inicios[1].args.includes(`--resume=${sessao}`));
}

async function contaEscolhidaQuaseSemFolgaNaoLevaASessao() {
  const amb = ambiente({ uso: { principal: leitura(10), segunda: leitura(98) } });
  const s = iniciar(amb, [`--session-id=${crypto.randomUUID()}`]);
  s.enviar(pedido('init-1', { subtype: 'initialize' }));
  await s.esperar((m) => m.type === 'control_response');
  const cfg = JSON.parse(fs.readFileSync(path.join(amb.home, 'config.json'), 'utf8'));
  fs.writeFileSync(path.join(amb.home, 'config.json'), JSON.stringify({ ...cfg, fixada: 'segunda' }));
  s.enviar(usuario('oi'));
  const primeiro = await s.esperar((m) => m.type === 'result');
  await esperarMs(1000);
  s.enviar(usuario('de novo'));
  const segundo = await s.esperar((m) => m.type === 'result' && m !== primeiro);
  await esperarMs(1000);
  s.filho.stdin.end();
  await s.saida;
  // Com 2% de folga a preventiva a tiraria de novo no turno seguinte: a sessão fica onde está, sem ir e voltar.
  assert.strictEqual(segundo.result, 'ok de principal');
  assert.strictEqual(lerTrocas(amb).length, 0);
}

async function pedidoDoHostDuranteATrocaChegaUmaVez() {
  const amb = ambiente({ limitadas: 'principal', extra: { FAKE_SIGTERM_MS: '800' } });
  const s = iniciar(amb, [`--session-id=${crypto.randomUUID()}`]);
  s.enviar(pedido('init-1', { subtype: 'initialize' }));
  await s.esperar((m) => m.type === 'control_response' && m.response.request_id === 'init-1');
  s.enviar(usuario('oi'));
  await esperarMs(200);
  s.enviar(pedido('modelo-1', { subtype: 'set_model', model: 'x' }));
  await s.esperar((m) => m.type === 'result');
  await s.esperar((m) => m.type === 'control_response' && m.response.request_id === 'modelo-1');
  await esperarMs(300);
  s.filho.stdin.end();
  await s.saida;

  assert.strictEqual(lerTrocas(amb).length, 1);
  const inicios = lerLog(amb).filter((e) => e.evento === 'inicio');
  const pedidosSegunda = lerLog(amb).filter((e) => e.evento === 'stdin' && e.pid === inicios[1].pid && e.msg.request_id === 'modelo-1');
  assert.strictEqual(pedidosSegunda.length, 1, 'pedido feito durante a troca chegou mais de uma vez ao processo novo');
  assert.strictEqual(s.recebidas.filter((m) => m.type === 'control_response' && m.response.request_id === 'modelo-1').length, 1);
}

async function respostaAtrasadaDoProcessoAntigoChegaAoHost() {
  const amb = ambiente({ limitadas: 'principal' });
  const s = iniciar(amb, [`--session-id=${crypto.randomUUID()}`]);
  s.enviar(pedido('init-1', { subtype: 'initialize' }));
  await s.esperar((m) => m.type === 'control_response' && m.response.request_id === 'init-1');
  s.enviar(pedido('lento-1', { subtype: 'atrasar' }));
  s.enviar(usuario('oi'));
  await s.esperar((m) => m.type === 'result');
  await s.esperar((m) => m.type === 'control_response' && m.response.request_id === 'lento-1', 3000);
  await esperarMs(200);
  s.filho.stdin.end();
  await s.saida;

  assert.strictEqual(lerTrocas(amb).length, 1);
  assert.strictEqual(s.recebidas.filter((m) => m.type === 'control_response' && m.response.request_id === 'lento-1').length, 1);
}

async function soErroDaContaDisparaTroca() {
  const { Proxy } = require('../lib/proxy');
  const proxy = new Proxy([]);
  const resultado = (texto) => proxy.gatilhoDeTroca({ type: 'result', is_error: true, result: texto });
  assert.strictEqual(resultado('MCP server github: authentication failed, check the OAuth token'), null);
  assert.strictEqual(resultado('Billing dashboard request failed'), null);
  assert.strictEqual(resultado('Invalid API key · Please run /login').motivo, 'auth');
  assert.strictEqual(resultado('Claude AI usage limit reached|1760000000').motivo, 'rate_limit');
  assert.strictEqual(resultado('Credit balance is too low').motivo, 'rate_limit');
}

async function semOutraContaRepassaOErro() {
  const amb = ambiente({ contas: ['principal'], limitadas: 'principal' });
  const s = iniciar(amb, [`--session-id=${crypto.randomUUID()}`]);
  s.enviar(pedido('init-1', { subtype: 'initialize' }));
  s.enviar(usuario('oi'));
  const resultado = await s.esperar((m) => m.type === 'result');
  s.filho.stdin.end();
  await s.saida;
  assert.strictEqual(resultado.is_error, true);
  assert.ok(s.recebidas.some((m) => m.type === 'rate_limit_event'));
  assert.strictEqual(lerTrocas(amb).length, 0);
}

async function threadDoT3RetomaASessaoAnterior() {
  const amb = ambiente();
  const projeto = path.join(amb.dir, 'projeto');
  fs.mkdirSync(projeto);
  const anterior = crypto.randomUUID();
  const nova = crypto.randomUUID();
  const banco = path.join(amb.dir, 't3.sqlite');
  execFileSync('/usr/bin/sqlite3', [banco, `
    CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT PRIMARY KEY, thread_id TEXT, owner_node_id TEXT, provider TEXT NOT NULL, provider_session_id TEXT, status TEXT NOT NULL, first_run_ordinal INTEGER, last_run_ordinal INTEGER, updated_at TEXT NOT NULL, payload_json TEXT NOT NULL);
    INSERT INTO orchestration_v2_projection_provider_threads VALUES ('pt1','th1',NULL,'claudeAgent',NULL,'idle',1,3,'2026-10-07T10:00:00Z','{"nativeThreadRef":{"nativeId":"${anterior}"}}');
    INSERT INTO orchestration_v2_projection_provider_threads VALUES ('pt2','th1',NULL,'claudeAgent',NULL,'running',4,4,'2026-10-07T11:00:00Z','{"nativeThreadRef":{"nativeId":"${nova}"}}');
    INSERT INTO orchestration_v2_projection_provider_threads VALUES ('pt3','th2',NULL,'claudeAgent',NULL,'idle',1,1,'2026-10-07T12:00:00Z','{"nativeThreadRef":{"nativeId":"${crypto.randomUUID()}"}}');`]);
  const dirProjeto = path.join(amb.casa, '.claude', 'projects', fs.realpathSync(projeto).replace(/[^a-zA-Z0-9]/g, '-'));
  fs.mkdirSync(dirProjeto, { recursive: true });
  fs.writeFileSync(path.join(dirProjeto, `${anterior}.jsonl`), '{}\n');
  {
    amb.env.CLAUDE_AUTO_T3_DB = banco;
    const s = iniciar(amb, [`--session-id=${nova}`], fs.realpathSync(projeto));
    s.enviar(pedido('init-1', { subtype: 'initialize' }));
    await s.esperar((m) => m.type === 'control_response');
    s.filho.stdin.end();
    await s.saida;
    const args = lerLog(amb).find((e) => e.evento === 'inicio').args;
    assert.ok(args.includes(`--resume=${anterior}`), args.join(' '));
    assert.ok(args.includes('--fork-session'));
    assert.ok(args.includes(`--session-id=${nova}`));
  }
}

// Cenários sem processo: o Proxy direto, com a leitura e a escolha de contas trocadas por dublês.
function proxyEmProcesso(config) {
  const contas = require('../lib/contas');
  const { Proxy } = require('../lib/proxy');
  fs.writeFileSync(path.join(HOME_EM_PROCESSO, 'config.json'), JSON.stringify(config));
  const p = new Proxy([]);
  // Aberta no ~/.claude na conta "principal", que a troca dos agentes depois tirou de lá.
  p.conta = 'principal';
  p.contaDaAbertura = 'principal';
  p.noClaudePadrao = true;
  return { contas, p };
}

async function comDubles(obj, dubles, fn) {
  const originais = Object.fromEntries(Object.keys(dubles).map((k) => [k, obj[k]]));
  Object.assign(obj, dubles);
  try {
    await fn();
  } finally {
    Object.assign(obj, originais);
  }
}

async function limiteNaContaQueEntrouNoClaudeMarcaEssaConta() {
  const { contas, p } = proxyEmProcesso({ principal: 'segunda', contas: { principal: {}, segunda: {} }, rota: ['principal', 'segunda'] });
  const marcadas = [];
  const excluidas = [];
  await comDubles(contas, {
    log() {},
    marcarEsgotada: (id) => marcadas.push(id),
    escolher: async ({ excluir = [] } = {}) => {
      excluidas.push(...excluir);
      return { escolhida: null, candidatos: [] };
    },
  }, () => p.avaliarTroca({ motivo: 'five_hour', ate: null, continuar: false }, p.geracao));
  // A segunda entrou no ~/.claude no meio do turno: o limite é dela, e é dela que a sessão sai.
  assert.deepStrictEqual(marcadas, ['segunda']);
  assert.deepStrictEqual(excluidas, ['segunda']);
}

async function contaQueSaiuDoClaudeVoltaParaAPastaPropria() {
  const { contas, p } = proxyEmProcesso({ principal: 'segunda', contas: { principal: {}, segunda: {} }, rota: ['principal', 'segunda'] });
  const trocas = [];
  p.trocar = async (t) => trocas.push([t.para, t.motivo]);
  await comDubles(contas, { log() {}, temLoginProprio: () => true }, () => p.checarPreventiva());
  assert.deepStrictEqual(trocas, [['principal', 'saiu-do-claude']]);
}

async function escolhaAMaoVemAntesDaVoltaParaAPastaPropria() {
  const { contas, p } = proxyEmProcesso({
    principal: 'segunda',
    fixada: 'terceira',
    contas: { principal: {}, segunda: {}, terceira: {} },
    rota: ['principal', 'segunda', 'terceira'],
  });
  const trocas = [];
  p.trocar = async (t) => trocas.push([t.para, t.motivo]);
  await comDubles(contas, {
    log() {},
    temLoginProprio: () => true,
    escolher: async () => ({ escolhida: 'terceira', candidatos: [{ id: 'terceira', folga: 80 }] }),
  }, () => p.checarPreventiva());
  // "Usar esta agora" na terceira: a sessão vai direto para lá, sem antes reabrir na pasta da própria conta.
  assert.deepStrictEqual(trocas, [['terceira', 'escolhida']]);
}

async function loginRecusadoNaPastaPropriaVoltaParaOClaudeSemMarcarAConta() {
  const { contas, p } = proxyEmProcesso({ principal: 'principal', contas: { principal: {}, segunda: {} }, rota: ['principal', 'segunda'] });
  p.noClaudePadrao = false;
  p.naPastaPropria = true;
  const marcadas = [];
  const trocas = [];
  p.trocar = async (t) => {
    trocas.push([t.para, t.motivo, t.forcada]);
    p.naPastaPropria = false;
    p.noClaudePadrao = true;
  };
  const dubles = {
    log() {},
    marcarEsgotada: (id) => marcadas.push(id),
    escolher: async () => ({ escolhida: 'segunda', candidatos: [] }),
    temLoginProprio: () => true,
  };
  await comDubles(contas, dubles, () => p.avaliarTroca({ motivo: 'auth', ate: null, continuar: true }, p.geracao));
  // O login da pasta própria foi recusado: a sessão volta para o ~/.claude, na mesma conta, que não é marcada.
  assert.deepStrictEqual(trocas, [['principal', 'login-da-pasta-propria', true]]);
  assert.deepStrictEqual(marcadas, []);
  // E os relançamentos desta sessão nessa conta não voltam para a pasta própria.
  await comDubles(contas, { envDaSessao: () => ({ CLAUDE_CONFIG_DIR: '/propria' }), envDaConta: () => ({}) }, async () => {
    assert.strictEqual(p.envDaAbertura().CLAUDE_CONFIG_DIR, undefined);
  });
  // Se o login do ~/.claude também for recusado, aí sim a conta é marcada.
  await comDubles(contas, dubles, () => p.avaliarTroca({ motivo: 'auth', ate: null, continuar: true }, p.geracao));
  assert.deepStrictEqual(marcadas, ['principal']);
  assert.deepStrictEqual(trocas[1], ['segunda', 'auth', true]);
}

async function semLoginProprioASessaoVoltaAContarComoDaSuaSemReabrir() {
  const { contas, p } = proxyEmProcesso({ principal: 'segunda', contas: { principal: {}, segunda: {} }, rota: ['principal', 'segunda'] });
  const trocas = [];
  const consultadas = [];
  p.trocar = async (t) => trocas.push([t.para, t.motivo]);
  await comDubles(contas, {
    log() {},
    // Só a segunda tem login na pasta própria; a principal, em que a sessão abriu, não.
    temLoginProprio: (id) => (consultadas.push(id), id === 'segunda'),
  }, async () => {
    // A segunda entrou no ~/.claude: sem login próprio, a sessão passa a contar como dela.
    assert.strictEqual(await p.checarSlot({ principal: 'segunda' }), false);
    assert.strictEqual(p.conta, 'segunda');
    // A principal voltou: a sessão volta a contar como dela, sem reabrir na pasta da segunda.
    assert.strictEqual(await p.checarSlot({ principal: 'principal' }), false);
    assert.strictEqual(p.conta, 'principal');
  });
  assert.deepStrictEqual(trocas, []);
  assert.deepStrictEqual(consultadas, ['principal']);
}

async function loginFeitoDepoisLevaASessaoParaAPastaPropria() {
  const { contas, p } = proxyEmProcesso({ principal: 'segunda', contas: { principal: {}, segunda: {} }, rota: ['principal', 'segunda'] });
  const trocas = [];
  const consultas = [];
  let temLogin = false;
  p.trocar = async (t) => trocas.push([t.para, t.motivo]);
  await comDubles(contas, {
    log() {},
    temLoginProprio: (id, cfg, opcoes) => (consultas.push([id, Boolean(opcoes && opcoes.fresco)]), temLogin),
  }, async () => {
    // Sem login próprio: a sessão passa a contar como da segunda.
    assert.strictEqual(await p.checarSlot({ principal: 'segunda' }), false);
    assert.strictEqual(p.conta, 'segunda');
    // A pessoa faz o login na pasta da principal: antes de um minuto, a sessão não consulta de novo.
    temLogin = true;
    assert.strictEqual(await p.checarSlot({ principal: 'segunda' }), false);
    assert.strictEqual(consultas.length, 1);
    // Passado o minuto, consulta sem o guardado e volta para a pasta própria.
    p.ultimaChecagemDoSlot -= 61 * 1000;
    assert.strictEqual(await p.checarSlot({ principal: 'segunda' }), true);
  });
  assert.deepStrictEqual(consultas, [['principal', true], ['principal', true]]);
  assert.deepStrictEqual(trocas, [['principal', 'saiu-do-claude']]);
}

(async () => {
  const cenarios = [trocaForcadaNoMeioDoTurno, trocaPreventivaNoFimDoTurno, voltaParaAPreferidaEntreTurnos, naoVoltaAbaixoDoLimiteDeVoltaNemAntesDeUmMinuto, naoVoltaComTarefaEmSegundoPlano, sessaoAbertaVaiParaAContaEscolhidaNoFimDoTurno, contaEscolhidaQuaseSemFolgaNaoLevaASessao, pedidoDoHostDuranteATrocaChegaUmaVez, respostaAtrasadaDoProcessoAntigoChegaAoHost, soErroDaContaDisparaTroca, semOutraContaRepassaOErro, threadDoT3RetomaASessaoAnterior, limiteNaContaQueEntrouNoClaudeMarcaEssaConta, contaQueSaiuDoClaudeVoltaParaAPastaPropria, escolhaAMaoVemAntesDaVoltaParaAPastaPropria, loginRecusadoNaPastaPropriaVoltaParaOClaudeSemMarcarAConta, semLoginProprioASessaoVoltaAContarComoDaSuaSemReabrir, loginFeitoDepoisLevaASessaoParaAPastaPropria];
  let falhas = 0;
  for (const cenario of cenarios) {
    try {
      await cenario();
      console.log(`ok    ${cenario.name}`);
    } catch (e) {
      falhas++;
      console.log(`FALHA ${cenario.name}\n${e.message}\n${e.stack.split("\n").slice(1, 3).join("\n")}`);
    }
  }
  fs.rmSync(HOME_EM_PROCESSO, { recursive: true, force: true });
  process.exit(falhas ? 1 : 0);
})();
