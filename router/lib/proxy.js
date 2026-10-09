'use strict';

const { spawn } = require('child_process');
const contas = require('./contas');
const { valorDaFlag, argsDeRetomada } = require('./args');

const AJUSTES_REPETIDOS = new Set([
  'set_permission_mode', 'set_model', 'set_max_thinking_tokens', 'apply_flag_settings', 'mcp_set_servers',
]);
const ERROS_DE_CONTA = {
  authentication_failed: 'auth',
  oauth_org_not_allowed: 'auth',
  verification_required: 'auth',
  account_on_hold: 'conta_suspensa',
  billing_error: 'cobranca',
  rate_limit: 'rate_limit',
};
const RESULTADO_DE_LIMITE = /usage limit|limit reached|hit your( \w+)? limit|rate.?limit|invalid api key|run \/login|credit balance/i;
const RESULTADO_DE_LOGIN = /invalid api key|run \/login/i;
const FERRAMENTAS_RASTREADAS = new Set(['Agent', 'Task', 'Workflow']);
const STATUS_FINAIS = new Set(['completed', 'failed', 'killed', 'stopped']);
const INTERVALO_DE_VOLTA_MS = 60 * 1000;

function divisorDeLinhas(aoReceber) {
  let resto = '';
  return (pedaco) => {
    resto += pedaco;
    let i;
    while ((i = resto.indexOf('\n')) >= 0) {
      const linha = resto.slice(0, i);
      resto = resto.slice(i + 1);
      if (linha.trim()) aoReceber(linha);
    }
  };
}

function textoDe(conteudo) {
  if (typeof conteudo === 'string') return conteudo;
  if (Array.isArray(conteudo)) return conteudo.map((b) => (b && typeof b.text === 'string' ? b.text : '')).join('\n');
  return '';
}

function mensagemDe(linha) {
  try {
    return JSON.parse(linha) || {};
  } catch {
    return {};
  }
}

function tipoDe(linha) {
  return mensagemDe(linha).type;
}

function idDePedido(linha) {
  const msg = mensagemDe(linha);
  return msg.type === 'control_request' ? msg.request_id : undefined;
}

class Proxy {
  constructor(args, { contaInicial = null } = {}) {
    this.args = args;
    this.contaInicial = contaInicial;
    this.sessionId = valorDaFlag(args, '--session-id') || valorDaFlag(args, '--resume') || valorDaFlag(args, '-r');
    this.conta = null;
    this.filho = null;
    this.geracao = 0;
    this.initReq = null;
    this.ajustes = new Map();
    this.pendentesDoHost = new Map();
    this.pendentesDoFilho = new Map();
    this.idsInternos = new Set();
    this.seq = 0;
    this.emTurno = false;
    this.trocando = false;
    this.avaliando = false;
    this.checandoPreventiva = false;
    this.preventivaPendente = false;
    this.ultimaChecagemDeVolta = 0;
    this.filaDoHost = [];
    this.retido = null;
    this.saidaDoFilho = null;
    this.tarefas = new Map();
    this.usos = new Map();
    this.usosPendentes = new Set();
    this.runIdsWorkflow = new Map();
    this.hostEncerrou = false;
    this.encerrando = false;
  }

  async iniciar() {
    let escolha;
    try {
      escolha = this.contaInicial ? { escolhida: this.contaInicial, folga: 'fixada' } : await contas.escolher();
    } catch (e) {
      contas.log(`stream: falha ao escolher conta (${e.message}); usando principal`);
      escolha = { escolhida: contas.principal(), folga: null };
    }
    this.conta = escolha.escolhida || contas.principal();
    contas.log(`stream: início na conta ${this.conta} (folga ${escolha.folga ?? '?'}) sessão ${this.sessionId || 'nova'}`);

    process.stdin.setEncoding('utf8');
    process.stdin.on('data', divisorDeLinhas((linha) => this.doHost(linha)));
    process.stdin.on('end', () => {
      this.hostEncerrou = true;
      if (!this.trocando && !this.avaliando && this.filho) this.filho.stdin.end();
    });
    process.stdout.on('error', () => this.encerrar('SIGTERM'));
    for (const sinal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(sinal, () => this.encerrar(sinal));
    process.on('SIGUSR1', () =>
      this.trocaDeTeste().catch((e) => contas.log(`stream: troca de teste falhou: ${e.message}`)),
    );

    this.geracao = 1;
    this.lancar(this.args);
  }

  lancar(args) {
    const geracao = this.geracao;
    try {
      contas.prepararConta(this.conta);
    } catch (e) {
      contas.log(`stream: preparar conta ${this.conta} falhou: ${e.message}`);
    }
    const filho = spawn(contas.resolverClaude(), args, {
      env: contas.envDaConta(this.conta),
      stdio: ['pipe', 'pipe', 'inherit'],
    });
    this.filho = filho;
    this.saidaDoFilho = null;
    this.tarefas.clear();
    this.usosPendentes.clear();
    filho.stdout.setEncoding('utf8');
    filho.stdout.on('data', divisorDeLinhas((linha) => this.doFilho(linha, geracao)));
    filho.stdin.on('error', (e) => contas.log(`stream: stdin do filho: ${e.message}`));
    filho.on('error', (e) => {
      contas.log(`stream: falha ao iniciar claude: ${e.message}`);
      if (geracao === this.geracao) this.sair(1);
    });
    filho.on('exit', (codigo, sinal) => this.filhoSaiu(geracao, codigo, sinal));
    return filho;
  }

  paraFilho(linha) {
    if (this.filho && this.filho.stdin.writable) this.filho.stdin.write(linha + '\n');
  }

  paraHost(linha) {
    if (!process.stdout.write(linha + '\n') && this.filho) {
      const filho = this.filho;
      filho.stdout.pause();
      process.stdout.once('drain', () => filho.stdout.resume());
    }
  }

  enviarInterno(requisicao) {
    const id = `claude-auto-${process.pid}-${++this.seq}`;
    this.idsInternos.add(id);
    this.paraFilho(JSON.stringify({ ...requisicao, request_id: id }));
  }

  doHost(linha) {
    let msg = null;
    try {
      msg = JSON.parse(linha);
    } catch {}
    if (msg && msg.type === 'control_request') {
      const subtipo = msg.request && msg.request.subtype;
      if (subtipo === 'initialize') this.initReq = msg;
      if (AJUSTES_REPETIDOS.has(subtipo)) this.ajustes.set(subtipo, msg);
      this.pendentesDoHost.set(msg.request_id, msg);
    } else if (msg && msg.type === 'control_response') {
      const id = msg.response && msg.response.request_id;
      if (!this.pendentesDoFilho.has(id)) return;
      this.pendentesDoFilho.delete(id);
    } else if (msg && msg.type === 'control_cancel_request') {
      this.pendentesDoHost.delete(msg.request_id);
    } else if (msg && msg.type === 'user') {
      this.emTurno = true;
    }
    if (this.trocando || this.avaliando) {
      this.filaDoHost.push(linha);
      return;
    }
    this.paraFilho(linha);
  }

  doFilho(linha, geracao) {
    if (geracao !== this.geracao) return;
    let msg;
    try {
      msg = JSON.parse(linha);
    } catch {
      this.paraHost(linha);
      return;
    }
    if (msg.session_id) this.sessionId = msg.session_id;
    if (msg.type === 'control_response') {
      const id = msg.response && msg.response.request_id;
      if (this.idsInternos.delete(id)) return;
      this.pendentesDoHost.delete(id);
    } else if (msg.type === 'control_request') {
      this.pendentesDoFilho.set(msg.request_id, msg);
    } else if (msg.type === 'control_cancel_request') {
      this.pendentesDoFilho.delete(msg.request_id);
    }

    const emTurnoAntes = this.emTurno;
    this.rastrear(msg);
    if (msg.type === 'rate_limit_event' && this.conta) contas.registrarLimiteAoVivo(this.conta, msg.rate_limit_info);

    if (this.retido) {
      this.retido.push(linha);
      return;
    }
    const gatilho = this.gatilhoDeTroca(msg);
    if (gatilho) {
      this.retido = [linha];
      this.avaliarTroca({ ...gatilho, continuar: emTurnoAntes || msg.type !== 'rate_limit_event' }, geracao);
      return;
    }
    this.paraHost(linha);
    if (msg.type === 'result') this.aposFimDeTurno();
  }

  gatilhoDeTroca(msg) {
    if (msg.type === 'rate_limit_event') {
      const info = msg.rate_limit_info || {};
      if (info.status !== 'rejected') return null;
      return { motivo: info.rateLimitType || 'rate_limit', ate: info.resetsAt ? info.resetsAt * 1000 : null };
    }
    if (msg.type === 'assistant' && !msg.parent_tool_use_id && ERROS_DE_CONTA[msg.error]) {
      return { motivo: ERROS_DE_CONTA[msg.error], ate: null };
    }
    if (msg.type === 'result' && msg.is_error) {
      const texto = [msg.result, ...(msg.errors || [])].filter((t) => typeof t === 'string').join(' ');
      if (RESULTADO_DE_LIMITE.test(texto)) return { motivo: RESULTADO_DE_LOGIN.test(texto) ? 'auth' : 'rate_limit', ate: null };
    }
    return null;
  }

  rastrear(msg) {
    if (msg.type === 'assistant' || msg.type === 'stream_event') this.emTurno = true;
    if (msg.type === 'assistant') {
      const blocos = (msg.message && msg.message.content) || [];
      for (const bloco of Array.isArray(blocos) ? blocos : []) {
        if (bloco.type !== 'tool_use' || !FERRAMENTAS_RASTREADAS.has(bloco.name)) continue;
        this.usos.set(bloco.id, { nome: bloco.name, input: bloco.input || {} });
        this.usosPendentes.add(bloco.id);
        if (this.usos.size > 500) this.usos.delete(this.usos.keys().next().value);
      }
    } else if (msg.type === 'user') {
      const blocos = msg.message && msg.message.content;
      for (const bloco of Array.isArray(blocos) ? blocos : []) {
        if (bloco.type !== 'tool_result' || !this.usos.has(bloco.tool_use_id)) continue;
        const runId = textoDe(bloco.content).match(/\bwf_[a-z0-9-]{6,}/);
        if (runId) this.runIdsWorkflow.set(bloco.tool_use_id, runId[0]);
        this.usosPendentes.delete(bloco.tool_use_id);
      }
    } else if (msg.type === 'system') {
      this.rastrearTarefa(msg);
    } else if (msg.type === 'result') {
      this.emTurno = (msg.queued_turn_count || 0) > 0;
    }
  }

  rastrearTarefa(msg) {
    if (msg.subtype === 'task_started') {
      if (msg.ambient || msg.subagent_type === 'main-session') return;
      this.tarefas.set(msg.task_id, {
        descricao: msg.description,
        tipo: msg.task_type,
        subagente: msg.subagent_type,
        workflow: msg.workflow_name,
        toolUseId: msg.tool_use_id,
        taskId: msg.task_id,
      });
    } else if (msg.subtype === 'task_notification') {
      this.tarefas.delete(msg.task_id);
      if (this.preventivaPendente && !this.tarefas.size) setTimeout(() => this.checarPreventiva(), 500);
    } else if (msg.subtype === 'task_updated') {
      if (msg.patch && STATUS_FINAIS.has(msg.patch.status)) this.tarefas.delete(msg.task_id);
    } else if (msg.subtype === 'background_tasks_changed' && Array.isArray(msg.tasks)) {
      const vivas = new Set(msg.tasks.map((t) => t.task_id));
      for (const [id, tarefa] of this.tarefas) {
        if (tarefa.segundoPlano && !vivas.has(id)) this.tarefas.delete(id);
      }
      for (const t of msg.tasks) {
        if (t.ambient || t.subagent_type === 'main-session') continue;
        const atual = this.tarefas.get(t.task_id) || { taskId: t.task_id, descricao: t.description, tipo: t.task_type, subagente: t.subagent_type };
        this.tarefas.set(t.task_id, { ...atual, segundoPlano: true });
      }
    }
  }

  tarefasAtivas() {
    const lista = [];
    const cobertos = new Set();
    for (const tarefa of this.tarefas.values()) {
      const uso = tarefa.toolUseId && this.usos.get(tarefa.toolUseId);
      if (tarefa.toolUseId) cobertos.add(tarefa.toolUseId);
      const ehWorkflow = (uso && uso.nome === 'Workflow') || /workflow/i.test(tarefa.tipo || '') || tarefa.workflow;
      lista.push({
        tipo: ehWorkflow ? 'workflow' : uso && (uso.nome === 'Agent' || uso.nome === 'Task') ? 'subagente' : tarefa.tipo === 'local_agent' ? 'subagente' : 'outra',
        descricao: tarefa.descricao || (uso && uso.input.description) || tarefa.workflow || tarefa.taskId,
        subagente: tarefa.subagente || (uso && uso.input.subagent_type),
        runId: (tarefa.toolUseId && this.runIdsWorkflow.get(tarefa.toolUseId)) || (/^wf_/.test(tarefa.taskId) ? tarefa.taskId : null),
      });
    }
    for (const id of this.usosPendentes) {
      if (cobertos.has(id)) continue;
      const uso = this.usos.get(id);
      lista.push({
        tipo: uso.nome === 'Workflow' ? 'workflow' : 'subagente',
        descricao: uso.input.description || (uso.input.meta && uso.input.meta.name) || uso.input.name || id,
        subagente: uso.input.subagent_type,
        runId: this.runIdsWorkflow.get(id) || null,
      });
    }
    return lista;
  }

  mensagemDeContinuacao(de, motivo, interrompidas) {
    let texto =
      `[claude-auto] A conta "${contas.nomeDaConta(de)}" atingiu o limite (${motivo}) no meio do turno ` +
      `e esta sessão foi retomada na conta "${contas.nomeDaConta(this.conta)}". ` +
      'Continue exatamente de onde parou, sem refazer o que já foi concluído.';
    if (interrompidas.length) {
      texto += '\n\nEstas tarefas estavam rodando e foram encerradas pela troca. Relance cada uma:';
      for (const t of interrompidas) {
        if (t.tipo === 'workflow') {
          texto += t.runId
            ? `\n- Workflow "${t.descricao}" (run ${t.runId}): relance com resumeFromRunId: "${t.runId}" para reaproveitar os agentes já concluídos.`
            : `\n- Workflow "${t.descricao}": relance o mesmo script.`;
        } else if (t.tipo === 'subagente') {
          texto += `\n- Subagente "${t.descricao}"${t.subagente ? ` (${t.subagente})` : ''}: relance com o mesmo prompt.`;
        } else {
          texto += `\n- Tarefa em segundo plano "${t.descricao}": relance se ainda for necessária.`;
        }
      }
    }
    return {
      type: 'user',
      message: { role: 'user', content: [{ type: 'text', text: texto }] },
      parent_tool_use_id: null,
      session_id: this.sessionId || '',
    };
  }

  async avaliarTroca(gatilho, geracao) {
    this.avaliando = true;
    try {
      contas.log(`stream: gatilho ${gatilho.motivo} na conta ${this.conta}`);
      contas.marcarEsgotada(this.conta, gatilho.ate, gatilho.motivo);
      const escolha = await contas.escolher({ excluir: [this.conta] });
      if (geracao !== this.geracao) return;
      if (this.encerrando) {
        this.liberarRetido();
        return;
      }
      if (!escolha.escolhida) {
        contas.log('stream: nenhuma outra conta disponível; repassando o erro');
        this.liberarRetido();
        return;
      }
      await this.trocar({ para: escolha.escolhida, motivo: gatilho.motivo, forcada: true, continuar: gatilho.continuar });
    } catch (e) {
      contas.log(`stream: troca falhou: ${e.stack || e.message}`);
      this.liberarRetido();
    } finally {
      this.avaliando = false;
      this.esvaziarFila();
    }
  }

  liberarRetido() {
    const retido = this.retido || [];
    this.retido = null;
    let teveResultado = false;
    for (const linha of retido) {
      this.paraHost(linha);
      if (linha.includes('"type":"result"')) teveResultado = true;
    }
    this.avaliando = false;
    this.esvaziarFila();
    if (this.saidaDoFilho) this.sair(this.saidaDoFilho.codigo);
    else if (teveResultado) this.aposFimDeTurno();
  }

  esvaziarFila() {
    if (this.trocando || this.avaliando) return;
    const fila = this.filaDoHost;
    this.filaDoHost = [];
    for (const linha of fila) this.paraFilho(linha);
    if (this.hostEncerrou && this.filho) this.filho.stdin.end();
  }

  matar(filho) {
    return new Promise((resolve) => {
      if (!filho || filho.exitCode !== null || filho.signalCode !== null) return resolve();
      const forcar = setTimeout(() => filho.kill('SIGKILL'), 5000);
      filho.once('exit', () => {
        clearTimeout(forcar);
        resolve();
      });
      filho.kill('SIGTERM');
    });
  }

  async trocar({ para, motivo, forcada, continuar }) {
    this.trocando = true;
    try {
      const de = this.conta;
      const interrompidas = forcada ? this.tarefasAtivas() : [];
      this.geracao++;
      for (const linha of this.retido || []) {
        if (tipoDe(linha) === 'control_response') this.paraHost(linha);
      }
      this.retido = null;
      for (const id of this.pendentesDoFilho.keys()) {
        this.paraHost(JSON.stringify({ type: 'control_cancel_request', request_id: id }));
      }
      this.pendentesDoFilho.clear();
      await this.matar(this.filho);
      if (this.encerrando) {
        this.sair(0);
        return;
      }

      this.conta = para;
      this.lancar(argsDeRetomada(this.args, this.sessionId));
      const initPendente = this.initReq && this.pendentesDoHost.has(this.initReq.request_id);
      if (this.initReq && !initPendente) this.enviarInterno(this.initReq);
      for (const req of this.ajustes.values()) {
        if (!this.pendentesDoHost.has(req.request_id)) this.enviarInterno(req);
      }
      for (const req of this.pendentesDoHost.values()) this.paraFilho(JSON.stringify(req));
      this.filaDoHost = this.filaDoHost.filter((linha) => !this.pendentesDoHost.has(idDePedido(linha)));
      if (forcada && continuar) {
        this.paraFilho(JSON.stringify(this.mensagemDeContinuacao(de, motivo, interrompidas)));
        this.emTurno = true;
      }
      contas.registrarTroca({ de, para, motivo, sessao: this.sessionId, interrompidas: interrompidas.length });
    } catch (e) {
      contas.log(`stream: troca para ${para} falhou: ${e.message}`);
      this.sair(1);
      return;
    } finally {
      this.trocando = false;
    }
    this.esvaziarFila();
  }

  aposFimDeTurno() {
    if (!this.emTurno) setTimeout(() => this.checarPreventiva(), 200);
  }

  async checarPreventiva() {
    if (this.trocando || this.avaliando || this.emTurno || this.checandoPreventiva || this.encerrando) return;
    this.checandoPreventiva = true;
    try {
      const cfg = contas.carregarConfig();
      const folga = contas.folgaDe(await contas.lerUso(this.conta));
      if (folga == null || folga >= cfg.limites.preventiva) {
        this.preventivaPendente = false;
        await this.checarVolta(cfg);
        return;
      }
      if (this.tarefas.size) {
        if (!this.preventivaPendente) contas.log(`stream: folga ${folga}% em ${this.conta}; troca preventiva espera tarefas em segundo plano`);
        this.preventivaPendente = true;
        return;
      }
      const escolha = await contas.escolher({ excluir: [this.conta] });
      if (!escolha.escolhida || (escolha.folga ?? 0) <= folga) return;
      if (this.trocando || this.avaliando || this.emTurno || this.tarefas.size || this.encerrando) return;
      this.preventivaPendente = false;
      await this.trocar({ para: escolha.escolhida, motivo: 'preventiva', forcada: false, continuar: false });
    } catch (e) {
      contas.log(`stream: checagem preventiva falhou: ${e.message}`);
    } finally {
      this.checandoPreventiva = false;
    }
  }

  async checarVolta(cfg) {
    if (!cfg.preferida || cfg.preferida === this.conta || this.contaInicial || this.tarefas.size) return;
    if (Date.now() - this.ultimaChecagemDeVolta < INTERVALO_DE_VOLTA_MS) return;
    this.ultimaChecagemDeVolta = Date.now();
    const preferida = contas.preferidaDeVolta(await contas.avaliarContas(), this.conta, cfg);
    if (!preferida || this.trocando || this.avaliando || this.emTurno || this.tarefas.size || this.encerrando) return;
    await this.trocar({ para: preferida.id, motivo: 'preferida', forcada: false, continuar: false });
  }

  async trocaDeTeste() {
    if (this.trocando || this.avaliando) return;
    const escolha = await contas.escolher({ excluir: [this.conta] });
    const para = escolha.escolhida || (process.env.CLAUDE_AUTO_TESTE_MESMA_CONTA ? this.conta : null);
    if (!para) {
      contas.log('stream: troca de teste sem outra conta disponível');
      return;
    }
    this.retido = [];
    this.avaliando = true;
    try {
      await this.trocar({ para, motivo: 'teste', forcada: true, continuar: this.emTurno });
    } finally {
      this.avaliando = false;
      this.esvaziarFila();
    }
  }

  filhoSaiu(geracao, codigo, sinal) {
    if (geracao !== this.geracao || this.trocando) return;
    const codigoFinal = codigo ?? (sinal ? 1 : 0);
    if (this.avaliando) {
      this.saidaDoFilho = { codigo: codigoFinal };
      return;
    }
    this.sair(codigoFinal);
  }

  encerrar(sinal) {
    this.encerrando = true;
    if (this.filho && this.filho.exitCode === null && this.filho.signalCode === null) {
      this.filho.kill(sinal);
      setTimeout(() => this.sair(1), 5000).unref();
    } else {
      this.sair(0);
    }
  }

  sair(codigo) {
    process.stdout.write('', () => process.exit(codigo));
  }
}

module.exports = { Proxy, divisorDeLinhas };
