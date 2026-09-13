"""Check Mach-O code signature on device via SSH."""
import paramiko
import time
import socket

def port_open():
    s = socket.socket(); s.settimeout(1)
    try:
        s.connect(('127.0.0.1', 2222)); s.close(); return True
    except Exception:
        return False

for _ in range(20):
    if port_open():
        break
    time.sleep(1)

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect('127.0.0.1', 2222, username='root', password='7789',
            look_for_keys=False, allow_agent=False, timeout=10)

def run(cmd, t=120):
    _, out, err = cli.exec_command(cmd, timeout=t)
    return (out.read() + err.read()).decode(errors='replace')

script = r'''
import struct
for name in ["/var/jb/usr/lib/TweakInject/VCamHub.dylib", "/var/jb/usr/lib/TweakInject/AVServicesd.dylib"]:
    f = open(name, "rb").read()
    magic_be = struct.unpack(">I", f[:4])[0]
    out = [name]
    if magic_be in (0xcafebabe, 0xbebafeca, 0xcafebabf):
        out.append("FAT")
        n = struct.unpack(">I", f[4:8])[0]
        off = size = None
        for i in range(n):
            cpu, sub, o, s, a = struct.unpack(">IIIII", f[8+i*20:28+i*20])
            if cpu in (0x0100000c, 0x01000017):
                off, size = o, s
                break
        if off:
            f = f[off:off+size]
    magic = struct.unpack("<I", f[:4])[0]
    out.append("magic=" + hex(magic))
    ncmds = struct.unpack("<I", f[16:20])[0]
    o = 32
    cmds = []
    for _ in range(ncmds):
        cmd, sz = struct.unpack("<II", f[o:o+8])
        cmds.append(cmd)
        o += sz
    out.append("cmds=" + ",".join(hex(c) for c in cmds))
    out.append("CODE_SIGNATURE=" + str(0x1D in cmds))
    print(" | ".join(out))
'''

print(run(f'/var/jb/usr/bin/python3 -c {repr(script)}'))
# Fallback: python3 nicht vorhanden? Filza hat internen python? -> per dd+xxd?
print(run('which python3 python 2>&1; ls /var/jb/usr/bin/ | grep -i py'))
cli.close()
