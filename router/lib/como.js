'use strict';

// `claude-accounts as <conta> "<pedido>"`: uma tarefa de uma vez, feita por um `claude -p` com o login de outra conta,
// sem trocar a conta da sessão que pediu. O caso que motivou: uma sessão na Max pessoal precisa salvar ou ler um
// artefato da org da empresa (a Team). Trocar a própria sessão de conta reabriria o processo duas vezes, perderia o
// cache nas duas e trocaria os conectores do claude.ai no meio do trabalho; aqui a sessão segue onde está e só a
// tarefa roda na outra conta.
//
// O filho é estreito de propósito: só as ferramentas pedidas (por padrão, as de artefato e a leitura de arquivo),
// sem os settings do usuário (que podem liberar Bash ou MCP inteiros), sem os servidores MCP locais e sem nenhuma
// credencial herdada da sessão que pediu. Quem precisar de mais nomeia com --tools, e o que foi pedido vai para o
// registro.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const contas = require('./contas');
const agentes = require('./agentes');

const FERRAMENTAS_PADRAO = ['Artifact', 'ArtifactComments', 'ArtifactData', 'Read'];
// O alias do CLI, que acompanha o Haiku vigente: um id fixo faria todo `as` sem --model falhar quando fosse aposentado.
const MODELO_PADRAO = 'haiku';
const ARQ_ACESSOS = path.join(contas.DIR_ESTADO, 'acessos.jsonl');
const MAX_ACESSOS = 500;
const TAMANHO_DO_PEDIDO_NO_REGISTRO = 300;
const ESPERA_DA_ENTRADA_MS = 5000;

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

// O ambiente do filho sem nada que autentique por fora da pasta: um token ou chave herdado da sessão que pediu faria a
// tarefa rodar na conta dela com o banner dizendo outra. A mesma limpeza que a renovação de login faz, menos o
// CLAUDE_CODE_ENTRYPOINT: é ele que diz de onde a sessão veio, e as ferramentas de artefato só existem nas sessões do
// VS Code e do app desktop (medido em 05/11/2026: `claude-vscode` e `claude-desktop` têm o Artifact, `cli` e `sdk-cli`
// não). Ele não autentica nada.
const MANTIDAS = new Set(['CLAUDE_CODE_ENTRYPOINT']);
const DE_ARTEFATO = new Set(['Artifact', 'ArtifactComments', 'ArtifactData']);
const ENTRADAS_COM_ARTEFATO = new Set(['claude-vscode', 'claude-desktop']);

function ambienteLimpo(base = process.env) {
  const env = { ...base };
  for (const chave of Object.keys(env)) {
    if ((chave.startsWith('CLAUDE_CODE_') && !MANTIDAS.has(chave)) || chave === 'CLAUDECODE') delete env[chave];
  }
  for (const chave of ['CLAUDE_AUTO_CONTA', 'CLAUDE_CONFIG_DIR', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN']) delete env[chave];
  return env;
}

// Onde e com que login a tarefa roda, ou o motivo de não rodar. A pasta é a mesma que uma sessão nova da conta usaria
// (`envDaSessao`). Aqui vale o login que a pasta declara; o token dela é conferido depois, em `conferirToken`.
function planejar(id, opcoes, cfg = contas.carregarConfig(), base = process.env) {
  if (!cfg.contas[id] || cfg.contas[id].pendente) {
    return { erro: `unknown account: ${id}. Accounts: ${Object.keys(cfg.contas).filter((c) => !cfg.contas[c].pendente).join(', ')}` };
  }
  if (!opcoes.pedido) return { erro: 'empty request: say what to do on that account' };
  const env = { ...contas.envDaSessao(id, ambienteLimpo(base), cfg), CLAUDE_AUTO_CONTA: id };
  const dir = env.CLAUDE_CONFIG_DIR || contas.DIR_PRINCIPAL;
  const declarado = contas.loginDaPasta(dir);
  // Na pasta do ~/.claude, quem está lá é a conta segundo `identidade` (que corrige o ~/.claude.json regravado por uma
  // sessão antiga depois de uma troca dos agentes); nas outras pastas, o que a pasta declara.
  const login = path.resolve(dir) === path.resolve(contas.DIR_PRINCIPAL) ? { ...contas.identidade(id, cfg) } : declarado;
  if (!login.chave) return { erro: `${id} has no login in ${dir}: run ${refazerLogin(id, cfg)}` };
  const outra = contaDaChave(login.chave, id, cfg);
  if (outra || (!contas.usaDirPadrao(id, cfg) && contas.loginDeOutraContaDaFila(id, cfg))) {
    const de = outra ? ` (${contas.nomeDaConta(outra, cfg)})` : '';
    return { erro: `${dir} is signed in to ${contas.rotuloDoLoginDaPasta(login)}${de}, not to ${id}; fix it with ${refazerLogin(id, cfg)}` };
  }
  const onde = contas.rotuloDoLoginDaPasta(login);
  const { ferramentas, liberadas } = permissoes(opcoes.ferramentas, opcoes.pedido);
  // O pedido vai pela entrada padrão do filho, nunca em argv: um pedido que começa com "-" (uma lista em markdown)
  // seria lido como opção do CLI.
  const args = [
    '-p',
    '--tools', ferramentas.join(','),
    ...(liberadas.length ? ['--allowedTools', liberadas.join(',')] : []),
    '--model', opcoes.modelo,
    '--no-session-persistence',
    '--setting-sources', 'project',
    '--strict-mcp-config',
    '--append-system-prompt',
    `Você roda com o login ${onde} (conta ${id}), a pedido de outra sessão e só para esta tarefa. ` +
      'Termine dizendo em que conta e organização a operação foi feita e o link de cada artefato que criou, mudou ou leu.',
  ];
  const semArtefato = opcoes.ferramentas.some((f) => DE_ARTEFATO.has(f)) && !ENTRADAS_COM_ARTEFATO.has(env.CLAUDE_CODE_ENTRYPOINT);
  const aviso = semArtefato
    ? 'the Artifact tools only exist in Claude Code sessions from VS Code or the desktop app; run this from one of them'
    : null;
  return { id, env, dir, login, onde, args, aviso, pedido: opcoes.pedido, ferramentas: opcoes.ferramentas, modelo: opcoes.modelo };
}

// As ferramentas que o filho tem e as que ele usa sem pedir. Leitura sem escopo (`Read`, `Glob`, `Grep`) fica fora da
// segunda lista: o filho lê artefatos de terceiros, e um artefato com instrução embutida levaria o modelo a ler
// `~/.ssh`, um `.env` ou as pastas das contas e devolver o conteúdo num comentário. Sem a regra, o `-p` lê só o
// diretório atual e nega o resto sem perguntar (medido em 05/11/2026). Um caminho absoluto que o próprio pedido cita, e
// que existe, ganha a regra só para ele (`Read(//caminho)`, ou `/**` numa pasta): é o "publique /x/relatorio.html".
// Quem nomeia uma regra com escopo em --tools (`Read(//x/**)`) a tem como escrita.
//
// A regra é fechada, porque um " / " solto num pedido em português liberaria a máquina inteira: nunca a raiz, o home
// nem um ancestral dele; nunca o que está dentro de uma pasta sensível ou a contém (chaves, as pastas do Claude e das
// contas, o Keychain); pasta só com 3 níveis ou mais (`/Users/x/projeto`, não `/opt/x`). Sai nas duas formas quando
// diferem, a citada (`/tmp/x.html`) e a resolvida (`/private/tmp/x.html`), e as duas passam pelos mesmos cortes.
const LEITURA_SEM_ESCOPO = new Set(['Read', 'Glob', 'Grep']);
const SENSIVEIS_NO_HOME = ['.ssh', '.gnupg', '.aws', '.claude', '.claude-accounts', '.config/aegro', 'Library/Keychains'];

const contem = (pasta, p) => p === pasta || p.startsWith(pasta.endsWith('/') ? pasta : `${pasta}/`);

function comAsDuasFormas(caminhos) {
  const formas = new Set();
  for (const c of caminhos) {
    formas.add(path.resolve(c));
    try {
      formas.add(fs.realpathSync(c));
    } catch {}
  }
  return [...formas];
}

function leituraPermitida(p, { home, sensiveis }) {
  if (home.some((h) => contem(p, h))) return false;
  return !sensiveis.some((s) => contem(s, p) || contem(p, s));
}

function caminhosDoPedido(pedido, home = os.homedir()) {
  const limites = {
    home: comAsDuasFormas([home]),
    sensiveis: comAsDuasFormas([...SENSIVEIS_NO_HOME.map((s) => path.join(home, s)), contas.DIR_CONTAS, contas.DIR_PRINCIPAL]),
  };
  const caminhos = [];
  for (const bruto of String(pedido).split(/\s+/)) {
    const t = bruto.replace(/^["'`(<[]+/, '').replace(/["'`)>\],;:!?.]+$/, '');
    if (!t.startsWith('/') && !t.startsWith('~/')) continue;
    const citado = path.resolve(t.startsWith('~/') ? path.join(home, t.slice(2)) : t);
    let real;
    let pasta;
    try {
      real = fs.realpathSync(citado);
      pasta = fs.statSync(real).isDirectory();
    } catch {
      continue;
    }
    const formas = [...new Set([citado, real])];
    if (!formas.every((f) => leituraPermitida(f, limites))) continue;
    if (pasta && real.split('/').filter(Boolean).length < 3) continue;
    for (const f of formas) caminhos.push(pasta ? `${f}/**` : f);
  }
  return [...new Set(caminhos)];
}

function permissoes(pedidas, pedido) {
  const ferramentas = [...new Set(pedidas.map((f) => f.replace(/\(.*\)$/, '')))];
  const liberadas = pedidas.filter((f) => !LEITURA_SEM_ESCOPO.has(f));
  if (ferramentas.includes('Read')) liberadas.push(...caminhosDoPedido(pedido).map((c) => `Read(/${c})`));
  return { ferramentas, liberadas: [...new Set(liberadas)] };
}

// O comando que conserta o login da pasta. Para a conta do ~/.claude, `login <id>` entraria no próprio ~/.claude, que é
// o slot dos agentes, e desfaria a troca deles; o certo é dar a ela a pasta própria, que a sessão nova já prefere.
function refazerLogin(id, cfg) {
  return contas.usaDirPadrao(id, cfg) ? contas.comandoParaRefazerLoginProprio(id) : `claude-accounts login ${id}`;
}

function contaDaChave(chave, exceto, cfg) {
  return [...new Set([...cfg.rota, ...cfg.reserva])].find((o) => o !== exceto && contas.identidade(o, cfg).chave === chave) || null;
}

// A verdade do login é o token, não o .claude.json: uma sessão antiga regrava o arquivo com o login que tem em memória,
// e a troca dos agentes muda o token do ~/.claude sem mudar o arquivo de quem ainda está aberto. O perfil da API diz de
// quem é o token, sem renovar nada. Token vencido não dá para conferir (o CLI o renova ao rodar): vale o declarado, com
// aviso. Sem resposta da API, o mesmo.
async function conferirToken(plano, cfg = contas.carregarConfig(), { lerItem = contas.lerItemDaPasta, conferir = agentes.conferirLogin } = {}) {
  const item = await lerItem(plano.dir);
  if (!item) return { erro: `${plano.id} has no login in ${plano.dir}: run ${refazerLogin(plano.id, cfg)}` };
  const r = await conferir(item);
  if (r.valido === false && !r.chave) return { erro: `the ${plano.id} login in ${plano.dir} no longer works (${r.motivo}): run ${refazerLogin(plano.id, cfg)}` };
  if (!r.chave || r.vencido) return { aviso: `could not check the token in ${plano.dir} (${r.vencido ? 'expired, the CLI renews it' : r.motivo}); going by the login the folder declares` };
  if (r.chave === plano.login.chave) return {};
  const outra = contaDaChave(r.chave, plano.id, cfg);
  const dela = outra ? `${contas.nomeDaConta(outra, cfg)} (${outra})` : 'an account outside the queue';
  return { erro: `the token in ${plano.dir} belongs to ${dela}, not to ${plano.id} (${plano.onde}); fix it with ${refazerLogin(plano.id, cfg)}` };
}

// Cada tarefa vira uma linha em `.estado/acessos.jsonl`: quem pediu (a conta da sessão de origem), em que conta rodou,
// com que ferramentas, de qual pasta e o começo do pedido. A linha nasce antes de o filho rodar (`codigo: null`) e é
// completada no fim, para que uma tarefa cujo pai morreu no meio ainda apareça. Só do dono (0600), últimas 500, sob a
// trava de arquivo do roteador para duas tarefas paralelas não se apagarem.
function registrar(entrada, arquivo = ARQ_ACESSOS) {
  try {
    contas.comTravaDeArquivo(arquivo, () => {
      const linhas = fs.existsSync(arquivo) ? fs.readFileSync(arquivo, 'utf8').split('\n').filter(Boolean) : [];
      const i = entrada.id ? linhas.findIndex((l) => l.includes(`"id":${JSON.stringify(entrada.id)}`)) : -1;
      if (i >= 0) linhas[i] = JSON.stringify(entrada);
      else linhas.push(JSON.stringify(entrada));
      const tmp = `${arquivo}.${process.pid}.tmp`;
      fs.writeFileSync(tmp, linhas.slice(-MAX_ACESSOS).join('\n') + '\n', { mode: 0o600 });
      fs.renameSync(tmp, arquivo);
    });
  } catch (e) {
    contas.log(`as: não deu para registrar o acesso: ${e.message}`);
  }
}

function lerAcessos(limite = 20, arquivo = ARQ_ACESSOS) {
  const n = Number.isInteger(limite) && limite > 0 ? limite : 20;
  try {
    return fs.readFileSync(arquivo, 'utf8').split('\n').filter(Boolean).slice(-n).reverse()
      .map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  } catch {
    return [];
  }
}

// O pedido pela entrada padrão (`echo … | claude-accounts as <conta>`). Uma entrada que não é terminal mas também não
// manda nada (um script que herdou um pipe aberto) não segura o comando: sem dado em 5 s, o pedido fica vazio. O prazo
// recomeça a cada pedaço, então uma entrada que mandou algo e ficou aberta vale pelo que chegou, 5 s depois do último.
function lerEntrada(entrada = process.stdin, esperaMs = ESPERA_DA_ENTRADA_MS) {
  if (entrada.isTTY) return Promise.resolve('');
  return new Promise((resolve) => {
    let texto = '';
    const parar = () => {
      entrada.pause();
      resolve(texto.trim());
    };
    let espera = setTimeout(parar, esperaMs);
    entrada.setEncoding('utf8');
    entrada.on('data', (d) => {
      texto += d;
      clearTimeout(espera);
      espera = setTimeout(parar, esperaMs);
    });
    entrada.on('end', () => {
      clearTimeout(espera);
      resolve(texto.trim());
    });
  });
}

// `verificarToken` e `preparar` existem para o teste rodar o ciclo inteiro sem ler o Keychain, sem chamar a API de
// perfil e sem ligar a pasta da conta ao ~/.claude de quem roda os testes.
async function rodar(args, { verificarToken = conferirToken, preparar = contas.prepararSessao } = {}) {
  const opcoes = lerArgs(args);
  if (opcoes.erro) {
    process.stderr.write(`claude-accounts: ${opcoes.erro}\n`);
    return 2;
  }
  if (!opcoes.pedido) opcoes.pedido = await lerEntrada();
  const cfg = contas.carregarConfig();
  const plano = planejar(opcoes.id, opcoes, cfg);
  const token = plano.erro ? null : await verificarToken(plano, cfg);
  const erro = plano.erro || (token && token.erro);
  if (erro) {
    process.stderr.write(`claude-accounts: ${erro}\n`);
    return 2;
  }
  for (const aviso of [plano.aviso, token.aviso].filter(Boolean)) process.stderr.write(`claude-accounts: ${aviso}\n`);
  const de = process.env.CLAUDE_AUTO_CONTA || null;
  process.stderr.write(`claude-accounts as ${plano.id}: ${plano.onde}, one task, tools ${plano.ferramentas.join(', ')}\n`);
  contas.log(`as: ${de || 'terminal'} pediu uma tarefa em ${plano.id} (${plano.onde}), ferramentas ${plano.ferramentas.join(',')}`);
  preparar(plano.id, plano.env, cfg);
  const inicio = Date.now();
  const entrada = {
    id: `${process.pid}-${inicio}`,
    em: inicio,
    de,
    conta: plano.id,
    login: plano.login.email,
    organizacao: plano.login.organizacao,
    ferramentas: plano.ferramentas,
    modelo: plano.modelo,
    cwd: process.cwd(),
    pedido: plano.pedido.slice(0, TAMANHO_DO_PEDIDO_NO_REGISTRO),
    codigo: null,
    ms: null,
  };
  registrar(entrada);
  // O Ctrl-C do terminal já chega ao filho, que está no mesmo grupo; o resto (o Bash de uma sessão que estourou o
  // prazo, um terminal fechado) só chega ao pai, que repassa. Os ouvintes saem quando o filho acaba.
  const ouvintes = [];
  const codigo = await new Promise((resolve) => {
    let filho;
    try {
      filho = spawn(contas.resolverClaude(), plano.args, { env: plano.env, stdio: ['pipe', 'inherit', 'inherit'] });
    } catch (e) {
      process.stderr.write(`claude-accounts: could not start claude: ${e.message}\n`);
      resolve(1);
      return;
    }
    ouvintes.push(['SIGINT', () => {}]);
    for (const sinal of ['SIGTERM', 'SIGHUP']) ouvintes.push([sinal, () => filho.kill(sinal)]);
    for (const [sinal, f] of ouvintes) process.on(sinal, f);
    filho.on('error', (e) => {
      process.stderr.write(`claude-accounts: could not start claude: ${e.message}\n`);
      resolve(1);
    });
    filho.on('exit', (c, sinal) => resolve(c ?? (sinal ? 128 : 1)));
    filho.stdin.on('error', () => {});
    filho.stdin.end(plano.pedido);
  });
  for (const [sinal, f] of ouvintes) process.removeListener(sinal, f);
  registrar({ ...entrada, codigo, ms: Date.now() - inicio });
  return codigo;
}

module.exports = {
  lerArgs,
  ambienteLimpo,
  planejar,
  conferirToken,
  registrar,
  lerAcessos,
  lerEntrada,
  caminhosDoPedido,
  rodar,
  FERRAMENTAS_PADRAO,
  MODELO_PADRAO,
  ARQ_ACESSOS,
};
