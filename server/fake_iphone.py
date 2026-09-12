"""Fake iPhone receiver: runs the WS server the tweak will run, counts H.264 frames."""
import asyncio, json, sys

from websockets.asyncio.server import serve

frames = 0
total_bytes = 0
first = None
last = None


async def handler(ws):
    global frames, total_bytes, first, last
    hs = await ws.recv()
    print("handshake:", hs)
    async for msg in ws:
        if isinstance(msg, str):
            continue
        if first is None:
            first = msg[:8].hex()
        last = msg[:8].hex()
        frames += 1
        total_bytes += len(msg)


async def main(port):
    async with serve(handler, "127.0.0.1", port):
        await asyncio.sleep(1)
        print(f"fake-iphone listening on {port}")
        for i in range(10):
            await asyncio.sleep(1)
            print(f"t={i + 1}s frames={frames} bytes={total_bytes}")


if __name__ == "__main__":
    asyncio.run(main(int(sys.argv[1]) if len(sys.argv) > 1 else 8767))
