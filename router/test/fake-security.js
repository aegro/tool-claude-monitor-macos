#!/usr/bin/env node
'use strict';

const fs = require('fs');

const arquivo = process.env.FAKE_KEYCHAIN;
const itens = () => JSON.parse(fs.readFileSync(arquivo, 'utf8'));
const salvar = (lista) => fs.writeFileSync(arquivo, JSON.stringify(lista));

function opcoes(args) {
  const o = {};
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '-a' || args[i] === '-s' || args[i] === '-X') o[args[i]] = args[++i];
    else o[args[i]] = true;
  }
  return o;
}

const acha = (o) => (item) => item.servico === o['-s'] && (o['-a'] == null || item.conta === o['-a']);

function rodar([comando, ...args]) {
  const o = opcoes(args);
  const lista = itens();
  if (comando === 'find-generic-password') {
    const item = lista.find(acha(o));
    if (!item) return 44;
    if (o['-w']) process.stdout.write(`${item.texto}\n`);
    return 0;
  }
  if (comando === 'add-generic-password') {
    const texto = Buffer.from(o['-X'], 'hex').toString('utf8');
    const resto = lista.filter((item) => !(item.servico === o['-s'] && item.conta === o['-a']));
    salvar([...resto, { conta: o['-a'], servico: o['-s'], texto }]);
    return 0;
  }
  if (comando === 'delete-generic-password') {
    const i = lista.findIndex(acha(o));
    if (i < 0) return 44;
    lista.splice(i, 1);
    salvar(lista);
    return 0;
  }
  return 1;
}

function linhaEmArgs(linha) {
  return (linha.match(/"[^"]*"|\S+/g) || []).map((parte) => parte.replace(/^"|"$/g, ''));
}

if (process.argv[2] === '-i') {
  let codigo = 0;
  for (const linha of fs.readFileSync(0, 'utf8').split('\n').filter(Boolean)) codigo = rodar(linhaEmArgs(linha)) || codigo;
  process.exit(codigo);
}
process.exit(rodar(process.argv.slice(2)));
