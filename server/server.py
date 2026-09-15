"""
VCamUSB Server — LordVCAM-style: full compositing pipeline on the PC.

  Source (OBS Virtual Camera / DirectShow / uploaded file / image)
      -> transform (zoom/pan/rotate/mirror/bg-color)
      -> filters (brightness/contrast/saturation/gamma)
      -> H.264 encode
      -> WebSocket -> iPhone tweak (127.0.0.1:8767 via USB tunnel)

Dashboard: http://localhost:8080  (drag to pan, wheel to zoom, rotate/mirror,
eyedropper bg color, filters, video playback controls, file upload)

HTTP API:
  GET  /                    dashboard
  GET  /api/stats           {connected,running,fps,mb_sent,uptime,source,encode}
  GET  /api/cameras         DirectShow device list
  GET  /api/logs            last log lines
  GET  /api/network         local IPs
  GET  /preview.jpg         live composited preview
  POST /api/control         JSON, LordVCAM-style message types:
        {type:'set_source', source_type:'local'|'file', camera_id|video_path}
        {type:'clear_source'}
        {type:'transform', zoom, panX, panY, flipH, rotation}
        {type:'bg_color', r, g, b}
        {type:'filters', brightness, contrast, saturation, gamma}
        {type:'playback', action:'play'|'pause'|'stop'|'seek'|'speed'|'loop', ...}
        {type:'fps', fps:30|60}
  POST /api/upload          multipart file upload
"""
import argparse
import asyncio
import json
import logging
import os
import re
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import cv2
import numpy as np

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("vcam")

DASHBOARD_PORT = 8080
DEFAULT_DEVICE = "OBS Virtual Camera"
WIDTH, HEIGHT = 1920, 1080
DEFAULT_FPS = 30
DASH_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboard.html")
UPLOAD_DIR = os.path.join(os.environ.get("TEMP", "/tmp"), "vcamusb_uploads")


# ---------------------------------------------------------------- Log buffer
class LogBuf:
    def __init__(self, n=60):
        self.n = n
        self.lines = []

    def add(self, level, text):
        self.lines.append({
            "time": time.strftime("%H:%M:%S"),
            "level": level,
            "text": text,
        })
        del self.lines[:-self.n]

    def get(self):
        return list(self.lines)


# ---------------------------------------------------------------- Camera list
def list_cameras():
    """DirectShow camera list via ffmpeg."""
    try:
        out = subprocess.run(
            ["ffmpeg", "-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy"],
            capture_output=True, text=True, timeout=30,
        )
        cams = []
        for line in (out.stderr or "").splitlines():
            if "(video)" in line and '"' in line:
                cams.append(line.split('"')[1])
        return cams
    except Exception as e:
        log.error("ffmpeg camera list failed: %s", e)
        return []


def local_ips():
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.append({"name": "WiFi/Ethernet", "ip": s.getsockname()[0]})
        s.close()
    except Exception:
        pass
    return ips


# ---------------------------------------------------------------- Transform + Filters
def apply_filters(frame, flt):
    """brightness in [-1,1] as offset multiplier, contrast/saturation/gamma around 1."""
    b = flt.get("brightness", 0.0)
    c = flt.get("contrast", 1.0)
    s = flt.get("saturation", 1.0)
    g = flt.get("gamma", 1.0)
    if abs(b) > 0.001:
        # brightness: scale pixel values (multiplicative like LordVCAM CSS mapping)
        frame = cv2.convertScaleAbs(frame, alpha=1.0 + b, beta=0)
    if abs(c - 1.0) > 0.001:
        frame = cv2.convertScaleAbs(frame, alpha=c, beta=128.0 * (1.0 - c))
    if abs(s - 1.0) > 0.001:
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV).astype(np.float32)
        hsv[:, :, 1] = np.clip(hsv[:, :, 1] * s, 0, 255)
        frame = cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2BGR)
    if abs(g - 1.0) > 0.001:
        inv = 1.0 / max(0.05, g)
        lut = np.array([np.clip((i / 255.0) ** inv, 0, 1) * 255
                        for i in range(256)], dtype=np.uint8)
        frame = cv2.LUT(frame, lut)
    return frame


def compose_frame(src, W, H, tr):
    """OBS-style compositing: bg canvas + movable/rotatable/flippable layer.
    Same math as LordVCAM (video_capture _capture_loop + dashboard drawFrame)."""
    zoom = tr.get("zoom", 1.0)
    pan_x = tr.get("pan_x", 0.0)
    pan_y = tr.get("pan_y", 0.0)
    flip_h = tr.get("flip_h", False)
    rotation = tr.get("rotation", 0)
    bg = tr.get("bg_color", [0, 0, 0])

    sw, sh = src.shape[1], src.shape[0]

    if flip_h:
        src = cv2.flip(src, 1)

    if rotation == 90:
        src = cv2.rotate(src, cv2.ROTATE_90_CLOCKWISE)
    elif rotation == 180:
        src = cv2.rotate(src, cv2.ROTATE_180)
    elif rotation == 270:
        src = cv2.rotate(src, cv2.ROTATE_90_COUNTERCLOCKWISE)

    ew, eh = src.shape[1], src.shape[0]  # effective dims after rotation
    base_scale = min(W / ew, H / eh)
    scale = base_scale * zoom
    rw, rh = int(ew * scale), int(eh * scale)
    if rw < 2 or rh < 2:
        rw, rh = 2, 2
    resized = cv2.resize(src, (rw, rh), interpolation=cv2.INTER_LINEAR)

    pos_x = int((W - rw) / 2 + pan_x * (W / 2))
    pos_y = int((H - rh) / 2 + pan_y * (H / 2))

    canvas = np.zeros((H, W, 3), dtype=np.uint8)
    canvas[:, :] = (bg[2], bg[1], bg[0])  # BGR

    # clamped paste
    x0, y0 = pos_x, pos_y
    sx0, sy0 = 0, 0
    sx1, sy1 = rw, rh
    if x0 < 0:
        sx0 = -x0
        x0 = 0
    if y0 < 0:
        sy0 = -y0
        y0 = 0
    if x0 + (sx1 - sx0) > W:
        sx1 -= (x0 + (sx1 - sx0)) - W
    if y0 + (sy1 - sy0) > H:
        sy1 -= (y0 + (sy1 - sy0)) - H
    if sx1 > sx0 and sy1 > sy0:
        canvas[y0:y0 + (sy1 - sy0), x0:x0 + (sx1 - sx0)] = resized[sy0:sy1, sx0:sx1]
    return canvas


# ---------------------------------------------------------------- Source reader
class SourceReader:
    """cv2-based: camera (DSHOW) or file/image. Loop + speed + seek handled here."""

    def __init__(self, state):
        self.state = state
        self.cap = None
        self.image_frame = None
        self.last_read = 0.0
        self.paused = False
        self._lock = threading.Lock()

    def open(self, src_type, payload):
        with self._lock:
            self.close()
            self.paused = False
            if src_type == "cam":
                idx = int(payload)
                # Robust: wenn der angeforderte Index nicht lesbar ist,
                # alle Indizes 0..7 scannen und den ersten nutzbaren nehmen.
                candidates = [idx] + [i for i in range(8) if i != idx]
                opened = False
                for i in candidates:
                    cap = cv2.VideoCapture(i, cv2.CAP_DSHOW)
                    if not cap.isOpened():
                        cap.release()
                        continue
                    ok, frame = cap.read()
                    if ok and frame is not None:
                        self.cap = cap
                        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, WIDTH)
                        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, HEIGHT)
                        opened = True
                        break
                    cap.release()
                if not opened:
                    raise RuntimeError(f"camera {payload} not openable")
            else:
                if re.search(r"\.(jpg|jpeg|png|bmp|webp|tiff|heic)$", payload, re.I):
                    self.image_frame = cv2.imread(payload)
                    if self.image_frame is None:
                        raise RuntimeError("image decode failed")
                else:
                    self.cap = cv2.VideoCapture(payload)
                    if not self.cap.isOpened():
                        raise RuntimeError("video open failed")

    def close(self):
        if self.cap:
            self.cap.release()
            self.cap = None
        self.image_frame = None

    def read_frame(self):
        """Returns frame or None (paused/ended). Throttles to fps*speed."""
        with self._lock:
            st = self.state
            speed = st["playback"].get("speed", 1.0)
            fps = st.get("fps", DEFAULT_FPS)
            interval = 1.0 / max(1, fps)
            if speed > 0:
                interval /= speed
            now = time.monotonic()
            if now - self.last_read < interval * 0.9:
                return "__throttle__"
            self.last_read = now

            if self.image_frame is not None:
                return self.image_frame.copy()
            if not self.cap:
                return None

            if st["playback"].get("action") == "pause" or self.paused:
                return "__pause__"

            ok, frame = self.cap.read()
            if not ok or frame is None:
                # seek handling
                if st["playback"].get("seek_frame") is not None:
                    self.cap.set(cv2.CAP_PROP_POS_FRAMES, st["playback"]["seek_frame"])
                    st["playback"]["seek_frame"] = None
                    return "__throttle__"
                if st["playback"].get("loop", True):
                    self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                    return "__throttle__"
                self.paused = True
                return "__pause__"
            return frame


# ---------------------------------------------------------------- Encoder (rawvideo -> h264 pipe)
class Encoder:
    def __init__(self, fps):
        self.fps = fps
        # Generation-ID: JEDE Encoder-Instanz bekommt eine eigene Pipe.
        # So liest der Pusher nie in eine alte/stale Pipe hinein.
        self.gen = int(time.time() * 1000) % 100000
        self.pipe = os.path.join(os.environ.get("TEMP", "/tmp"), f"vcam_out_{self.gen}.h264")
        self.fflog_path = os.path.join(os.environ.get("TEMP", "/tmp"), "vcam_ffmpeg.log")
        self._start()

    def _start(self):
        try:
            os.unlink(self.pipe)
        except OSError:
            pass
        # ffmpeg stderr in Datei loggen (Diagnose!), Fenster unterdrücken
        creationflags = 0x08000000 if os.name == "nt" else 0  # CREATE_NO_WINDOW
        try:
            self.fflog = open(self.fflog_path, "ab")
        except OSError:
            self.fflog = None
        self.proc = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "warning",
             "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{WIDTH}x{HEIGHT}",
             "-r", str(self.fps), "-i", "-",
             "-an", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
             "-pix_fmt", "yuv420p", "-g", str(self.fps * 2), "-b:v", "3M",
             "-x264-params", "aud=1:bframes=0:keyint=30:min-keyint=30:scenecut=0",
             "-color_range", "pc",
             "-f", "h264", "-flush_packets", "1", self.pipe],
            stdin=subprocess.PIPE,
            stderr=self.fflog if self.fflog is not None else subprocess.DEVNULL,
            creationflags=creationflags)

    def send(self, frame):
        # Selbstheilung: ist ffmpeg gestorben, sofort neu starten.
        if self.proc.poll() is not None:
            log.warning("ffmpeg gestorben (rc=%s) — Neustart", self.proc.returncode)
            self._start()
            return
        try:
            self.proc.stdin.write(frame.tobytes())
        except Exception as e:
            log.error("encoder write fehlgeschlagen: %s", e)
            self._start()

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(timeout=3)
        except Exception:
            self.proc.kill()
        if self.fflog:
            try:
                self.fflog.close()
            except Exception:
                pass


# ---------------------------------------------------------------- Render thread
class Pipeline:
    """Owns source reader + encoder + latest preview JPEG."""

    def __init__(self, state, logbuf):
        self.state = state
        self.logbuf = logbuf
        self.reader = SourceReader(state)
        self.encoder = None
        self.latest_jpg = b""
        self._jpg_lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = None
        self.cur_src = None
        self.cur_fps = DEFAULT_FPS

    def start(self):
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=2)
        self.close()

    def close(self):
        self.reader.close()
        if self.encoder:
            self.encoder.close()
            self.encoder = None

    def _sync(self):
        """(Re)open source/encoder when state changed."""
        want = self.state.get("want")
        if want != self.cur_src:
            self.reader.close()
            src_type, payload = want
            try:
                self.reader.open(src_type, payload)
                self.cur_src = want
                self.state["src_error"] = None
                self.logbuf.add("debug", f"source opened: {src_type} {payload}")
            except Exception as e:
                self.state["src_error"] = str(e)
                self.cur_src = None
                self.logbuf.add("error", f"source failed: {e}")
                self.state["want"] = None
                return
        if self.state.get("fps", DEFAULT_FPS) != self.cur_fps:
            self.cur_fps = self.state["fps"]
            if self.encoder:
                self.encoder.close()
            self.encoder = Encoder(self.cur_fps)

    def _loop(self):
        while not self._stop.is_set():
            want = self.state.get("want")
            if not want:
                time.sleep(0.1)
                continue
            self._sync()
            if not self.encoder:
                self.encoder = Encoder(self.cur_fps)
            frame = self.reader.read_frame()
            if frame is None:
                time.sleep(0.05)
                continue
            if isinstance(frame, str):
                continue
            out = compose_frame(frame, WIDTH, HEIGHT, self.state["transform"])
            out = apply_filters(out, self.state["filters"])
            self.encoder.send(out)
            # preview JPEG (höhere Auflösung + Qualität fürs Dashboard)
            try:
                small = cv2.resize(out, (960, int(960 * HEIGHT / WIDTH)),
                                   interpolation=cv2.INTER_AREA)
                ok, jpg = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 85])
                if ok:
                    with self._jpg_lock:
                        self.latest_jpg = jpg.tobytes()
            except Exception:
                pass

    def preview(self):
        with self._jpg_lock:
            return self.latest_jpg


# ---------------------------------------------------------------- WS pusher (h264 pipe -> iPhone)
class FramePusher:
    def __init__(self, pipe, ip, port, state):
        self.pipe, self.ip, self.port = pipe, ip, port
        self.state = state
        self._closed = False

    async def run(self):
        from websockets.asyncio.client import connect
        import struct as _struct
        # Diagnose counters for the USB/WebSocket leg.
        self.state.setdefault("ws_messages", 0)
        self.state.setdefault("ws_bytes", 0)
        self.state.setdefault("au_sent", 0)
        self.state.setdefault("nal_sent", 0)

        async def send_binary(ws, payload):
            if not payload:
                return
            await ws.send(payload)
            self.state["ws_messages"] += 1
            self.state["ws_bytes"] += len(payload)
            self.state["bytes_sent"] += len(payload)

        while not self._closed:
            try:
                async with connect(f"ws://{self.ip}:{self.port}",
                                   max_size=16 * 1024 * 1024,
                                   ping_interval=None, ping_timeout=None) as ws:
                    self.state["connected"] = True
                    log.info("connected to %s:%s", self.ip, self.port)
                    await ws.send(json.dumps({"type": "hs", "v": 1}))
                    # wait for pipe (dynamisch aus dem Resolver)
                    def current_pipe():
                        return getattr(self, "pipe_resolver", None) and \
                               self.pipe_resolver.get() or self.pipe
                    while (not current_pipe() or
                           not os.path.exists(current_pipe())) and not self._closed:
                        await asyncio.sleep(0.1)

                    # Persistenter Annex-B-Puffer + AU-Zusammenbau.
                    # libx264 mit aud=1: vor jedem Frame ein AUD-NAL (Typ 9).
                    # Wir gruppieren NALs zu Access Units und senden:
                    #   - SPS/PPS als eigene Message (roh, erstes Byte 0x67/0x68)
                    #   - jede AU als AVCC-Message ([4-byte len][NAL]...)
                    buf = b""
                    cur_au = []          # gesammelte VCL/SEI-NALs der aktuellen AU
                    sent_sps_pps = False

                    def parse_nals(data):
                        """Liefert Liste von rohen NAL-Bytes (ohne Startcode)."""
                        nals = []
                        i = 0
                        n = len(data)
                        start = 0
                        # Finde Startcodes
                        positions = []
                        while i < n - 2:
                            if data[i] == 0 and data[i+1] == 0:
                                if data[i+2] == 1:
                                    positions.append((i, 3))
                                    i += 3
                                    continue
                                elif i+3 < n and data[i+2] == 0 and data[i+3] == 1:
                                    positions.append((i, 4))
                                    i += 4
                                    continue
                            i += 1
                        for idx in range(len(positions)):
                            sc_pos, sc_len = positions[idx]
                            end = positions[idx+1][0] if idx+1 < len(positions) else n
                            nal = data[sc_pos + sc_len:end]
                            if nal:
                                nals.append(nal)
                        return nals

                    def nal_type(nal):
                        return nal[0] & 0x1f if nal else 0

                    async def flush_au(ws):
                        nonlocal cur_au, sent_sps_pps
                        if not cur_au:
                            return
                        # AVCC: [4-byte BE length][NAL]... für alle NALs der AU
                        avcc = b""
                        for nal in cur_au:
                            avcc += _struct.pack(">I", len(nal)) + nal
                        cur_au = []
                        if avcc:
                            await send_binary(ws, avcc)
                            self.state["au_sent"] += 1
                            self.state["frames_sent"] += 1
                            return

                    # Pipe-Leser: liest die AKTUELLE Generations-Pipe.
                    # Wechselt der Encoder die Pipe (Neustart), wird die neue
                    # Pipe ab Anfang gelesen. Keine stale-Pipe-Reste mehr.
                    import os as _os
                    import msvcrt as _msvcrt
                    f = None
                    read_pos = 0
                    cur_gen = None
                    while not self._closed:
                        # Aktuelle Pipe ermitteln (ändert sich bei Encoder-Restart)
                        pipe_now = current_pipe()
                        if pipe_now != cur_gen:
                            # Neue Generation: alles zurücksetzen
                            if f is not None:
                                try:
                                    f.close()
                                except Exception:
                                    pass
                            f = None
                            read_pos = 0
                            cur_gen = pipe_now
                        if not pipe_now or not _os.path.exists(pipe_now):
                            await asyncio.sleep(0.05)
                            continue
                        # Datei-Handle aktuell halten (Reopen bei Trunkierung)
                        try:
                            cur_size = _os.path.getsize(pipe_now)
                        except OSError:
                            cur_size = -1
                        if f is None or (cur_size >= 0 and read_pos > cur_size):
                            if f is not None:
                                try:
                                    f.close()
                                except Exception:
                                    pass
                            f = None
                            read_pos = 0
                        if f is None:
                            try:
                                f = open(pipe_now, "rb")
                                _msvcrt.setmode(f.fileno(), _os.O_BINARY)
                                f.seek(read_pos)
                            except Exception:
                                f = None
                                await asyncio.sleep(0.05)
                                continue
                        try:
                            chunk = f.read(64 * 1024)
                        except Exception:
                            await asyncio.sleep(0.02)
                            continue
                        if not chunk:
                            await asyncio.sleep(0.02)
                            continue
                        read_pos += len(chunk)
                        buf += chunk
                        # Startcode-Positionen finden
                        positions = []
                        i = 0
                        n = len(buf)
                        while i < n - 2:
                            if buf[i] == 0 and buf[i+1] == 0:
                                if buf[i+2] == 1:
                                    positions.append((i, 3))
                                    i += 3
                                    continue
                                elif i+3 < n and buf[i+2] == 0 and buf[i+3] == 1:
                                    positions.append((i, 4))
                                    i += 4
                                    continue
                            i += 1
                        if not positions:
                            if len(buf) > 1_000_000:
                                buf = b""
                            continue
                        # Verarbeite alle vollständigen NALs (alle bis auf die letzte)
                        # Die letzte könnte unvollständig sein -> im Puffer lassen
                        last_start = positions[-1][0]
                        complete = buf[:last_start]
                        buf = buf[last_start:]   # Rest ab letztem Startcode behalten
                        # NALs aus dem kompletten Teil extrahieren
                        nals = parse_nals(complete)
                        for nal in nals:
                            t = nal_type(nal)
                            if t == 7 or t == 8:
                                # SPS/PPS: eigene Message (roh)
                                await send_binary(ws, nal)
                                self.state["nal_sent"] += 1
                            elif t == 9:
                                # AUD: aktuelle AU abschließen
                                await flush_au(ws)
                            elif t == 1 or t == 5 or t == 6:
                                cur_au.append(nal)
                        await asyncio.sleep(0.001)
            except Exception as e:
                import traceback as _tb
                log.error("pusher exception: %s\n%s", e, _tb.format_exc())
                self.state["connected"] = False
                if not self._closed:
                    log.warning("link down (%s), retrying in 2s", e)
                await asyncio.sleep(2)

    def close(self):
        self._closed = True


# ---------------------------------------------------------------- Dashboard HTTP
def parse_multipart(body, content_type):
    m = re.search(r"boundary=([^;]+)", content_type or "")
    if not m:
        return {}
    b = m.group(1).strip().strip('"').encode()
    out = {}
    for p in body.split(b"--" + b):
        p = p.strip(b"\r\n")
        if not p or p == b"--":
            continue
        head, _, data = p.partition(b"\r\n\r\n")
        data = data[:-2] if data.endswith(b"\r\n") else data
        hm = re.search(rb'name="([^"]+)"(?:; filename="([^"]*)")?', head)
        if hm:
            name = hm.group(1).decode()
            fname = hm.group(2).decode() if hm.group(2) else None
            out[name] = (fname, data)
    return out


class Dashboard:
    def __init__(self, state, logbuf):
        self.state = state
        self.logbuf = logbuf
        self.html = open(DASH_PATH, encoding="utf-8").read()

    def handle_get(self, u):
        if u.path == "/":
            return 200, "text/html", self.html
        if u.path == "/api/stats":
            st = self.state
            fps = 0
            if st["start_time"]:
                fps = round(st["frames_sent"] / max(1, time.time() - st["start_time"]), 1)
            body = {
                "connected": st["connected"],
                "running": st.get("want") is not None,
                "source": st["want"][0] if st["want"] else "none",
                "encode": f"{WIDTH}x{HEIGHT} @{st.get('fps', DEFAULT_FPS)}fps",
                "fps": fps,
                "mb_sent": round(st["bytes_sent"] / 1e6, 1),
                "ws_messages": st.get("ws_messages", 0),
                "ws_bytes": st.get("ws_bytes", 0),
                "au_sent": st.get("au_sent", 0),
                "nal_sent": st.get("nal_sent", 0),
                "uptime": int(time.time() - st["start_time"]) if st["start_time"] else 0,
                "src_error": st.get("src_error"),
            }
            return 200, "application/json", json.dumps(body)
        if u.path == "/api/cameras":
            return 200, "application/json", json.dumps(list_cameras())
        if u.path == "/api/logs":
            return 200, "application/json", json.dumps(self.logbuf.get())
        if u.path == "/api/network":
            return 200, "application/json", json.dumps({"interfaces": local_ips()})
        if u.path == "/preview.jpg":
            jpg = self.state["pipeline"].preview()
            if jpg:
                return 200, "image/jpeg", jpg
            return 404, "text/plain", b"no preview"
        return 404, "text/plain", "not found"

    def handle_post(self, u, body, ctype):
        if u.path == "/api/upload":
            fields = parse_multipart(body, ctype)
            up = fields.get("file")
            if not up:
                return 400, "application/json", json.dumps({"error": "no file"})
            fname, data = up
            os.makedirs(UPLOAD_DIR, exist_ok=True)
            safe = re.sub(r"[^\w.\- ]", "_", fname or "upload")
            path = os.path.join(UPLOAD_DIR, f"{int(time.time())}_{safe}")
            with open(path, "wb") as f:
                f.write(data)
            self.state["want"] = ("file", path)
            self.state["start_time"] = time.time()
            self.logbuf.add("debug", f"uploaded: {fname}")
            return 200, "application/json", json.dumps({"ok": True, "path": path})
        if u.path == "/api/control":
            try:
                msg = json.loads(body.decode("utf-8"))
            except Exception:
                return 400, "application/json", json.dumps({"error": "bad json"})
            st = self.state
            t = msg.get("type")
            if t == "set_source":
                if msg.get("source_type") == "local":
                    st["want"] = ("cam", str(msg.get("camera_id") or 0))
                elif msg.get("video_path"):
                    st["want"] = ("file", msg["video_path"])
                st["start_time"] = time.time()
                self.logbuf.add("debug", f"source set: {st['want']}")
            elif t == "clear_source":
                st["want"] = None
                self.logbuf.add("debug", "source cleared")
            elif t == "transform":
                tr = st["transform"]
                tr["zoom"] = msg.get("zoom", tr["zoom"])
                tr["pan_x"] = msg.get("panX", tr["pan_x"])
                tr["pan_y"] = msg.get("panY", tr["pan_y"])
                tr["flip_h"] = msg.get("flipH", tr["flip_h"])
                tr["rotation"] = msg.get("rotation", tr["rotation"])
            elif t == "bg_color":
                st["transform"]["bg_color"] = [msg.get("r", 0), msg.get("g", 0), msg.get("b", 0)]
            elif t == "filters":
                f = st["filters"]
                for k in ("brightness", "contrast", "saturation", "gamma"):
                    if k in msg:
                        f[k] = msg[k]
            elif t == "playback":
                pb = st["playback"]
                act = msg.get("action")
                if act == "play":
                    pb["action"] = "play"
                elif act == "pause":
                    pb["action"] = "pause"
                elif act == "stop":
                    pb["seek_frame"] = 0
                    pb["action"] = "pause"
                elif act == "seek":
                    pb["seek_frame"] = int(msg.get("position", 0) * 1000)
                elif act == "speed":
                    pb["speed"] = msg.get("speed", 1.0)
                elif act == "loop":
                    pb["loop"] = msg.get("enabled", True)
            elif t == "fps":
                st["fps"] = int(msg.get("fps", 30))
            return 200, "application/json", json.dumps({"ok": True})
        return 404, "text/plain", "not found"


def dashboard_server(state, logbuf):
    dash = Dashboard(state, logbuf)

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            code, ctype, body = dash.handle_get(urlparse(self.path))
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if isinstance(body, str):
                body = body.encode()
            self.wfile.write(body)

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n) if n else b""
            code, ctype, body2 = dash.handle_post(urlparse(self.path), body,
                                                  self.headers.get("Content-Type"))
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.end_headers()
            if isinstance(body2, str):
                body2 = body2.encode()
            self.wfile.write(body2)

        def log_message(self, *a):
            pass

    ThreadingHTTPServer(("127.0.0.1", DASHBOARD_PORT), H).serve_forever()


# ---------------------------------------------------------------- main
async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", choices=["cam", "file"], default="cam")
    ap.add_argument("--video", default="")
    ap.add_argument("--device", default="")
    ap.add_argument("--camera-id", default="")
    ap.add_argument("--ip", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8767)
    ap.add_argument("--list-cameras", action="store_true")
    a = ap.parse_args()

    if a.list_cameras:
        for c in list_cameras():
            print(c)
        return

    device_arg = a.camera_id or a.device or DEFAULT_DEVICE
    state = {
        "want": ("file", a.video) if (a.source == "file" and a.video) else ("cam", device_arg),
        "transform": {"zoom": 1.0, "pan_x": 0.0, "pan_y": 0.0, "flip_h": False,
                      "rotation": 0, "bg_color": [0, 0, 0]},
        "filters": {"brightness": 0.0, "contrast": 1.0, "saturation": 1.0, "gamma": 1.0},
        "playback": {"action": "play", "speed": 1.0, "loop": True, "seek_frame": None},
        "fps": DEFAULT_FPS,
        "connected": False,
        "bytes_sent": 0,
        "frames_sent": 0,
        "start_time": 0.0,
        "src_error": None,
    }
    logbuf = LogBuf()
    pipeline = Pipeline(state, logbuf)
    state["pipeline"] = pipeline
    pipeline.start()

    threading.Thread(target=dashboard_server, args=(state, logbuf), daemon=True).start()
    log.info("Dashboard: http://localhost:%d   (target ws://%s:%d)", DASHBOARD_PORT, a.ip, a.port)
    logbuf.add("debug", "VCamUSB server started")

    # camera id: if initial source is cam with device name, map to index.
    # Numerische IDs direkt übernehmen (kein Namens-Mapping).
    if state["want"] and state["want"][0] == "cam":
        name = state["want"][1]
        if name.isdigit():
            idx = int(name)
        else:
            cams = list_cameras()
            idx = 0
            for i, c in enumerate(cams):
                if c.lower() in name.lower() or name.lower() in c.lower():
                    idx = i
                    break
        state["want"] = ("cam", str(idx))
        logbuf.add("debug", f"camera mapped to index {idx}")

    state["start_time"] = time.time()
    # Pusher liest die Pipe-DYNAMISCH aus der aktuellen Encoder-Instanz.
    # Der Encoder bekommt bei jedem Neustart eine neue Generations-Pipe.
    class PipeResolver:
        def __init__(self, pipeline):
            self.pipeline = pipeline
        def get(self):
            enc = self.pipeline.encoder
            return enc.pipe if enc else ""
    pusher = FramePusher(PipeResolver(pipeline).get(), a.ip, a.port, state)
    pusher.pipe_resolver = PipeResolver(pipeline)
    asyncio.create_task(pusher.run())

    try:
        while True:
            await asyncio.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        pusher.close()
        pipeline.stop()


if __name__ == "__main__":
    asyncio.run(main())
