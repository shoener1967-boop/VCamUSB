"""USB-Tunnel: PC-Port 8767 -> iPhone-Port 8767."""
import asyncio
import sys
sys.path.insert(0, r"C:\Users\shosh\AppData\Local\hermes\hermes-agent\venv\Lib\site-packages")
from pymobiledevice3.tcp_forwarder import UsbmuxTcpForwarder

async def main():
    fwd = UsbmuxTcpForwarder(None, 8767, 8767)
    print("Tunnel aktiv: PC 8767 -> iPhone 8767")
    await fwd.start(address="127.0.0.1")

asyncio.run(main())
