"""VCamUSB connect — tunnelt den WebSocket-Server des iPhone-Tweaks direkt über
usbmuxd zum PC, ohne SSH/iproxy. Nutzt pymobiledevice3 (UsbmuxdConnect).

Usage:
    python usb_connect.py             # Tunnel 8767 -> iPhone 8767, dann Server starten
"""
import asyncio
import sys

from pymobiledevice3.usbmux import list_devices
from pymobiledevice3.services.usbmux import UsbmuxdConnect


async def tunnel(device_port: int, local_port: int = None):
    """Forward local_port -> device's 127.0.0.1:device_port over usbmuxd."""
    devices = await list_devices()
    if not devices:
        print("Kein Gerät am USB gefunden.")
        return
    dev = devices[0]
    print(f"Gerät: {dev.serial} ({dev.product_type})")

    local_port = local_port or device_port
    # UsbmuxdConnect fwd style: use pymobiledevice3 usbmux forward command-equivalent
    from pymobiledevice3.cli.usbmux import forward  # noqa
    raise SystemExit("Nutze: python -m pymobiledevice3 usbmux forward %d %d" % (local_port, device_port))


if __name__ == "__main__":
    asyncio.run(tunnel(int(sys.argv[1]) if len(sys.argv) > 1 else 8767))
