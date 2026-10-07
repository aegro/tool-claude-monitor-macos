#!/usr/bin/env python3
import json
import os
import sys

conta = os.environ.get("CLAUDE_AUTO_CONTA", "?")
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
    if conta in limitadas:
        print("You've hit your limit · resets 8pm (America/Sao_Paulo)", flush=True)
    else:
        print(f"ok de {conta}: {linha}", flush=True)
