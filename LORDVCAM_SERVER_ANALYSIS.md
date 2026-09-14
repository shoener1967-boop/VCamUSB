# LordVCAM-Server — Vollständige Analyse (dekompiliert)

Quelle: `LordVCAM-Server.exe` (PyInstaller-Bundle) → `server.pyc` (Python 3.11)
Methode: marshal + co_names/co_consts Extraktion (uncompyle6/decompyle3 scheitern an 3.11)

## Architektur (aus dem eingebetteten Help-Text)

```
Server encodiert IMMER auf feste hohe Qualität (default 1080p 30fps)
→ iOS-Tweak skaliert RUNTER auf aktuelle Kamera-Auflösung/Format
→ Tweak muss nur downscalen (besser als upscalen)
```

## Server-Komponenten (Klassen/Konstanten)

- `VirtualCameraServer` — Hauptklasse (WebSocket + Broadcast)
- `H264Encoder` — ffmpeg-basiert, Hardware-Encoding wenn verfügbar
- `VideoCapture` — cv2/DirectShow (OBS Virtual Camera, camera-id)
- `AudioCapture` — Mikrofon (sounddevice)
- `PacketProtocol` — Sequence-Nummern, `get_frame_yuv_with_id`
- `DashboardServer` — Web-UI Port 8080
- `AppRunner` — aiohttp

## Konstanten (Defaults)

- DEFAULT_WS_PORT, DEFAULT_DASHBOARD_PORT = 8080
- DEFAULT_ENCODE_WIDTH=1920, DEFAULT_ENCODE_HEIGHT=1080, DEFAULT_ENCODE_FPS=30
- DEFAULT_PIXEL_FORMAT (NV12/YUV)
- VIDEO_BACKPRESSURE_LIMIT, AUDIO_BACKPRESSURE_LIMIT
- RTT_PING_INTERVAL, LATENCY_WARNING_MS, EMA_ALPHA

## Quellen (--source)

- `local`  → cv2.VideoCapture(camera_id, DirectShow)  [OBS Virtual Camera]
- `file`   → Video-Datei
- `webrtc` → WebRTC-Quelle
- `mic`    → Audio (Mikrofon)

## Kern-Loop

```
Central encode loop: capture → encode EINMAL → broadcast an ALLE Clients
- Encode passiert nur EINMAL (unabhängig von Client-Anzahl)
- Selbe H.264-Bytes an alle Clients
- Per-Client Backpressure: langsame Clients droppen Frames, schnelle unberührt
```

## Transport

- TCP (WebSocket), Option: WSS (SSL, self-signed cert auto-generiert)
- Sequence-Nummern nur für Monitoring (kein Retransmit)
- Audio als separater Stream (`_broadcast_audio`, `create_audio_packet`)

## Funktionen (co_names Highlights)

- `_encode_and_broadcast` — zentraler Encode+Broadcast
- `_start_streaming` / `_stop_streaming` — bei erstem/letztem Client
- `_send_to_client` — fire-and-forget
- `_parse_client_format` — Client-Format-Handshake (informational)
- `_rtt_ping_loop` — Latenz-Messung
- `reduce_bitrate` — adaptive Bitrate
- `get_frame_yuv_with_id` — YUV-NV12 + Frame-ID

## Schlussfolgerung für VCamUSB

1. **Server auf 1080p (oder 1440×1080) umstellen**, Tweak skaliert NUR runter.
   Wir machen aktuell das Gegenteil (1280×720 Server + upscale auf 1440×1080) = falsch.

2. **Broadcast-Modell übernehmen:** einmal encoden, an alle Clients. Wir haben
   das schon (Hub broadcastet), aber ohne den "encode once" Fokus.

3. **Audio fehlt uns komplett** — LordVCAM streamt auch Audio (Mikrofon).
   Für TikTok/Video-Aufnahme relevant.

4. **Adaptive Bitrate + Backpressure** — LordVCAM hat das, wir nicht.

5. **Client-Format-Handshake** — der Tweak meldet sein Format zurück.
   Wir raten aktuell (1280×720 vs 1440×1080).
