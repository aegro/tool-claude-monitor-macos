'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
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
    assert.strictEqual(a[a.indexOf('-p') + 1], 'leia o artefato');
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
  },
};

let falhas = 0;
for (const [nome, teste] of Object.entries(testes)) {
  try {
    teste();
    console.log(`ok    ${nome}`);
  } catch (e) {
    falhas += 1;
    console.log(`FALHA ${nome}\n${e.stack}`);
  }
}
fs.rmSync(raiz, { recursive: true, force: true });
process.exit(falhas ? 1 : 0);
