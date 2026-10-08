import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


def ler(fd, segundos, quieto=None):
    recebido = False
    fim = time.time() + segundos
    ultima = time.time()
    while time.time() < fim:
        prontos, _, _ = select.select([fd], [], [], 0.2)
        if fd in prontos:
            try:
                dados = os.read(fd, 65536)
            except OSError:
                return recebido
            if not dados:
                return recebido
            recebido = True
            ultima = time.time()
        elif quieto and recebido and time.time() - ultima > quieto:
            return recebido
    return recebido


def main():
    bin_, agente, mensagem = sys.argv[1:4]
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(bin_, [bin_, "attach", agente], dict(os.environ, TERM="xterm-256color"))
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    abriu = ler(fd, 10, quieto=1.5)
    if abriu:
        os.write(fd, mensagem.encode())
        ler(fd, 0.8)
        os.write(fd, b"\r")
        ler(fd, 3)
        os.write(fd, b"\x1a")
        ler(fd, 1)
    try:
        os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)
    except (ProcessLookupError, ChildProcessError):
        pass
    sys.exit(0 if abriu else 1)


if __name__ == "__main__":
    main()
