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

const renovaEm = agora + 3 * 3600000;

function leitura(minutos, usado, renovacao = renovaEm) {
  return { em: agora + minutos * 60000, cinco: { usado, renovaEm: renovacao } };
}

function sondaCom(minutos, cinco, sete) {
  return { ok: true, verificadoEm: agora + minutos * 60000, uso: { cinco: { usado: cinco, renovaEm }, sete: { usado: sete, renovaEm }, janelas: [] } };
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
  impressaoDoSlotSegueORefreshTokenSemExporOToken() {
    const impressao = agentes.impressaoDoLogin(slotDaConta);
    assert.match(impressao, /^[0-9a-f]{64}$/);
    assert.ok(!impressao.includes('a-r'));
    const renovadoSoNoAcesso = JSON.stringify({ mcpOAuth: {}, claudeAiOauth: { accessToken: 'outro', refreshToken: 'a-r' } });
    assert.strictEqual(agentes.mesmoLogin(renovadoSoNoAcesso, impressao), true);
    const renovado = JSON.stringify({ mcpOAuth: mcp, claudeAiOauth: { accessToken: 'a2', refreshToken: 'a-r2' }, designOauth: design });
    assert.strictEqual(agentes.mesmoLogin(renovado, impressao), false);
    assert.strictEqual(agentes.mesmoLogin(loginDaSegunda, impressao), false);
    assert.strictEqual(agentes.impressaoDoLogin(JSON.stringify({ mcpOAuth: mcp })), null);
    assert.strictEqual(agentes.mesmoLogin(JSON.stringify({ mcpOAuth: mcp }), null), false);
    assert.strictEqual(agentes.mesmoLogin(null, impressao), false);
  },
  desfazerSoVoltaOQueEstaTrocaGravou() {
    const escrito = agentes.slotComLogin(slotDaConta, loginDaSegunda);
    assert.strictEqual(agentes.textoParaDesfazer(escrito, escrito, slotDaConta), slotDaConta);
    const renovadoDepois = JSON.stringify({ ...JSON.parse(escrito), claudeAiOauth: { accessToken: 'b2', refreshToken: 'b-r2' } });
    assert.strictEqual(agentes.textoParaDesfazer(renovadoDepois, escrito, slotDaConta), null);
    assert.strictEqual(agentes.textoParaDesfazer(slotDaConta, escrito, slotDaConta), null);
    assert.strictEqual(agentes.textoParaDesfazer(null, escrito, slotDaConta), null);
  },
  perfilDoLoginGuardadoDecideSeEleEntraNoSlot() {
    const perfil = { account: { uuid: 'u2' }, organization: { uuid: 'o2' } };
    assert.deepStrictEqual(agentes.resultadoDoPerfil(200, perfil, 'u2:o2'), { valido: true, chave: 'u2:o2' });
    assert.deepStrictEqual(agentes.resultadoDoPerfil(200, perfil, null), { valido: true, chave: 'u2:o2' });
    assert.strictEqual(agentes.resultadoDoPerfil(200, perfil, 'u1:o1').valido, false);
    assert.strictEqual(agentes.resultadoDoPerfil(401, null, 'u2:o2').valido, false);
    assert.strictEqual(agentes.resultadoDoPerfil(403, null, 'u2:o2').valido, false);
    assert.strictEqual(agentes.resultadoDoPerfil(429, null, 'u2:o2').valido, null);
    assert.strictEqual(agentes.resultadoDoPerfil(500, null, 'u2:o2').valido, null);
    assert.strictEqual(agentes.resultadoDoPerfil(200, {}, 'u2:o2').valido, null);
  },
  loginGuardadoVencidoNaoEntraNoSlot() {
    const com = (expiresAt) => JSON.stringify({ claudeAiOauth: { accessToken: 'b', refreshToken: 'b-r', expiresAt } });
    assert.strictEqual(agentes.loginVencido(com(agora - 1000), agora), true);
    assert.strictEqual(agentes.loginVencido(com(agora + 60000), agora), false);
    assert.strictEqual(agentes.loginVencido(loginDaSegunda, agora), false);
  },
  loginMarcadoComoInvalidoSaiDaTroca() {
    configurar();
    const arquivo = path.join(contas.DIR_ESTADO, 'agentes', 'segunda.json');
    fs.mkdirSync(path.dirname(arquivo), { recursive: true });
    fs.writeFileSync(arquivo, JSON.stringify({ chave: 'u2:o2', guardadoEm: agora }));
    assert.strictEqual(agentes.prontaParaAgentes('segunda'), true);
    fs.writeFileSync(arquivo, JSON.stringify({ chave: 'u2:o2', guardadoEm: agora, invalidoEm: agora, motivoInvalido: 'HTTP 401' }));
    assert.strictEqual(agentes.loginUtilizavel(agentes.loginGuardado('segunda')), false);
    assert.strictEqual(agentes.prontaParaAgentes('segunda'), false);
    assert.strictEqual(agentes.loginUtilizavel(null), false);
    fs.rmSync(arquivo);
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

  trocarDePreferidaFuraAEsperaDaVolta() {
    const estado = { preferidaChecada: 'principal', ultimaChecagemDeVolta: agora };
    assert.strictEqual(agentes.deveChecarVolta(estado, 'segunda', agora + 1000), true);
    assert.strictEqual(agentes.deveChecarVolta(estado, 'principal', agora + 1000), false);
    assert.strictEqual(agentes.deveChecarVolta(estado, 'principal', agora + 5 * 60 * 1000), true);
    assert.strictEqual(agentes.deveChecarVolta({}, 'principal', agora), true);
    assert.strictEqual(agentes.deveChecarVolta(estado, null, agora + 10 * 60 * 1000), false);
  },
  semAlvoPreventivoEsperaCincoMinutosPelaMesmaConta() {
    const estado = { semAlvoPreventivo: { conta: 'principal', em: agora } };
    assert.strictEqual(agentes.deveProcurarAlvoPreventivo({}, 'principal', agora), true);
    assert.strictEqual(agentes.deveProcurarAlvoPreventivo(estado, 'principal', agora + 60 * 1000), false);
    assert.strictEqual(agentes.deveProcurarAlvoPreventivo(estado, 'principal', agora + 5 * 60 * 1000), true);
    assert.strictEqual(agentes.deveProcurarAlvoPreventivo(estado, 'segunda', agora + 1000), true);
  },
  ritmoDeUsoMedeOsUltimosDezMinutos() {
    const leituras = [leitura(-12, 10), leitura(-8, 50), leitura(-4, 54), leitura(0, 58)];
    assert.strictEqual(agentes.ritmoDeUso(leituras, 'cinco', agora), 1);
    assert.strictEqual(agentes.ritmoDeUso([leitura(0, 58)], 'cinco', agora), null);
    assert.strictEqual(agentes.ritmoDeUso([leitura(-12, 10), leitura(0, 58)], 'cinco', agora), null);
    assert.strictEqual(agentes.ritmoDeUso([], 'cinco', agora), null);
  },
  ritmoPedeDoisMinutosEntreAsLeituras() {
    const proximas = [{ em: agora - 5000, cinco: { usado: 70, renovaEm } }, { em: agora, cinco: { usado: 71, renovaEm } }];
    assert.strictEqual(agentes.ritmoDeUso(proximas, 'cinco', agora), null);
    assert.strictEqual(agentes.ritmoDeUso([leitura(-1.9, 70), leitura(0, 72)], 'cinco', agora), null);
    assert.strictEqual(agentes.ritmoDeUso([leitura(-2, 70), leitura(0, 72)], 'cinco', agora), 1);
    assert.strictEqual(agentes.ritmoDeUso([leitura(-2, 70), leitura(-1, 71), leitura(0, 72)], 'cinco', agora), 1);
  },
  ritmoDescartaLeiturasDeAntesDaRenovacao() {
    const caiu = [leitura(-9, 90), leitura(-6, 95), leitura(-4, 2), leitura(-2, 4), leitura(0, 6)];
    assert.strictEqual(agentes.ritmoDeUso(caiu, 'cinco', agora), 1);
    const novaRenovacao = renovaEm + 5 * 3600000;
    const mudouARenovacao = [leitura(-8, 40), leitura(-6, 60), leitura(-4, 61, novaRenovacao), leitura(0, 63, novaRenovacao)];
    assert.strictEqual(agentes.ritmoDeUso(mudouARenovacao, 'cinco', agora), 0.5);
    assert.strictEqual(agentes.ritmoDeUso([leitura(-4, 40), leitura(0, 44, renovaEm + 500)], 'cinco', agora), 1);
    assert.strictEqual(agentes.ritmoDeUso([leitura(-2, 90), leitura(0, 1)], 'cinco', agora), null);
  },
  guardarLeituraPodaAntigasEIgnoraRepetida() {
    const mapa = { principal: [leitura(-11, 30)], segunda: [leitura(-20, 10)] };
    const sonda = sondaCom(-1, 40, 5);
    const novo = agentes.guardarLeitura(mapa, 'principal', sonda, agora);
    assert.deepStrictEqual(Object.keys(novo), ['principal']);
    assert.deepStrictEqual(novo.principal, [{ em: agora - 60000, cinco: { usado: 40, renovaEm }, sete: { usado: 5, renovaEm } }]);
    assert.strictEqual(agentes.guardarLeitura(novo, 'principal', sonda, agora).principal.length, 1);
    assert.deepStrictEqual(agentes.guardarLeitura(novo, 'principal', { ok: false, verificadoEm: agora }, agora), novo);
    const doCache = { ...sondaCom(0, 41, 5), usoDe: agora - 30000 };
    assert.strictEqual(agentes.guardarLeitura(novo, 'principal', doCache, agora).principal[1].em, agora - 30000);
  },
  ritmoDaContaUsaAJanelaQueLimita() {
    const leituras = [
      { em: agora - 4 * 60000, cinco: { usado: 20, renovaEm }, sete: { usado: 80, renovaEm } },
      { em: agora, cinco: { usado: 28, renovaEm }, sete: { usado: 82, renovaEm } },
    ];
    assert.strictEqual(agentes.ritmoDaConta(leituras, sondaCom(0, 28, 82), agora), 0.5);
    assert.strictEqual(agentes.ritmoDaConta(leituras, sondaCom(0, 90, 82), agora), 2);
    assert.strictEqual(agentes.ritmoDaConta(leituras, { ok: false }, agora), null);
  },
  ritmoLentoEm4NaoTroca() {
    const cfg = configurar();
    assert.strictEqual(cfg.limites.horizonteMinutos, 2);
    assert.strictEqual(cfg.limites.margem, 2);
    assert.strictEqual(agentes.deveTrocarAntes(4, 0.5, cfg), false);
    assert.strictEqual(agentes.deveTrocarAntes(4, 0.99, cfg), false);
    assert.strictEqual(agentes.alvoPreventivo(4, 0.5, candidatas({ principal: { folga: 4 } }), cfg, 'principal'), null);
  },
  ritmoRapidoTrocaAntes() {
    const cfg = configurar();
    assert.strictEqual(agentes.deveTrocarAntes(10, 4, cfg), true);
    assert.strictEqual(agentes.deveTrocarAntes(10, 3.9, cfg), false);
    const alvo = agentes.alvoPreventivo(10, 4, candidatas({ principal: { folga: 10 } }), cfg, 'principal');
    assert.strictEqual(alvo && alvo.id, 'segunda');
    const daReserva = agentes.alvoPreventivo(0, 0, candidatas({ principal: { folga: 0 }, segunda: { folga: 1 } }), cfg, 'principal');
    assert.strictEqual(daReserva && daReserva.id, 'extra');
  },
  margemSempreTroca() {
    const cfg = configurar();
    assert.strictEqual(agentes.deveTrocarAntes(2, 0, cfg), true);
    assert.strictEqual(agentes.deveTrocarAntes(2, null, cfg), true);
    assert.strictEqual(agentes.deveTrocarAntes(3, 0, cfg), false);
    const comMargem = configurar({ limites: { margem: 4 } });
    assert.strictEqual(agentes.deveTrocarAntes(4, 0, comMargem), true);
    assert.strictEqual(agentes.deveTrocarAntes(10, 3, comMargem), true);
  },
  ritmoDesconhecidoUsaAPreventiva() {
    const cfg = configurar();
    assert.strictEqual(cfg.limites.preventiva, 5);
    assert.strictEqual(agentes.deveTrocarAntes(4, null, cfg), true);
    assert.strictEqual(agentes.deveTrocarAntes(5, null, cfg), false);
    const alvo = agentes.alvoPreventivo(4, null, candidatas({ principal: { folga: 4 } }), cfg, 'principal');
    assert.strictEqual(alvo && alvo.id, 'segunda');
    assert.strictEqual(agentes.alvoPreventivo(40, null, candidatas(), cfg, 'principal'), null);
  },
  folgaDesconhecidaNaoTroca() {
    const cfg = configurar();
    assert.strictEqual(agentes.deveTrocarAntes(null, 10, cfg), false);
    assert.strictEqual(agentes.alvoPreventivo(null, 10, candidatas({ principal: { folga: null } }), cfg, 'principal'), null);
    assert.strictEqual(agentes.alvoPreventivo(undefined, null, candidatas(), cfg, 'principal'), null);
  },
  semOutraContaComLoginDeAgentesNaoTroca() {
    const cfg = configurar();
    const soOSlot = candidatas({ principal: { folga: 2 } }).filter((c) => c.id === 'principal');
    assert.strictEqual(agentes.alvoPreventivo(2, null, soOSlot, cfg, 'principal'), null);
    const semLogin = candidatas({ principal: { folga: 2 }, segunda: { logada: false }, extra: { logada: false } });
    assert.strictEqual(agentes.alvoPreventivo(2, null, semLogin, cfg, 'principal'), null);
  },
  contaQueNaoTemMaisFolgaNaoTroca() {
    const cfg = configurar();
    const piores = candidatas({ principal: { folga: 4 }, segunda: { folga: 4 }, extra: { folga: 3 } });
    assert.strictEqual(agentes.alvoPreventivo(4, null, piores, cfg, 'principal'), null);
    const desconhecidas = candidatas({ principal: { folga: 4 }, segunda: { folga: null }, extra: { folga: null } });
    assert.strictEqual(agentes.alvoPreventivo(4, null, desconhecidas, cfg, 'principal'), null);
    const esgotadas = candidatas({ principal: { folga: 4 }, segunda: { esgotada: { ate: agora + 60000 } }, extra: { esgotada: { ate: agora + 60000 } } });
    assert.strictEqual(agentes.alvoPreventivo(4, null, esgotadas, cfg, 'principal'), null);
  },

  loginGrandeNaoVaiEmArgv() {
    const pequena = agentes.linhaDoSecurity('Claude Code-credentials', loginDaSegunda);
    assert.ok(pequena && pequena.startsWith('add-generic-password -U '));
    assert.strictEqual(agentes.linhaDoSecurity('Claude Code-credentials', 'x'.repeat(4000)), null);
    assert.strictEqual(agentes.linhaDoSecurity('nome"quebrado', loginDaSegunda), null);
  },

  async aberturaEsperaATravaOcupada() {
    const trava = path.join(contas.DIR_ESTADO, 'agentes.trava');
    fs.mkdirSync(trava, { recursive: true });
    fs.writeFileSync(path.join(trava, 'dono'), 'outro:processo');
    let rodou = 0;
    const ocupada = await agentes.comTravaEsperando(async () => (rodou += 1), { prazoMs: 300, intervaloMs: 50 });
    assert.deepStrictEqual(ocupada, { acao: 'ocupado' });
    assert.strictEqual(rodou, 0);
    setTimeout(() => fs.rmSync(trava, { recursive: true, force: true }), 150);
    const liberada = await agentes.comTravaEsperando(async () => (rodou += 1), { prazoMs: 2000, intervaloMs: 50 });
    assert.strictEqual(liberada, 1);
    assert.strictEqual(fs.existsSync(trava), false);
  },
  preferidaBaixaNaoBloqueiaOAlvoPreventivo() {
    const cfg = configurar({ preferida: 'principal' });
    const lista = candidatas({ principal: { folga: 8 }, segunda: { folga: 10 }, extra: { folga: 90 } });
    const alvo = agentes.alvoPreventivo(10, 4, lista, cfg, 'segunda');
    assert.strictEqual(alvo && alvo.id, 'extra');
  },
  alvoPreventivoNaoPodeDispararATrocaDeNovo() {
    const cfg = configurar({ preferida: 'principal' });
    const lista = candidatas({ principal: { folga: 4 }, segunda: { folga: 3 }, extra: { folga: 90 } });
    const alvo = agentes.alvoPreventivo(3, null, lista, cfg, 'segunda');
    assert.strictEqual(alvo && alvo.id, 'extra');
    const semSaida = candidatas({ principal: { folga: 4 }, segunda: { folga: 3 }, extra: { folga: 4 } });
    assert.strictEqual(agentes.alvoPreventivo(3, null, semSaida, cfg, 'segunda'), null);
    const rapida = candidatas({ principal: { folga: 9 }, segunda: { folga: 9 }, extra: { folga: 11 } });
    assert.strictEqual(agentes.alvoPreventivo(9, 4, rapida, cfg, 'segunda').id, 'extra');
  },
  alvoPreventivoPrefereARotaComFolgaSuficiente() {
    const cfg = configurar({ preferida: 'principal' });
    const lista = candidatas({ principal: { folga: 30 }, segunda: { folga: 4 }, extra: { folga: 90 } });
    assert.strictEqual(agentes.alvoPreventivo(4, null, lista, cfg, 'segunda').id, 'principal');
    const rotaMaisFolgada = candidatas({ principal: { folga: 30 }, segunda: { folga: 50 }, extra: { folga: 90 } });
    assert.strictEqual(agentes.alvoPreventivo(4, null, rotaMaisFolgada, cfg, 'extra').id, 'segunda');
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
