'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const { PassThrough } = require('stream');
const path = require('path');

require('./ambiente-limpo');

const raiz = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-auto-como-'));
process.env.CLAUDE_AUTO_HOME = path.join(raiz, 'contas');
fs.mkdirSync(process.env.CLAUDE_AUTO_HOME, { recursive: true });

const contas = require('../lib/contas');
const como = require('../lib/como');

const conta = (email, org, uuid, orgUuid) => ({ emailAddress: email, organizationName: org, accountUuid: uuid, organizationUuid: orgUuid });
const TEAM = conta('thomas@empresa.com', 'Empresa', 'u1', 'org-team');
const MAX = conta('thomas@empresa.com', 'Pessoal', 'u1', 'org-max');

// Toda conta mora na própria pasta (a principal com `dir`), para nada ler o ~/.claude de quem roda os testes.
function configurar(logins) {
  const contasCfg = {};
  for (const id of Object.keys(logins)) {
    const dir = path.join(raiz, 'pastas', id);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, '.claude.json'), JSON.stringify(logins[id] ? { oauthAccount: logins[id] } : {}));
    contasCfg[id] = { dir };
  }
  fs.writeFileSync(
    path.join(process.env.CLAUDE_AUTO_HOME, 'config.json'),
    JSON.stringify({ principal: 'principal', contas: contasCfg, rota: Object.keys(logins) }),
  );
  return contas.carregarConfig();
}

const testes = {
  argumentosViramContaPedidoEFerramentas() {
    const padrao = como.lerArgs(['principal', 'publique', 'o', 'arquivo']);
    assert.strictEqual(padrao.id, 'principal');
    assert.strictEqual(padrao.pedido, 'publique o arquivo');
    assert.deepStrictEqual(padrao.ferramentas, como.FERRAMENTAS_PADRAO);
    assert.strictEqual(padrao.modelo, como.MODELO_PADRAO);
    const mais = como.lerArgs(['principal', '--tools', 'Artifact, mcp__slack', '--model', 'claude-sonnet-5-5', '--', '--leia', 'isto']);
    assert.deepStrictEqual(mais.ferramentas, ['Artifact', 'mcp__slack']);
    assert.strictEqual(mais.modelo, 'claude-sonnet-5-5');
    assert.strictEqual(mais.pedido, '--leia isto');
    assert.ok(como.lerArgs([]).erro);
    assert.ok(como.lerArgs(['principal', '--tools']).erro);
    assert.ok(como.lerArgs(['principal', '--tools', ',']).erro);
  },
  rodaNaPastaDaContaComOFilhoEstreito() {
    const cfg = configurar({ principal: TEAM, max: MAX });
    const plano = como.planejar('principal', { pedido: 'leia o artefato', ferramentas: como.FERRAMENTAS_PADRAO, modelo: 'm' }, cfg, {});
    assert.ifError(plano.erro);
    assert.strictEqual(plano.env.CLAUDE_CONFIG_DIR, path.join(raiz, 'pastas', 'principal'));
    assert.strictEqual(plano.env.CLAUDE_AUTO_CONTA, 'principal');
    assert.strictEqual(plano.onde, 'thomas@empresa.com, Empresa');
    const a = plano.args;
    // O pedido vai pela entrada padrão do filho: em argv, um pedido começando com "-" viraria opção do CLI.
    assert.strictEqual(plano.pedido, 'leia o artefato');
    assert.ok(!a.includes('leia o artefato'));
    assert.strictEqual(a[0], '-p');
    assert.strictEqual(a[a.indexOf('--tools') + 1], 'Artifact,ArtifactComments,ArtifactData,Read');
    assert.strictEqual(a[a.indexOf('--allowedTools') + 1], 'Artifact,ArtifactComments,ArtifactData,Read');
    // Sem os settings do usuário (que podem liberar Bash), sem MCP local, sem transcrição.
    assert.strictEqual(a[a.indexOf('--setting-sources') + 1], 'project');
    assert.ok(a.includes('--strict-mcp-config'));
    assert.ok(a.includes('--no-session-persistence'));
    assert.match(a[a.indexOf('--append-system-prompt') + 1], /thomas@empresa\.com, Empresa/);
  },
  recusaContaSemLoginOuComOLoginDeOutra() {
    const cfg = configurar({ principal: TEAM, max: MAX, vazia: null, copia: MAX });
    const pedir = (id, pedido = 'x') => como.planejar(id, { pedido, ferramentas: ['Artifact'], modelo: 'm' }, cfg, {});
    assert.match(pedir('vazia').erro, /has no login .*claude-accounts login vazia/);
    // O mesmo e-mail na org errada: rodaria na outra conta com o nome desta.
    assert.match(pedir('copia').erro, /signed in to thomas@empresa\.com, Pessoal \(max\), not to copia/);
    assert.match(pedir('sumiu').erro, /unknown account: sumiu/);
    assert.match(pedir('principal', '').erro, /empty request/);
  },
  filhoNaoHerdaCredencialDaSessaoQuePediu() {
    const env = como.ambienteLimpo({
      PATH: '/bin', CLAUDECODE: '1', CLAUDE_CODE_OAUTH_TOKEN: 't', CLAUDE_CODE_ENTRYPOINT: 'claude-vscode',
      CLAUDE_CODE_SESSION_ID: 's', ANTHROPIC_API_KEY: 'k', ANTHROPIC_AUTH_TOKEN: 'a', CLAUDE_CONFIG_DIR: '/outra',
      CLAUDE_AUTO_CONTA: 'max',
    });
    // De onde a sessão veio fica: é o que dá as ferramentas de artefato ao filho, e não autentica nada.
    assert.deepStrictEqual(env, { PATH: '/bin', CLAUDE_CODE_ENTRYPOINT: 'claude-vscode' });
    const cfg = configurar({ principal: TEAM, max: MAX });
    const plano = como.planejar('principal', { pedido: 'x', ferramentas: ['Artifact'], modelo: 'm' }, cfg, { PATH: '/bin', ANTHROPIC_API_KEY: 'k' });
    assert.strictEqual(plano.env.ANTHROPIC_API_KEY, undefined);
    assert.strictEqual(plano.env.PATH, '/bin');
    // Fora do VS Code e do app desktop não há Artifact: o comando avisa em vez de deixar o filho dizer que não achou.
    assert.match(plano.aviso, /only exist in Claude Code sessions from VS Code or the desktop app/);
    const doVsCode = como.planejar('principal', { pedido: 'x', ferramentas: ['Artifact'], modelo: 'm' }, cfg, { CLAUDE_CODE_ENTRYPOINT: 'claude-vscode' });
    assert.strictEqual(doVsCode.aviso, null);
    const semArtefato = como.planejar('principal', { pedido: 'x', ferramentas: ['Read'], modelo: 'm' }, cfg, {});
    assert.strictEqual(semArtefato.aviso, null);
  },
  async tokenDeOutraContaNaPastaRecusa() {
    const cfg = configurar({ principal: TEAM, max: MAX });
    const plano = como.planejar('principal', { pedido: 'x', ferramentas: ['Artifact'], modelo: 'm' }, cfg, {});
    const com = (r, item = '{}') => como.conferirToken(plano, cfg, { lerItem: async () => item, conferir: async () => r });
    assert.deepStrictEqual(await com({ valido: true, chave: 'u1:org-team' }), {});
    // O arquivo diz Team, o token é da Max: rodaria na Max com o banner dizendo Team.
    assert.match((await com({ valido: true, chave: 'u1:org-max' })).erro, /token .* belongs to max \(max\), not to principal/);
    assert.match((await com({ valido: true, chave: 'u9:org-x' })).erro, /belongs to an account outside the queue/);
    assert.match((await com({ valido: false, motivo: 'HTTP 401' })).erro, /no longer works \(HTTP 401\)/);
    assert.match((await com({ valido: true, chave: null, vencido: true })).aviso, /expired, the CLI renews it/);
    assert.match((await com({ valido: null, motivo: 'timeout' })).aviso, /could not check the token .*timeout/);
    assert.match((await com({}, null)).erro, /has no login/);
  },
  async entradaSemDadoNaoSeguraOComando() {
    const parada = new PassThrough();
    parada.isTTY = false;
    assert.strictEqual(await como.lerEntrada(parada, 50), '');
    const comPedido = new PassThrough();
    comPedido.isTTY = false;
    const lido = como.lerEntrada(comPedido, 1000);
    comPedido.end('- publique o relatório\n');
    assert.strictEqual(await lido, '- publique o relatório');
  },
  registroGuardaAsUltimasTarefasSoParaODono() {
    const arquivo = path.join(raiz, 'acessos.jsonl');
    for (let i = 0; i < 505; i += 1) como.registrar({ em: i, conta: 'principal', pedido: `p${i}` }, arquivo);
    const linhas = fs.readFileSync(arquivo, 'utf8').trim().split('\n');
    assert.strictEqual(linhas.length, 500);
    assert.strictEqual(JSON.parse(linhas[0]).em, 5);
    assert.strictEqual(fs.statSync(arquivo).mode & 0o777, 0o600);
    const ultimas = como.lerAcessos(2, arquivo);
    assert.deepStrictEqual(ultimas.map((a) => a.em), [504, 503]);
    assert.deepStrictEqual(como.lerAcessos(5, path.join(raiz, 'nao-existe.jsonl')), []);
    assert.strictEqual(como.lerAcessos(0, arquivo).length, 20);
    assert.strictEqual(como.lerAcessos(NaN, arquivo).length, 20);
    // A linha nasce antes do filho e é completada no fim, no mesmo lugar.
    como.registrar({ id: 'x-1', em: 1000, codigo: null }, arquivo);
    como.registrar({ id: 'x-1', em: 1000, codigo: 0, ms: 5 }, arquivo);
    const fim = como.lerAcessos(3, arquivo);
    assert.deepStrictEqual(fim[0], { id: 'x-1', em: 1000, codigo: 0, ms: 5 });
    assert.strictEqual(fim.filter((a) => a.id === 'x-1').length, 1);
  },
  async rodarEntregaOPedidoAoFilhoERegistraOFim() {
    configurar({ principal: TEAM, max: MAX });
    const saida = path.join(raiz, 'filho.json');
    const preparadas = [];
    const sem = { verificarToken: async () => ({}), preparar: (id) => preparadas.push(id) };
    const ouvintes = () => ['SIGINT', 'SIGTERM', 'SIGHUP'].map((s) => process.listenerCount(s));
    const antes = ouvintes();
    const env = { CLAUDE_AUTO_CLAUDE_BIN: path.join(__dirname, 'fake-claude-como.js'), COMO_FAKE_SAIDA: saida };
    const comEnv = async (extra, fn) => {
      Object.assign(process.env, env, extra);
      try {
        return await fn();
      } finally {
        for (const k of Object.keys({ ...env, ...extra })) delete process.env[k];
      }
    };
    fs.rmSync(como.ARQ_ACESSOS, { force: true });

    // O pedido chega inteiro pela entrada padrão, mesmo começando com "-", e o código do filho é o do comando.
    const codigo = await comEnv({ COMO_FAKE_CODIGO: '3' }, () => como.rodar(['principal', '--tools', 'Read', '--', '- publique', 'o relatório'], sem));
    assert.strictEqual(codigo, 3);
    const recebido = JSON.parse(fs.readFileSync(saida, 'utf8'));
    assert.strictEqual(recebido.pedido, '- publique o relatório');
    assert.ok(!recebido.args.includes('- publique o relatório'));
    assert.strictEqual(recebido.configDir, path.join(raiz, 'pastas', 'principal'));
    assert.strictEqual(recebido.conta, 'principal');
    assert.deepStrictEqual(preparadas, ['principal']);
    const [registro] = como.lerAcessos(5);
    assert.strictEqual(registro.conta, 'principal');
    assert.strictEqual(registro.pedido, '- publique o relatório');
    assert.strictEqual(registro.codigo, 3);
    assert.ok(Number.isInteger(registro.ms));
    assert.strictEqual(como.lerAcessos(5).length, 1);
    assert.deepStrictEqual(ouvintes(), antes);

    // Filho morto por sinal: 128, como no shell sem o número do sinal.
    assert.strictEqual(await comEnv({ COMO_FAKE_SINAL: 'SIGKILL' }, () => como.rodar(['principal', '--tools', 'Read', 'x'], sem)), 128);

    // Binário que não sobe (interpretador inexistente): 1, e o registro fecha mesmo assim.
    const quebrado = path.join(raiz, 'claude-quebrado');
    fs.writeFileSync(quebrado, '#!/nao/existe/interpretador\n', { mode: 0o755 });
    const falhou = await comEnv({ CLAUDE_AUTO_CLAUDE_BIN: quebrado }, () => como.rodar(['principal', '--tools', 'Read', 'y'], sem));
    assert.strictEqual(falhou, 1);
    assert.strictEqual(como.lerAcessos(1)[0].codigo, 1);
    assert.deepStrictEqual(ouvintes(), antes);

    // Token de outra conta: nada roda e nada é registrado.
    const n = como.lerAcessos(50).length;
    const recusado = await comEnv({}, () => como.rodar(['principal', 'z'], { ...sem, verificarToken: async () => ({ erro: 'token de outra' }) }));
    assert.strictEqual(recusado, 2);
    assert.strictEqual(como.lerAcessos(50).length, n);
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
      console.log(`FALHA ${nome}\n${e.stack}`);
    }
  }
  fs.rmSync(raiz, { recursive: true, force: true });
  process.exit(falhas ? 1 : 0);
})();
