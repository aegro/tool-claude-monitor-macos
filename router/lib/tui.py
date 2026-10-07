import errno
import fcntl
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

LIMITE = re.compile(
    r"hit your (?:\w+ )?limit|usage limit reached|limit will reset|weekly limit reached|session limit reached",
    re.IGNORECASE,
)
ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")
FLAGS_COM_VALOR = {"--resume", "-r", "--session-id", "--resume-session-at"}
FLAGS_SEM_VALOR = {"--continue", "-c", "--fork-session"}
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
        copiar_tamanho(fd)
        self.texto = ""
        self.armado_em = time.time() + armar_em

    def trocar(self, motivo):
        sessao = self.sessao_atual()
        if not sessao:
            log(self.config, "limite detectado, mas sem id de sessão; nada a fazer")
            self.armado_em = float("inf")
            return
        try:
            saida = subprocess.run(
                [self.config["contas"], "_trocar", "--de", self.conta, "--motivo", motivo, "--sessao", sessao],
                capture_output=True, text=True, timeout=30, env=os.environ,
            ).stdout
            escolha = json.loads(saida or "{}")
        except (subprocess.SubprocessError, ValueError) as erro:
            log(self.config, f"falha ao escolher outra conta: {erro}")
            escolha = {}
        if not escolha.get("para"):
            log(self.config, "nenhuma outra conta disponível; mantendo a sessão")
            self.armado_em = float("inf")
            return
        try:
            os.kill(self.pid, signal.SIGTERM)
            for _ in range(50):
                if os.waitpid(self.pid, os.WNOHANG)[0]:
                    break
                time.sleep(0.1)
            else:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass
        os.close(self.fd)
        aviso = f"\r\n\x1b[33m[claude-auto] {self.conta} hit its limit; continuing on {escolha['para']}…\x1b[0m\r\n"
        os.write(sys.stdout.fileno(), aviso.encode())
        self.conta = escolha["para"]
        self.env = dict(self.env, CLAUDE_AUTO_CONTA=self.conta)
        if escolha.get("configDir"):
            self.env["CLAUDE_CONFIG_DIR"] = escolha["configDir"]
        else:
            self.env.pop("CLAUDE_CONFIG_DIR", None)
        self.sessao = sessao
        self.lancar(sem_flags_de_sessao(self.args) + ["--resume", sessao], armar_em=float("inf"))
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
                            time.sleep(0.5)
                            self.trocar("limite")
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
