'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const raiz = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-auto-agentes-'));
process.env.CLAUDE_AUTO_HOME = path.join(raiz, 'contas');
process.env.CLAUDE_AUTO_SLOT_DIR = path.join(raiz, 'slot');
fs.mkdirSync(process.env.CLAUDE_AUTO_HOME, { recursive: true });

const agentes = require('../lib/agentes');
const contas = require('../lib/contas');

const agora = Date.now();
const cwd = '/Users/exemplo/projeto';

function configurar(extra = {}) {
  fs.writeFileSync(
    path.join(process.env.CLAUDE_AUTO_HOME, 'config.json'),
    JSON.stringify({ contas: { principal: {}, segunda: {}, extra: {} }, rota: ['principal', 'segunda'], reserva: ['extra'], ...extra }),
  );
  return contas.carregarConfig();
}

function candidatas(mudancas = {}) {
  const base = {
    principal: { papel: 'rota', folga: 40 },
    segunda: { papel: 'rota', folga: 80 },
    extra: { papel: 'reserva', folga: 90 },
  };
  return Object.entries(base).map(([id, c]) => ({ id, esgotada: null, logada: true, ...c, ...(mudancas[id] || {}) }));
}

const escolhida = (lista, opcoes) => (contas.decidir(lista, opcoes) || {}).id || null;

function sessao(sessionId, entradas) {
  const dir = path.join(process.env.CLAUDE_AUTO_SLOT_DIR, 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'));
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${sessionId}.jsonl`), entradas.map((e) => JSON.stringify(e)).join('\n') + '\n');
}

function limite(ms) {
  return { type: 'assistant', isApiErrorMessage: true, error: 'rate_limit', timestamp: new Date(ms).toISOString() };
}

const mcp = { 'servidor|1': { accessToken: 'mcp', refreshToken: 'mcp-r' } };
const design = { accessToken: 'design' };
const slotDaConta = JSON.stringify({ mcpOAuth: mcp, claudeAiOauth: { accessToken: 'a', refreshToken: 'a-r' }, designOauth: design });
const loginDaSegunda = JSON.stringify({ claudeAiOauth: { accessToken: 'b', refreshToken: 'b-r' } });

const testes = {
  agenteParadoPorLimiteEhDetectado() {
    sessao('s1', [{ type: 'user', timestamp: new Date(agora - 70000).toISOString() }, limite(agora - 60000)]);
    const p = agentes.paradoPorLimite({ id: 'a1', sessionId: 's1', cwd, kind: 'background', startedAt: agora - 3600000 });
    assert.ok(p);
    assert.strictEqual(p.quando, agora - 60000);
  },
  respostaNormalOuParadaAntigaOuInterativaNaoContam() {
    sessao('s2', [limite(agora - 120000), { type: 'assistant', timestamp: new Date(agora - 60000).toISOString() }]);
    assert.strictEqual(agentes.paradoPorLimite({ id: 'a2', sessionId: 's2', cwd, kind: 'background' }), null);
    sessao('s3', [limite(agora - 7 * 3600000)]);
    assert.strictEqual(agentes.paradoPorLimite({ id: 'a3', sessionId: 's3', cwd, kind: 'background' }), null);
    sessao('s4', [limite(agora - 60000)]);
    assert.strictEqual(agentes.paradoPorLimite({ id: 'a4', sessionId: 's4', cwd, kind: 'interactive' }), null);
  },
  primeiraParadaPedeTroca() {
    const p = { sessionId: 's1', quando: agora - 60000, processoDesde: agora - 3600000 };
    const plano = agentes.planejar([p], {});
    assert.deepStrictEqual(plano.novas, [p]);
    assert.strictEqual(plano.precisaTrocar, true);
  },
  paradaDeProcessoAnteriorATrocaSoRetoma() {
    const troca = agora - 300000;
    const p = { sessionId: 's1', quando: agora - 60000, processoDesde: agora - 3600000 };
    const plano = agentes.planejar([p], { ultimaTroca: troca });
    assert.strictEqual(plano.novas.length, 1);
    assert.strictEqual(plano.precisaTrocar, false);
  },
  paradaDepoisDeRetomadoNaContaNovaPedeOutraTroca() {
    const troca = agora - 300000;
    const p = { sessionId: 's1', quando: agora - 60000, processoDesde: troca + 5000 };
    assert.strictEqual(agentes.planejar([p], { ultimaTroca: troca }).precisaTrocar, true);
  },
  paradaJaEmpurradaNaoRepete() {
    const p = { sessionId: 's1', quando: agora - 60000, processoDesde: 0 };
    const plano = agentes.planejar([p], { empurrados: { s1: agora - 60000 } });
    assert.strictEqual(plano.novas.length, 0);
    assert.strictEqual(plano.precisaTrocar, false);
  },
  paradaDesistidaNaoRepeteMasParadaNovaSim() {
    const p = { sessionId: 's1', quando: agora - 60000, processoDesde: 0 };
    assert.strictEqual(agentes.planejar([p], { desistidos: { s1: agora - 60000 } }).novas.length, 0);
    assert.strictEqual(agentes.planejar([p], { desistidos: { s1: agora - 600000 } }).novas.length, 1);
  },
  trocaNoSlotSoMudaOLoginEMantemAsOutrasChaves() {
    const guardado = agentes.loginDoItem(slotDaConta);
    assert.deepStrictEqual(JSON.parse(guardado), { claudeAiOauth: { accessToken: 'a', refreshToken: 'a-r' } });
    const trocado = JSON.parse(agentes.slotComLogin(slotDaConta, loginDaSegunda));
    assert.deepStrictEqual(Object.keys(trocado), ['mcpOAuth', 'claudeAiOauth', 'designOauth']);
    assert.deepStrictEqual(trocado.claudeAiOauth, { accessToken: 'b', refreshToken: 'b-r' });
    assert.deepStrictEqual(trocado.mcpOAuth, mcp);
    assert.deepStrictEqual(trocado.designOauth, design);
    assert.strictEqual(agentes.slotComLogin(JSON.stringify(trocado), guardado), slotDaConta);
  },
  loginGuardadoComOutrasChavesSoEmprestaOClaudeAiOauth() {
    const antigo = JSON.stringify({ claudeAiOauth: { accessToken: 'b' }, mcpOAuth: { velho: {} }, designOauth: { accessToken: 'velho' } });
    const trocado = JSON.parse(agentes.slotComLogin(slotDaConta, antigo));
    assert.deepStrictEqual(trocado.mcpOAuth, mcp);
    assert.deepStrictEqual(trocado.designOauth, design);
    assert.deepStrictEqual(JSON.parse(agentes.loginDoItem(antigo)), { claudeAiOauth: { accessToken: 'b' } });
  },
  slotIlegivelOuLoginSemClaudeAiOauthRecusamATroca() {
    assert.throws(() => agentes.slotComLogin(slotDaConta.slice(0, 40), loginDaSegunda), /not valid JSON/);
    assert.throws(() => agentes.slotComLogin('[]', loginDaSegunda), /not valid JSON/);
    assert.throws(() => agentes.slotComLogin(slotDaConta, loginDaSegunda.slice(0, 20)), /no claudeAiOauth/);
    assert.throws(() => agentes.slotComLogin(slotDaConta, JSON.stringify({ mcpOAuth: mcp })), /no claudeAiOauth/);
    assert.strictEqual(agentes.loginDoItem(JSON.stringify({ mcpOAuth: mcp })), null);
    assert.strictEqual(agentes.loginDoItem(slotDaConta.slice(0, 40)), null);
    assert.strictEqual(agentes.loginDoItem(null), null);
  },
  trocaDePrincipalSoMudaAPrincipal() {
    fs.writeFileSync(contas.ARQ_CONFIG, JSON.stringify({ contas: { segunda: {} }, preferida: 'segunda', ativo: false }));
    contas.definirPrincipal('segunda');
    const salvo = JSON.parse(fs.readFileSync(contas.ARQ_CONFIG, 'utf8'));
    assert.strictEqual(salvo.principal, 'segunda');
    assert.ok(salvo.contas.principal);
    assert.deepStrictEqual(salvo.rota, ['principal']);
    assert.strictEqual(salvo.preferida, 'segunda');
    assert.strictEqual(salvo.ativo, false);
    assert.strictEqual(salvo.limites, undefined);
  },
  semPreferidaEscolheAMaiorFolga() {
    configurar();
    assert.strictEqual(escolhida(candidatas()), 'segunda');
    assert.strictEqual(escolhida(candidatas({ segunda: { folga: 2 }, principal: { folga: 1 } })), 'extra');
  },
  comPreferidaElegivelEscolheEla() {
    configurar({ preferida: 'principal' });
    assert.strictEqual(escolhida(candidatas()), 'principal');
    assert.strictEqual(escolhida(candidatas({ principal: { folga: 3 } })), 'principal');
    configurar({ preferida: 'extra' });
    assert.strictEqual(escolhida(candidatas({ extra: { folga: 10 } })), 'extra');
  },
  preferidaInelegivelCaiNaMaiorFolga() {
    configurar({ preferida: 'principal' });
    assert.strictEqual(escolhida(candidatas({ principal: { folga: 2 } })), 'segunda');
    assert.strictEqual(escolhida(candidatas({ principal: { folga: null } })), 'segunda');
    assert.strictEqual(escolhida(candidatas({ principal: { esgotada: { ate: agora + 60000 } } })), 'segunda');
    assert.strictEqual(escolhida(candidatas({ principal: { logada: false } })), 'segunda');
    assert.strictEqual(escolhida(candidatas(), { excluir: ['principal'] }), 'segunda');
    configurar({ preferida: 'sumiu' });
    assert.strictEqual(escolhida(candidatas()), 'segunda');
  },
  voltaParaAPreferidaSoComFolgaDeVolta() {
    const cfg = configurar({ preferida: 'principal' });
    assert.strictEqual(cfg.limites.voltar, 20);
    const volta = (mudancas, atual = 'segunda', c = cfg) => (contas.preferidaDeVolta(candidatas(mudancas), atual, c) || {}).id || null;
    assert.strictEqual(volta({ principal: { folga: 20 } }), 'principal');
    assert.strictEqual(volta({ principal: { folga: 19 } }), null);
    assert.strictEqual(volta({ principal: { folga: null } }), null);
    assert.strictEqual(volta({ principal: { esgotada: { ate: agora + 60000 } } }), null);
    assert.strictEqual(volta({ principal: { logada: false } }), null);
    assert.strictEqual(volta({}, 'principal'), null);
    assert.strictEqual(volta({}, 'segunda', configurar()), null);
    assert.strictEqual(volta({ principal: { folga: 30 } }, 'segunda', configurar({ preferida: 'principal', limites: { voltar: 50 } })), null);
  },
};

let falhas = 0;
for (const [nome, teste] of Object.entries(testes)) {
  try {
    teste();
    console.log(`ok    ${nome}`);
  } catch (e) {
    falhas += 1;
    console.log(`FALHA ${nome}\n  ${e.message}`);
  }
}
fs.rmSync(raiz, { recursive: true, force: true });
process.exit(falhas ? 1 : 0);
