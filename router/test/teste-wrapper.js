'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const raiz = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-auto-wrapper-'));
process.env.CLAUDE_AUTO_HOME = path.join(raiz, 'contas');
fs.mkdirSync(process.env.CLAUDE_AUTO_HOME, { recursive: true });

const { binarioDoWrapper } = require('../lib/args');
const contas = require('../lib/contas');

const executaveis = new Set(['/ext/resources/native-binary/claude', '/usr/local/bin/claude']);
const ehExecutavel = (p) => executaveis.has(p);

function binarioFalso(nome, corpo) {
  const dir = fs.mkdtempSync(path.join(raiz, 'bin-'));
  const arquivo = path.join(dir, nome);
  fs.writeFileSync(arquivo, corpo, { mode: 0o755 });
  return arquivo;
}

const testes = {
  limiteAoVivoGravaAPorcentagemDeCadaJanelaPorConta() {
    const agora = 1791500000000;
    const r = contas.registrarLimiteAoVivo('principal', {
      status: 'allowed',
      rateLimitType: 'five_hour',
      utilization: 0.4,
      resetsAt: 1791514800,
      unifiedWindows: {
        five_hour: { utilization: 0.4123, resetsAt: 1791514800 },
        seven_day: { utilization: 0.76, resetsAt: 1791630000 },
      },
    }, agora);
    assert.deepStrictEqual(r, {
      em: agora, status: 'allowed',
      janelas: { five_hour: { usado: 41.2, renovaEm: 1791514800000 }, seven_day: { usado: 76, renovaEm: 1791630000000 } },
    });
    const gravado = JSON.parse(fs.readFileSync(path.join(contas.DIR_AO_VIVO, 'principal.json'), 'utf8'));
    assert.deepStrictEqual(gravado, r);
    // Só o tipo do evento, sem janelas unificadas, ainda conta; evento sem número nenhum não grava nada.
    assert.deepStrictEqual(contas.registrarLimiteAoVivo('max', { status: 'allowed_warning', rateLimitType: 'seven_day', utilization: 0.9 }, agora).janelas,
      { seven_day: { usado: 90, renovaEm: null } });
    assert.strictEqual(contas.registrarLimiteAoVivo('compare', { status: 'allowed' }, agora), null);
    assert.ok(!fs.existsSync(path.join(contas.DIR_AO_VIVO, 'compare.json')));
  },

  primeiroArgumentoComOCaminhoDoClaudeViraOBinario() {
    const r = binarioDoWrapper(['/ext/resources/native-binary/claude', '--output-format', 'stream-json'], ehExecutavel);
    assert.strictEqual(r.bin, '/ext/resources/native-binary/claude');
    assert.deepStrictEqual(r.args, ['--output-format', 'stream-json']);
  },

  argumentosNormaisPassamIntactos() {
    for (const argv of [[], ['-p', 'oi'], ['--resume', 'abc'], ['agents'], ['relativo/claude', 'x']]) {
      const r = binarioDoWrapper(argv, ehExecutavel);
      assert.strictEqual(r.bin, null);
      assert.deepStrictEqual(r.args, argv);
    }
  },

  caminhoQueNaoEDoClaudeOuNaoExecutaPassaIntacto() {
    assert.deepStrictEqual(binarioDoWrapper(['/usr/bin/env', 'x'], ehExecutavel), { bin: null, args: ['/usr/bin/env', 'x'] });
    assert.deepStrictEqual(binarioDoWrapper(['/nao/existe/claude', 'x'], ehExecutavel), { bin: null, args: ['/nao/existe/claude', 'x'] });
  },

  umClaudeQueApontaParaOLancadorNaoViraBinarioParaNaoEntrarEmLaco() {
    const atalho = '/Users/exemplo/.local/bin/claude';
    const r = binarioDoWrapper([atalho, '-p', 'oi'], (p) => p === atalho, (p) => p === atalho);
    assert.strictEqual(r.bin, null);
    assert.deepStrictEqual(r.args, ['-p', 'oi']);
    const lancador = '/Users/exemplo/Code/router/bin/claude-auto';
    const direto = binarioDoWrapper([lancador, '-p', 'oi'], () => true, (p) => p === lancador);
    assert.deepStrictEqual(direto, { bin: null, args: ['-p', 'oi'] });
  },

  oClaudeAutoRodaOBinarioQueOWrapperRecebeu() {
    const marca = path.join(raiz, 'rodou.txt');
    const falso = binarioFalso('claude', `#!/bin/sh\nprintf '%s\\n' "$@" > '${marca}'\n`);
    fs.writeFileSync(path.join(process.env.CLAUDE_AUTO_HOME, 'config.json'), JSON.stringify({ ativo: false }));
    const r = spawnSync(process.execPath, [path.join(__dirname, '..', 'lib', 'claude-auto.js'), falso, '--version'], {
      env: { ...process.env, CLAUDE_AUTO_CLAUDE_BIN: '' },
      encoding: 'utf8',
    });
    assert.strictEqual(r.status, 0, r.stderr);
    assert.strictEqual(fs.readFileSync(marca, 'utf8'), '--version\n');
  },

  avisoDeTrocaDizOMotivoEAHoraDaVolta() {
    const agora = new Date(2026, 9, 8, 16, 31).getTime();
    const volta = new Date(2026, 9, 8, 18, 59).getTime();
    const nomes = { aegro: 'Thomas (Aegro)', max: 'Thomas (Max)' };
    const nome = (id) => nomes[id] || id;
    assert.deepStrictEqual(contas.textoDaTroca({ de: 'aegro', para: 'max', motivo: 'five_hour' }, nome, volta, agora), {
      titulo: 'Trocou para Thomas (Max)',
      texto: 'Thomas (Aegro) bateu o limite de 5h. Volta às 18:59.',
    });
    const semana = contas.textoDaTroca({ de: 'aegro', para: 'max', motivo: 'seven_day_opus' }, nome, null, agora);
    assert.strictEqual(semana.texto, 'Thomas (Aegro) bateu o limite da semana.');
    const outroDia = contas.textoDaTroca({ de: 'aegro', para: 'max', motivo: 'limite' }, nome, new Date(2026, 9, 10, 7, 59).getTime(), agora);
    assert.strictEqual(outroDia.texto, 'Thomas (Aegro) bateu o limite. Volta às 10/10 07:59.');
  },

  avisoDosAgentesEDaVoltaParaAPreferida() {
    const nome = (id) => ({ aegro: 'Thomas (Aegro)', max: 'Thomas (Max)' })[id] || id;
    const agentes = contas.textoDaTroca({ de: 'aegro', para: 'max', motivo: 'agents preventiva' }, nome);
    assert.strictEqual(agentes.texto, 'Thomas (Aegro) estava quase no limite. Os agentes seguiram junto.');
    const volta = contas.textoDaTroca({ de: 'max', para: 'aegro', motivo: 'agents preferida' }, nome);
    assert.deepStrictEqual(volta, { titulo: 'Voltou para Thomas (Aegro)', texto: 'Thomas (Aegro) voltou a ter folga. Os agentes voltaram junto.' });
    assert.strictEqual(contas.textoDaTroca({ de: 'x', para: 'y', motivo: 'algo novo' }).texto, 'x ficou sem folga.');
  },

  voltaNoPassadoNaoEntraNoAviso() {
    const agora = Date.now();
    const r = contas.textoDaTroca({ de: 'a', para: 'b', motivo: 'five_hour' }, (id) => id, agora - 60000, agora);
    assert.strictEqual(r.texto, 'a bateu o limite de 5h.');
  },

  voltaSoQuandoOMotivoEUmLimite() {
    const agora = new Date(2026, 9, 8, 15, 0).getTime();
    const volta = new Date(2026, 9, 8, 16, 0).getTime();
    const texto = (motivo) => contas.textoDaTroca({ de: 'a', para: 'b', motivo }, (id) => id, volta, agora).texto;
    assert.strictEqual(texto('rate_limit'), 'a bateu o limite. Volta às 16:00.');
    assert.strictEqual(texto('agents seven_day_opus'), 'a bateu o limite da semana. Volta às 16:00. Os agentes seguiram junto.');
    assert.strictEqual(texto('manual'), 'a foi trocada à mão.');
    assert.strictEqual(texto('auth'), 'a pediu login de novo.');
    assert.strictEqual(texto('cobranca'), 'a deu erro de cobrança.');
    assert.strictEqual(texto('agents conta_suspensa'), 'a teve a conta suspensa. Os agentes seguiram junto.');
    assert.strictEqual(texto('agents preventiva'), 'a estava quase no limite. Os agentes seguiram junto.');
  },

  voltaDoAvisoSoVemDeUmaJanelaDeUsoConhecida() {
    const estado = path.join(process.env.CLAUDE_AUTO_HOME, '.estado');
    fs.mkdirSync(estado, { recursive: true });
    const agora = Date.now();
    const cinco = agora + 2 * 3600 * 1000;
    const semana = agora + 3 * 86400 * 1000;
    const cheia = agora + 5 * 3600 * 1000;
    fs.writeFileSync(
      path.join(estado, 'uso.json'),
      JSON.stringify({
        comUso: {
          ok: true,
          uso: {
            cinco: { usado: 100, renovaEm: cinco },
            sete: { usado: 40, renovaEm: semana },
            janelas: [
              { chave: 'session', usado: 100, renovaEm: cinco },
              { chave: 'weekly_opus', usado: 99, renovaEm: cheia },
            ],
          },
        },
        semJanelaCheia: { ok: true, uso: { cinco: null, sete: null, janelas: [{ chave: 'session', usado: 50, renovaEm: cinco }] } },
      }),
    );
    assert.strictEqual(contas.voltaConhecida('comUso', 'five_hour', agora), cinco);
    assert.strictEqual(contas.voltaConhecida('comUso', 'agents seven_day', agora), semana);
    // O limite semanal de um modelo volta quando a janela daquele modelo renova, não a semanal geral.
    assert.strictEqual(contas.voltaConhecida('comUso', 'seven_day_opus', agora), cheia);
    assert.strictEqual(contas.voltaConhecida('comUso', 'agents seven_day_opus', agora), cheia);
    // Sem a janela do modelo no cache, fica a semanal geral.
    assert.strictEqual(contas.voltaConhecida('comUso', 'seven_day_sonnet', agora), semana);
    assert.strictEqual(contas.voltaConhecida('comUso', 'rate_limit', agora), cheia);
    // Sem janela que explique o limite, o aviso fica sem hora em vez de mostrar o palpite de 1h.
    assert.strictEqual(contas.voltaConhecida('semJanelaCheia', 'limite', agora), null);
    assert.strictEqual(contas.voltaConhecida('naoSondada', 'five_hour', agora), null);
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
