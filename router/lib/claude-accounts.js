'use strict';

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const contas = require('./contas');
const agentes = require('./agentes');

const AJUDA = `claude-accounts: Claude Code accounts for claude-auto

  pick [--json]                account the router would use now
  status                       headroom and windows of each account
  on | off                     turn switching on or off (same as the Monitor Claude toggle)
  add <id> [--name N] [--reserve]
                               create ~/.claude-accounts/<id> with links to ~/.claude
  login <id>                   log the account in (opens the browser)
  login <id> --agents          separate login used by claude agents when this account takes over
  agents [use <id>]            which account the background agents run on; switch it by hand
  sync                         redo links and copy MCP servers and project trust
  switches [-n N]              latest recorded switches
  release <id>                 clear the exhausted mark
  env <id>                     CLAUDE_CONFIG_DIR export for the shell
  run <id> [args...]           open claude directly on that account
`;

const SINONIMOS = {
  escolher: 'pick',
  ligar: 'on',
  desligar: 'off',
  adicionar: 'add',
  sincronizar: 'sync',
  trocas: 'switches',
  liberar: 'release',
  rodar: 'run',
};
const PAPEIS = { rota: 'route', reserva: 'reserve' };

function opcao(args, nomes, padrao = null) {
  for (const nome of [].concat(nomes)) {
    const i = args.indexOf(nome);
    if (i >= 0 && args[i + 1] !== undefined) return args[i + 1];
  }
  return padrao;
}

function exigirConta(id) {
  const cfg = contas.carregarConfig();
  if (!id || !cfg.contas[id]) {
    process.stderr.write(`unknown account: ${id || '(empty)'}. Accounts: ${Object.keys(cfg.contas).join(', ')}\n`);
    process.exit(2);
  }
  return id;
}

function horaCurta(ms) {
  if (!ms) return '–';
  const d = new Date(ms);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getDate())}/${p(d.getMonth() + 1)} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

function tabela(linhas) {
  const larguras = linhas[0].map((_, c) => Math.max(...linhas.map((l) => String(l[c]).length)));
  return linhas.map((l) => l.map((v, c) => String(v).padEnd(larguras[c])).join('  ').trimEnd()).join('\n');
}

async function status() {
  const candidatos = await contas.avaliarContas({ maxIdadeMs: 0 });
  const escolhida = contas.decidir(candidatos);
  const linhas = [['account', 'login', 'role', 'headroom', '5h session', '7d weekly', 'other', 'state']];
  for (const c of candidatos) {
    const janelas = c.sonda.uso ? c.sonda.uso.janelas : [];
    const janela = (chave) => janelas.find((j) => j.chave === chave);
    const fmt = (j) => (j ? `${Math.round(j.usado)}% (${horaCurta(j.renovaEm)})` : '–');
    const outras = janelas
      .filter((j) => !['session', 'weekly_all'].includes(j.chave))
      .map((j) => `${j.rotulo.replace('Weekly ', '')} ${Math.round(j.usado)}%`);
    const situacao = [
      escolhida && escolhida.id === c.id ? 'router' : null,
      c.esgotada ? `exhausted until ${horaCurta(c.esgotada.ate)}` : null,
      c.sonda.ok || c.sonda.semLogin ? null : `probe: ${c.sonda.erro}`,
    ].filter(Boolean);
    linhas.push([
      c.id,
      contas.rotuloDoLogin(c.id, contas.identidade(c.id).email, c.sonda),
      PAPEIS[c.papel] || c.papel,
      c.folga == null ? '–' : `${c.folga}%`,
      fmt(janela('session')),
      fmt(janela('weekly_all')),
      outras.join(', ') || '–',
      situacao.join('; ') || 'ok',
    ]);
  }
  console.log(tabela(linhas));
  console.log(`\nrouter would use now: ${escolhida ? escolhida.id : 'no account available'}`);
  avisarDuplicadas();
  if (contas.carregarConfig().ativo === false) console.log('switching is off: claude-auto hands everything to plain claude');
}

function avisarDuplicadas() {
  for (const { email, ids } of contas.contasDuplicadas()) {
    console.log(`\nwarning: ${ids.join(' and ')} are logged into the same account (${email}), so switching between them changes nothing.`);
    console.log('log one of them into another account with claude-accounts login <id>; if the browser is already signed in, finish the sign-in in a private window.');
  }
}

function entrarParaAgentes(id, args) {
  fs.mkdirSync(contas.DIR_CONTAS, { recursive: true });
  const dir = fs.mkdtempSync(path.join(contas.DIR_CONTAS, `.login-agentes-${id}-`));
  contas.escreverJson(path.join(dir, '.claude.json'), { hasCompletedOnboarding: true });
  const env = { ...agentes.envDoSlot(), CLAUDE_CONFIG_DIR: dir };
  const filho = spawn(contas.resolverClaude(), ['auth', 'login', ...args], { env, stdio: 'inherit' });
  process.on('SIGINT', () => {});
  filho.on('exit', async (codigo) => {
    try {
      if (codigo !== 0) throw new Error('login cancelled');
      const conta = await agentes.guardarLoginDoDir(id, dir);
      console.log(`agents login for ${id}: ${conta.emailAddress || 'unknown'}`);
      const esperado = contas.identidade(id).email;
      if (esperado && conta.emailAddress && esperado !== conta.emailAddress) {
        console.log(`warning: ${id} is ${esperado} in the terminal but this agents login is ${conta.emailAddress}`);
      }
    } catch (e) {
      process.stderr.write(`claude-accounts: ${e.message}\n`);
      process.exitCode = 1;
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
}

async function statusDosAgentes() {
  const cfg = contas.carregarConfig();
  const noSlot = agentes.contaNoSlot(cfg);
  const linhas = [['account', 'login', 'agents']];
  for (const id of [...cfg.rota, ...cfg.reserva]) {
    const guardado = agentes.loginGuardado(id);
    const pronta =
      id === noSlot
        ? 'running the agents now'
        : agentes.loginUtilizavel(guardado)
          ? 'ready'
          : guardado
            ? `stopped working: claude-accounts login ${id} --agents`
            : `missing: claude-accounts login ${id} --agents`;
    linhas.push([id, contas.identidade(id, cfg).email || 'not logged in', pronta]);
  }
  console.log(tabela(linhas));
  const lista = (await agentes.listarAgentes()) || [];
  const paradas = lista.map((a) => agentes.paradoPorLimite(a)).filter(Boolean);
  console.log(`\n${lista.length} agents, ${paradas.length} stopped by a limit${paradas.length ? `: ${paradas.map((p) => p.nome).join(', ')}` : ''}`);
}

function entrar(id, args) {
  contas.prepararConta(id);
  const filho = spawn(contas.resolverClaude(), ['auth', 'login', ...args], { env: contas.envDaConta(id), stdio: 'inherit' });
  process.on('SIGINT', () => {});
  filho.on('exit', (codigo) => {
    if (codigo === 0) {
      const { email } = contas.identidade(id);
      console.log(`${id} is logged in as ${email || 'unknown'}`);
      avisarDuplicadas();
    }
    process.exit(codigo ?? 1);
  });
}

function ligar(ativo) {
  contas.atualizarConfig((salvo) => ({ ...salvo, ativo }));
  console.log(ativo ? 'account switching is on' : 'account switching is off: claude-auto now opens plain claude');
}

function adicionar(args) {
  const id = args[0];
  if (!id || !/^[a-z0-9][a-z0-9._-]*$/.test(id) || id === contas.principal()) {
    process.stderr.write('usage: claude-accounts add <id> [--name N] [--reserve]  (lowercase id, no spaces)\n');
    process.exit(2);
  }
  contas.atualizarConfig((salvo, atual) => {
    const nome = opcao(args, ['--name', '--nome'], (atual.contas[id] || {}).nome || id);
    const rota = atual.rota.filter((c) => c !== id);
    const reserva = atual.reserva.filter((c) => c !== id);
    (args.includes('--reserve') || args.includes('--reserva') ? reserva : rota).push(id);
    return { ...salvo, contas: { ...atual.contas, [id]: { ...(atual.contas[id] || {}), nome } }, rota, reserva };
  });
  const cfg = contas.carregarConfig();
  contas.prepararConta(id);
  console.log(`account ${id} ready at ${contas.dirDaConta(id)}`);
  console.log(`route: ${cfg.rota.join(', ')}${cfg.reserva.length ? ` | reserve: ${cfg.reserva.join(', ')}` : ''}`);
  console.log(`next step: claude-accounts login ${id}`);
}

function rodarClaude(id, args) {
  contas.prepararConta(id);
  const filho = spawn(contas.resolverClaude(), args, { env: contas.envDaConta(id), stdio: 'inherit' });
  process.on('SIGINT', () => {});
  filho.on('exit', (codigo) => process.exit(codigo ?? 1));
}

async function main() {
  const [bruto, ...args] = process.argv.slice(2);
  const comando = SINONIMOS[bruto] || bruto;
  switch (comando) {
    case 'pick': {
      const r = await contas.escolher();
      if (args.includes('--json')) {
        const candidatos = r.candidatos.map(({ id, papel, folga, esgotada, logada }) => ({ id, role: PAPEIS[papel] || papel, headroom: folga, exhausted: esgotada, loggedIn: logada }));
        console.log(JSON.stringify({ account: r.escolhida, headroom: r.folga, candidates: candidatos }, null, 2));
      } else {
        console.log(r.escolhida || '');
      }
      if (!r.escolhida) process.exitCode = 1;
      break;
    }
    case 'status':
      await status();
      break;
    case 'on':
    case 'off':
      ligar(comando === 'on');
      break;
    case 'add':
      adicionar(args);
      break;
    case 'login':
      if (args.includes('--agents')) entrarParaAgentes(exigirConta(args[0]), args.slice(1).filter((a) => a !== '--agents'));
      else entrar(exigirConta(args[0]), args.slice(1));
      break;
    case 'agents':
      if (args[0] === 'use') {
        const r = await agentes.trocarSlot(exigirConta(args[1]), 'manual');
        console.log(r.acao === 'ocupado' ? 'another switch is running, try again' : r.mudou ? `agents now run on ${r.para} (was ${r.de})` : `agents already run on ${r.para}`);
        if (r.acao === 'ocupado') process.exitCode = 1;
      } else {
        await statusDosAgentes();
      }
      break;
    case '_vigiar':
      console.log(JSON.stringify(await agentes.vigiar()));
      break;
    case 'sync': {
      const cfg = contas.carregarConfig();
      for (const id of Object.keys(cfg.contas)) {
        contas.prepararConta(id);
        console.log(`${id}: ${contas.dirDaConta(id, cfg)}`);
      }
      break;
    }
    case 'switches': {
      const trocas = contas.lerTrocas(Number(opcao(args, '-n', 20)));
      if (!trocas.length) console.log('no switches recorded');
      else console.log(tabela([['when', 'switch', 'reason', 'session'], ...trocas.map((t) => [horaCurta(t.em), `${t.de} → ${t.para}`, t.motivo, (t.sessao || '–').slice(0, 8)])]));
      break;
    }
    case 'release':
      contas.liberar(exigirConta(args[0]));
      console.log(`${args[0]} released`);
      break;
    case 'env': {
      const id = exigirConta(args[0]);
      const env = contas.envDaConta(id, {});
      console.log(env.CLAUDE_CONFIG_DIR ? `export CLAUDE_CONFIG_DIR='${env.CLAUDE_CONFIG_DIR}'` : 'unset CLAUDE_CONFIG_DIR');
      break;
    }
    case 'run':
      rodarClaude(exigirConta(args[0]), args.slice(1));
      break;
    case '_trocar': {
      const de = opcao(args, '--de');
      const motivo = opcao(args, '--motivo', 'limite');
      contas.marcarEsgotada(de, null, motivo);
      const r = await contas.escolher({ excluir: [de] });
      if (!r.escolhida) {
        console.log('{}');
        break;
      }
      contas.prepararConta(r.escolhida);
      contas.registrarTroca({ de, para: r.escolhida, motivo, sessao: opcao(args, '--sessao') });
      const env = contas.envDaConta(r.escolhida, {});
      console.log(JSON.stringify({ para: r.escolhida, configDir: env.CLAUDE_CONFIG_DIR || null }));
      break;
    }
    default:
      process.stdout.write(AJUDA);
      if (bruto && !['help', '-h', '--help', 'ajuda'].includes(bruto)) process.exitCode = 2;
  }
}

main().catch((e) => {
  process.stderr.write(`claude-accounts: ${e.message}\n`);
  process.exit(1);
});
