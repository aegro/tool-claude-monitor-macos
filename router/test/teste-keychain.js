'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

require('./ambiente-limpo');

const raiz = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-auto-keychain-'));
process.env.CLAUDE_AUTO_HOME = path.join(raiz, 'contas');
process.env.CLAUDE_AUTO_SLOT_DIR = path.join(raiz, 'slot');
process.env.FAKE_KEYCHAIN = path.join(raiz, 'keychain.json');
const bin = path.join(raiz, 'bin');
fs.mkdirSync(bin, { recursive: true });
fs.writeFileSync(path.join(bin, 'security'), `#!/bin/sh\nexec "${process.execPath}" "${path.join(__dirname, 'fake-security.js')}" "$@"\n`, { mode: 0o755 });
process.env.PATH = `${bin}:${process.env.PATH}`;
process.env.CLAUDE_AUTO_CLAUDE_BIN = path.join(__dirname, 'fake-claude-agentes.js');
process.env.FAKE_AGENTES = path.join(raiz, 'agentes.json');
process.env.FAKE_AGENTES_LOG = path.join(raiz, 'agentes.log');

const agentes = require('../lib/agentes');
const contas = require('../lib/contas');

const usuario = contas.CONTA_KEYCHAIN;
const servicoDaSegunda = `claude-auto agents ${agentes.SERVICO_SLOT.slice(-8)} segunda`;
const contaDe = (id) => ({ accountUuid: `u-${id}`, organizationUuid: `o-${id}` });
const daqui = Date.now() + 3600000;
const mcp = { 'servidor|1': { accessToken: 'mcp', refreshToken: 'mcp-r' } };
const slotDaPrincipal = JSON.stringify({ mcpOAuth: mcp, claudeAiOauth: { accessToken: 'token-principal', refreshToken: 'r1', expiresAt: daqui } });
const loginDaSegunda = JSON.stringify({ claudeAiOauth: { accessToken: 'token-segunda', refreshToken: 'r2', expiresAt: daqui } });
const itemSemLogin = JSON.stringify({ mcpOAuth: mcp });

const keychain = () => JSON.parse(fs.readFileSync(process.env.FAKE_KEYCHAIN, 'utf8'));
const itemDe = (conta, servico) => (keychain().find((i) => i.conta === conta && i.servico === servico) || {}).texto;

function cenario(itens) {
  fs.rmSync(process.env.CLAUDE_AUTO_HOME, { recursive: true, force: true });
  fs.mkdirSync(path.join(process.env.CLAUDE_AUTO_HOME, '.estado', 'agentes'), { recursive: true });
  fs.mkdirSync(process.env.CLAUDE_AUTO_SLOT_DIR, { recursive: true });
  fs.writeFileSync(
    path.join(process.env.CLAUDE_AUTO_HOME, 'config.json'),
    JSON.stringify({ contas: { principal: {}, segunda: {} }, rota: ['principal', 'segunda'], principal: 'principal', notificar: false }),
  );
  for (const id of ['principal', 'segunda']) {
    const conta = contaDe(id);
    fs.writeFileSync(
      path.join(process.env.CLAUDE_AUTO_HOME, '.estado', 'agentes', `${id}.json`),
      JSON.stringify({ oauthAccount: conta, chave: `${conta.accountUuid}:${conta.organizationUuid}`, guardadoEm: Date.now() }),
    );
  }
  fs.writeFileSync(path.join(process.env.CLAUDE_AUTO_SLOT_DIR, '.claude.json'), JSON.stringify({ oauthAccount: contaDe('principal') }));
  fs.writeFileSync(process.env.FAKE_KEYCHAIN, JSON.stringify(itens));
}

const comItemDeOutraContaNaFrente = () => [
  { conta: 'unknown', servico: agentes.SERVICO_SLOT, texto: itemSemLogin },
  { conta: usuario, servico: agentes.SERVICO_SLOT, texto: slotDaPrincipal },
  { conta: usuario, servico: servicoDaSegunda, texto: loginDaSegunda },
];

async function comPerfis(fn, { recusados = [], semResposta = false } = {}) {
  const original = global.fetch;
  global.fetch = async (_url, { headers }) => {
    const id = headers.Authorization.replace('Bearer token-', '');
    if (semResposta) throw new Error('network down');
    if (recusados.includes(id)) return { ok: false, status: 401, json: async () => ({}) };
    return { ok: true, status: 200, json: async () => ({ account: { uuid: `u-${id}` }, organization: { uuid: `o-${id}` } }) };
  };
  try {
    return await fn();
  } finally {
    global.fetch = original;
  }
}

const cwdDoAgente = '/Users/exemplo/projeto';
const transcriptDe = (sessionId) =>
  path.join(process.env.CLAUDE_AUTO_SLOT_DIR, 'projects', cwdDoAgente.replace(/[^a-zA-Z0-9]/g, '-'), `${sessionId}.jsonl`);
const slotDaPrincipalVencido = JSON.stringify({ mcpOAuth: mcp, claudeAiOauth: { accessToken: 'token-principal', refreshToken: 'r1', expiresAt: Date.now() - 60000 } });

function agenteParadoPorLogin(sessionId, quando) {
  const arquivo = transcriptDe(sessionId);
  fs.mkdirSync(path.dirname(arquivo), { recursive: true });
  const entradas = [
    { type: 'user', timestamp: new Date(quando - 10000).toISOString(), message: { role: 'user', content: 'trabalhe' } },
    { type: 'assistant', isApiErrorMessage: true, error: 'authentication_failed', timestamp: new Date(quando).toISOString(), message: { role: 'assistant', content: [{ type: 'text', text: 'Login reached its time limit · Please run /login' }] } },
  ];
  fs.appendFileSync(arquivo, entradas.map((e) => JSON.stringify(e)).join('\n') + '\n');
  process.env.FAKE_TRANSCRIPT = arquivo;
  fs.writeFileSync(
    process.env.FAKE_AGENTES,
    JSON.stringify([{ id: 'a1', sessionId, name: 'Agente', cwd: cwdDoAgente, kind: 'background', status: 'idle', startedAt: Date.now() - 3600000 }]),
  );
}

function cenarioDosAgentes(slot) {
  cenario([
    { conta: usuario, servico: agentes.SERVICO_SLOT, texto: slot },
    { conta: usuario, servico: servicoDaSegunda, texto: loginDaSegunda },
  ]);
  const uso = { ok: true, verificadoEm: Date.now(), uso: { cinco: { usado: 10, renovaEm: Date.now() + 3600000 }, sete: { usado: 15, renovaEm: Date.now() + 86400000 }, janelas: [] } };
  fs.writeFileSync(path.join(contas.DIR_ESTADO, 'uso.json'), JSON.stringify({ principal: uso, segunda: uso, 'agents segunda': uso }));
  fs.writeFileSync(process.env.FAKE_AGENTES_LOG, '');
}

const eventosDoFake = () => fs.readFileSync(process.env.FAKE_AGENTES_LOG, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
const ultimaTroca = () => JSON.parse(fs.readFileSync(path.join(contas.DIR_ESTADO, 'trocas.jsonl'), 'utf8').trim().split('\n').pop());
const tokenNoSlot = () => JSON.parse(itemDe(usuario, agentes.SERVICO_SLOT)).claudeAiOauth.accessToken;

const testes = {
  async loginDoSlotRecusadoVencidoOuVivo() {
    const paradas = [{ motivo: 'auth', quando: Date.now() - 1000 }];
    cenario([{ conta: usuario, servico: agentes.SERVICO_SLOT, texto: slotDaPrincipalVencido }]);
    assert.strictEqual(await comPerfis(() => agentes.situacaoDoLoginNoSlot({}, paradas)), 'morto');
    cenario([{ conta: usuario, servico: agentes.SERVICO_SLOT, texto: slotDaPrincipal }]);
    assert.strictEqual(await comPerfis(() => agentes.situacaoDoLoginNoSlot({}, paradas), { recusados: ['principal'] }), 'morto');
    assert.strictEqual(await comPerfis(() => agentes.situacaoDoLoginNoSlot({}, paradas), { semResposta: true }), 'sem-conferencia');
    const estado = {};
    assert.strictEqual(await comPerfis(() => agentes.situacaoDoLoginNoSlot(estado, paradas)), 'vivo');
    assert.strictEqual(estado.loginVivoApesarDoErro.impressao, agentes.impressaoDoLogin(slotDaPrincipal));
    const recusadaDeNovo = [{ motivo: 'auth', quando: estado.loginVivoApesarDoErro.em + 1000 }];
    assert.strictEqual(await comPerfis(() => agentes.situacaoDoLoginNoSlot(estado, recusadaDeNovo)), 'morto');
    assert.strictEqual(await comPerfis(() => agentes.situacaoDoLoginNoSlot(estado, paradas)), 'vivo');
  },
  async vigiaTrocaOSlotERetomaQuandoOLoginDosAgentesCai() {
    cenarioDosAgentes(slotDaPrincipalVencido);
    agenteParadoPorLogin('s-login', Date.now() - 60000);
    const r = await comPerfis(() => agentes.vigiar());
    assert.strictEqual(r.acao, 'retomou');
    assert.deepStrictEqual({ de: r.troca.de, para: r.troca.para, mudou: r.troca.mudou }, { de: 'principal', para: 'segunda', mudou: true });
    assert.deepStrictEqual(r.retomados, ['Agente']);
    assert.strictEqual(tokenNoSlot(), 'token-segunda');
    assert.strictEqual(ultimaTroca().motivo, 'agents auth');
    assert.ok(agentes.loginGuardado('principal').invalidoEm);
    assert.strictEqual(agentes.loginUtilizavel(agentes.loginGuardado('segunda')), true);
    assert.strictEqual(contas.lerJson(path.join(contas.DIR_ESTADO, 'esgotadas.json'), {}).principal, undefined);
    const continuacao = eventosDoFake().find((e) => e.evento === 'continuar');
    assert.strictEqual(continuacao.texto, agentes.CONTINUAR_DEPOIS_DO_LOGIN);
    const r2 = await comPerfis(() => agentes.vigiar());
    assert.notStrictEqual(r2.acao, 'retomou');
    assert.strictEqual(tokenNoSlot(), 'token-segunda');
  },
  async vigiaSoRetomaComOLoginRefeitoETrocaSeEleCairDeNovo() {
    cenarioDosAgentes(slotDaPrincipal);
    agenteParadoPorLogin('s-refeito', Date.now() - 60000);
    const r = await comPerfis(() => agentes.vigiar());
    assert.strictEqual(r.acao, 'retomou');
    assert.strictEqual(r.troca, null);
    assert.strictEqual(tokenNoSlot(), 'token-principal');
    assert.strictEqual(agentes.loginGuardado('principal').invalidoEm, undefined);
    agenteParadoPorLogin('s-refeito', Date.now());
    const r2 = await comPerfis(() => agentes.vigiar());
    assert.strictEqual(r2.acao, 'retomou');
    assert.deepStrictEqual({ de: r2.troca.de, para: r2.troca.para }, { de: 'principal', para: 'segunda' });
    assert.strictEqual(tokenNoSlot(), 'token-segunda');
  },
  async vigiaEsperaQuandoNaoDaParaConferirOLoginDoSlot() {
    cenarioDosAgentes(slotDaPrincipal);
    agenteParadoPorLogin('s-sem-rede', Date.now() - 60000);
    const r = await comPerfis(() => agentes.vigiar(), { semResposta: true });
    assert.strictEqual(r.acao, 'adiada');
    assert.strictEqual(tokenNoSlot(), 'token-principal');
    assert.deepStrictEqual(eventosDoFake(), []);
  },
  async slotLidoPelaContaDoUsuarioComOutroItemNaFrente() {
    cenario(comItemDeOutraContaNaFrente());
    fs.writeFileSync(path.join(process.env.CLAUDE_AUTO_SLOT_DIR, '.claude.json'), JSON.stringify({ oauthAccount: contaDe('segunda') }));
    assert.strictEqual(await comPerfis(() => agentes.contaRealNoSlot()), 'principal');
  },
  async trocaDoSlotComOutroItemNaFrente() {
    cenario(comItemDeOutraContaNaFrente());
    const troca = await comPerfis(() => agentes.trocarSlot('segunda'));
    assert.deepStrictEqual({ de: troca.de, para: troca.para, mudou: troca.mudou }, { de: 'principal', para: 'segunda', mudou: true });
    const slot = JSON.parse(itemDe(usuario, agentes.SERVICO_SLOT));
    assert.strictEqual(slot.claudeAiOauth.accessToken, 'token-segunda');
    assert.deepStrictEqual(slot.mcpOAuth, mcp);
    assert.strictEqual(itemDe('unknown', agentes.SERVICO_SLOT), itemSemLogin);
    const config = JSON.parse(fs.readFileSync(path.join(process.env.CLAUDE_AUTO_SLOT_DIR, '.claude.json'), 'utf8'));
    assert.deepStrictEqual(config.oauthAccount, contaDe('segunda'));
    assert.strictEqual(await comPerfis(() => agentes.contaRealNoSlot()), 'segunda');
  },
  async preventivaEsperaLeituraNovaDepoisDaTrocaAMao() {
    const usoQuaseNoLimite = { cinco: { usado: 98, renovaEm: Date.now() + 3600000 }, sete: { usado: 50, renovaEm: Date.now() + 86400000 }, janelas: [] };
    const usoComFolga = { cinco: { usado: 10, renovaEm: Date.now() + 3600000 }, sete: { usado: 10, renovaEm: Date.now() + 86400000 }, janelas: [] };
    const preparar = () => {
      cenario(comItemDeOutraContaNaFrente());
      const recusada = { ok: false, erro: 'HTTP 429', limitada: true, esperarAte: Date.now() + 3600000, verificadoEm: Date.now(), uso: usoQuaseNoLimite, usoDe: Date.now() - 3600000 };
      const fresca = { ok: true, verificadoEm: Date.now(), uso: usoComFolga };
      fs.writeFileSync(
        path.join(contas.DIR_ESTADO, 'uso.json'),
        JSON.stringify({ principal: recusada, segunda: fresca, 'agents principal': recusada, 'agents segunda': fresca }),
      );
    };
    const preventiva = (estado) => comPerfis(() => agentes.trocarPreventiva(contas.carregarConfig(), [{ kind: 'background' }], estado));

    preparar();
    const comEscolha = { escolhaManual: { conta: 'principal', em: Date.now() - 1000 } };
    assert.strictEqual(await preventiva(comEscolha), null);
    assert.strictEqual(JSON.parse(itemDe(usuario, agentes.SERVICO_SLOT)).claudeAiOauth.accessToken, 'token-principal');

    preparar();
    const chave = `${contaDe('principal').accountUuid}:${contaDe('principal').organizationUuid}`;
    fs.writeFileSync(
      path.join(contas.DIR_ESTADO, 'ritmo.json'),
      JSON.stringify({ conta: chave, janela: 'cinco', ppPorMinuto: 0, em: Date.now(), usado: 10, usadoEm: Date.now() }),
    );
    assert.strictEqual(await preventiva({ escolhaManual: { conta: 'principal', em: Date.now() - 1000 } }), null);
    assert.strictEqual(JSON.parse(itemDe(usuario, agentes.SERVICO_SLOT)).claudeAiOauth.accessToken, 'token-principal');
    fs.rmSync(path.join(contas.DIR_ESTADO, 'ritmo.json'));

    preparar();
    const troca = await preventiva({});
    assert.deepStrictEqual({ de: troca.de, para: troca.para, mudou: troca.mudou }, { de: 'principal', para: 'segunda', mudou: true });
  },
  async trocaParaAContaQueJaEstaNoSlotNaoGrava() {
    cenario(comItemDeOutraContaNaFrente());
    const antes = keychain();
    const troca = await comPerfis(() => agentes.trocarSlot('principal'));
    assert.strictEqual(troca.mudou, false);
    assert.deepStrictEqual(keychain(), antes);
  },
  async loginDaPastaGuardadoEApagadoSoNaContaDoUsuario() {
    const dir = path.join(raiz, 'login-novo');
    const servico = contas.servicoDoDir(dir);
    cenario([
      { conta: 'unknown', servico, texto: itemSemLogin },
      { conta: usuario, servico, texto: loginDaSegunda },
    ]);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, '.claude.json'), JSON.stringify({ oauthAccount: contaDe('segunda') }));
    assert.deepStrictEqual(await agentes.guardarLoginDoDir('segunda', dir), contaDe('segunda'));
    assert.strictEqual(JSON.parse(itemDe(usuario, servicoDaSegunda)).claudeAiOauth.accessToken, 'token-segunda');
    assert.strictEqual(itemDe(usuario, servico), undefined);
    assert.strictEqual(itemDe('unknown', servico), itemSemLogin);
  },
  credencialDaPastaLidaPelaContaDoUsuario: async () => {
    if (process.platform !== 'darwin') return;
    const dir = path.join(raiz, 'pasta-da-conta');
    const servico = contas.servicoDoDir(dir);
    cenario([
      { conta: 'unknown', servico, texto: itemSemLogin },
      { conta: usuario, servico, texto: loginDaSegunda },
    ]);
    assert.strictEqual(await contas.lerItemDaPasta(dir, servico), loginDaSegunda);
  },
  usuarioNoAmbienteDosFilhos() {
    assert.deepStrictEqual(contas.garantirUsuario({}), { USER: usuario, LOGNAME: usuario });
    assert.deepStrictEqual(contas.garantirUsuario({ USER: 'outro', LOGNAME: 'outro' }), { USER: 'outro', LOGNAME: 'outro' });
    const script = `const a = require(${JSON.stringify(require.resolve('../lib/agentes'))}); const e = a.envDoSlot(); console.log(JSON.stringify([e.USER, e.LOGNAME]));`;
    const saida = execFileSync('/usr/bin/env', ['-i', `HOME=${os.homedir()}`, `CLAUDE_AUTO_HOME=${process.env.CLAUDE_AUTO_HOME}`, process.execPath, '-e', script], { encoding: 'utf8' });
    assert.deepStrictEqual(JSON.parse(saida), [os.userInfo().username, os.userInfo().username]);
  },
};

(async () => {
  let falhas = 0;
  for (const [nome, teste] of Object.entries(testes)) {
    try {
      await teste();
      console.log(`ok    ${nome}`);
    } catch (e) {
      falhas += 1;
      console.log(`FALHA ${nome}\n  ${e.message}`);
    }
  }
  fs.rmSync(raiz, { recursive: true, force: true });
  process.exit(falhas ? 1 : 0);
})();
