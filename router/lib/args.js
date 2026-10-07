'use strict';

const FLAGS_DE_SESSAO_COM_VALOR = new Set(['--resume', '-r', '--session-id', '--resume-session-at', '--resume-drops-turn']);
const FLAGS_DE_SESSAO_SEM_VALOR = new Set(['--continue', '-c', '--fork-session']);

function valorDaFlag(args, nome) {
  for (let i = 0; i < args.length; i++) {
    if (args[i] === nome) {
      const proximo = args[i + 1];
      return proximo !== undefined && !proximo.startsWith('-') ? proximo : null;
    }
    if (args[i].startsWith(`${nome}=`)) return args[i].slice(nome.length + 1);
  }
  return null;
}

function temFlag(args, nome) {
  return args.some((a) => a === nome || a.startsWith(`${nome}=`));
}

function semFlagsDeSessao(args) {
  const resultado = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const nome = arg.includes('=') ? arg.slice(0, arg.indexOf('=')) : arg;
    if (FLAGS_DE_SESSAO_SEM_VALOR.has(arg)) continue;
    if (FLAGS_DE_SESSAO_COM_VALOR.has(nome)) {
      if (!arg.includes('=') && args[i + 1] !== undefined && !args[i + 1].startsWith('-')) i++;
      continue;
    }
    resultado.push(arg);
  }
  return resultado;
}

function argsDeRetomada(args, sessionId) {
  const base = semFlagsDeSessao(args);
  return sessionId ? [...base, `--resume=${sessionId}`] : base;
}

module.exports = { valorDaFlag, temFlag, semFlagsDeSessao, argsDeRetomada };
