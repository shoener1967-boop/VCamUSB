"""Installiert VCamInject .deb auf dem iPhone via SSH-over-usbmuxd.
Deinstalliert vorher VCamUSB (alt) und startet mediaserverd + SpringBoard neu.
"""
import socket, subprocess, sys, time

DEB = r"C:\Users\shosh\VCamUSB\com.shosh.vcamusb_0.1.0_iphoneos-arm64e.deb"
PORT = 2222


def port_open():
    s = socket.socket()
    s.settimeout(1)
    try:
        s.connect(("127.0.0.1", PORT))
        s.close()
        return True
    except Exception:
        return False


def main():
    fwd = None
    if not port_open():
        print("[install] kein SSH auf :2222 — starte usbmuxd-Forwarder...")
        fwd = subprocess.Popen(
            [sys.executable, "-m", "pymobiledevice3", "usbmux", "forward",
             str(PORT), "22"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(30):
            if port_open():
                break
            time.sleep(0.5)
    if not port_open():
        print("[install] FEHLER: kein SSH auf :2222 erreichbar.")
        return

    import paramiko
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    print("[install] verbinde zu root@127.0.0.1:%d ..." % PORT)
    cli.connect("127.0.0.1", PORT, username="root", password="7789",
                look_for_keys=False, allow_agent=False, timeout=10)

    sftp = cli.open_sftp()
    remote = "/var/tmp/com.shosh.vcamusb.deb"
    print("[install] lade .deb hoch...")
    sftp.put(DEB, remote)
    sftp.close()

    def run(cmd, timeout=60):
        stdin, stdout, stderr = cli.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode(errors="replace")
        err = stderr.read().decode(errors="replace")
        return out + err

    # alte Version entfernen (Package-Name bleibt com.shosh.vcamusb)
    print("[install] entferne alte Version...")
    print(run("/var/jb/usr/bin/dpkg -r com.shosh.vcamusb 2>/dev/null; echo done"))
    print("[install] dpkg -i ...")
    print(run("/var/jb/usr/bin/dpkg -i " + remote))
    print("[install] Dateien:")
    print(run("ls -la /var/jb/Library/MobileSubstrate/DynamicLibraries/ | grep -i vcam"))
    # KRITISCH: die .roothidepatch-Symlinks ENTFERNEN! (PatchLoader würde sonst
    # AutoPatches.dylib statt unserer Dylib laden!)
    print("[install] entferne falsche .roothidepatch-Symlinks...")
    print(run("rm -f /var/jb/Library/MobileSubstrate/DynamicLibraries/VCamHub.dylib.roothidepatch "
              "/var/jb/Library/MobileSubstrate/DynamicLibraries/VCamInject.dylib.roothidepatch "
              "/var/jb/usr/lib/TweakInject/VCamHub.dylib.roothidepatch "
              "/var/jb/usr/lib/TweakInject/VCamInject.dylib.roothidepatch && echo links-weg"))
    # Owner wie LordVCAM: mobile:staff + .sig-Dateien
    print("[install] Owner + .sig-Dateien (LordVCAM-Schema)...")
    print(run("chown mobile:staff /var/jb/usr/lib/TweakInject/VCamHub.dylib "
              "/var/jb/usr/lib/TweakInject/VCamInject.dylib && "
              "echo -n 'aHRqdGNjbw==' > /var/jb/usr/lib/TweakInject/VCamHub.dylib.sig && "
              "echo -n 'aHRqdGNjbw==' > /var/jb/usr/lib/TweakInject/VCamInject.dylib.sig && echo sig-ok"))
    # mediaserverd neu starten (nicht nur SpringBoard!)
    print("[install] starte mediaserverd neu...")
    print(run("/var/jb/usr/bin/killall -9 mediaserverd 2>/dev/null; sleep 1; echo msd-ok"))
    print("[install] respring SpringBoard...")
    print(run("/var/jb/usr/bin/killall -9 SpringBoard 2>/dev/null; echo respring-ok"))
    cli.close()
    print("[install] FERTIG")
    if fwd:
        fwd.terminate()


if __name__ == "__main__":
    main()
