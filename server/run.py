"""VCamUSB — startet alles in einem: USB-Tunnel (usbmuxd) + Streaming-Server.

Kein SSH, kein iproxy. Der Tunnel nutzt usbmuxd direkt (UsbmuxTcpForwarder).

Usage:
    python run.py                          # Tunnel + Server + Dashboard
    python run.py --no-tunnel              # Server ohne Tunnel (Gerät via WLAN)
    python run.py --tunnel-only            # Nur den Tunnel starten (Debug)
"""
import argparse
import asyncio
import subprocess
import sys


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-tunnel", action="store_true")
    ap.add_argument("--tunnel-only", action="store_true")
    ap.add_argument("--port", type=int, default=8767)
    a = ap.parse_args()

    from pymobiledevice3.tcp_forwarder import UsbmuxTcpForwarder
    from pymobiledevice3.usbmux import list_devices

    devices = await list_devices()
    if not devices:
        print("[run] Kein Gerät am USB gefunden. (WLAN-Modus: --no-tunnel)")
        if not a.no_tunnel and not a.tunnel_only:
            print("[run] Trotzdem Server starten? Nein — Abbruch.")
            return
        if a.no_tunnel:
            pass
        else:
            return
    else:
        dev = devices[0]
        print(f"[run] Gerät: {dev.serial} (connection: {dev.connection_type})")

    forwarder = None
    if not a.no_tunnel and devices:
        # UsbmuxTcpForwarder(serial, dst_port_on_device, src_port_local)
        forwarder = UsbmuxTcpForwarder(dev.serial, a.port, a.port)
        await forwarder.start()
        print(f"[run] USB-Tunnel aktiv: localhost:{a.port} -> Gerät:{a.port}")

    if a.tunnel_only:
        print("[run] Tunnel läuft. STRG+C zum Beenden.")
        try:
            await asyncio.Future()
        except KeyboardInterrupt:
            pass
        return

    srv_cmd = [sys.executable, "server.py", "--source", "cam",
               "--ip", "127.0.0.1", "--port", str(a.port)]
    print(f"[run] Starte Server: {' '.join(srv_cmd)}")
    proc = subprocess.Popen(srv_cmd, cwd=".")
    print("[run] Dashboard: http://localhost:8080")

    try:
        while True:
            await asyncio.sleep(1)
            if proc.poll() is not None:
                print("[run] Server beendet.")
                break
    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()
        if forwarder:
            forwarder.stop()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
