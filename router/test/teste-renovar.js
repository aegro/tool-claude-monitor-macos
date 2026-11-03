'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

require('./ambiente-limpo');

const raiz = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-auto-renovar-'));
process.env.CLAUDE_AUTO_HOME = path.join(raiz, 'contas');
fs.mkdirSync(process.env.CLAUDE_AUTO_HOME, { recursive: true });

const contas = require('../lib/contas');
const renovar = require('../lib/renovar');

const hora = 3600 * 1000;

function configurar() {
  fs.writeFileSync(
    path.join(process.env.CLAUDE_AUTO_HOME, 'config.json'),
    JSON.stringify({ contas: { principal: {}, parada: {}, viva: {} }, rota: ['principal', 'parada', 'viva'], principal: 'principal' }),
  );
  fs.rmSync(renovar.ARQ_RENOVACOES, { force: true });
  return contas.carregarConfig();
}

function cenario({ vencidas = ['parada'], emUso = {}, renova = true } = {}) {
  const tokens = {};
  for (const id of ['principal', 'parada', 'viva']) {
    tokens[id] = { accessToken: `a-${id}`, refreshToken: `r-${id}`, expiresAt: Date.now() + (vencidas.includes(id) ? -hora : hora) };
  }
  const rodou = [];
  const deps = {
    lerCredencial: async (id) => tokens[id],
    processosNaPasta: async (dir) => emUso[path.basename(dir)] || [],
    rodarUsage: async (dir) => {
      const id = path.basename(dir);
      rodou.push(id);
      if (renova) tokens[id] = { ...tokens[id], expiresAt: Date.now() + 8 * hora };
      return { ok: true };
    },
  };
  return { deps, rodou, tokens };
}

const testes = {
  async renovaSoAContaParadaForaDoSlot() {
    configurar();
    const { deps, rodou } = cenario({ vencidas: ['principal', 'parada'] });
    const r = await renovar.renovarParadas({ deps });
    assert.deepStrictEqual(rodou, ['parada']);
    assert.strictEqual(r.contas.parada.resultado, 'renovado');
    assert.strictEqual(r.contas.principal, undefined);
    assert.strictEqual(renovar.lerRenovacoes().parada.resultado, 'renovado');
  },

  async contaComProcessoVivoNaPastaNaoERenovada() {
    configurar();
    const { deps, rodou } = cenario({ emUso: { parada: [4242] } });
    const r = await renovar.renovarParadas({ deps });
    assert.deepStrictEqual(rodou, []);
    assert.strictEqual(r.contas.parada.resultado, 'em-uso');
  },

  async semListaDeProcessosNaoArrisca() {
    configurar();
    const { deps, rodou } = cenario();
    const r = await renovar.renovarParadas({ deps: { ...deps, processosNaPasta: async () => null } });
    assert.deepStrictEqual(rodou, []);
    assert.strictEqual(r.contas.parada.resultado, 'falhou');
  },

  async falhaDizPorQueEEsperaMeiaHora() {
    configurar();
    const { deps, rodou } = cenario({ renova: false });
    const r = await renovar.renovarParadas({ deps });
    assert.strictEqual(r.contas.parada.resultado, 'falhou');
    assert.match(r.contas.parada.erro, /still expired/);
    await renovar.renovarParadas({ deps });
    assert.deepStrictEqual(rodou, ['parada']);
    await renovar.renovarParadas({ deps, forcar: true });
    assert.deepStrictEqual(rodou, ['parada', 'parada']);
  },

  async loginValidoNaoRoda() {
    configurar();
    const { deps, rodou } = cenario({ vencidas: [] });
    const r = await renovar.renovarParadas({ deps });
    assert.deepStrictEqual(rodou, []);
    assert.deepStrictEqual(r.contas, {});
  },

  async semRefreshTokenNaoRoda() {
    configurar();
    const { deps, rodou, tokens } = cenario();
    tokens.parada = { ...tokens.parada, refreshToken: undefined };
    const r = await renovar.renovarParadas({ deps });
    assert.deepStrictEqual(rodou, []);
    assert.strictEqual(r.contas.parada.resultado, 'falhou');
  },

  processosPeloAmbienteSoDaPastaExata() {
    const dir = '/Users/x/.claude-accounts/parada';
    const ps = [
      `  101 claude --resume abc HOME=/Users/x CLAUDE_CONFIG_DIR=${dir} TERM=xterm`,
      `  102 claude CLAUDE_CONFIG_DIR=${dir}2 TERM=xterm`,
      `  103 node x.js CLAUDE_CONFIG_DIR=${dir}/`,
      '  104 claude HOME=/Users/x',
    ].join('\n');
    assert.deepStrictEqual(renovar.processosNoAmbiente(ps, dir), [101, 103]);
  },

  envDaRenovacaoApontaParaAPastaSemHerdarASessao() {
    process.env.CLAUDE_CODE_ENTRYPOINT = 'cli';
    process.env.CLAUDE_AUTO_CONTA = 'outra';
    const env = renovar.envDaRenovacao('/tmp/conta');
    assert.strictEqual(env.CLAUDE_CONFIG_DIR, '/tmp/conta');
    assert.strictEqual(env.CLAUDE_CODE_ENTRYPOINT, undefined);
    assert.strictEqual(env.CLAUDE_AUTO_CONTA, undefined);
    delete process.env.CLAUDE_CODE_ENTRYPOINT;
    delete process.env.CLAUDE_AUTO_CONTA;
  },

  async prazoMataOGrupoMesmoComNetoSegurandoOStderr() {
    const bin = path.join(raiz, 'claude-pendurado.sh');
    fs.writeFileSync(bin, '#!/bin/sh\ntrap "" TERM\nsleep 30 &\nsleep 30\n', { mode: 0o755 });
    const inicio = Date.now();
    const r = await renovar.rodarUsage(path.join(raiz, 'pasta'), { prazoMs: 500, comando: bin });
    assert.strictEqual(r.ok, false);
    assert.match(r.erro, /too long/);
    assert.ok(Date.now() - inicio < 5000, 'rodarUsage ficou pendurado');
  },

  async cliQueSaiComErroDizOMotivo() {
    const bin = path.join(raiz, 'claude-falha.sh');
    fs.writeFileSync(bin, '#!/bin/sh\necho "OAuth token has expired" >&2\nexit 1\n', { mode: 0o755 });
    const r = await renovar.rodarUsage(path.join(raiz, 'pasta'), { prazoMs: 5000, comando: bin });
    assert.deepStrictEqual(r, { ok: false, erro: 'OAuth token has expired' });
  },

  async sessaoComPidReusadoNaoContaComoViva() {
    const dir = path.join(raiz, 'conta-velha');
    fs.mkdirSync(path.join(dir, 'sessions'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'sessions', 'a.json'), JSON.stringify({ pid: process.pid, procStart: 'Mon Jan  1 00:00:00 2024' }));
    assert.deepStrictEqual(await renovar.sessoesVivasNaPasta(dir, async () => 'Tue Nov  3 10:44:42 2026'), []);
    fs.writeFileSync(path.join(dir, 'sessions', 'a.json'), JSON.stringify({ pid: process.pid, procStart: 'Tue Nov  3 10:44:42 2026' }));
    assert.deepStrictEqual(await renovar.sessoesVivasNaPasta(dir, async () => 'Tue Nov 3 10:44:42 2026'), [process.pid]);
  },

  envSemChaveDeApi() {
    process.env.ANTHROPIC_API_KEY = 'x';
    process.env.ANTHROPIC_AUTH_TOKEN = 'y';
    const env = renovar.envDaRenovacao('/tmp/conta');
    assert.strictEqual(env.ANTHROPIC_API_KEY, undefined);
    assert.strictEqual(env.ANTHROPIC_AUTH_TOKEN, undefined);
    delete process.env.ANTHROPIC_API_KEY;
    delete process.env.ANTHROPIC_AUTH_TOKEN;
  },

  async travaOcupadaNaoRodaDuasVezes() {
    configurar();
    fs.mkdirSync(path.join(contas.DIR_ESTADO, 'renovar.trava'), { recursive: true });
    const { deps, rodou } = cenario();
    const r = await renovar.renovarParadas({ deps });
    assert.strictEqual(r.acao, 'ocupado');
    assert.deepStrictEqual(rodou, []);
    fs.rmSync(path.join(contas.DIR_ESTADO, 'renovar.trava'), { recursive: true, force: true });
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
