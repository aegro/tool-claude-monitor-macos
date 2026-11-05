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
    // Leitura sem escopo não é liberada: um artefato de terceiro com instrução embutida não leva o filho a ~/.ssh.
    assert.strictEqual(a[a.indexOf('--allowedTools') + 1], 'Artifact,ArtifactComments,ArtifactData');
    // Sem os settings do usuário (que podem liberar Bash), sem MCP local, sem transcrição.
    assert.strictEqual(a[a.indexOf('--setting-sources') + 1], 'project');
    assert.ok(a.includes('--strict-mcp-config'));
    assert.ok(a.includes('--no-session-persistence'));
    assert.match(a[a.indexOf('--append-system-prompt') + 1], /thomas@empresa\.com, Empresa/);
  },
  leituraSoDoQueOPedidoCita() {
    const cfg = configurar({ principal: TEAM, max: MAX });
    const arquivo = path.join(raiz, 'relatorio.html');
    fs.writeFileSync(arquivo, '<p>x</p>');
    const real = fs.realpathSync(arquivo);
    const liberadas = (pedido, ferramentas = como.FERRAMENTAS_PADRAO) => {
      const a = como.planejar('principal', { pedido, ferramentas, modelo: 'm' }, cfg, {}).args;
      return a.includes('--allowedTools') ? a[a.indexOf('--allowedTools') + 1].split(',') : [];
    };
    // O caminho citado (com aspas e pontuação em volta) ganha a regra só para ele, já resolvido (/tmp → /private/tmp).
    assert.ok(liberadas(`publique "${arquivo}".`).includes(`Read(/${real})`));
    const pasta = path.join(raiz, 'relatorios');
    fs.mkdirSync(pasta, { recursive: true });
    assert.ok(liberadas(`resuma ${pasta}`).includes(`Read(/${fs.realpathSync(pasta)}/**)`));
    // As duas formas, quando diferem (no macOS o tmpdir é um link para /private/var/…).
    if (path.resolve(arquivo) !== real) assert.ok(liberadas(`publique ${arquivo}`).includes(`Read(/${path.resolve(arquivo)})`));
    // Pasta que contém a das contas (aqui, o CLAUDE_AUTO_HOME do teste) não é liberada.
    assert.ok(!liberadas(`resuma ${raiz}`).some((f) => f.startsWith('Read')));
    // Caminho que não existe não vira regra; sem Read nas ferramentas, nenhuma regra de leitura.
    assert.ok(!liberadas('leia /nao/existe/nada.txt').some((f) => f.startsWith('Read')));
    assert.deepStrictEqual(liberadas(`publique ${arquivo}`, ['Artifact']), ['Artifact']);
    // Só leitura, sem caminho: o filho tem o Read (no diretório atual) e nenhuma flag de liberação vazia.
    const so = como.planejar('principal', { pedido: 'x', ferramentas: ['Read'], modelo: 'm' }, cfg, {}).args;
    assert.ok(!so.includes('--allowedTools'));
    assert.strictEqual(so[so.indexOf('--tools') + 1], 'Read');
    // Regra com escopo pedida à mão vale como escrita, e o --tools leva só o nome.
    const mao = como.planejar('principal', { pedido: 'x', ferramentas: ['Artifact', 'Read(//dados/**)'], modelo: 'm' }, cfg, {}).args;
    assert.strictEqual(mao[mao.indexOf('--tools') + 1], 'Artifact,Read');
    assert.strictEqual(mao[mao.indexOf('--allowedTools') + 1], 'Artifact,Read(//dados/**)');
  },
  palavraSoltaNaoLiberaAMaquinaNemOHome() {
    const home = path.join(raiz, 'home', 'thomas');
    for (const d of ['.ssh', '.claude-accounts', '.config/aegro', 'Code/projeto']) fs.mkdirSync(path.join(home, d), { recursive: true });
    fs.writeFileSync(path.join(home, '.ssh', 'id_ed25519'), 'chave');
    fs.writeFileSync(path.join(home, 'Code', 'projeto', 'relatorio.html'), '<p>x</p>');
    const regras = (pedido) => como.caminhosDoPedido(pedido, home);
    // A raiz, o home e os ancestrais dele: nada.
    assert.deepStrictEqual(regras('leia o artefato A / B e resuma'), []);
    assert.deepStrictEqual(regras('resumo (/) aqui'), []);
    assert.deepStrictEqual(regras('resuma ~/ e o resto'), []);
    assert.deepStrictEqual(regras(`veja ${home}`), []);
    assert.deepStrictEqual(regras(`veja ${path.dirname(home)}`), []);
    // Pastas sensíveis, por dentro ou por quem as contém.
    assert.deepStrictEqual(regras('leia ~/.ssh/id_ed25519'), []);
    assert.deepStrictEqual(regras('resuma ~/.ssh'), []);
    assert.deepStrictEqual(regras('resuma ~/.config'), []);
    assert.deepStrictEqual(regras('leia ~/.claude-accounts'), []);
    // Pasta rasa demais.
    assert.deepStrictEqual(regras('resuma /usr'), []);
    // A profundidade vale para as duas formas: no macOS /var/db é raso, mesmo resolvendo para /private/var/db.
    if (fs.existsSync('/var/db') && fs.realpathSync('/var/db') !== '/var/db') assert.deepStrictEqual(regras('resuma /var/db'), []);
    // O que o pedido cita de verdade passa.
    const arquivo = fs.realpathSync(path.join(home, 'Code', 'projeto', 'relatorio.html'));
    assert.ok(regras('publique ~/Code/projeto/relatorio.html').includes(arquivo));
    assert.ok(regras('resuma ~/Code/projeto').includes(`${fs.realpathSync(path.join(home, 'Code', 'projeto'))}/**`));
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
    assert.strictEqual(plano.semArtefato, true);
    const doVsCode = como.planejar('principal', { pedido: 'x', ferramentas: ['Artifact'], modelo: 'm' }, cfg, { CLAUDE_CODE_ENTRYPOINT: 'claude-vscode' });
    assert.strictEqual(doVsCode.aviso, null);
    assert.strictEqual(doVsCode.semArtefato, false);
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
    assert.match((await com({}, null)).erro, /claude-accounts login principal$/);
    // A conta do ~/.claude (sem `dir`): `login <id>` entraria no slot dos agentes; o conserto é a pasta própria.
    const doPadrao = { ...cfg, contas: { ...cfg.contas, principal: {} } };
    const noPadrao = (r, item = '{}') => como.conferirToken(plano, doPadrao, { lerItem: async () => item, conferir: async () => r });
    assert.match((await noPadrao({ valido: false, motivo: 'HTTP 401' })).erro, /claude-accounts login principal --own-folder$/);
    assert.match((await noPadrao({}, null)).erro, /claude-accounts login principal --own-folder$/);
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
    // Mandou algo e não fechou: vale o que chegou, depois do prazo de inatividade.
    const aberta = new PassThrough();
    aberta.isTTY = false;
    const parcial = como.lerEntrada(aberta, 50);
    aberta.write('pedido sem fim\n');
    assert.strictEqual(await parcial, 'pedido sem fim');
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
  async checkDizOndeRodariaSemRodarNemRegistrar() {
    configurar({ principal: TEAM, max: MAX });
    fs.rmSync(como.ARQ_ACESSOS, { force: true });
    // De uma sessão do VS Code, como a skill roda: no CI e num terminal comum não haveria Artifact (ver abaixo).
    const entradaAntes = process.env.CLAUDE_CODE_ENTRYPOINT;
    process.env.CLAUDE_CODE_ENTRYPOINT = 'claude-vscode';
    const escrito = [];
    const saida = { write: (t) => escrito.push(t) };
    const ok = { verificarToken: async () => ({}), saida };
    // Sem pedido e sem tocar na entrada padrão: a conferência não espera nada.
    assert.strictEqual(await como.rodar(['principal', '--check', '--json'], ok), 0);
    const r = JSON.parse(escrito.pop());
    assert.deepStrictEqual(r, {
      account: 'principal', ok: true, login: 'thomas@empresa.com', organization: 'Empresa',
      folder: path.join(raiz, 'pastas', 'principal'), token: 'checked', warnings: [], error: null,
    });
    // Token vencido: a org vem do declarado, e a saída diz que o token não foi conferido.
    assert.strictEqual(await como.rodar(['max', '--check', '--json'], { ...ok, verificarToken: async () => ({ aviso: 'expirou' }) }), 0);
    const vencido = JSON.parse(escrito.pop());
    assert.strictEqual(vencido.organization, 'Pessoal');
    assert.strictEqual(vencido.token, 'unchecked');
    assert.deepStrictEqual(vencido.warnings, ['expirou']);
    // A tarefa não rodaria: saída 2, com o motivo no JSON.
    configurar({ principal: TEAM, max: MAX, copia: MAX });
    assert.strictEqual(await como.rodar(['copia', '--check', '--json'], ok), 2);
    assert.match(JSON.parse(escrito.pop()).error, /signed in to thomas@empresa\.com, Pessoal \(max\), not to copia/);
    assert.strictEqual(await como.rodar(['principal', '--check', '--json'], { ...ok, verificarToken: async () => ({ erro: 'token de outra' }) }), 2);
    const recusado = JSON.parse(escrito.pop());
    assert.strictEqual(recusado.error, 'token de outra');
    // O token desmentiu o que a pasta declara: login e org saem vazios, a pasta fica.
    assert.strictEqual(recusado.organization, null);
    assert.strictEqual(recusado.login, null);
    assert.strictEqual(recusado.folder, path.join(raiz, 'pastas', 'principal'));
    configurar({ principal: TEAM, max: MAX, vazia: null });
    assert.strictEqual(await como.rodar(['vazia', '--check', '--json'], ok), 2);
    assert.strictEqual(JSON.parse(escrito.pop()).folder, path.join(raiz, 'pastas', 'vazia'));
    // Falha inesperada no meio da conferência ainda sai como JSON.
    assert.strictEqual(await como.rodar(['principal', '--check', '--json'], { ...ok, verificarToken: async () => { throw new Error('rede caiu'); } }), 2);
    assert.match(JSON.parse(escrito.pop()).error, /could not check principal: rede caiu/);
    // Em texto, uma linha com o login, a org, a pasta e o token.
    assert.strictEqual(await como.rodar(['principal', '--check'], ok), 0);
    assert.strictEqual(escrito.pop(), `principal: thomas@empresa.com, Empresa (folder ${path.join(raiz, 'pastas', 'principal')}, token checked)\n`);
    // Fora do VS Code e do app desktop, a publicação falharia: para a conferência, isso é "não rodaria".
    delete process.env.CLAUDE_CODE_ENTRYPOINT;
    assert.strictEqual(await como.rodar(['principal', '--check', '--json'], ok), 2);
    const semArtefato = JSON.parse(escrito.pop());
    assert.strictEqual(semArtefato.ok, false);
    assert.match(semArtefato.error, /only exist in Claude Code sessions from VS Code or the desktop app/);
    // Sem ferramenta de artefato pedida, a mesma sessão passa.
    assert.strictEqual(await como.rodar(['principal', '--check', '--json', '--tools', 'Read'], ok), 0);
    escrito.pop();
    if (entradaAntes === undefined) delete process.env.CLAUDE_CODE_ENTRYPOINT;
    else process.env.CLAUDE_CODE_ENTRYPOINT = entradaAntes;
    // Nada disso roda o claude nem entra no registro.
    assert.deepStrictEqual(como.lerAcessos(5), []);
    assert.ok(como.lerArgs(['principal', '--json']).erro);
    // Opção só vale antes do pedido; com --check, pedido é erro (nada roda).
    assert.strictEqual(como.lerArgs(['principal', 'resuma', 'o', '--check', 'do', 'relatório']).pedido, 'resuma o --check do relatório');
    assert.strictEqual(como.lerArgs(['principal', 'resuma', 'o', '--check', 'do', 'relatório']).check, false);
    assert.match(como.lerArgs(['principal', '--check', 'publique', '/x']).erro, /--check runs nothing/);
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
