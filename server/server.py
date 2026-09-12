"""
VCamUSB Server — pushes H.264 camera frames over WebSocket to the iPhone tweak.

Sources: OBS Virtual Camera / any DirectShow device / a video file.
No auth, no license, no cloud. USB only: iPhone runs its own WS server, PC connects.

Usage:
    python server.py                     # OBS Virtual Camera by default
    python server.py --source file --video path.mp4
    python server.py --list-cameras      # list DirectShow devices
"""
import argparse, asyncio, json, logging, os, subprocess, sys, threading, time

try:
    import cv2
    HAVE_CV2 = True
except Exception:
    HAVE_CV2 = False

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("vcam")

DASHBOARD_PORT = 8080
DEFAULT_DEVICE = "OBS Virtual Camera"
WIDTH, HEIGHT, FPS = 1280, 720, 30


def list_cameras():
    """DirectShow camera list via ffmpeg."""
    try:
        out = subprocess.run(
            ["ffmpeg", "-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy"],
            capture_output=True, text=True, timeout=30,
        )
        cams = []
        for line in (out.stderr or "").splitlines():
            if '(video)' in line and '"' in line:
                cams.append(line.split('"')[1])
        return cams
    except Exception as e:
        log.error("ffmpeg camera list failed: %s", e)
        return []


def spawn_ffmpeg(device=None, video_path=None, ws_port=8767):
    """Spawn ffmpeg -> raw H.264 Annex B -> named pipe; return pipe path."""
    pipe = os.path.join(os.environ.get("TEMP", "/tmp"), f"vcam_{ws_port}.h264")
    try:
        os.unlink(pipe)
    except OSError:
        pass
    if video_path:
        args = [
            "ffmpeg", "-hide_banner", "-loglevel", "warning", "-stream_loop", "-1",
            "-re", "-i", video_path,
        ]
    else:
        src = device or DEFAULT_DEVICE
        # OBS Virtual Camera: skip explicit video_size/framerate — device drives format.
        if "obs" in src.lower():
            args = [
                "ffmpeg", "-hide_banner", "-loglevel", "warning",
                "-f", "dshow", "-rtbufsize", "64M", "-i", f"video={src}",
            ]
        else:
            args = [
                "ffmpeg", "-hide_banner", "-loglevel", "warning",
                "-f", "dshow", "-rtbufsize", "64M", "-framerate", str(FPS),
                "-video_size", f"{WIDTH}x{HEIGHT}", "-i", f"video={src}",
            ]
    args += [
        "-an", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-pix_fmt", "yuv420p", "-g", str(FPS * 2), "-b:v", "3M",
        "-f", "h264", "-flush_packets", "1", pipe,
    ]
    log.info("ffmpeg: %s", " ".join(args))
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    # wait for pipe OR early ffmpeg death
    for _ in range(150):
        if os.path.exists(pipe):
            return proc, pipe
        if proc.poll() is not None:
            err = proc.stderr.read() if proc.stderr else ""
            raise RuntimeError(f"ffmpeg exited early: {err[-300:]}")
        time.sleep(0.1)
    proc.terminate()
    raise RuntimeError("ffmpeg pipe did not appear")


class FramePusher:
    """Reads Annex B H.264 from pipe, sends binary frames to the iPhone WS server."""

    def __init__(self, device, video_path, ip, port):
        self.ip, self.port = ip, port
        self.proc, self.pipe = spawn_ffmpeg(device, video_path, port)
        self._closed = False

    async def run(self):
        from websockets.asyncio.client import connect
        while not self._closed:
            try:
                async with connect(f"ws://{self.ip}:{self.port}", max_size=16 * 1024 * 1024) as ws:
                    log.info("connected to %s:%s", self.ip, self.port)
                    await ws.send(json.dumps({"type": "hs", "v": 1}))
                    with open(self.pipe, "rb") as f:
                        while not self._closed:
                            # split Annex B units: 00 00 00 01 / 00 00 01
                            chunk = f.read(64 * 1024)
                            if not chunk:
                                await asyncio.sleep(0.05)
                                continue
                            # find unit boundaries; send each NAL unit as one WS message
                            start = 0
                            i = 0
                            n = len(chunk)
                            while i < n - 3:
                                if chunk[i] == 0 and chunk[i + 1] == 0:
                                    if chunk[i + 2] == 1:
                                        if start < i:
                                            await ws.send(chunk[start:i])
                                        start = i + 3
                                        i += 3
                                        continue
                                    elif i + 3 < n and chunk[i + 2] == 0 and chunk[i + 3] == 1:
                                        if start < i:
                                            await ws.send(chunk[start:i])
                                        start = i + 4
                                        i += 4
                                        continue
                                i += 1
                            if start < n:
                                await ws.send(chunk[start:n])
                            await asyncio.sleep(0.005)
            except Exception as e:
                if not self._closed:
                    log.warning("link down (%s), retrying in 2s", e)
                await asyncio.sleep(2)

    def close(self):
        self._closed = True
        try:
            self.proc.terminate()
        except Exception:
            pass


# --- minimal dashboard (no flask dep; stdlib only) ---
INDEX = """<!doctype html><html><head><meta charset=utf-8><title>VCamUSB</title>
<style>body{{font-family:system-ui;background:#0f1115;color:#e6e6e6;padding:24px}}
select,button,input{{font-size:16px;padding:8px 12px;border-radius:8px;border:1px solid #333;background:#1a1d24;color:#e6e6e6}}
button{{background:#2d7ff9;border:none;cursor:pointer}}#st{{margin-top:12px;color:#8ab4f8}}</style></head>
<body><h2>VCamUSB</h2>
<p>Quelle: <select id=src><option value=cam>OBS Virtual Camera / DirectShow</option><option value=file>Video-Datei</option></select></p>
<p id=filerow style=display:none>Datei: <input id=fpath size=48></p>
<p><button onclick=start()>Start</button> <button onclick=stop()>Stop</button> <span id=st></span></p>
<script>
async function q(p){let r=await fetch(p);return r.json()}
async function start(){let s=document.getElementById('src').value;
 let b=document.getElementById('fpath').value;
 let r=await q('/start?src='+s+'&file='+encodeURIComponent(b));
 document.getElementById('st').textContent=JSON.stringify(r)}
async function stop(){let r=await q('/stop');document.getElementById('st').textContent=JSON.stringify(r)}
document.getElementById('src').onchange=e=>document.getElementById('filerow').style.display=e.target.value=='file'?'block':'none'
</script></body></html>"""


class Dashboard:
    def __init__(self, server_state):
        self.state = server_state

    def handle(self, path):
        import urllib.parse
        u = urllib.parse.urlparse(path)
        if u.path == "/":
            return 200, "text/html", INDEX
        if u.path == "/start":
            q = urllib.parse.parse_qs(u.query)
            src = (q.get("src") or ["cam"])[0]
            file = (q.get("file") or [""])[0]
            self.state["want"] = ("file", file) if src == "file" and file else ("cam", None)
            return 200, "application/json", json.dumps({"ok": True, "src": src})
        if u.path == "/stop":
            self.state["want"] = None
            return 200, "application/json", json.dumps({"ok": True, "stopped": True})
        return 404, "text/plain", "not found"


async def dashboard_server(state):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    dash = Dashboard(state)

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            code, ctype, body = dash.handle(self.path)
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.end_headers()
            self.wfile.write(body.encode())

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", DASHBOARD_PORT), H)
    await asyncio.to_thread(srv.serve_forever)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", choices=["cam", "file"], default="cam")
    ap.add_argument("--video", default="")
    ap.add_argument("--device", default="")
    ap.add_argument("--ip", default="127.0.0.1", help="iPhone reachable address")
    ap.add_argument("--port", type=int, default=8767)
    ap.add_argument("--list-cameras", action="store_true")
    a = ap.parse_args()

    if a.list_cameras:
        for c in list_cameras():
            print(c)
        return

    state = {"want": ("file", a.video) if a.source == "file" else ("cam", a.device or DEFAULT_DEVICE)}
    asyncio.create_task(dashboard_server(state))
    log.info("Dashboard: http://localhost:%d   (target ws://%s:%d)", DASHBOARD_PORT, a.ip, a.port)

    pusher = None
    while True:
        want = state.get("want")
        if want and (pusher is None or pusher.sel != want):
            if pusher:
                pusher.close()
            src, payload = want
            device, video = (payload, None) if src == "cam" else (None, payload)
            try:
                pusher = FramePusher(device, video, a.ip, a.port)
                pusher.sel = want
                asyncio.create_task(pusher.run())
                log.info("pushing source=%s payload=%s", src, payload)
            except Exception as e:
                log.error("start failed: %s", e)
                state["want"] = None
        elif not want and pusher:
            pusher.close()
            pusher = None
        await asyncio.sleep(1)


if __name__ == "__main__":
    asyncio.run(main())
