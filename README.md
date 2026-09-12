# VCamUSB

Virtuelle Kamera fürs iPhone über USB — open source, **kein Login, keine Lizenz, keine Cloud**.

**Architektur** (wie LordVCam, aber frei):
```
[PC: Quelle] → ffmpeg → H.264 → WebSocket ──USB──> [iPhone: Tweak] → VideoToolbox → Kamera-Feed
   OBS Virtual Cam /            (Tunnel via iproxy 8767→8767)      (mediaserverd-Hook)
   Webcam / Video-Datei
```

## Komponenten
- `server/` — Windows-PC-Server (Python): Dashboard (localhost:8080), Quelle wählen, ffmpeg encode, WS-Push
- `tweak/` — iOS-Tweak (Theos, roothide-Schema): WS-Server in SpringBoard, H.264-Decode, Recon-Dump

## Status
- [x] PC-Server end-to-end getestet (H.264-Frames über WebSocket, fake-iPhone-Receiver: 2099 Frames in 6s)
- [ ] Tweak: Phase 1 (Transport + Decoder + Recon) — Build via GitHub Actions
- [ ] Tweak: Phase 2 (Kamera-Pfad-Hook) — nach Recon aufm Gerät

## Build (Tweak)
Via GitHub Actions (macOS-Runner), siehe `.github/workflows/build.yml`.
Lokal aufm Mac: `THEOS=... make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide`

## USB-Setup
1. iPhone: SSH via `iproxy 2222 22`, WS via `iproxy 8767 8767`
2. PC: `python server.py` → Dashboard auf http://localhost:8080
3. Quelle wählen (OBS Virtual Camera läuft nur, wenn OBS offen ist)
