"""Sendet eine Modus-Textnachricht an VCamInject via Hub-Broadcast."""
import asyncio
import sys
import json
import struct
import socket

MODE = sys.argv[1] if len(sys.argv) > 1 else "mode:normal"

async def main():
    # Einfacher WS-Client ohne externes lib (rohes WebSocket-Handshake + Frame)
    import os
    key = os.urandom(16)
    import base64
    b64key = base64.b64encode(key).decode()

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(('127.0.0.1', 8767))
    req = (f"GET / HTTP/1.1\r\nHost: 127.0.0.1:8767\r\n"
           f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {b64key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    s.sendall(req.encode())
    resp = s.recv(2048)
    if b"101" not in resp:
        print("Handshake failed:", resp[:100])
        return

    # Text-Frame senden (opcode 0x1, masked)
    payload = MODE.encode()
    mask = os.urandom(4)
    hdr = bytes([0x81])
    n = len(payload)
    if n < 126:
        hdr += bytes([0x80 | n])
    else:
        hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
    masked = bytes([b ^ mask[i % 4] for i, b in enumerate(payload)])
    s.sendall(hdr + mask + masked)
    print(f"Gesendet: {MODE}")
    s.close()

asyncio.run(main())
