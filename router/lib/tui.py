import errno
import fcntl
import glob
import json
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import tty
from datetime import datetime, timezone

LIMITE = re.compile(
    r"hit your (?:\w+ )?limit|usage limit reached|limit will reset|weekly limit reached|session limit reached",
    re.IGNORECASE,
)
ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")
FLAGS_COM_VALOR = {"--resume", "-r", "--session-id", "--resume-session-at"}
FLAGS_SEM_VALOR = {"--continue", "-c", "--fork-session"}
VALOR_OBRIGATORIO = {
    "--agent", "--agents", "--append-system-prompt", "--autocompact", "--debug-file", "--effort", "--environment",
    "--fallback-model", "--input-format", "--json-schema", "--max-budget-usd", "--model", "-n", "--name",
    "--output-format", "--permission-mode", "--permission-prompts", "--plugin-dir", "--plugin-url",
    "--remote-control-session-name-prefix", "--session-id", "--setting-sources", "--settings", "--system-prompt",
    "--system-prompt-snapshot", "--resume-session-at",
}
VALOR_OPCIONAL = {
    "--cloud", "-d", "--debug", "--from-pr", "--prompt-suggestions", "--remote-control", "-r", "--resume",
    "--teleport", "-w", "--worktree",
}
VALOR_VARIADICO = {
    "--add-dir", "--betas", "--file", "--mcp-config", "--tools", "--allowedTools", "--allowed-tools",
    "--disallowedTools", "--disallowed-tools",
}
REARMAR_SEM_TROCA = 300
CONTINUAR = (
    "[claude-auto] A conta anterior atingiu o limite e esta sessão foi retomada em outra conta. "
    "Continue exatamente de onde parou, sem refazer o que já foi concluído."
)


def log(config, mensagem):
    try:
        with open(config["log"], "a") as arquivo:
            arquivo.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} [{os.getpid()}] tui: {mensagem}\n")
    except OSError:
        pass


def sem_flags_de_sessao(args):
    resultado = []
    pular = False
    for i, arg in enumerate(args):
        if pular:
            pular = False
            continue
        nome = arg.split("=", 1)[0]
        if arg in FLAGS_SEM_VALOR:
            continue
        if nome in FLAGS_COM_VALOR:
            if "=" not in arg and i + 1 < len(args) and not args[i + 1].startswith("-"):
                pular = True
            continue
        resultado.append(arg)
    return resultado


def sem_prompt(args):
    resultado = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--":
            break
        if not arg.startswith("-"):
            i += 1
            continue
        resultado.append(arg)
        i += 1
        if "=" in arg:
            continue
        if arg in VALOR_OBRIGATORIO and i < len(args):
            resultado.append(args[i])
            i += 1
        elif arg in VALOR_OPCIONAL and i < len(args) and not args[i].startswith("-"):
            resultado.append(args[i])
            i += 1
        elif arg in VALOR_VARIADICO:
            while i < len(args) and not args[i].startswith("-"):
                resultado.append(args[i])
                i += 1
    return resultado


def instante(entrada):
    try:
        return datetime.strptime(entrada["timestamp"][:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    except (KeyError, TypeError, ValueError):
        return None


def valor(args, nome):
    for i, arg in enumerate(args):
        if arg == nome and i + 1 < len(args) and not args[i + 1].startswith("-"):
            return args[i + 1]
        if arg.startswith(nome + "="):
            return arg.split("=", 1)[1]
    return None


def copiar_tamanho(destino):
    try:
        tamanho = fcntl.ioctl(sys.stdin.fileno(), termios.TIOCGWINSZ, b"\0" * 8)
        fcntl.ioctl(destino, termios.TIOCSWINSZ, tamanho)
    except OSError:
        pass


class Supervisor:
    def __init__(self, config):
        self.config = config
        self.conta = config["conta"]
        self.env = dict(os.environ, **config["env"])
        self.args = list(config["args"])
        self.sessao = valor(self.args, "--session-id") or valor(self.args, "--resume") or valor(self.args, "-r")
        self.pid = None
        self.fd = None
        self.texto = ""
        self.armado_em = 0.0
        self.continuar_em = None
        self.lancado_em = 0.0

    def dir_config(self):
        return self.env.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")

    def sessao_atual(self):
        try:
            with open(os.path.join(self.dir_config(), "sessions", f"{self.pid}.json")) as arquivo:
                return json.load(arquivo).get("sessionId") or self.sessao
        except (OSError, ValueError):
            return self.sessao

    def lancar(self, args, armar_em):
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.execve(self.config["bin"], [self.config["bin"], *args], self.env)
            finally:
                os._exit(127)
        self.pid, self.fd = pid, fd
        self.lancado_em = time.time()
        copiar_tamanho(fd)
        self.texto = ""
        self.armado_em = time.time() + armar_em

    def repassar(self, segundos, entrada=None):
        try:
            fontes = [self.fd] if entrada is None else [self.fd, entrada]
            prontos, _, _ = select.select(fontes, [], [], segundos)
            if entrada is not None and entrada in prontos:
                dados = os.read(entrada, 4096)
                if dados:
                    os.write(self.fd, dados)
            if self.fd in prontos:
                dados = os.read(self.fd, 65536)
                if dados:
                    os.write(sys.stdout.fileno(), dados)
                    return
        except OSError:
            pass
        time.sleep(min(segundos, 0.05))

    def terminou(self):
        try:
            return bool(os.waitpid(self.pid, os.WNOHANG)[0])
        except ChildProcessError:
            return True

    def encerrar(self):
        for sinal in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.kill(self.pid, sinal)
            except ProcessLookupError:
                break
            prazo = time.time() + 5
            while time.time() < prazo:
                if self.terminou():
                    os.close(self.fd)
                    return
                self.repassar(0.1)
        os.close(self.fd)
        prazo = time.time() + 5
        while time.time() < prazo and not self.terminou():
            time.sleep(0.1)

    def limite_no_transcript(self):
        sessao = self.sessao_atual()
        arquivos = glob.glob(os.path.join(self.dir_config(), "projects", "*", f"{sessao}.jsonl")) if sessao else []
        if not arquivos:
            return False
        try:
            with open(arquivos[0], "rb") as arquivo:
                arquivo.seek(0, os.SEEK_END)
                arquivo.seek(max(0, arquivo.tell() - 262144))
                linhas = arquivo.read().decode("utf-8", "ignore").splitlines()
        except OSError:
            return False
        for linha in reversed(linhas):
            try:
                entrada = json.loads(linha)
            except ValueError:
                continue
            if entrada.get("type") != "assistant":
                continue
            if not entrada.get("isApiErrorMessage") or entrada.get("error") != "rate_limit":
                return False
            quando = instante(entrada)
            return quando is None or quando >= self.lancado_em - 1
        return False

    def limite_confirmado(self):
        prazo = time.time() + 3
        while not self.limite_no_transcript():
            if time.time() >= prazo:
                return False
            self.repassar(0.3, sys.stdin.fileno())
        return True

    def rearmar_depois_de_falha(self):
        self.texto = ""
        self.armado_em = time.time() + REARMAR_SEM_TROCA

    def trocar(self, motivo):
        sessao = self.sessao_atual()
        if not sessao:
            log(self.config, "limite detectado, mas sem id de sessão; nada a fazer")
            self.rearmar_depois_de_falha()
            return
        try:
            processo = subprocess.Popen(
                [self.config["contas"], "_trocar", "--de", self.conta, "--motivo", motivo, "--sessao", sessao],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=os.environ,
            )
            prazo = time.time() + 30
            while processo.poll() is None and time.time() < prazo:
                self.repassar(0.1)
            if processo.poll() is None:
                processo.kill()
            escolha = json.loads(processo.communicate()[0] or "{}")
        except (OSError, subprocess.SubprocessError, ValueError) as erro:
            log(self.config, f"falha ao escolher outra conta: {erro}")
            escolha = {}
        if not escolha.get("para"):
            log(self.config, "nenhuma outra conta disponível; mantendo a sessão")
            self.rearmar_depois_de_falha()
            return
        self.encerrar()
        aviso = f"\r\n\x1b[33m[claude-auto] {self.conta} hit its limit; continuing on {escolha['para']}…\x1b[0m\r\n"
        os.write(sys.stdout.fileno(), aviso.encode())
        self.conta = escolha["para"]
        self.env = dict(self.env, CLAUDE_AUTO_CONTA=self.conta)
        if escolha.get("configDir"):
            self.env["CLAUDE_CONFIG_DIR"] = escolha["configDir"]
        else:
            self.env.pop("CLAUDE_CONFIG_DIR", None)
        self.sessao = sessao
        self.lancar(sem_prompt(sem_flags_de_sessao(self.args)) + ["--resume", sessao], armar_em=float("inf"))
        self.continuar_em = time.time()
        log(self.config, f"troca para {self.conta}, sessão {sessao}")

    def talvez_continuar(self, ultima_saida):
        if self.continuar_em is None:
            return
        agora = time.time()
        quieto = agora - ultima_saida > 1.5
        if (quieto and agora - self.continuar_em > 3) or agora - self.continuar_em > 15:
            os.write(self.fd, CONTINUAR.encode())
            time.sleep(0.3)
            os.write(self.fd, b"\r")
            self.continuar_em = None
            self.texto = ""
            self.armado_em = time.time() + 2

    def rodar(self):
        entrada = sys.stdin.fileno()
        saida = sys.stdout.fileno()
        original = termios.tcgetattr(entrada)
        signal.signal(signal.SIGWINCH, lambda *_: copiar_tamanho(self.fd))
        self.lancar(self.args, armar_em=0)
        ultima_saida = time.time()
        tty.setraw(entrada)
        try:
            while True:
                try:
                    prontos, _, _ = select.select([entrada, self.fd], [], [], 0.25)
                except InterruptedError:
                    continue
                if entrada in prontos:
                    dados = os.read(entrada, 4096)
                    if not dados:
                        break
                    os.write(self.fd, dados)
                if self.fd in prontos:
                    try:
                        dados = os.read(self.fd, 65536)
                    except OSError as erro:
                        if erro.errno != errno.EIO:
                            raise
                        dados = b""
                    if not dados:
                        break
                    os.write(saida, dados)
                    ultima_saida = time.time()
                    if time.time() >= self.armado_em:
                        self.texto = (self.texto + ANSI.sub(b"", dados).decode("utf-8", "ignore"))[-4000:]
                        if LIMITE.search(self.texto):
                            if self.limite_confirmado():
                                self.trocar("limite")
                            else:
                                log(self.config, "aviso de limite na tela sem erro de limite no transcript; ignorado")
                                self.texto = ""
                            ultima_saida = time.time()
                            continue
                self.talvez_continuar(ultima_saida)
        finally:
            termios.tcsetattr(entrada, termios.TCSAFLUSH, original)
        try:
            _, status = os.waitpid(self.pid, 0)
            return os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else (status >> 8)
        except ChildProcessError:
            return 0


if __name__ == "__main__":
    configuracao = json.loads(os.environ.pop("CLAUDE_AUTO_TUI", "{}"))
    sys.exit(Supervisor(configuracao).rodar())
