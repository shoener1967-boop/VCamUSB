"""Setzt/schreibt die Stufe von VCamInject über den Status-Port 8769.

Nutzung:
    python send_stage.py 0|1|2|3          # nur setzen
    python send_stage.py stat             # nur Status lesen
    python send_stage.py 3 --stat         # setzen und Status lesen

Verbindet per SSH direct-tcpip auf iPhone 127.0.0.1:8769 (mediaserverd).
"""
import sys
import time
import paramiko

HOST = "127.0.0.1"
SSH_PORT = 2222
USER = "root"
PASSWORD = "7789"


def read_status(cli, cmd=None):
    chan = cli.get_transport().open_channel(
        "direct-tcpip", ("127.0.0.1", 8769), ("127.0.0.1", 0), timeout=5)
    if cmd:
        chan.sendall(cmd.encode())
    time.sleep(1.5)
    data = b""
    while chan.recv_ready():
        data += chan.recv(65536)
    time.sleep(0.3)
    while chan.recv_ready():
        data += chan.recv(65536)
    chan.close()
    return data.decode(errors="replace")


def main():
    args = [a for a in sys.argv[1:] if a != "--stat"]
    want_stat = "--stat" in sys.argv

    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, SSH_PORT, username=USER, password=PASSWORD,
                look_for_keys=False, allow_agent=False, timeout=15)
    try:
        cmd = None
        if args:
            n = args[0]
            if n in ("0", "1", "2", "3"):
                cmd = f"stage={n}"
                print(f"Setze stage={n}")
            elif n == "stat":
                pass   # nur lesen
            else:
                print("Ungültige Stufe (0-3)")
                return
        out = read_status(cli, cmd)
        if want_stat or not args or args[0] == "stat":
            print(out)
    finally:
        cli.close()


if __name__ == "__main__":
    main()
