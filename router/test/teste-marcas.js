'use strict';

// A marca que tira uma conta da fila (esgotadas.json) tem de sair quando o motivo dela deixou de valer, sem esperar a
// hora anotada: o login refeito tira a de `auth`, e a leitura que mostra a janela já renovada tira a de limite.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

require('./ambiente-limpo');

const raiz = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-auto-marcas-'));
process.env.CLAUDE_AUTO_HOME = path.join(raiz, 'contas');
fs.mkdirSync(process.env.CLAUDE_AUTO_HOME, { recursive: true });

const contas = require('../lib/contas');

const MIN = 60 * 1000;
const HORA = 60 * MIN;
const agora = Date.now();

const ARQ_ESGOTADAS = path.join(contas.DIR_ESTADO, 'esgotadas.json');
const gravarMarcas = (marcas) => {
  fs.mkdirSync(contas.DIR_ESTADO, { recursive: true });
  fs.writeFileSync(ARQ_ESGOTADAS, JSON.stringify(marcas));
};
const lerMarcas = () => JSON.parse(fs.readFileSync(ARQ_ESGOTADAS, 'utf8'));

// Leitura boa, feita agora, com a janela de 5h em `usado5` renovando em `renova5` e a semana em 20%.
function sonda({ usado5 = 69, renova5 = agora + 2 * HORA, usado7 = 20, renova7 = agora + 3 * 24 * HORA, verificadoEm = agora } = {}) {
  const cinco = renova5 === null ? null : { usado: usado5, renovaEm: renova5 };
  return {
    ok: true,
    verificadoEm,
    uso: {
      cinco,
      sete: { usado: usado7, renovaEm: renova7 },
      janelas: [
        ...(cinco ? [{ chave: 'session', rotulo: 'Session (5h)', ...cinco }] : []),
        { chave: 'weekly_all', rotulo: 'Weekly (7d)', usado: usado7, renovaEm: renova7 },
        { chave: 'weekly_scoped', rotulo: 'Weekly Opus', usado: 99, renovaEm: renova7 + HORA },
      ],
    },
  };
}

// A marca de five_hour do caso de 13/11/2026: posta 2h45 antes, valendo até daqui a 15 min.
const marca5h = (extra = {}) => ({ ate: agora + 15 * MIN, motivo: 'five_hour', em: agora - 165 * MIN, ...extra });

const testes = {
  janelaRenovadaLongeDoTetoSuperaAMarca() {
    assert.strictEqual(contas.marcaSuperada(marca5h(), sonda(), agora), true);
  },

  aMesmaJanelaNaoSuperaMesmoComArredondamento() {
    // O servidor arredonda o resetsAt do aviso e o da leitura de jeitos diferentes: dentro de 5 min, é a mesma janela.
    assert.strictEqual(contas.marcaSuperada(marca5h(), sonda({ renova5: agora + 15 * MIN + 2 * MIN }), agora), false);
  },

  janelaNoTetoNaoSupera() {
    assert.strictEqual(contas.marcaSuperada(marca5h(), sonda({ usado5: 98 }), agora), false);
  },

  leituraAnteriorAMarcaNaoSupera() {
    const marca = marca5h({ em: agora - MIN });
    assert.strictEqual(contas.marcaSuperada(marca, sonda({ verificadoEm: agora - 2 * MIN }), agora), false);
  },

  leituraQueFalhouNaoSupera() {
    assert.strictEqual(contas.marcaSuperada(marca5h(), { ...sonda(), ok: false }, agora), false);
  },

  contaSemJanelaDe5hNaoSuperaFiveHour() {
    assert.strictEqual(contas.marcaSuperada(marca5h(), sonda({ renova5: null }), agora), false);
  },

  marcaDosAgentesLeAMesmaJanela() {
    assert.strictEqual(contas.marcaSuperada(marca5h({ motivo: 'agents five_hour' }), sonda(), agora), true);
  },

  semanaDeUmModeloUsaAJanelaDoModelo() {
    // A semanal geral está folgada, mas a do modelo que bateu (Opus, 99%) não: a marca fica.
    const marca = { ate: agora + 2 * HORA, motivo: 'seven_day_opus', em: agora - HORA };
    assert.strictEqual(contas.marcaSuperada(marca, sonda(), agora), false);
  },

  semanaGeralRenovadaSupera() {
    const marca = { ate: agora + HORA, motivo: 'seven_day', em: agora - 2 * HORA };
    assert.strictEqual(contas.marcaSuperada(marca, sonda(), agora), true);
  },

  loginEOutrosMotivosNaoSaemPorLeitura() {
    for (const motivo of ['auth', 'cobranca', 'conta_suspensa', 'rate_limit', 'limite']) {
      const marca = { ate: agora + HORA, motivo, em: agora - HORA };
      assert.strictEqual(contas.marcaSuperada(marca, sonda(), agora), false, motivo);
    }
  },

  revisarMarcaTiraSoADaConta() {
    gravarMarcas({ principal: marca5h(), segunda: marca5h() });
    assert.strictEqual(contas.revisarMarca('principal', sonda(), agora), true);
    assert.deepStrictEqual(Object.keys(lerMarcas()), ['segunda']);
    assert.strictEqual(contas.revisarMarca('principal', sonda(), agora), false);
  },

  liberarSeMotivoTiraAMarcaDeLogin() {
    gravarMarcas({ segunda: { ate: agora + 6 * HORA, motivo: 'auth', em: agora - HORA } });
    assert.strictEqual(contas.liberarSeMotivo('segunda', ['auth'], 'login refeito'), true);
    assert.deepStrictEqual(lerMarcas(), {});
  },

  liberarSeMotivoNaoTiraLimiteNemCobranca() {
    const marcas = {
      principal: marca5h(),
      segunda: { ate: agora + 6 * HORA, motivo: 'cobranca', em: agora - HORA },
    };
    gravarMarcas(marcas);
    assert.strictEqual(contas.liberarSeMotivo('principal', ['auth'], 'login refeito'), false);
    assert.strictEqual(contas.liberarSeMotivo('segunda', ['auth'], 'login refeito'), false);
    assert.deepStrictEqual(Object.keys(lerMarcas()).sort(), ['principal', 'segunda']);
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
