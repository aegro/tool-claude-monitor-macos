'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execFile, execFileSync, spawn, spawnSync } = require('child_process');

const HOME = os.homedir();
const PRINCIPAL_PADRAO = 'principal';
const DIR_PRINCIPAL = path.join(HOME, '.claude');
const ARQ_CONFIG_PRINCIPAL = path.join(HOME, '.claude.json');
const DIR_CONTAS = process.env.CLAUDE_AUTO_HOME || path.join(HOME, '.claude-accounts');
const DIR_ESTADO = path.join(DIR_CONTAS, '.estado');
const ARQ_CONFIG = path.join(DIR_CONTAS, 'config.json');
const ARQ_USO = path.join(DIR_ESTADO, 'uso.json');
const ARQ_ESGOTADAS = path.join(DIR_ESTADO, 'esgotadas.json');
const ARQ_TROCAS = path.join(DIR_ESTADO, 'trocas.jsonl');
const ARQ_LOG = path.join(DIR_ESTADO, 'claude-auto.log');
const DIR_AO_VIVO = path.join(DIR_ESTADO, 'ao-vivo');
const URL_USO = 'https://api.anthropic.com/api/oauth/usage';
const ARQ_CONSENTIMENTO = 'remote-settings-consent.json';

const COMPARTILHADOS = [
  'settings.json', 'CLAUDE.md', 'AGENTS.md', 'keybindings.json', 'statusline-command.sh', 'history.jsonl',
  'hooks', 'skills', 'plugins', 'agents', 'commands', 'output-styles', 'themes', 'projects',
  'file-history', 'tasks', 'todos', 'plans', 'paste-cache', 'session-env', 'skill-suggest',
];
const DIRS_GARANTIDOS = new Set([
  'hooks', 'skills', 'plugins', 'agents', 'commands', 'projects', 'file-history', 'tasks', 'todos', 'plans',
  'paste-cache', 'session-env',
]);

const CHAVES_CONFIG = [
  'mcpServers', 'hasCompletedOnboarding', 'lastOnboardingVersion', 'theme', 'autoUpdates', 'installMethod',
  'autoUpdatesProtectedForNative', 'bypassPermissionsModeAccepted', 'hasSeenAutoModeEntryWarning',
  'hasResetAutoModeOptInForDefaultOffer', 'optionAsMetaKeyInstalled', 'editorMode', 'verbose',
  'preferredNotifChannel', 'autoCompactEnabled', 'diffTool', 'hasSeenTasksHint', 'claudeInChromeDefaultEnabled',
  'officialMarketplaceAutoInstallAttempted', 'officialMarketplaceAutoInstalled',
];
const CHAVES_PROJETO = [
  'hasTrustDialogAccepted', 'allowedTools', 'mcpServers', 'enabledMcpjsonServers', 'disabledMcpjsonServers',
  'disabledMcpServers', 'enabledMcpServers', 'hasCompletedProjectOnboarding', 'projectOnboardingSeenCount',
  'mcpContextUris', 'ignorePatterns', 'hasClaudeMdExternalIncludesApproved', 'hasClaudeMdExternalIncludesWarningShown',
];

const TRAVA_DE_ARQUIVO_VELHA_MS = 10000;
const PRAZO_DA_TRAVA_DE_ARQUIVO_MS = 5000;

const CONFIG_PADRAO = {
  principal: PRINCIPAL_PADRAO,
  reserva: [],
  limites: { reserva: 3, preventiva: 5, voltar: 20, horizonteMinutos: 2, margem: 2 },
  ativo: true,
  cacheUsoSegundos: 60,
  notificar: true,
};

function lerJson(arquivo, padrao) {
  try {
    return JSON.parse(fs.readFileSync(arquivo, 'utf8'));
  } catch {
    return padrao;
  }
}

function escreverJson(arquivo, dados) {
  fs.mkdirSync(path.dirname(arquivo), { recursive: true });
  const tmp = `${arquivo}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(dados, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(tmp, arquivo);
}

function dormir(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function inodeDaTravaVelha(dir, agora = Date.now()) {
  try {
    const info = fs.statSync(dir);
    return agora - info.mtimeMs > TRAVA_DE_ARQUIVO_VELHA_MS ? info.ino : null;
  } catch {
    return null;
  }
}

function marcarTomada(tomada) {
  for (let tentativa = 0; tentativa < 2; tentativa += 1) {
    try {
      fs.mkdirSync(tomada);
      return true;
    } catch (e) {
      if (e.code !== 'EEXIST' || inodeDaTravaVelha(tomada) == null) return false;
      try {
        fs.rmdirSync(tomada);
      } catch {}
    }
  }
  return false;
}

function soltarTravaDeArquivo(dir, dono) {
  try {
    if (fs.statSync(dir).ino !== dono) return;
    try {
      fs.rmdirSync(dir);
    } catch (e) {
      if (e.code !== 'ENOTEMPTY' && e.code !== 'EEXIST') return;
      const tomada = path.join(dir, 'tomada');
      // Tomada fresca é de um tomador vivo que já conferiu o inode desta trava: ela fica para ele terminar,
      // senão um terceiro pegaria uma trava nova que esse tomador renomearia em seguida.
      if (inodeDaTravaVelha(tomada) == null) return;
      fs.rmdirSync(tomada);
      fs.rmdirSync(dir);
    }
  } catch {}
}

function tomarTravaDeArquivo(dir) {
  try {
    fs.mkdirSync(dir);
    return fs.statSync(dir).ino;
  } catch (e) {
    if (e.code !== 'EEXIST') throw e;
  }
  const velha = inodeDaTravaVelha(dir);
  if (velha == null) return null;
  const tomada = path.join(dir, 'tomada');
  if (!marcarTomada(tomada)) return null;
  let inode = null;
  try {
    inode = fs.statSync(dir).ino;
  } catch {}
  if (inode !== velha) {
    try {
      fs.rmdirSync(tomada);
    } catch {}
    return null;
  }
  const afastada = `${dir}.${process.pid}.${crypto.randomUUID()}`;
  try {
    fs.renameSync(dir, afastada);
  } catch {
    return null;
  }
  fs.rmSync(afastada, { recursive: true, force: true });
  return null;
}

function comTravaDeArquivo(arquivo, fn, { prazoMs = PRAZO_DA_TRAVA_DE_ARQUIVO_MS } = {}) {
  fs.mkdirSync(path.dirname(arquivo), { recursive: true });
  const dir = `${arquivo}.lock`;
  const limite = Date.now() + prazoMs;
  let dono = tomarTravaDeArquivo(dir);
  while (dono == null) {
    if (Date.now() >= limite) throw new Error(`${arquivo} is being changed by another process; try again`);
    dormir(50);
    dono = tomarTravaDeArquivo(dir);
  }
  try {
    return fn();
  } finally {
    soltarTravaDeArquivo(dir, dono);
  }
}

function atualizarJson(arquivo, mudar, opcoes) {
  return comTravaDeArquivo(
    arquivo,
    () => {
      const atual = fs.existsSync(arquivo) ? lerJson(arquivo, null) : {};
      if (!atual || typeof atual !== 'object' || Array.isArray(atual)) {
        throw new Error(`${arquivo} is not valid JSON; fix it before changing accounts`);
      }
      const novo = mudar(atual);
      if (novo) escreverJson(arquivo, novo);
      return novo;
    },
    opcoes,
  );
}

function atualizarConfig(mudar) {
  return atualizarJson(ARQ_CONFIG, (salvo) => mudar(salvo, normalizarConfig(salvo)));
}

function carregarConfig() {
  return normalizarConfig(lerJson(ARQ_CONFIG, {}));
}

function normalizarConfig(lido) {
  const salvo = lido && typeof lido === 'object' && !Array.isArray(lido) ? lido : {};
  const principal = salvo.principal || PRINCIPAL_PADRAO;
  const cfg = {
    ...CONFIG_PADRAO,
    ...salvo,
    principal,
    contas: { [principal]: { nome: principal === PRINCIPAL_PADRAO ? 'Principal' : principal }, ...(salvo.contas || {}) },
    limites: { ...CONFIG_PADRAO.limites, ...(salvo.limites || {}) },
  };
  cfg.rota = (cfg.rota || []).filter((id) => cfg.contas[id]);
  if (!cfg.rota.length) cfg.rota = [principal];
  cfg.reserva = (cfg.reserva || []).filter((id) => cfg.contas[id] && !cfg.rota.includes(id));
  if (cfg.fixada && !cfg.rota.includes(cfg.fixada) && !cfg.reserva.includes(cfg.fixada)) delete cfg.fixada;
  return cfg;
}

function definirPrincipal(id) {
  atualizarConfig((salvo, atual) =>
    atual.principal === id ? null : { ...salvo, principal: id, contas: atual.contas, rota: atual.rota },
  );
}

function expandir(p) {
  return p.startsWith('~/') ? path.join(HOME, p.slice(2)) : p;
}

function dirDaConta(id, cfg = carregarConfig()) {
  const conta = cfg.contas[id] || {};
  if (conta.dir) return path.resolve(expandir(conta.dir));
  return id === cfg.principal ? DIR_PRINCIPAL : path.join(DIR_CONTAS, id);
}

function usaDirPadrao(id, cfg = carregarConfig()) {
  return id === cfg.principal && !(cfg.contas[id] || {}).dir;
}

function arquivoConfigDaConta(id, cfg = carregarConfig()) {
  return usaDirPadrao(id, cfg) ? ARQ_CONFIG_PRINCIPAL : path.join(dirDaConta(id, cfg), '.claude.json');
}

function nomeDaConta(id, cfg = carregarConfig()) {
  return (cfg.contas[id] && cfg.contas[id].nome) || id;
}

function envDaConta(id, base = process.env) {
  const cfg = carregarConfig();
  const env = { ...base, CLAUDE_AUTO_CONTA: id };
  if (usaDirPadrao(id, cfg)) delete env.CLAUDE_CONFIG_DIR;
  else env.CLAUDE_CONFIG_DIR = dirDaConta(id, cfg);
  return env;
}

// A pasta própria de uma conta (~/.claude-accounts/<id>), mesmo quando ela é a do ~/.claude agora.
function dirPropria(id, cfg = carregarConfig()) {
  const conta = cfg.contas[id] || {};
  return conta.dir ? path.resolve(expandir(conta.dir)) : path.join(DIR_CONTAS, id);
}

// Se a conta tem login na pasta própria (o item do Keychain existe; o valor não é lido).
function temLoginProprio(id, cfg = carregarConfig()) {
  if (process.platform !== 'darwin') return fs.existsSync(path.join(dirPropria(id, cfg), '.credentials.json'));
  const hash = crypto.createHash('sha256').update(dirPropria(id, cfg)).digest('hex').slice(0, 8);
  const r = spawnSync('security', ['find-generic-password', '-s', `Claude Code-credentials-${hash}`], { stdio: 'ignore', timeout: 8000 });
  return r.status === 0;
}

// O ambiente de uma sessão de stream (VS Code, T3). Ela abre na pasta própria da conta sempre que ali há login,
// mesmo quando a conta é a do ~/.claude: a troca dos agentes troca o login do ~/.claude, e uma sessão aberta lá
// relê o Keychain e passa a gastar a conta que entrou, com o nome da que saiu (09/10: sessões da Max gastando a
// Squad Compare). Sem login próprio, fica no ~/.claude, como antes.
function envDaSessao(id, base = process.env) {
  const cfg = carregarConfig();
  if (!usaDirPadrao(id, cfg) || !temLoginProprio(id, cfg)) return envDaConta(id, base);
  return { ...base, CLAUDE_AUTO_CONTA: id, CLAUDE_CONFIG_DIR: dirPropria(id, cfg) };
}

function log(mensagem) {
  try {
    fs.mkdirSync(DIR_ESTADO, { recursive: true });
    try {
      if (fs.statSync(ARQ_LOG).size > 5 * 1024 * 1024) fs.renameSync(ARQ_LOG, `${ARQ_LOG}.1`);
    } catch {}
    fs.appendFileSync(ARQ_LOG, `${new Date().toISOString()} [${process.pid}] ${mensagem}\n`);
  } catch {}
}

function garantirLink(origem, destino) {
  let atual = null;
  try {
    atual = fs.lstatSync(destino);
  } catch {}
  if (atual && atual.isSymbolicLink()) {
    if (fs.readlinkSync(destino) === origem) return;
    fs.unlinkSync(destino);
  } else if (atual && atual.isDirectory() && fs.readdirSync(destino).length === 0) {
    fs.rmdirSync(destino);
  } else if (atual) {
    const reserva = `${destino}.local-${Date.now()}`;
    fs.renameSync(destino, reserva);
    log(`link: ${destino} já existia, movido para ${reserva}`);
  }
  fs.symlinkSync(origem, destino);
}

function prepararConta(id) {
  const cfg = carregarConfig();
  if (usaDirPadrao(id, cfg)) return;
  prepararPasta(id, dirDaConta(id, cfg), arquivoConfigDaConta(id, cfg));
}

// Prepara a pasta em que uma sessão de stream vai abrir (o `env` de envDaSessao). Para a conta do ~/.claude aberta
// na pasta própria, é o mesmo que uma conta extra recebe: os links, a config e os consentimentos da principal,
// que ficaram parados desde a última vez que ela não estava no ~/.claude. O ~/.claude em si não é tocado.
function prepararSessao(id, env = {}) {
  const cfg = carregarConfig();
  if (!usaDirPadrao(id, cfg)) return prepararConta(id);
  const dir = env.CLAUDE_CONFIG_DIR && path.resolve(env.CLAUDE_CONFIG_DIR);
  if (!dir || dir === path.resolve(DIR_PRINCIPAL)) return;
  prepararPasta(id, dir, path.join(dir, '.claude.json'));
}

function prepararPasta(id, dir, arquivoConfig) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (const nome of COMPARTILHADOS) {
    const origem = path.join(DIR_PRINCIPAL, nome);
    if (!fs.existsSync(origem)) {
      if (!DIRS_GARANTIDOS.has(nome)) continue;
      fs.mkdirSync(origem, { recursive: true });
    }
    try {
      garantirLink(origem, path.join(dir, nome));
    } catch (e) {
      log(`link: falhou para ${nome} em ${id}: ${e.message}`);
    }
  }
  copiarConfigDaPrincipal(id, arquivoConfig);
  sincronizarConsentimentos(dir);
}

function sincronizarConsentimentos(dir) {
  const origem = lerJson(path.join(DIR_PRINCIPAL, ARQ_CONSENTIMENTO), null);
  if (!origem || !origem.records) return false;
  const arquivo = path.join(dir, ARQ_CONSENTIMENTO);
  const alvo = lerJson(arquivo, { version: origem.version, records: {} });
  alvo.records = alvo.records || {};
  let mudou = false;
  for (const [org, registro] of Object.entries(origem.records)) {
    const atual = alvo.records[org];
    if (atual && (atual.updatedAt || 0) >= (registro.updatedAt || 0)) continue;
    alvo.records[org] = registro;
    mudou = true;
  }
  if (mudou) escreverJson(arquivo, alvo);
  return mudou;
}

function sincronizarConfig(id, cfg = carregarConfig()) {
  if (usaDirPadrao(id, cfg)) return false;
  return copiarConfigDaPrincipal(id, arquivoConfigDaConta(id, cfg));
}

function copiarConfigDaPrincipal(id, arquivo) {
  const origem = lerJson(ARQ_CONFIG_PRINCIPAL, null);
  if (!origem) return false;
  try {
    return Boolean(
      atualizarJson(arquivo, (alvo) => {
        const antes = JSON.stringify(alvo);
        for (const chave of CHAVES_CONFIG) {
          if (chave in origem) alvo[chave] = origem[chave];
        }
        alvo.projects = alvo.projects || {};
        for (const [projeto, dados] of Object.entries(origem.projects || {})) {
          const destino = (alvo.projects[projeto] = alvo.projects[projeto] || {});
          for (const chave of CHAVES_PROJETO) {
            if (chave in dados) destino[chave] = dados[chave];
          }
        }
        return JSON.stringify(alvo) === antes ? null : alvo;
      }),
    );
  } catch (e) {
    log(`config: não deu para copiar a config da principal para ${id}: ${e.message}`);
    return false;
  }
}

function servicoKeychain(id, cfg = carregarConfig()) {
  if (usaDirPadrao(id, cfg)) return 'Claude Code-credentials';
  const hash = crypto.createHash('sha256').update(dirDaConta(id, cfg)).digest('hex').slice(0, 8);
  return `Claude Code-credentials-${hash}`;
}

function executar(cmd, args, timeout = 8000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout, encoding: 'utf8' }, (erro, saida) => resolve(erro ? null : saida));
  });
}

async function lerCredencial(id, cfg = carregarConfig()) {
  let bruto = null;
  if (process.platform === 'darwin') {
    bruto = await executar('security', ['find-generic-password', '-s', servicoKeychain(id, cfg), '-w']);
  } else {
    try {
      bruto = fs.readFileSync(path.join(dirDaConta(id, cfg), '.credentials.json'), 'utf8');
    } catch {}
  }
  if (!bruto) return null;
  try {
    return JSON.parse(bruto.trim()).claudeAiOauth || null;
  } catch {
    return null;
  }
}

function chaveDaConta(conta) {
  return conta && conta.accountUuid ? [conta.accountUuid, conta.organizationUuid].filter(Boolean).join(':') : null;
}

// O login que a troca dos agentes guardou para a conta ao mexer no ~/.claude (.estado/agentes/<id>.json).
function loginGuardadoDaConta(id) {
  const guardado = lerJson(path.join(DIR_ESTADO, 'agentes', `${id}.json`), null);
  return guardado && guardado.oauthAccount && !guardado.invalidoEm ? guardado.oauthAccount : null;
}

// Quem está no ~/.claude. Depois que a troca dos agentes põe outra conta ali, uma sessão do Claude Code ainda
// aberta regrava o ~/.claude.json com o login com que começou: o arquivo passa a nomear uma conta que mora em outra
// pasta da fila, e a conta do ~/.claude parecia uma cópia dela. Quando o arquivo nomeia outra conta da fila e há o
// login guardado desta, vale o guardado. Só contam as contas que estão na fila (rota e reserva), como no Monitor: uma
// conta que saiu da fila e ficou em `contas` não troca o login que alguém pôs à mão no terminal.
function contaDoDirPadrao(id, cfg, declarada) {
  const guardada = loginGuardadoDaConta(id);
  const chave = chaveDaConta(declarada);
  if (!guardada || !chave || chaveDaConta(guardada) === chave) return declarada;
  const outras = new Set();
  for (const outro of [...cfg.rota, ...cfg.reserva]) {
    if (outro === id) continue;
    if (!usaDirPadrao(outro, cfg)) outras.add(chaveDaConta((lerJson(arquivoConfigDaConta(outro, cfg), {}) || {}).oauthAccount));
    outras.add(chaveDaConta(loginGuardadoDaConta(outro)));
  }
  return outras.has(chave) ? guardada : declarada;
}

function identidade(id, cfg = carregarConfig()) {
  const dados = lerJson(arquivoConfigDaConta(id, cfg), {});
  const declarada = dados.oauthAccount || {};
  const conta = (usaDirPadrao(id, cfg) ? contaDoDirPadrao(id, cfg, declarada) : declarada) || {};
  return {
    email: conta.emailAddress || null,
    organizacao: conta.organizationName || null,
    chave: conta.accountUuid ? [conta.accountUuid, conta.organizationUuid].filter(Boolean).join(':') : null,
  };
}

function rotuloDoLogin(id, email, sonda) {
  if (!sonda || sonda.semLogin) return `missing: claude-accounts login ${id}`;
  return email || 'logged in';
}

function contasDuplicadas(cfg = carregarConfig()) {
  const grupos = new Map();
  for (const id of Object.keys(cfg.contas)) {
    const ident = identidade(id, cfg);
    if (!ident.chave) continue;
    const grupo = grupos.get(ident.chave) || { email: ident.email, ids: [] };
    grupo.ids.push(id);
    grupos.set(ident.chave, grupo);
  }
  return [...grupos.values()].filter((g) => g.ids.length > 1);
}

function rotuloDaJanela(limite) {
  if (limite.kind === 'session') return 'Session (5h)';
  if (limite.kind === 'weekly_all') return 'Weekly (7d)';
  const escopo = limite.scope || {};
  const superficie = escopo.surface && (escopo.surface.display_name || escopo.surface);
  const nome = (escopo.model && escopo.model.display_name) || superficie || '';
  return nome ? `Weekly ${nome}` : `Weekly (${limite.kind})`;
}

function janelaSimples(bruta) {
  if (!bruta || typeof bruta.utilization !== 'number') return null;
  return { usado: bruta.utilization, renovaEm: bruta.resets_at ? Date.parse(bruta.resets_at) : null };
}

function normalizarUso(json) {
  const cinco = janelaSimples(json.five_hour);
  const sete = janelaSimples(json.seven_day);
  let janelas;
  if (Array.isArray(json.limits) && json.limits.length) {
    janelas = json.limits.map((limite) => ({
      chave: limite.kind,
      rotulo: rotuloDaJanela(limite),
      usado: typeof limite.percent === 'number' ? limite.percent : 0,
      renovaEm: limite.resets_at ? Date.parse(limite.resets_at) : null,
      severidade: limite.severity || null,
    }));
  } else {
    janelas = [];
    if (cinco) janelas.push({ chave: 'session', rotulo: 'Session (5h)', ...cinco });
    if (sete) janelas.push({ chave: 'weekly_all', rotulo: 'Weekly (7d)', ...sete });
    for (const [chave, valor] of Object.entries(json)) {
      const extra = chave.startsWith('seven_day_') && janelaSimples(valor);
      if (extra) janelas.push({ chave, rotulo: `Weekly ${chave.slice(10)}`, ...extra });
    }
  }
  return {
    cinco: cinco || janelas.find((j) => j.chave === 'session') || null,
    sete: sete || janelas.find((j) => j.chave === 'weekly_all') || null,
    janelas,
  };
}

function usadoEfetivo(janela, agora = Date.now()) {
  if (!janela) return 0;
  if (janela.renovaEm && janela.renovaEm <= agora) return 0;
  return janela.usado || 0;
}

function folgaDe(sonda, agora = Date.now()) {
  if (!sonda || !sonda.uso) return null;
  const usado = Math.max(usadoEfetivo(sonda.uso.cinco, agora), usadoEfetivo(sonda.uso.sete, agora));
  return Math.max(0, Math.min(100, Math.round(100 - usado)));
}

async function sondar(id, cfg = carregarConfig(), credencialDada = null) {
  const inicio = Date.now();
  const credencial = credencialDada || (await lerCredencial(id, cfg));
  if (!credencial || !credencial.accessToken) {
    return { ok: false, erro: 'sem login', semLogin: true, verificadoEm: Date.now() };
  }
  const base = { plano: credencial.subscriptionType || null };
  if (credencial.expiresAt && credencial.expiresAt <= Date.now()) {
    return { ...base, ok: false, erro: 'token expired, refreshes when the account is used', verificadoEm: Date.now() };
  }
  try {
    const resposta = await fetch(URL_USO, {
      headers: {
        Authorization: `Bearer ${credencial.accessToken}`,
        'anthropic-beta': 'oauth-2025-04-20',
        'Content-Type': 'application/json',
        'User-Agent': 'claude-auto/1.0',
      },
      signal: AbortSignal.timeout(10000),
    });
    const ms = Date.now() - inicio;
    if (resposta.status === 429) {
      const segundos = Number(resposta.headers.get('retry-after')) || 120;
      return { ...base, ok: false, erro: 'HTTP 429', limitada: true, esperarAte: Date.now() + segundos * 1000, ms, verificadoEm: Date.now() };
    }
    if (!resposta.ok) return { ...base, ok: false, erro: `HTTP ${resposta.status}`, ms, verificadoEm: Date.now() };
    return { ...base, ok: true, ms, verificadoEm: Date.now(), uso: normalizarUso(await resposta.json()) };
  } catch (e) {
    return { ...base, ok: false, erro: e.name === 'TimeoutError' ? 'timeout' : e.message, verificadoEm: Date.now() };
  }
}

async function lerUso(id, { maxIdadeMs, credencial = null, chaveDoCache = id } = {}) {
  const cfg = carregarConfig();
  const limite = maxIdadeMs ?? cfg.cacheUsoSegundos * 1000;
  const anterior = lerJson(ARQ_USO, {})[chaveDoCache];
  if (anterior && anterior.ok && Date.now() - anterior.verificadoEm < limite) return anterior;
  if (anterior && anterior.esperarAte && Date.now() < anterior.esperarAte) return anterior;
  const atual = await sondar(id, cfg, credencial);
  if (!atual.ok && anterior && anterior.uso) {
    atual.uso = anterior.uso;
    atual.usoDe = anterior.usoDe || anterior.verificadoEm;
  }
  const cache = lerJson(ARQ_USO, {});
  cache[chaveDoCache] = atual;
  try {
    escreverJson(ARQ_USO, cache);
  } catch {}
  return atual;
}

function lerEsgotadas() {
  const todas = lerJson(ARQ_ESGOTADAS, {});
  const agora = Date.now();
  return Object.fromEntries(Object.entries(todas).filter(([, v]) => v && v.ate > agora));
}

function prazoPadrao(id, motivo) {
  const cache = lerJson(ARQ_USO, {})[id];
  const uso = cache && cache.uso;
  const agora = Date.now();
  if (uso) {
    const janela = motivo === 'five_hour' ? uso.cinco : String(motivo).startsWith('seven_day') ? uso.sete : null;
    if (janela && janela.renovaEm > agora) return janela.renovaEm;
    const cheias = (uso.janelas || []).filter((j) => j.usado >= 98 && j.renovaEm > agora).map((j) => j.renovaEm);
    if (cheias.length) return Math.max(...cheias);
  }
  if (['auth', 'cobranca', 'conta_suspensa'].includes(motivo)) return agora + 6 * 3600 * 1000;
  return agora + 3600 * 1000;
}

function marcarEsgotada(id, ate, motivo) {
  const todas = lerEsgotadas();
  todas[id] = { ate: ate && ate > Date.now() ? ate : prazoPadrao(id, motivo), motivo, em: Date.now() };
  escreverJson(ARQ_ESGOTADAS, todas);
  log(`conta ${id} marcada como esgotada até ${new Date(todas[id].ate).toISOString()} (${motivo})`);
}

function liberar(id) {
  const todas = lerEsgotadas();
  delete todas[id];
  escreverJson(ARQ_ESGOTADAS, todas);
}

async function avaliarContas({ maxIdadeMs } = {}) {
  const cfg = carregarConfig();
  const ids = [...cfg.rota, ...cfg.reserva];
  const sondas = await Promise.all(ids.map((id) => lerUso(id, { maxIdadeMs })));
  const esgotadas = lerEsgotadas();
  return ids.map((id, i) => ({
    id,
    nome: nomeDaConta(id, cfg),
    papel: cfg.rota.includes(id) ? 'rota' : 'reserva',
    sonda: sondas[i],
    folga: folgaDe(sondas[i]),
    esgotada: esgotadas[id] || null,
    logada: !sondas[i].semLogin,
  }));
}

function decidir(candidatos, { excluir = [] } = {}) {
  const cfg = carregarConfig();
  const ordem = candidatos.map((c) => c.id);
  const pontos = (c) => (c.folga == null ? 1 : c.folga);
  const elegivel = (c) => !excluir.includes(c.id) && !c.esgotada && c.logada && pontos(c) > 0;
  // A conta que a pessoa escolheu à mão (`fixada`) vale acima da regra enquanto tiver como abrir sessão; esgotada,
  // sem login ou deixada de fora por uma troca, a regra volta a decidir.
  const fixada = cfg.fixada && candidatos.find((c) => c.id === cfg.fixada);
  if (fixada && elegivel(fixada)) return fixada;
  const preferida = cfg.preferida && candidatos.find((c) => c.id === cfg.preferida);
  if (preferida && elegivel(preferida) && pontos(preferida) >= cfg.limites.reserva) return preferida;
  const melhor = (lista) =>
    lista.filter(elegivel).sort((a, b) => pontos(b) - pontos(a) || ordem.indexOf(a.id) - ordem.indexOf(b.id))[0] || null;
  const daRota = melhor(candidatos.filter((c) => c.papel === 'rota'));
  let escolhida = daRota;
  if (!daRota || pontos(daRota) < cfg.limites.reserva) {
    const daReserva = melhor(candidatos.filter((c) => c.papel === 'reserva'));
    if (daReserva && (!daRota || pontos(daReserva) > pontos(daRota))) escolhida = daReserva;
  }
  return escolhida;
}

function preferidaDeVolta(candidatos, atual, cfg = carregarConfig()) {
  if (cfg.fixada || !cfg.preferida || cfg.preferida === atual) return null;
  const c = candidatos.find((x) => x.id === cfg.preferida);
  if (!c || c.esgotada || !c.logada || c.folga == null || c.folga < cfg.limites.voltar) return null;
  return c;
}

async function escolher({ excluir = [], maxIdadeMs } = {}) {
  const candidatos = await avaliarContas({ maxIdadeMs });
  const escolhida = decidir(candidatos, { excluir });
  return { escolhida: escolhida ? escolhida.id : null, folga: escolhida ? escolhida.folga : null, candidatos };
}

function notificar(titulo, texto) {
  if (!carregarConfig().notificar) return;
  try {
    if (process.platform === 'darwin') {
      const esc = (s) => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
      spawn('osascript', ['-e', `display notification "${esc(texto)}" with title "${esc(titulo)}"`], {
        stdio: 'ignore',
        detached: true,
      }).unref();
    } else {
      spawn('notify-send', [titulo, texto], { stdio: 'ignore', detached: true }).on('error', () => {}).unref();
    }
  } catch {}
}

function apararTrocas() {
  try {
    if (fs.statSync(ARQ_TROCAS).size <= 1024 * 1024) return;
    const recentes = fs.readFileSync(ARQ_TROCAS, 'utf8').split('\n').filter(Boolean).slice(-1000);
    const tmp = `${ARQ_TROCAS}.${process.pid}.${Date.now()}.tmp`;
    fs.writeFileSync(tmp, recentes.join('\n') + '\n');
    fs.renameSync(tmp, ARQ_TROCAS);
  } catch {}
}

function motivoLegivel(motivo) {
  const texto = String(motivo || '');
  const base = texto.startsWith('agents ') ? texto.slice('agents '.length) : texto;
  if (base === 'five_hour') return 'bateu o limite de 5h';
  if (base.startsWith('seven_day')) return 'bateu o limite da semana';
  if (base === 'limite' || base === 'rate_limit') return 'bateu o limite';
  if (base === 'auth') return 'pediu login de novo';
  if (base === 'cobranca') return 'deu erro de cobrança';
  if (base === 'conta_suspensa') return 'teve a conta suspensa';
  if (base === 'preventiva') return 'estava quase no limite';
  if (base === 'ao abrir') return 'estava sem folga quando os agentes abriram';
  if (base === 'manual') return 'foi trocada à mão';
  if (base === 'escolhida') return 'deu lugar à conta que você escolheu';
  if (base === 'teste') return 'saiu num teste de troca';
  return 'ficou sem folga';
}

function eLimite(motivo) {
  const base = String(motivo || '').replace(/^agents /, '');
  return base === 'five_hour' || base.startsWith('seven_day') || base === 'limite' || base === 'rate_limit';
}

function horaDaVolta(ms, agora = Date.now()) {
  const d = new Date(ms);
  const p = (n) => String(n).padStart(2, '0');
  const hora = `${p(d.getHours())}:${p(d.getMinutes())}`;
  return new Date(agora).toDateString() === d.toDateString() ? hora : `${p(d.getDate())}/${p(d.getMonth() + 1)} ${hora}`;
}

function textoDaTroca({ de, para, motivo }, nome = (id) => id, volta = null, agora = Date.now()) {
  const agentes = String(motivo || '').startsWith('agents ');
  if (String(motivo || '').replace(/^agents /, '') === 'preferida') {
    return {
      titulo: `Voltou para ${nome(para)}`,
      texto: `${nome(para)} voltou a ter folga${agentes ? '. Os agentes voltaram junto.' : '.'}`,
    };
  }
  let texto = `${nome(de)} ${motivoLegivel(motivo)}.`;
  // Só um limite renova numa hora certa; para os outros motivos, o prazo guardado é um palpite.
  if (volta && volta > agora && eLimite(motivo)) texto += ` Volta às ${horaDaVolta(volta, agora)}.`;
  if (agentes) texto += ' Os agentes seguiram junto.';
  return { titulo: `Trocou para ${nome(para)}`, texto };
}

// A hora da volta na notificação só sai de uma janela de uso conhecida (a busca do prazoPadrao,
// sem o palpite de 1h/6h): o prazo de esgotadas.json continua guiando a escolha, mas um palpite
// não vira "Volta às" para quem lê o aviso. Um limite semanal de um modelo (seven_day_opus) usa
// a janela daquele modelo, que renova em outra hora que a semanal geral.
function janelaDoModelo(uso, base) {
  const modelo = base.slice('seven_day_'.length).toLowerCase();
  if (!modelo) return null;
  // O formato antigo guarda a chave crua (seven_day_opus); o novo, a janela com escopo e o nome do
  // modelo no rótulo ("Weekly Opus").
  const casa = (j) =>
    j.chave === base ||
    String(j.chave || '').toLowerCase().endsWith(`_${modelo}`) ||
    String(j.rotulo || '').toLowerCase() === `weekly ${modelo}`;
  return (uso.janelas || []).find(casa) || null;
}

function voltaConhecida(id, motivo, agora = Date.now()) {
  const cache = lerJson(ARQ_USO, {})[id];
  const uso = cache && cache.uso;
  if (!uso) return null;
  const base = String(motivo || '').replace(/^agents /, '');
  const doModelo = base.startsWith('seven_day_') ? janelaDoModelo(uso, base) : null;
  if (doModelo && doModelo.renovaEm > agora) return doModelo.renovaEm;
  const janela = base === 'five_hour' ? uso.cinco : base.startsWith('seven_day') ? uso.sete : null;
  if (janela && janela.renovaEm > agora) return janela.renovaEm;
  const cheias = (uso.janelas || []).filter((j) => j.usado >= 98 && j.renovaEm > agora).map((j) => j.renovaEm);
  return cheias.length ? Math.max(...cheias) : null;
}

function registrarTroca({ de, para, motivo, sessao, interrompidas = 0 }) {
  const registro = { em: Date.now(), de, para, motivo, sessao: sessao || null, interrompidas, pid: process.pid };
  try {
    fs.mkdirSync(DIR_ESTADO, { recursive: true });
    apararTrocas();
    fs.appendFileSync(ARQ_TROCAS, JSON.stringify(registro) + '\n');
  } catch {}
  log(`troca ${de} -> ${para} (${motivo}) sessão ${sessao || '-'}`);
  // A sessão que só voltou para a pasta da própria conta não trocou de conta: nada a avisar.
  if (de === para) return;
  const cfg = carregarConfig();
  const aviso = textoDaTroca({ de, para, motivo }, (id) => nomeDaConta(id, cfg), voltaConhecida(de, motivo));
  notificar(aviso.titulo, aviso.texto);
}

function lerTrocas(limite = 30) {
  try {
    return fs
      .readFileSync(ARQ_TROCAS, 'utf8')
      .split('\n')
      .filter(Boolean)
      .slice(-limite)
      .map((l) => JSON.parse(l))
      .reverse();
  } catch {
    return [];
  }
}

function executavel(arquivo) {
  try {
    fs.accessSync(arquivo, fs.constants.X_OK);
    return fs.statSync(arquivo).isFile();
  } catch {
    return false;
  }
}

function resolverClaude() {
  const cfg = carregarConfig();
  const lancador = path.resolve(__dirname, '..', 'bin', 'claude-auto');
  const candidatos = [
    process.env.CLAUDE_AUTO_CLAUDE_BIN,
    cfg.claudeBin && expandir(cfg.claudeBin),
    path.join(HOME, '.local', 'bin', 'claude'),
    ...(process.env.PATH || '').split(path.delimiter).map((d) => d && path.join(d, 'claude')),
  ].filter(Boolean);
  for (const candidato of candidatos) {
    if (!executavel(candidato)) continue;
    if (fs.realpathSync(candidato) === lancador) continue;
    return candidato;
  }
  throw new Error('binário do claude não encontrado (defina CLAUDE_AUTO_CLAUDE_BIN)');
}

function principal() {
  return carregarConfig().principal;
}

function ferramentasDoXcode() {
  try {
    execFileSync('/usr/bin/xcode-select', ['-p'], { stdio: 'ignore', timeout: 5000 });
    return true;
  } catch {
    return false;
  }
}

function python3() {
  const doPath = (process.env.PATH || '').split(path.delimiter).filter(Boolean).map((d) => path.join(d, 'python3'));
  const stubDoMac = (candidato) => process.platform === 'darwin' && candidato === '/usr/bin/python3';
  const candidatos = [...new Set(['/usr/bin/python3', ...doPath])];
  return candidatos.find((c) => fs.existsSync(c) && !(stubDoMac(c) && !ferramentasDoXcode())) || null;
}

/**
 * Os números de limite que uma sessão em stream-json acabou de receber do servidor (`rate_limit_event`, lido dos
 * cabeçalhos da resposta), um arquivo por conta: o Monitor lê daqui sem gastar consulta ao `/usage`, que tem limite
 * apertado. `usado` em porcentagem (o evento traz fração), `renovaEm` em ms.
 */
// O login de cada conta, relido no máximo uma vez por minuto: o evento chega a cada resposta e o login quase nunca
// muda. Se mudar, por um minuto os números saem com o login anterior, e o Monitor os deixa de fora.
const loginsLidos = new Map();
function loginDaConta(id) {
  const lido = loginsLidos.get(id);
  if (lido && Date.now() - lido.em < 60000) return lido.chave;
  let chave = null;
  try { chave = identidade(id).chave; } catch {}
  loginsLidos.set(id, { chave, em: Date.now() });
  return chave;
}

function registrarLimiteAoVivo(id, info, agora = Date.now()) {
  if (!id || !info || typeof info !== 'object') return null;
  const janelas = {};
  const anotar = (chave, utilizacao, renova) => {
    if (typeof utilizacao !== 'number' || !Number.isFinite(utilizacao)) return;
    janelas[chave] = {
      usado: Math.round(Math.min(1, Math.max(0, utilizacao)) * 1000) / 10,
      renovaEm: typeof renova === 'number' ? renova * 1000 : null,
    };
  };
  for (const [chave, janela] of Object.entries(info.unifiedWindows || {})) {
    if (janela && typeof janela === 'object') anotar(chave, janela.utilization, janela.resetsAt);
  }
  if (info.rateLimitType && !janelas[info.rateLimitType]) anotar(info.rateLimitType, info.utilization, info.resetsAt);
  if (!Object.keys(janelas).length) return null;
  // Só as janelas deste evento, todas com a hora dele: o Monitor junta cada uma à última leitura completa, que
  // guarda as outras. Repetir aqui uma janela de um evento antigo a faria parecer nova.
  const registro = { em: agora, conta: loginDaConta(id), status: info.status || null, janelas };
  try {
    fs.mkdirSync(DIR_AO_VIVO, { recursive: true });
    escreverJson(path.join(DIR_AO_VIVO, `${id}.json`), registro);
  } catch {}
  return registro;
}

module.exports = {
  envDaSessao,
  temLoginProprio,
  dirPropria,
  contaDoDirPadrao,
  principal,
  python3,
  lerJson,
  escreverJson,
  usaDirPadrao,
  DIR_CONTAS,
  DIR_ESTADO,
  DIR_PRINCIPAL,
  ARQ_CONFIG,
  ARQ_LOG,
  carregarConfig,
  atualizarConfig,
  atualizarJson,
  comTravaDeArquivo,
  definirPrincipal,
  dirDaConta,
  nomeDaConta,
  envDaConta,
  prepararConta,
  prepararSessao,
  sincronizarConfig,
  servicoKeychain,
  lerCredencial,
  identidade,
  rotuloDoLogin,
  contasDuplicadas,
  sondar,
  lerUso,
  folgaDe,
  usadoEfetivo,
  avaliarContas,
  decidir,
  preferidaDeVolta,
  escolher,
  marcarEsgotada,
  lerEsgotadas,
  liberar,
  registrarTroca,
  registrarLimiteAoVivo,
  DIR_AO_VIVO,
  textoDaTroca,
  voltaConhecida,
  lerTrocas,
  notificar,
  resolverClaude,
  log,
};
