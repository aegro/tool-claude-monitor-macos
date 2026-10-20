'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

require('./ambiente-limpo');

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

// Um HOME de mentira com a principal no ~/.claude (Aegro) e o mesmo e-mail numa Max: cada `rodar` é um processo à
// parte com esse HOME, o `security` falso dizendo que a pasta própria tem login, e `contas` carregado.
function mundoComDuasOrganizacoes() {
  const home = fs.mkdtempSync(path.join(raiz, 'orgs-'));
  const accounts = path.join(home, '.claude-accounts');
  const propria = path.join(accounts, 'principal');
  const bin = path.join(home, 'bin');
  fs.mkdirSync(path.join(home, '.claude'), { recursive: true });
  fs.mkdirSync(propria, { recursive: true });
  fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(path.join(bin, 'security'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  // O `claude` falso: o login grava o oauthAccount pedido na pasta da sessão; o logout anota de que pasta saiu.
  const saidas = path.join(home, 'logouts.txt');
  const claude = path.join(bin, 'claude-falso');
  fs.writeFileSync(claude, `#!/usr/bin/env node
const fs = require('fs'), path = require('path');
const dir = process.env.CLAUDE_CONFIG_DIR;
const arquivo = dir ? path.join(dir, '.claude.json') : path.join(process.env.HOME, '.claude.json');
if (process.argv[3] === 'login') {
  const atual = fs.existsSync(arquivo) ? JSON.parse(fs.readFileSync(arquivo, 'utf8')) : {};
  fs.writeFileSync(arquivo, JSON.stringify({ ...atual, oauthAccount: JSON.parse(process.env.FAKE_LOGIN) }));
} else if (process.argv[3] === 'logout') {
  fs.appendFileSync(${JSON.stringify(saidas)}, (dir || '~/.claude') + '\\n');
}
`, { mode: 0o755 });
  const aegro = { accountUuid: 'u1', organizationUuid: 'org-aegro', organizationName: 'Aegro', emailAddress: 'a@exemplo.com' };
  const max = { accountUuid: 'u1', organizationUuid: 'org-max', organizationName: 'Max', emailAddress: 'a@exemplo.com' };
  fs.writeFileSync(path.join(home, '.claude.json'), JSON.stringify({ oauthAccount: aegro }));
  const env = { ...process.env, HOME: home, CLAUDE_AUTO_HOME: accounts, CLAUDE_AUTO_CLAUDE_BIN: claude, PATH: `${bin}:${process.env.PATH}` };
  const m = {
    home, accounts, propria, aegro, max,
    config(cfg) {
      fs.writeFileSync(path.join(accounts, 'config.json'), JSON.stringify({ notificar: false, ...cfg }));
    },
    logar(dir, conta) {
      fs.writeFileSync(path.join(dir, '.claude.json'), JSON.stringify(conta ? { oauthAccount: conta } : {}));
    },
    rodar(codigo) {
      const r = spawnSync(process.execPath, ['-e', `const contas = require(${JSON.stringify(path.join(__dirname, '../lib/contas'))});\n${codigo}`], { env, encoding: 'utf8' });
      assert.strictEqual(r.status, 0, r.stderr);
      return JSON.parse(r.stdout.trim().split('\n').pop());
    },
    entrar(args, conta) {
      return spawnSync(process.execPath, [path.join(__dirname, '../lib/claude-accounts.js'), 'login', ...args], {
        env: { ...env, FAKE_LOGIN: JSON.stringify(conta) },
        encoding: 'utf8',
      });
    },
    saidas() {
      return fs.existsSync(saidas) ? fs.readFileSync(saidas, 'utf8').trim().split('\n').filter(Boolean) : [];
    },
    log() {
      const arquivo = path.join(accounts, '.estado', 'claude-auto.log');
      return fs.existsSync(arquivo) ? fs.readFileSync(arquivo, 'utf8').split('\n') : [];
    },
  };
  m.config({ principal: 'principal', contas: { principal: {}, max: {} }, rota: ['principal', 'max'] });
  return m;
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
    assert.deepStrictEqual(r.janelas, { five_hour: { usado: 41.2, renovaEm: 1791514800000 }, seven_day: { usado: 76, renovaEm: 1791630000000 } });
    assert.strictEqual(r.em, agora);
    const gravado = JSON.parse(fs.readFileSync(path.join(contas.DIR_AO_VIVO, 'principal.json'), 'utf8'));
    assert.deepStrictEqual(gravado, r);
    // O evento seguinte só fala da janela de 5h: o arquivo traz só ela, com a hora dele, e a semanal fica com a
    // última leitura completa do Monitor, em vez de ser repetida aqui como se fosse nova.
    const depois = contas.registrarLimiteAoVivo('principal', { status: 'allowed', rateLimitType: 'five_hour', utilization: 0.45, resetsAt: 1791514800 }, agora + 60000);
    assert.deepStrictEqual(depois.janelas, { five_hour: { usado: 45, renovaEm: 1791514800000 } });
    assert.strictEqual(depois.em, agora + 60000);
    // O login vai junto, para o Monitor não mostrar os números de um login com o nome de outro.
    fs.mkdirSync(path.join(process.env.CLAUDE_AUTO_HOME, 'max'), { recursive: true });
    fs.writeFileSync(path.join(process.env.CLAUDE_AUTO_HOME, 'max', '.claude.json'),
      JSON.stringify({ oauthAccount: { accountUuid: 'conta-max', organizationUuid: 'org-x', emailAddress: 'max@exemplo.com' } }));
    assert.strictEqual(contas.registrarLimiteAoVivo('max', { status: 'allowed', rateLimitType: 'five_hour', utilization: 0.1 }, agora).conta,
      'conta-max:org-x');
    // Só o tipo do evento, sem janelas unificadas, ainda conta; evento sem número nenhum não grava nada.
    assert.deepStrictEqual(contas.registrarLimiteAoVivo('max', { status: 'allowed_warning', rateLimitType: 'seven_day', utilization: 0.9 }, agora).janelas,
      { seven_day: { usado: 90, renovaEm: null } });
    assert.strictEqual(contas.registrarLimiteAoVivo('compare', { status: 'allowed' }, agora), null);
    assert.ok(!fs.existsSync(path.join(contas.DIR_AO_VIVO, 'compare.json')));
  },

  contaDoTerminalVemDoLoginGuardadoQuandoOArquivoNomeiaOutraContaDaFila() {
    const home = process.env.CLAUDE_AUTO_HOME;
    const aegro = { accountUuid: 'u1', organizationUuid: 'org-aegro', organizationName: 'Aegro' };
    const max = { accountUuid: 'u1', organizationUuid: 'org-max', organizationName: 'Max' };
    fs.mkdirSync(path.join(home, 'aegro'), { recursive: true });
    fs.writeFileSync(path.join(home, 'aegro', '.claude.json'), JSON.stringify({ oauthAccount: aegro }));
    fs.mkdirSync(path.join(contas.DIR_ESTADO, 'agentes'), { recursive: true });
    fs.writeFileSync(path.join(contas.DIR_ESTADO, 'agentes', 'max.json'), JSON.stringify({ oauthAccount: max, chave: 'u1:org-max' }));
    const cfg = { principal: 'max', contas: { max: {}, aegro: {} }, rota: ['max', 'aegro'], reserva: [] };
    // A sessão aberta regravou o ~/.claude.json com a Aegro, que mora na pasta dela: vale o login guardado da Max.
    assert.strictEqual(contas.contaDoDirPadrao('max', cfg, aegro).organizationUuid, 'org-max');
    // Um login novo que não é de nenhuma conta da fila (o /login no terminal) fica como está.
    const outra = { accountUuid: 'u9', organizationUuid: 'org-9' };
    assert.strictEqual(contas.contaDoDirPadrao('max', cfg, outra), outra);
    // O arquivo concorda com o guardado, ou não há guardado: fica o arquivo.
    assert.strictEqual(contas.contaDoDirPadrao('max', cfg, max), max);
    assert.strictEqual(contas.contaDoDirPadrao('aegro', { principal: 'aegro', contas: { aegro: {} }, rota: ['aegro'], reserva: [] }, aegro), aegro);
    // Uma conta que saiu da fila mas ficou em `contas` não conta: o login dela no terminal fica como está.
    assert.strictEqual(contas.contaDoDirPadrao('max', { ...cfg, rota: ['max'] }, aegro), aegro);
  },

  sessaoDaContaDoClaudeAbreNaPastaPropriaQuandoTemLoginLa() {
    const home = process.env.CLAUDE_AUTO_HOME;
    fs.writeFileSync(path.join(home, 'config.json'), JSON.stringify({ principal: 'max', contas: { max: {}, aegro: {} }, rota: ['max', 'aegro'] }));
    const bin = fs.mkdtempSync(path.join(raiz, 'sec-'));
    fs.writeFileSync(path.join(bin, 'security'), '#!/bin/sh\n[ -n "$FAKE_SECURITY_SLEEP" ] && exec sleep "$FAKE_SECURITY_SLEEP"\nexit "${FAKE_SECURITY_STATUS:-0}"\n', { mode: 0o755 });
    const antes = { PATH: process.env.PATH, status: process.env.FAKE_SECURITY_STATUS, sleep: process.env.FAKE_SECURITY_SLEEP };
    process.env.PATH = `${bin}:${process.env.PATH}`;
    // No macOS o login da pasta própria é um item do Keychain (o `security` falso responde); fora dele, o arquivo.
    const credenciais = path.join(home, 'max', '.credentials.json');
    // Sem login anotado na pasta própria, o ~/.claude.json de quem roda o teste não entra na conta.
    fs.mkdirSync(path.join(home, 'max'), { recursive: true });
    fs.writeFileSync(path.join(home, 'max', '.claude.json'), '{}');
    const login = (tem) => {
      contas.esquecerLoginProprio();
      if (process.platform === 'darwin') process.env.FAKE_SECURITY_STATUS = tem ? '0' : '44';
      else if (tem) {
        fs.mkdirSync(path.dirname(credenciais), { recursive: true });
        fs.writeFileSync(credenciais, '{}');
      } else fs.rmSync(credenciais, { force: true });
    };
    try {
      // Com login na pasta própria, a conta do ~/.claude abre lá: a troca dos agentes não a leva junto.
      login(true);
      assert.strictEqual(contas.envDaSessao('max', {}).CLAUDE_CONFIG_DIR, path.join(home, 'max'));
      assert.strictEqual(contas.envDaSessao('max', {}).CLAUDE_AUTO_CONTA, 'max');
      // Sem login próprio, fica no ~/.claude, como antes.
      login(false);
      assert.strictEqual(contas.envDaSessao('max', {}).CLAUDE_CONFIG_DIR, undefined);
      // Conta que não é a do ~/.claude: a pasta dela, como sempre.
      assert.strictEqual(contas.envDaSessao('aegro', {}).CLAUDE_CONFIG_DIR, path.join(home, 'aegro'));
      if (process.platform === 'darwin') {
        // A resposta do Keychain fica guardada pela sessão: o `security` não roda de novo a cada consulta.
        login(true);
        assert.strictEqual(contas.temLoginProprio('max'), true);
        process.env.FAKE_SECURITY_STATUS = '44';
        assert.strictEqual(contas.temLoginProprio('max'), true);
        // Por poucos minutos: passado o prazo, o logout aparece; e quem vai reabrir a sessão consulta sem o guardado.
        const agora = Date.now;
        try {
          Date.now = () => agora() + 6 * 60 * 1000;
          assert.strictEqual(contas.temLoginProprio('max'), false);
        } finally {
          Date.now = agora;
        }
        process.env.FAKE_SECURITY_STATUS = '0';
        assert.strictEqual(contas.temLoginProprio('max'), false);
        assert.strictEqual(contas.temLoginProprio('max', undefined, { fresco: true }), true);
        assert.strictEqual(contas.temLoginProprio('max'), true);
        // Um Keychain que não responde em 2 s conta como sem login e não fica guardado.
        contas.esquecerLoginProprio();
        process.env.FAKE_SECURITY_STATUS = '0';
        process.env.FAKE_SECURITY_SLEEP = '3';
        assert.strictEqual(contas.temLoginProprio('max'), false);
        delete process.env.FAKE_SECURITY_SLEEP;
        assert.strictEqual(contas.temLoginProprio('max'), true);
      }
    } finally {
      contas.esquecerLoginProprio();
      process.env.PATH = antes.PATH;
      if (antes.status === undefined) delete process.env.FAKE_SECURITY_STATUS; else process.env.FAKE_SECURITY_STATUS = antes.status;
      if (antes.sleep === undefined) delete process.env.FAKE_SECURITY_SLEEP; else process.env.FAKE_SECURITY_SLEEP = antes.sleep;
      fs.rmSync(credenciais, { force: true });
      fs.writeFileSync(path.join(home, 'config.json'), '{}');
    }
  },

  pastaPropriaComLoginDeOutraContaNaoRecebeSessaoNemNumeros() {
    const m = mundoComDuasOrganizacoes();
    // A pasta própria da principal tem o login da Max (o mesmo e-mail, em outra organização): a sessão fica no
    // ~/.claude, e o status da conta diz por quê.
    m.logar(m.propria, m.max);
    let r = m.rodar(`
      const env = contas.envDaSessao('principal', {});
      console.log(JSON.stringify({ dir: env.CLAUDE_CONFIG_DIR || null, outra: contas.loginProprioDeOutraConta('principal') }));`);
    assert.strictEqual(r.dir, null);
    assert.strictEqual(r.outra.chave, 'u1:org-max');
    assert.strictEqual(r.outra.organizacao, 'Max');
    // Um aviso só, no log, por mais sessões que abram.
    m.rodar(`contas.envDaSessao('principal', {}); contas.envDaSessao('principal', {}); console.log('null');`);
    assert.strictEqual(m.log().filter((l) => l.includes('tem o login de outra conta')).length, 1);
    // Com o login dela, a sessão abre na pasta própria, como antes; e sem login legível lá, também.
    m.logar(m.propria, m.aegro);
    r = m.rodar(`console.log(JSON.stringify(contas.envDaSessao('principal', {}).CLAUDE_CONFIG_DIR || null));`);
    assert.strictEqual(r, m.propria);
    m.logar(m.propria, null);
    r = m.rodar(`console.log(JSON.stringify(contas.envDaSessao('principal', {}).CLAUDE_CONFIG_DIR || null));`);
    assert.strictEqual(r, m.propria);
    // Os números ao vivo levam o login da pasta em que a sessão roda, não o da conta: o Monitor deixa de fora os da
    // Max gravados no arquivo da principal.
    m.logar(m.propria, m.max);
    r = m.rodar(`
      const info = { status: 'allowed', rateLimitType: 'seven_day', utilization: 0.85, resetsAt: 1792508400 };
      console.log(JSON.stringify([contas.registrarLimiteAoVivo('principal', info, 1, ${JSON.stringify(m.propria)}).conta,
        contas.registrarLimiteAoVivo('principal', info, 1).conta]));`);
    assert.deepStrictEqual(r, ['u1:org-max', 'u1:org-aegro']);
    // Pasta sem login anotado: os números levam o login da conta, como antes, em vez de nenhum.
    m.logar(m.propria, null);
    r = m.rodar(`console.log(JSON.stringify(contas.registrarLimiteAoVivo('principal', { status: 'allowed', rateLimitType: 'five_hour', utilization: 0.1 }, 1, ${JSON.stringify(m.propria)}).conta));`);
    assert.strictEqual(r, 'u1:org-aegro');
  },

  contaForaDoClaudeComLoginDeOutraContaDaFilaSaiDaEscolha() {
    const m = mundoComDuasOrganizacoes();
    // A troca dos agentes pôs a Max no ~/.claude e guardou o login da principal (Aegro). A pasta da principal, onde ela
    // abre agora, ficou com o login da Max: escolher a principal gastaria a Max.
    m.config({ principal: 'max', contas: { principal: {}, max: {} }, rota: ['principal', 'max'] });
    fs.writeFileSync(path.join(m.home, '.claude.json'), JSON.stringify({ oauthAccount: m.max }));
    fs.mkdirSync(path.join(m.accounts, '.estado', 'agentes'), { recursive: true });
    fs.writeFileSync(path.join(m.accounts, '.estado', 'agentes', 'principal.json'), JSON.stringify({ oauthAccount: m.aegro, chave: 'u1:org-aegro' }));
    m.logar(m.propria, m.max);
    let r = m.rodar(`console.log(JSON.stringify(contas.loginDeOutraContaDaFila('principal')));`);
    assert.strictEqual(r.chave, 'u1:org-max');
    // A conta do ~/.claude não entra nessa regra (quem decide é envDaSessao), e um login certo libera a principal.
    assert.strictEqual(m.rodar(`console.log(JSON.stringify(contas.loginDeOutraContaDaFila('max')));`), null);
    m.logar(m.propria, m.aegro);
    assert.strictEqual(m.rodar(`console.log(JSON.stringify(contas.loginDeOutraContaDaFila('principal')));`), null);
  },

  loginQueCaiEmOutraContaEhRecusadoEDesfeito() {
    const m = mundoComDuasOrganizacoes();
    const extra = path.join(m.accounts, 'max');
    fs.mkdirSync(extra, { recursive: true });
    fs.writeFileSync(path.join(extra, '.claude.json'), JSON.stringify({ oauthAccount: m.max }));
    m.config({ principal: 'principal', contas: { principal: {}, max: {}, compare: {} }, rota: ['principal', 'max', 'compare'] });
    // A conta nova entra na organização da Max: o login sai da pasta dela e o Monitor recebe a conta repetida.
    let r = m.entrar(['compare'], m.max);
    assert.strictEqual(r.status, 3, r.stderr);
    const conflito = JSON.parse(r.stdout.match(/^conflict: (.*)$/m)[1]);
    assert.deepStrictEqual([conflito.account, conflito.organizationName, conflito.emailAddress], ['max', 'Max', 'a@exemplo.com']);
    assert.match(r.stderr, /which is max \(max\); signed out of it\. Run claude-accounts login compare again/);
    assert.deepStrictEqual(m.saidas(), [path.join(m.accounts, 'compare')]);
    // A pasta própria da principal com a Max: recusado, e na pasta própria, não no ~/.claude.
    r = m.entrar(['principal', '--own-folder'], m.max);
    assert.strictEqual(r.status, 3, r.stderr);
    assert.match(r.stderr, /Run claude-accounts login principal --own-folder again/);
    assert.deepStrictEqual(m.saidas(), [path.join(m.accounts, 'compare'), m.propria]);
    // Uma organização que não é de nenhuma conta, mas não é a da principal: na pasta própria dela, também não serve.
    r = m.entrar(['principal', '--own-folder'], { accountUuid: 'u1', organizationUuid: 'org-9', organizationName: 'Nove' });
    assert.strictEqual(r.status, 3, r.stderr);
    assert.strictEqual(JSON.parse(r.stdout.match(/^conflict: (.*)$/m)[1]).account, null);
    assert.match(r.stderr, /but principal is a@exemplo\.com, Aegro in ~\/\.claude/);
    assert.strictEqual(m.saidas().length, 3);
    // Uma conta fora da fila não conta como outra: o login dela pode se repetir.
    m.config({ principal: 'principal', contas: { principal: {}, max: {}, compare: {} }, rota: ['principal', 'compare'] });
    r = m.entrar(['compare'], m.max);
    assert.strictEqual(r.status, 0, r.stderr);
    m.config({ principal: 'principal', contas: { principal: {}, max: {}, compare: {} }, rota: ['principal', 'max', 'compare'] });
    r = m.entrar(['principal', '--own-folder', '--agents'], m.aegro);
    assert.strictEqual(r.status, 2);
    // O login certo fica, e diz a organização.
    r = m.entrar(['principal', '--own-folder'], m.aegro);
    assert.strictEqual(r.status, 0, r.stderr);
    assert.match(r.stdout, /principal is logged in as a@exemplo\.com, Aegro/);
    assert.strictEqual(JSON.parse(fs.readFileSync(path.join(m.propria, '.claude.json'), 'utf8')).oauthAccount.organizationUuid, 'org-aegro');
    // No ~/.claude (o do terminal e dos agentes) o login errado fica, sem logout, e o erro diz como refazer.
    r = m.entrar(['principal'], m.max);
    assert.strictEqual(r.status, 3, r.stderr);
    assert.doesNotMatch(r.stderr, /signed out/);
    assert.strictEqual(m.saidas().length, 3);
  },

  contaPendenteFicaForaDaFilaAteSerConcluida() {
    const m = mundoComDuasOrganizacoes();
    const adicionar = (...args) => {
      const r = spawnSync(process.execPath, [path.join(__dirname, '../lib/claude-accounts.js'), 'add', ...args], {
        env: { ...process.env, HOME: m.home, CLAUDE_AUTO_HOME: m.accounts },
        encoding: 'utf8',
      });
      assert.strictEqual(r.status, 0, r.stderr);
      return JSON.parse(fs.readFileSync(path.join(m.accounts, 'config.json'), 'utf8'));
    };
    m.config({ principal: 'principal', contas: { principal: {}, max: {} }, rota: ['principal', 'max'], reserva: [] });
    // O assistente cria a conta antes do login: ela existe (o login precisa da pasta), mas nenhuma sessão abre nela.
    let cfg = adicionar('nova', '--name', 'Nova conta', '--pending');
    assert.deepStrictEqual(cfg.contas.nova, { nome: 'Nova conta', pendente: true });
    assert.deepStrictEqual([cfg.rota, cfg.reserva], [['principal', 'max'], []]);
    assert.ok(fs.existsSync(path.join(m.accounts, 'nova')));
    // Uma conta pendente com o login de outra da fila não vira aviso de repetida: o assistente mostra isso ele mesmo.
    m.logar(path.join(m.accounts, 'nova'), m.aegro);
    assert.deepStrictEqual(m.rodar(`console.log(JSON.stringify(contas.contasDuplicadas()));`), []);
    // Um add sem --pending põe na fila e tira a marca, como antes.
    cfg = adicionar('nova', '--reserve');
    assert.deepStrictEqual(cfg.contas.nova, { nome: 'Nova conta' });
    assert.deepStrictEqual([cfg.rota, cfg.reserva], [['principal', 'max'], ['nova']]);
  },

  pastaPropriaDaContaDoClaudeRecebeOQueUmaContaExtraRecebe() {
    // Num processo à parte, com um HOME falso: o ~/.claude e o ~/.claude.json lidos aqui são de mentira.
    const home = fs.mkdtempSync(path.join(raiz, 'home-'));
    const accounts = path.join(home, '.claude-accounts');
    fs.mkdirSync(path.join(home, '.claude', 'skills'), { recursive: true });
    fs.mkdirSync(accounts, { recursive: true });
    fs.writeFileSync(path.join(home, '.claude', 'settings.json'), '{}');
    const principal = JSON.stringify({ mcpServers: { x: { command: 'x' } }, projects: { '/p': { hasTrustDialogAccepted: true } } });
    fs.writeFileSync(path.join(home, '.claude.json'), principal);
    fs.writeFileSync(path.join(accounts, 'config.json'), JSON.stringify({ principal: 'max', contas: { max: {} }, rota: ['max'] }));
    const propria = path.join(accounts, 'max');
    const rodar = (env) => {
      const r = spawnSync(process.execPath, ['-e', `require(${JSON.stringify(path.join(__dirname, '../lib/contas'))}).prepararSessao('max', ${JSON.stringify(env)})`], {
        env: { ...process.env, HOME: home, CLAUDE_AUTO_HOME: accounts },
        encoding: 'utf8',
      });
      assert.strictEqual(r.status, 0, r.stderr);
    };
    // Aberta no ~/.claude: nada a preparar.
    rodar({});
    assert.strictEqual(fs.existsSync(propria), false);
    // Aberta na pasta própria: os links, a config da principal e o trust dos projetos chegam lá.
    rodar({ CLAUDE_CONFIG_DIR: propria });
    assert.strictEqual(fs.readlinkSync(path.join(propria, 'settings.json')), path.join(home, '.claude', 'settings.json'));
    assert.strictEqual(fs.readlinkSync(path.join(propria, 'skills')), path.join(home, '.claude', 'skills'));
    const copiada = JSON.parse(fs.readFileSync(path.join(propria, '.claude.json'), 'utf8'));
    assert.deepStrictEqual(copiada.mcpServers, { x: { command: 'x' } });
    assert.strictEqual(copiada.projects['/p'].hasTrustDialogAccepted, true);
    // O ~/.claude.json da principal fica como estava.
    assert.strictEqual(fs.readFileSync(path.join(home, '.claude.json'), 'utf8'), principal);
  },

  sessaoQueSoMudaDePastaNaMesmaContaNaoEntraNaListaDeTrocas() {
    const home = process.env.CLAUDE_AUTO_HOME;
    fs.writeFileSync(path.join(home, 'config.json'), JSON.stringify({ notificar: false }));
    const arquivo = path.join(home, '.estado', 'trocas.jsonl');
    fs.rmSync(arquivo, { force: true });
    const lidas = () => (fs.existsSync(arquivo) ? fs.readFileSync(arquivo, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : []);
    try {
      contas.registrarTroca({ de: 'max', para: 'max', motivo: 'saiu-do-claude', sessao: 's' });
      contas.registrarTroca({ de: 'max', para: 'max', motivo: 'login-da-pasta-propria', sessao: 's' });
      assert.deepStrictEqual(lidas(), []);
      // A troca de teste com uma conta só continua na lista: é ela que testa o aviso.
      contas.registrarTroca({ de: 'max', para: 'max', motivo: 'teste', sessao: 's' });
      contas.registrarTroca({ de: 'max', para: 'aegro', motivo: 'five_hour', sessao: 's' });
      assert.deepStrictEqual(lidas().map((t) => t.motivo), ['teste', 'five_hour']);
    } finally {
      fs.rmSync(arquivo, { force: true });
      fs.writeFileSync(path.join(home, 'config.json'), '{}');
    }
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
