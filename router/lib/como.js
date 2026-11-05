'use strict';

// `claude-accounts as <conta> "<pedido>"`: uma tarefa de uma vez, feita por um `claude -p` com o login de outra conta,
// sem trocar a conta da sessão que pediu. O caso que motivou: uma sessão na Max pessoal precisa salvar ou ler um
// artefato da org da empresa (a Team). Trocar a própria sessão de conta reabriria o processo duas vezes, perderia o
// cache nas duas e trocaria os conectores do claude.ai no meio do trabalho; aqui a sessão segue onde está e só a
// tarefa roda na outra conta.
//
// O filho é estreito de propósito: só as ferramentas pedidas (por padrão, as de artefato e a leitura de arquivo),
// sem os settings do usuário (que podem liberar Bash ou MCP inteiros) e sem os servidores MCP locais. Quem precisar
// de mais nomeia com --tools, e o que foi pedido vai para o registro.

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const contas = require('./contas');

const FERRAMENTAS_PADRAO = ['Artifact', 'ArtifactComments', 'ArtifactData', 'Read'];
const MODELO_PADRAO = 'claude-haiku-5-5';
const ARQ_ACESSOS = path.join(contas.DIR_ESTADO, 'acessos.jsonl');
const MAX_ACESSOS = 500;
const TAMANHO_DO_PEDIDO_NO_REGISTRO = 300;

// Lê `<conta> [--tools a,b] [--model m] [--] <pedido...>`. Sem pedido nos argumentos, ele vem da entrada padrão.
function lerArgs(args) {
  const r = { id: null, ferramentas: FERRAMENTAS_PADRAO, modelo: MODELO_PADRAO, pedido: '' };
  const resto = [];
  for (let i = 0; i < args.length; i += 1) {
    const a = args[i];
    if (a === '--') {
      resto.push(...args.slice(i + 1));
      break;
    }
    if (a === '--tools' || a === '--model') {
      const valor = args[i + 1];
      if (valor === undefined || valor.startsWith('--')) return { erro: `${a} needs a value` };
      if (a === '--tools') {
        const lista = valor.split(',').map((s) => s.trim()).filter(Boolean);
        if (!lista.length) return { erro: '--tools needs at least one tool' };
        r.ferramentas = lista;
      } else {
        r.modelo = valor;
      }
      i += 1;
    } else if (!r.id) {
      r.id = a;
    } else {
      resto.push(a);
    }
  }
  if (!r.id) return { erro: 'usage: claude-accounts as <account> [--tools a,b] [--model m] "<request>"' };
  r.pedido = resto.join(' ').trim();
  return r;
}

// Onde e com que login a tarefa roda, ou o motivo de não rodar. A pasta é a mesma que uma sessão nova da conta usaria
// (`envDaSessao`), e o login de lá tem que ser o da conta: o mesmo e-mail em duas orgs entra sem aviso na org que o
// navegador já usa, e uma tarefa "na Team" que rodasse na Max publicaria o artefato no lugar errado sem ninguém notar.
function planejar(id, opcoes, cfg = contas.carregarConfig(), base = process.env) {
  if (!cfg.contas[id] || cfg.contas[id].pendente) {
    return { erro: `unknown account: ${id}. Accounts: ${Object.keys(cfg.contas).filter((c) => !cfg.contas[c].pendente).join(', ')}` };
  }
  if (!opcoes.pedido) return { erro: 'empty request: say what to do on that account' };
  const env = { ...contas.envDaSessao(id, base, cfg), CLAUDE_AUTO_CONTA: id };
  const dir = env.CLAUDE_CONFIG_DIR || contas.DIR_PRINCIPAL;
  const login = contas.loginDaPasta(dir);
  if (!login.chave) return { erro: `${id} has no login in ${dir}: run claude-accounts login ${id}` };
  const outra = [...cfg.rota, ...cfg.reserva].find((o) => o !== id && contas.identidade(o, cfg).chave === login.chave);
  if (outra || (!contas.usaDirPadrao(id, cfg) && contas.loginDeOutraContaDaFila(id, cfg))) {
    const de = outra ? ` (${contas.nomeDaConta(outra, cfg)})` : '';
    return { erro: `${dir} is signed in to ${contas.rotuloDoLoginDaPasta(login)}${de}, not to ${id}; fix it with claude-accounts login ${id}` };
  }
  const onde = contas.rotuloDoLoginDaPasta(login);
  const lista = opcoes.ferramentas.join(',');
  const args = [
    '-p', opcoes.pedido,
    '--tools', lista,
    '--allowedTools', lista,
    '--model', opcoes.modelo,
    '--no-session-persistence',
    '--setting-sources', 'project',
    '--strict-mcp-config',
    '--append-system-prompt',
    `Você roda com o login ${onde} (conta ${id}), a pedido de outra sessão e só para esta tarefa. ` +
      'Termine dizendo em que conta e organização a operação foi feita e o link de cada artefato que criou, mudou ou leu.',
  ];
  return { id, env, dir, login, onde, args, ferramentas: opcoes.ferramentas, modelo: opcoes.modelo };
}

// Cada tarefa vira uma linha em `.estado/acessos.jsonl`: quem pediu (a conta da sessão de origem), em que conta rodou,
// com que ferramentas, de qual pasta e o começo do pedido. O arquivo é só de quem roda (0600) e guarda as últimas 500.
function registrar(entrada, arquivo = ARQ_ACESSOS) {
  try {
    fs.mkdirSync(path.dirname(arquivo), { recursive: true });
    const linhas = fs.existsSync(arquivo) ? fs.readFileSync(arquivo, 'utf8').split('\n').filter(Boolean) : [];
    linhas.push(JSON.stringify(entrada));
    const tmp = `${arquivo}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, linhas.slice(-MAX_ACESSOS).join('\n') + '\n', { mode: 0o600 });
    fs.renameSync(tmp, arquivo);
  } catch (e) {
    contas.log(`as: não deu para registrar o acesso: ${e.message}`);
  }
}

function lerAcessos(limite = 20, arquivo = ARQ_ACESSOS) {
  try {
    return fs.readFileSync(arquivo, 'utf8').split('\n').filter(Boolean).slice(-limite).reverse()
      .map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  } catch {
    return [];
  }
}

function lerEntrada() {
  if (process.stdin.isTTY) return Promise.resolve('');
  return new Promise((resolve) => {
    let texto = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (d) => (texto += d));
    process.stdin.on('end', () => resolve(texto.trim()));
  });
}

async function rodar(args) {
  const opcoes = lerArgs(args);
  if (opcoes.erro) {
    process.stderr.write(`claude-accounts: ${opcoes.erro}\n`);
    return 2;
  }
  if (!opcoes.pedido) opcoes.pedido = await lerEntrada();
  const plano = planejar(opcoes.id, opcoes);
  if (plano.erro) {
    process.stderr.write(`claude-accounts: ${plano.erro}\n`);
    return 2;
  }
  const de = process.env.CLAUDE_AUTO_CONTA || null;
  process.stderr.write(`claude-accounts as ${plano.id}: ${plano.onde}, one task, tools ${plano.ferramentas.join(', ')}\n`);
  contas.log(`as: ${de || 'terminal'} pediu uma tarefa em ${plano.id} (${plano.onde}), ferramentas ${plano.ferramentas.join(',')}`);
  contas.prepararConta(plano.id);
  const inicio = Date.now();
  const codigo = await new Promise((resolve) => {
    const filho = spawn(contas.resolverClaude(), plano.args, { env: plano.env, stdio: ['ignore', 'inherit', 'inherit'] });
    process.on('SIGINT', () => filho.kill('SIGINT'));
    filho.on('error', (e) => {
      process.stderr.write(`claude-accounts: could not start claude: ${e.message}\n`);
      resolve(1);
    });
    filho.on('exit', (c) => resolve(c ?? 1));
  });
  registrar({
    em: inicio,
    de,
    conta: plano.id,
    login: plano.login.email,
    organizacao: plano.login.organizacao,
    ferramentas: plano.ferramentas,
    modelo: plano.modelo,
    cwd: process.cwd(),
    pedido: opcoes.pedido.slice(0, TAMANHO_DO_PEDIDO_NO_REGISTRO),
    codigo,
    ms: Date.now() - inicio,
  });
  return codigo;
}

module.exports = { lerArgs, planejar, registrar, lerAcessos, rodar, FERRAMENTAS_PADRAO, MODELO_PADRAO, ARQ_ACESSOS };
