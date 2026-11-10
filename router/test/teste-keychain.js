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

async function comPerfis(fn) {
  const original = global.fetch;
  global.fetch = async (_url, { headers }) => {
    const id = headers.Authorization.replace('Bearer token-', '');
    return { ok: true, status: 200, json: async () => ({ account: { uuid: `u-${id}` }, organization: { uuid: `o-${id}` } }) };
  };
  try {
    return await fn();
  } finally {
    global.fetch = original;
  }
}

const testes = {
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
  async trocaParaAContaQueJaEstaNoSlotNaoGrava() {
    cenario(comItemDeOutraContaNaFrente());
    const antes = keychain();
    const troca = await comPerfis(() => agentes.trocarSlot('principal'));
    assert.strictEqual(troca.mudou, false);
    assert.deepStrictEqual(keychain(), antes);
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
