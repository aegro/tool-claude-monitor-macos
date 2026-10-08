#!/usr/bin/env python3
import json
import os
import pty
import select
import shutil
import sys
import tempfile
import time

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def ambiente():
    dir_ = tempfile.mkdtemp(prefix="claude-auto-tui-")
    contas = os.path.join(dir_, "contas")
    bin_ = os.path.join(dir_, "bin")
    casa = os.path.join(dir_, "casa")
    os.makedirs(os.path.join(contas, ".estado"))
    os.makedirs(bin_)
    os.makedirs(os.path.join(casa, ".claude"))
    with open(os.path.join(contas, "config.json"), "w") as arquivo:
        json.dump({"contas": {"principal": {}, "segunda": {}}, "rota": ["principal", "segunda"], "notificar": False}, arquivo)
    seguranca = os.path.join(bin_, "security")
    with open(seguranca, "w") as arquivo:
        arquivo.write("#!/bin/sh\necho '{\"claudeAiOauth\":{\"accessToken\":\"x\",\"expiresAt\":1}}'\n")
    os.chmod(seguranca, 0o755)
    fake = os.path.join(RAIZ, "test", "fake-tui.py")
    os.chmod(fake, 0o755)
    env = dict(
        os.environ,
        HOME=casa,
        PATH=f"{bin_}:{os.environ['PATH']}",
        CLAUDE_AUTO_HOME=contas,
        CLAUDE_AUTO_CLAUDE_BIN=fake,
        CLAUDE_AUTO_T3_DB=os.path.join(dir_, "sem-t3"),
        FAKE_LOG=os.path.join(dir_, "fake.log"),
        FAKE_LIMITADAS="principal",
        TERM="xterm-256color",
    )
    return dir_, env


def main():
    dir_, env = ambiente()
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(os.path.join(RAIZ, "bin", "claude-auto"), ["claude-auto", "--model", "opus", "primeiro prompt"], env)
    saida = b""
    enviado = citado = False
    inicio = time.time()
    while time.time() - inicio < 40 and b"ok de segunda: cita" not in saida:
        prontos, _, _ = select.select([fd], [], [], 0.2)
        if prontos:
            try:
                saida += os.read(fd, 65536)
            except OSError:
                break
        if not enviado and b"> " in saida:
            os.write(fd, b"oi\r")
            enviado = True
        if not citado and b"ok de segunda: [claude-auto]" in saida:
            time.sleep(3)
            os.write(fd, "cita: You've hit your weekly limit\r".encode())
            citado = True
    fim = time.time() + 5
    while time.time() < fim:
        if select.select([fd], [], [], 0.2)[0]:
            try:
                saida += os.read(fd, 65536)
            except OSError:
                break
    os.write(fd, b"\x04")
    time.sleep(1)
    texto = saida.decode("utf-8", "ignore")
    with open(env["FAKE_LOG"]) as arquivo:
        inicios = [json.loads(l) for l in arquivo if l.strip()]
    with open(os.path.join(env["CLAUDE_AUTO_HOME"], ".estado", "trocas.jsonl")) as arquivo:
        trocas = [json.loads(l) for l in arquivo if l.strip()]
    falhas = []
    if [i["conta"] for i in inicios] != ["principal", "segunda"]:
        falhas.append(f"contas iniciadas: {[i['conta'] for i in inicios]}")
    sessao = inicios[0]["args"][inicios[0]["args"].index("--session-id") + 1] if "--session-id" in inicios[0]["args"] else None
    if not sessao:
        falhas.append(f"sessão nova sem --session-id: {inicios[0]['args']}")
    if len(inicios) > 1 and inicios[1]["args"] != ["--model", "opus", "--resume", sessao]:
        falhas.append(f"retomada com args errados: {inicios[1]['args']}")
    if "continuing on segunda" not in texto:
        falhas.append("aviso de troca não apareceu")
    if "ok de segunda: [claude-auto]" not in texto:
        falhas.append("mensagem de continuação não chegou à nova conta")
    if not trocas or (trocas[0]["de"], trocas[0]["para"], trocas[0]["sessao"]) != ("principal", "segunda", sessao):
        falhas.append(f"troca registrada: {trocas}")
    if len(trocas) != 1 or len(inicios) != 2:
        falhas.append(f"aviso de limite citado pelo modelo disparou troca: {len(trocas)} trocas, {len(inicios)} inícios")
    with open(os.path.join(env["CLAUDE_AUTO_HOME"], ".estado", "esgotadas.json")) as arquivo:
        if "segunda" in json.load(arquivo):
            falhas.append("conta segunda marcada como esgotada sem erro de limite")
    shutil.rmtree(dir_, ignore_errors=True)
    if falhas:
        print("FALHA trocaNoTerminal\n  " + "\n  ".join(falhas) + "\n--- saída ---\n" + texto[-1500:])
        sys.exit(1)
    print("ok    trocaNoTerminal")


main()
