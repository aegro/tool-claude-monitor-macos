#!/usr/bin/env python3
import json
import os
import signal
import sys
import time

conta = os.environ.get("CLAUDE_AUTO_CONTA", "?")
args = sys.argv[1:]
sessao = next((args[i + 1] for i, a in enumerate(args[:-1]) if a in ("--session-id", "--resume")), "sem-sessao")
transcript = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "projects", "fake", f"{sessao}.jsonl")
os.makedirs(os.path.dirname(transcript), exist_ok=True)


def registrar(entrada):
    entrada["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    with open(transcript, "a") as arquivo:
        arquivo.write(json.dumps(entrada) + "\n")


with open(os.environ["FAKE_LOG"], "a") as arquivo:
    arquivo.write(json.dumps({"evento": "inicio", "conta": conta, "args": sys.argv[1:]}) + "\n")
limitadas = os.environ.get("FAKE_LIMITADAS", "").split(",")
sys.stdout.write(f"\x1b[1mfake claude ({conta})\x1b[0m\r\n")
sys.stdout.flush()
while True:
    try:
        linha = input("> ")
    except EOFError:
        break
    registrar({"type": "user", "message": {"content": linha}})
    if conta in limitadas:
        registrar({"type": "assistant", "isApiErrorMessage": True, "error": "rate_limit"})
        print("You've hit your limit · resets 8pm (America/Sao_Paulo)", flush=True)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True:
            sys.stdout.write("\r⏺ Usage limit reached · continuing automatically at 8pm · esc to cancel" * 30)
            sys.stdout.flush()
            time.sleep(0.01)
    else:
        registrar({"type": "assistant", "message": {"content": linha}})
        print(f"ok de {conta}: {linha}", flush=True)
