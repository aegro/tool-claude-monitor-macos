'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');
const contas = require('./contas');

const SLOT_PADRAO = !process.env.CLAUDE_AUTO_SLOT_DIR;
const DIR_SLOT = path.resolve(process.env.CLAUDE_AUTO_SLOT_DIR || contas.DIR_PRINCIPAL);
const SERVICO_SLOT = SLOT_PADRAO ? 'Claude Code-credentials' : servicoDoDir(DIR_SLOT);
const ARQ_SLOT = SLOT_PADRAO ? path.join(os.homedir(), '.claude.json') : path.join(DIR_SLOT, '.claude.json');
const DIR_LOGINS = path.join(contas.DIR_ESTADO, 'agentes');
const ARQ_ESTADO = path.join(contas.DIR_ESTADO, 'agentes.json');
const DIR_TRAVA = path.join(contas.DIR_ESTADO, 'agentes.trava');
const CONTA_KEYCHAIN = os.userInfo().username;
const JANELA_DE_RETOMADA_MS = 6 * 3600 * 1000;
const TENTATIVAS_DE_RETOMADA = 3;
const URL_PERFIL = 'https://api.anthropic.com/api/oauth/profile';
const CONTINUAR =
  '[claude-auto] A conta anterior atingiu o limite e esta sessão foi retomada em outra conta. ' +
  'Continue exatamente de onde parou, sem refazer o que já foi concluído.';

function servicoDoDir(dir) {
  return `Claude Code-credentials-${crypto.createHash('sha256').update(dir).digest('hex').slice(0, 8)}`;
}

function servicoGuardado(id) {
  return SLOT_PADRAO ? `claude-auto agents ${id}` : `claude-auto agents ${servicoDoDir(DIR_SLOT).slice(-8)} ${id}`;
}

function arquivoDoLogin(id) {
  return path.join(DIR_LOGINS, `${id}.json`);
}

function loginGuardado(id) {
  return contas.lerJson(arquivoDoLogin(id), null);
}

function envDoSlot() {
  const env = { ...process.env };
  for (const chave of Object.keys(env)) {
    if (chave.startsWith('CLAUDE_CODE_') || chave === 'CLAUDECODE') delete env[chave];
  }
  delete env.CLAUDE_AUTO_CONTA;
  if (SLOT_PADRAO) delete env.CLAUDE_CONFIG_DIR;
  else env.CLAUDE_CONFIG_DIR = DIR_SLOT;
  return env;
}

function rodar(cmd, args, { entrada, timeout = 15000, env } = {}) {
  return new Promise((resolve) => {
    const filho = execFile(cmd, args, { timeout, encoding: 'utf8', env, maxBuffer: 16 * 1024 * 1024 }, (erro, saida, stderr) =>
      resolve({ ok: !erro, saida: saida || '', erro: erro ? (stderr || erro.message).trim() : null }),
    );
    if (entrada != null) filho.stdin.end(entrada);
  });
}

function esperar(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function lerItem(servico) {
  const r = await rodar('security', ['find-generic-password', '-s', servico, '-w']);
  return r.ok ? r.saida.replace(/\n$/, '') : null;
}

async function gravarItem(servico, texto) {
  const hex = Buffer.from(texto, 'utf8').toString('hex');
  await rodar('security', ['-i'], { entrada: `add-generic-password -U -a "${CONTA_KEYCHAIN}" -s "${servico}" -X ${hex}\n` });
  return (await lerItem(servico)) === texto;
}

async function apagarItem(servico) {
  await rodar('security', ['delete-generic-password', '-s', servico]);
}

function chaveDe(conta) {
  return conta && conta.accountUuid ? [conta.accountUuid, conta.organizationUuid].filter(Boolean).join(':') : null;
}

async function chaveDoToken(texto) {
  try {
    const token = JSON.parse(texto).claudeAiOauth.accessToken;
    const resposta = await fetch(URL_PERFIL, {
      headers: { Authorization: `Bearer ${token}`, 'anthropic-beta': 'oauth-2025-04-20' },
      signal: AbortSignal.timeout(10000),
    });
    if (!resposta.ok) return null;
    const perfil = await resposta.json();
    if (!perfil.account || !perfil.account.uuid) return null;
    return [perfil.account.uuid, perfil.organization && perfil.organization.uuid].filter(Boolean).join(':');
  } catch {
    return null;
  }
}

function contaDaChave(chave, cfg = contas.carregarConfig()) {
  if (!chave) return null;
  const ids = Object.keys(cfg.contas);
  const guardada = ids.find((id) => (loginGuardado(id) || {}).chave === chave);
  if (guardada) return guardada;
  return ids.find((id) => !contas.usaDirPadrao(id, cfg) && contas.identidade(id, cfg).chave === chave) || null;
}

function principalSemIdentidadeGuardada(cfg) {
  return SLOT_PADRAO && !(loginGuardado(cfg.principal) || {}).chave ? cfg.principal : null;
}

function contaNoSlot(cfg = contas.carregarConfig()) {
  const chave = chaveDe((contas.lerJson(ARQ_SLOT, {}) || {}).oauthAccount);
  return contaDaChave(chave, cfg) || principalSemIdentidadeGuardada(cfg);
}

async function contaRealNoSlot(cfg = contas.carregarConfig()) {
  const texto = await lerItem(SERVICO_SLOT);
  const chave = texto && (await chaveDoToken(texto));
  return contaDaChave(chave, cfg) || contaNoSlot(cfg);
}

function prontaParaAgentes(id, cfg = contas.carregarConfig()) {
  return Boolean(loginGuardado(id)) || contaNoSlot(cfg) === id;
}

async function credencialGuardada(id) {
  try {
    return JSON.parse(await lerItem(servicoGuardado(id))).claudeAiOauth || null;
  } catch {
    return null;
  }
}

async function avaliarParaAgentes(cfg = contas.carregarConfig()) {
  const prontas = (await contas.avaliarContas()).filter((c) => prontaParaAgentes(c.id, cfg));
  return Promise.all(
    prontas.map(async (c) => {
      if (c.logada || !loginGuardado(c.id)) return c;
      const credencial = await credencialGuardada(c.id);
      if (!credencial) return c;
      const sonda = await contas.lerUso(c.id, { credencial, chaveDoCache: `agents ${c.id}` });
      return { ...c, sonda, folga: contas.folgaDe(sonda), logada: !sonda.semLogin };
    }),
  );
}

let donoDaTrava = null;

function travaEhDe(dono) {
  try {
    return fs.readFileSync(path.join(DIR_TRAVA, 'dono'), 'utf8') === dono;
  } catch {
    return false;
  }
}

function renovarTrava() {
  if (!donoDaTrava || !travaEhDe(donoDaTrava)) return;
  const agora = new Date();
  try {
    fs.utimesSync(DIR_TRAVA, agora, agora);
  } catch {}
}

async function comTrava(fn) {
  fs.mkdirSync(contas.DIR_ESTADO, { recursive: true });
  try {
    fs.mkdirSync(DIR_TRAVA);
  } catch {
    let antiga = false;
    try {
      antiga = Date.now() - fs.statSync(DIR_TRAVA).mtimeMs > 5 * 60 * 1000;
    } catch {}
    if (!antiga) return { acao: 'ocupado' };
    fs.rmSync(DIR_TRAVA, { recursive: true, force: true });
    fs.mkdirSync(DIR_TRAVA);
  }
  const dono = `${process.pid}:${crypto.randomUUID()}`;
  fs.writeFileSync(path.join(DIR_TRAVA, 'dono'), dono);
  donoDaTrava = dono;
  try {
    return await fn();
  } finally {
    donoDaTrava = null;
    if (travaEhDe(dono)) fs.rmSync(DIR_TRAVA, { recursive: true, force: true });
  }
}

async function trocarSlotSemTrava(para, motivo) {
  const cfg = contas.carregarConfig();
  const atual = await lerItem(SERVICO_SLOT);
  if (!atual) throw new Error('there is no login in the agents slot');
  const configDoSlot = contas.lerJson(ARQ_SLOT, {}) || {};
  const chaveDeclarada = chaveDe(configDoSlot.oauthAccount);
  const chaveReal = (await chaveDoToken(atual)) || chaveDeclarada;
  const de = contaDaChave(chaveReal, cfg) || (chaveReal === chaveDeclarada ? contaNoSlot(cfg) : null);
  if (de === para) return { de, para, mudou: false };
  if (!de) throw new Error('the login in the agents slot matches no account; leaving it alone');
  const destino = loginGuardado(para);
  const textoDestino = destino && (await lerItem(servicoGuardado(para)));
  if (!textoDestino) throw new Error(`${para} has no agents login: run claude-accounts login ${para} --agents`);

  const contaDe = chaveReal === chaveDeclarada ? configDoSlot.oauthAccount : (loginGuardado(de) || {}).oauthAccount;
  if (!(await gravarItem(servicoGuardado(de), atual))) throw new Error(`could not keep the ${de} login`);
  contas.escreverJson(arquivoDoLogin(de), { oauthAccount: contaDe || null, chave: chaveReal, guardadoEm: Date.now() });
  if (!(await gravarItem(SERVICO_SLOT, textoDestino))) {
    await gravarItem(SERVICO_SLOT, atual);
    throw new Error(`could not load the ${para} login into the agents slot`);
  }
  const novoConfig = contas.lerJson(ARQ_SLOT, {}) || {};
  novoConfig.oauthAccount = destino.oauthAccount;
  contas.escreverJson(ARQ_SLOT, novoConfig);
  if (SLOT_PADRAO) contas.definirPrincipal(para);
  contas.registrarTroca({ de, para, motivo: `agents ${motivo}` });
  return { de, para, mudou: true };
}

function trocarSlot(para, motivo = 'manual') {
  return comTrava(async () => {
    const troca = await trocarSlotSemTrava(para, motivo);
    if (troca.mudou) {
      const estado = contas.lerJson(ARQ_ESTADO, {}) || {};
      estado.ultimaTroca = Date.now();
      contas.escreverJson(ARQ_ESTADO, estado);
    }
    return troca;
  });
}

async function guardarLoginDoDir(id, dir) {
  const texto = await lerItem(servicoDoDir(dir));
  const conta = (contas.lerJson(path.join(dir, '.claude.json'), {}) || {}).oauthAccount;
  if (!texto || !conta) throw new Error('the login did not finish');
  if (!(await gravarItem(servicoGuardado(id), texto))) throw new Error('could not store the agents login');
  contas.escreverJson(arquivoDoLogin(id), { oauthAccount: conta, chave: chaveDe(conta), guardadoEm: Date.now() });
  await apagarItem(servicoDoDir(dir));
  return conta;
}

async function listarAgentes() {
  const r = await rodar(contas.resolverClaude(), ['agents', '--json'], { env: envDoSlot(), timeout: 20000 });
  if (!r.ok) return null;
  try {
    return JSON.parse(r.saida);
  } catch {
    return null;
  }
}

function arquivoDaSessao(agente) {
  const projetos = path.join(DIR_SLOT, 'projects');
  const direto = path.join(projetos, String(agente.cwd || '').replace(/[^a-zA-Z0-9]/g, '-'), `${agente.sessionId}.jsonl`);
  if (fs.existsSync(direto)) return direto;
  try {
    for (const nome of fs.readdirSync(projetos)) {
      const arquivo = path.join(projetos, nome, `${agente.sessionId}.jsonl`);
      if (fs.existsSync(arquivo)) return arquivo;
    }
  } catch {}
  return null;
}

function entradasFinais(arquivo, bytes = 262144) {
  try {
    const fd = fs.openSync(arquivo, 'r');
    const tamanho = fs.fstatSync(fd).size;
    const n = Math.min(tamanho, bytes);
    const buf = Buffer.alloc(n);
    fs.readSync(fd, buf, 0, n, tamanho - n);
    fs.closeSync(fd);
    return buf
      .toString('utf8')
      .split('\n')
      .map((linha) => {
        try {
          return JSON.parse(linha);
        } catch {
          return null;
        }
      })
      .filter(Boolean);
  } catch {
    return [];
  }
}

function paradoPorLimite(agente, estado = {}, agora = Date.now()) {
  if (!agente || !agente.sessionId || (agente.kind && agente.kind !== 'background')) return null;
  const arquivo = arquivoDaSessao(agente);
  const ultima = arquivo && entradasFinais(arquivo).reverse().find((e) => e.type === 'assistant');
  if (!ultima || !ultima.isApiErrorMessage || ultima.error !== 'rate_limit') return null;
  const quando = Date.parse(ultima.timestamp);
  if (!quando || agora - quando > JANELA_DE_RETOMADA_MS) return null;
  const respawnado = ((estado.respawnados || {})[agente.sessionId]) || 0;
  return {
    id: agente.id,
    sessionId: agente.sessionId,
    nome: agente.name || agente.id,
    quando,
    processoDesde: Math.max(respawnado, agente.startedAt || 0),
    arquivo,
  };
}

function planejar(paradas, estado = {}) {
  const empurrados = estado.empurrados || {};
  const desistidos = estado.desistidos || {};
  const ultimaTroca = estado.ultimaTroca || 0;
  const novas = paradas.filter((p) => empurrados[p.sessionId] !== p.quando && desistidos[p.sessionId] !== p.quando);
  const precisaTrocar = novas.some((p) => p.quando > ultimaTroca && p.processoDesde >= ultimaTroca);
  return { novas, precisaTrocar };
}

function continuacaoChegou(arquivo, desde) {
  return entradasFinais(arquivo, 65536).some((e) => {
    if (e.type !== 'user' || Date.parse(e.timestamp) < desde) return false;
    const conteudo = (e.message || {}).content;
    const texto = Array.isArray(conteudo) ? conteudo.map((c) => (c && c.text) || '').join(' ') : String(conteudo || '');
    return texto.includes('[claude-auto]');
  });
}

async function trabalhando(id) {
  const agente = ((await listarAgentes()) || []).find((a) => a.id === id);
  return Boolean(agente && agente.status && agente.status !== 'idle' && agente.state !== 'blocked');
}

async function retomar(p, estado) {
  const bin = contas.resolverClaude();
  const respawn = await rodar(bin, ['respawn', p.id], { env: envDoSlot(), timeout: 30000 });
  if (!respawn.ok) {
    contas.log(`agentes: respawn de ${p.nome} falhou: ${respawn.erro}`);
    return false;
  }
  estado.respawnados = { ...(estado.respawnados || {}), [p.sessionId]: Date.now() };
  await esperar(3000);
  const python = contas.python3();
  if (!python) {
    contas.log('agentes: sem python3 para retomar os agentes');
    return false;
  }
  for (let tentativa = 1; tentativa <= 2; tentativa++) {
    const desde = Date.now() - 1000;
    await rodar(python, [path.join(__dirname, 'empurrar.py'), bin, p.id, CONTINUAR], { env: envDoSlot(), timeout: 45000 });
    for (let i = 0; i < 10; i++) {
      renovarTrava();
      if (continuacaoChegou(p.arquivo, desde) || (await trabalhando(p.id))) {
        contas.log(`agentes: ${p.nome} retomado`);
        return true;
      }
      await esperar(1000);
    }
  }
  contas.log(`agentes: a continuação não chegou a ${p.nome}`);
  return false;
}

function avisarUmaVez(estado, chave, titulo, texto) {
  const avisos = estado.avisos || {};
  if (Date.now() - (avisos[chave] || 0) < 3600 * 1000) return;
  estado.avisos = { ...avisos, [chave]: Date.now() };
  contas.notificar(titulo, texto);
}

function registrarFalhaDeRetomada(estado, p) {
  const anterior = (estado.falhas || {})[p.sessionId];
  const tentativas = anterior && anterior.quando === p.quando ? anterior.tentativas + 1 : 1;
  estado.falhas = { ...(estado.falhas || {}), [p.sessionId]: { quando: p.quando, tentativas } };
  if (tentativas < TENTATIVAS_DE_RETOMADA) return;
  estado.desistidos = { ...(estado.desistidos || {}), [p.sessionId]: p.quando };
  contas.log(`agentes: desistindo de retomar ${p.nome} depois de ${tentativas} tentativas`);
  avisarUmaVez(estado, `retomar ${p.sessionId}`, 'Claude: agent not resumed', `${p.nome} stopped by a limit and did not resume; continue it by hand.`);
}

async function voltarParaPreferida(cfg, estado) {
  const atual = contaNoSlot(cfg);
  if (!cfg.preferida || cfg.preferida === atual || !loginGuardado(cfg.preferida)) return null;
  if (Date.now() - (estado.ultimaChecagemDeVolta || 0) < 5 * 60 * 1000) return null;
  estado.ultimaChecagemDeVolta = Date.now();
  const preferida = contas.preferidaDeVolta(await avaliarParaAgentes(cfg), atual, cfg);
  if (!preferida) return null;
  try {
    const troca = await trocarSlotSemTrava(preferida.id, 'preferida');
    estado.ultimaTroca = Date.now();
    return troca;
  } catch (e) {
    contas.log(`agentes: voltar para ${preferida.id} falhou: ${e.message}`);
    return null;
  }
}

async function migrarOciosos(lista, estado) {
  const ultimaTroca = estado.ultimaTroca || 0;
  if (!ultimaTroca) return [];
  const migrados = [];
  for (const agente of lista) {
    if (agente.kind !== 'background' || !agente.pid || agente.status !== 'idle' || agente.state === 'blocked') continue;
    const desde = Math.max(((estado.respawnados || {})[agente.sessionId]) || 0, agente.startedAt || 0);
    if (desde >= ultimaTroca) continue;
    renovarTrava();
    const r = await rodar(contas.resolverClaude(), ['respawn', agente.id], { env: envDoSlot(), timeout: 30000 });
    if (!r.ok) continue;
    estado.respawnados = { ...(estado.respawnados || {}), [agente.sessionId]: Date.now() };
    migrados.push(agente.name || agente.id);
  }
  if (migrados.length) contas.log(`agentes: reiniciados na conta nova: ${migrados.join(', ')}`);
  return migrados;
}

async function vigiar() {
  const cfg = contas.carregarConfig();
  if (cfg.ativo === false) return { acao: 'desligado' };
  return comTrava(async () => {
    const lista = await listarAgentes();
    if (!lista) return { acao: 'sem-agentes' };
    const estado = contas.lerJson(ARQ_ESTADO, {}) || {};
    const paradas = lista.map((agente) => paradoPorLimite(agente, estado)).filter(Boolean);
    const { novas, precisaTrocar } = planejar(paradas, estado);

    let troca = null;
    if (!novas.length) {
      troca = await voltarParaPreferida(cfg, estado);
      const migrados = await migrarOciosos(lista, estado);
      contas.escreverJson(ARQ_ESTADO, estado);
      return { acao: troca || migrados.length ? 'migrou' : 'nada', agentes: lista.length, troca, migrados };
    }
    if (precisaTrocar) {
      const de = await contaRealNoSlot(cfg);
      if (de) contas.marcarEsgotada(de, null, 'limite');
      const candidatos = (await avaliarParaAgentes(cfg)).filter((c) => c.id !== de);
      const escolhida = contas.decidir(candidatos, { excluir: de ? [de] : [] });
      if (!escolhida) {
        avisarUmaVez(estado, 'sem-conta', 'Claude: agents hit the limit', 'No other account with headroom has an agents login.');
        contas.escreverJson(ARQ_ESTADO, estado);
        contas.log(`agentes: ${novas.length} parados por limite e nenhuma outra conta pronta`);
        return { acao: 'sem-conta', parados: novas.map((p) => p.nome) };
      }
      troca = await trocarSlotSemTrava(escolhida.id, 'limite');
      estado.ultimaTroca = Date.now();
      contas.escreverJson(ARQ_ESTADO, estado);
    }

    const retomados = [];
    for (const p of novas) {
      if (await retomar(p, estado)) {
        estado.empurrados = { ...(estado.empurrados || {}), [p.sessionId]: p.quando };
        retomados.push(p.nome);
      } else {
        registrarFalhaDeRetomada(estado, p);
      }
      contas.escreverJson(ARQ_ESTADO, estado);
    }
    if (retomados.length) {
      contas.notificar('Claude: agents resumed', `${retomados.length} on ${contas.nomeDaConta(contaNoSlot())}`);
    }
    const migrados = await migrarOciosos(lista, estado);
    contas.escreverJson(ARQ_ESTADO, estado);
    return { acao: 'retomou', troca, retomados, migrados };
  });
}

async function prepararSlot({ prazoDaAvaliacaoMs = 8000 } = {}) {
  const cfg = contas.carregarConfig();
  if (cfg.ativo === false) return null;
  return comTrava(async () => {
    const atual = contaNoSlot(cfg);
    const prontas = await Promise.race([avaliarParaAgentes(cfg), esperar(prazoDaAvaliacaoMs).then(() => null)]);
    if (!prontas) {
      contas.log('agentes: avaliação das contas passou do prazo; abrindo sem trocar');
      return null;
    }
    const noSlot = prontas.find((c) => c.id === atual);
    const sair = Boolean(noSlot && (noSlot.esgotada || noSlot.folga === 0));
    const escolhida = sair ? contas.decidir(prontas, { excluir: [atual] }) : contas.preferidaDeVolta(prontas, atual, cfg);
    if (!escolhida || escolhida.id === atual) return null;
    const estado = contas.lerJson(ARQ_ESTADO, {}) || {};
    const troca = await trocarSlotSemTrava(escolhida.id, 'ao abrir');
    estado.ultimaTroca = Date.now();
    contas.escreverJson(ARQ_ESTADO, estado);
    return troca;
  });
}

module.exports = {
  CONTINUAR,
  DIR_SLOT,
  contaNoSlot,
  contaRealNoSlot,
  prontaParaAgentes,
  loginGuardado,
  trocarSlot,
  guardarLoginDoDir,
  servicoDoDir,
  envDoSlot,
  listarAgentes,
  paradoPorLimite,
  planejar,
  vigiar,
  prepararSlot,
};
