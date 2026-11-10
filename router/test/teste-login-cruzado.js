'use strict';

// Pastas da fila com o login de outra conta (10/11/2026): a da Aegro ficou com o login da Max, a da Max com o da
// Aegro e a da Squad Compare com o da Aegro. A conta não recebe sessão nem é lida com o token que está na pasta.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

require('./ambiente-limpo');

const raiz = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-auto-cruzado-'));
process.env.CLAUDE_AUTO_HOME = path.join(raiz, 'contas');
process.env.FAKE_KEYCHAIN = path.join(raiz, 'keychain.json');
const bin = path.join(raiz, 'bin');
fs.mkdirSync(bin, { recursive: true });
fs.writeFileSync(path.join(bin, 'security'), `#!/bin/sh\nexec "${process.execPath}" "${path.join(__dirname, 'fake-security.js')}" "$@"\n`, { mode: 0o755 });
process.env.PATH = `${bin}:${process.env.PATH}`;

const contas = require('../lib/contas');

const IDS = ['aegro', 'max', 'compare'];
const contaDe = (id) => ({ accountUuid: id === 'compare' ? 'u-squad' : 'u-thomas', organizationUuid: `o-${id}`, emailAddress: `${id}@exemplo`, organizationName: `Org ${id}` });
const chaveDe = (id) => `${contaDe(id).accountUuid}:${contaDe(id).organizationUuid}`;
const dirDe = (id) => path.join(process.env.CLAUDE_AUTO_HOME, id);
const daqui = Date.now() + 3600000;

// `pastas` diz de quem é o login em cada pasta; cada conta tem o próprio login guardado pela troca dos agentes.
function cenario(pastas) {
  fs.rmSync(process.env.CLAUDE_AUTO_HOME, { recursive: true, force: true });
  fs.mkdirSync(path.join(process.env.CLAUDE_AUTO_HOME, '.estado', 'agentes'), { recursive: true });
  // A Max tem pasta declarada: nenhuma conta do teste mora no ~/.claude de quem roda a suíte.
  fs.writeFileSync(
    path.join(process.env.CLAUDE_AUTO_HOME, 'config.json'),
    JSON.stringify({ contas: { aegro: {}, max: { dir: dirDe('max') }, compare: {} }, rota: ['aegro', 'max'], reserva: ['compare'], principal: 'max', notificar: false }),
  );
  const itens = [];
  for (const id of IDS) {
    fs.writeFileSync(
      path.join(process.env.CLAUDE_AUTO_HOME, '.estado', 'agentes', `${id}.json`),
      JSON.stringify({ oauthAccount: contaDe(id), chave: chaveDe(id), guardadoEm: Date.now() }),
    );
    const dona = pastas[id];
    fs.mkdirSync(dirDe(id), { recursive: true });
    fs.writeFileSync(path.join(dirDe(id), '.claude.json'), JSON.stringify({ oauthAccount: contaDe(dona) }));
    const texto = JSON.stringify({ claudeAiOauth: { accessToken: `token-${dona}`, refreshToken: `r-${dona}`, expiresAt: daqui } });
    itens.push({ conta: contas.CONTA_KEYCHAIN, servico: contas.servicoDoDir(dirDe(id)), texto });
    fs.writeFileSync(path.join(dirDe(id), '.credentials.json'), texto);
  }
  fs.writeFileSync(process.env.FAKE_KEYCHAIN, JSON.stringify(itens));
  return contas.carregarConfig();
}

// Cada token responde com o uso da conta dele; `lidos` diz quais tokens foram usados.
async function comUso(fn) {
  const original = global.fetch;
  const lidos = [];
  global.fetch = async (_url, { headers }) => {
    const dona = headers.Authorization.replace('Bearer token-', '');
    lidos.push(dona);
    const usado = { aegro: 30, max: 6, compare: 50 }[dona];
    return { ok: true, status: 200, json: async () => ({ seven_day: { utilization: usado, resets_at: new Date(daqui).toISOString() } }) };
  };
  try {
    return { resultado: await fn(), lidos };
  } finally {
    global.fetch = original;
  }
}

const testes = {
  pastaQueTrocouDeLoginComOutraSoPeloGuardadoFicaDeFora() {
    // 16:47: a pasta da Aegro já tinha o login da Max, então o login da Aegro na pasta da Compare só era reconhecido
    // pelo que a troca dos agentes guardou para a Aegro.
    const cfg = cenario({ aegro: 'max', max: 'aegro', compare: 'aegro' });
    assert.strictEqual((contas.loginDeOutraContaDaFila('compare', cfg) || {}).chave, chaveDe('aegro'));
    assert.strictEqual((contas.loginDeOutraContaDaFila('aegro', cfg) || {}).chave, chaveDe('max'));
  },
  loginNaContaErradaERecusadoNaHoraMesmoQuandoSoOGuardadoODenuncia() {
    // `claude-accounts login compare` caindo na org da Aegro enquanto a pasta da Aegro está com o login da Max.
    const cfg = cenario({ aegro: 'max', max: 'max', compare: 'aegro' });
    assert.strictEqual((contas.conflitoDoLogin('compare', dirDe('compare'), cfg) || {}).outra, 'aegro');
  },
  pastaComOProprioLoginContinuaNaFila() {
    const cfg = cenario({ aegro: 'aegro', max: 'max', compare: 'compare' });
    for (const id of ['aegro', 'compare']) assert.strictEqual(contas.loginDeOutraContaDaFila(id, cfg), null);
  },
  async contaComLoginDeOutraNaoELidaComOTokenDaPasta() {
    cenario({ aegro: 'max', max: 'max', compare: 'compare' });
    // Uma leitura de antes, já com o login trocado: os números são os da Max e não podem ficar como da Aegro.
    fs.writeFileSync(
      path.join(contas.DIR_ESTADO, 'uso.json'),
      JSON.stringify({ aegro: { ok: true, verificadoEm: Date.now(), uso: { cinco: null, sete: { usado: 6, renovaEm: daqui }, janelas: [] } } }),
    );
    const { resultado, lidos } = await comUso(() => contas.lerUso('aegro'));
    assert.deepStrictEqual(lidos, []);
    assert.strictEqual(resultado.ok, false);
    assert.strictEqual(resultado.semLogin, true);
    assert.strictEqual(resultado.loginDeOutraConta, true);
    assert.strictEqual(resultado.uso, undefined);
    assert.strictEqual(JSON.parse(fs.readFileSync(path.join(contas.DIR_ESTADO, 'uso.json'), 'utf8')).aegro.uso, undefined);
  },
  async credencialDadaAindaLeAConta() {
    // O login dos agentes guardado para a conta é dela: com ele, a leitura segue.
    cenario({ aegro: 'max', max: 'max', compare: 'compare' });
    const credencial = { accessToken: 'token-aegro', expiresAt: daqui };
    const { resultado, lidos } = await comUso(() => contas.lerUso('aegro', { credencial, chaveDoCache: 'agents aegro' }));
    assert.deepStrictEqual(lidos, ['aegro']);
    assert.strictEqual(resultado.ok, true);
  },
  async contaComOProprioLoginELida() {
    cenario({ aegro: 'aegro', max: 'max', compare: 'compare' });
    const { resultado, lidos } = await comUso(() => contas.lerUso('compare'));
    assert.deepStrictEqual(lidos, ['compare']);
    assert.strictEqual(resultado.ok, true);
  },
  async avaliacaoDeixaAsContasCruzadasSemLogin() {
    cenario({ aegro: 'max', max: 'max', compare: 'aegro' });
    const { resultado } = await comUso(() => contas.avaliarContas({ maxIdadeMs: 0 }));
    const logada = Object.fromEntries(resultado.map((c) => [c.id, c.logada]));
    assert.deepStrictEqual(logada, { aegro: false, max: true, compare: false });
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
