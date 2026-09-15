# VCamUSB / LordVCAM — Komplettübergabe für eine neue KI

Stand: 2026-09-15

## 1. Ziel

VCamUSB soll einen PC-Video-/Audio-Stream über USB auf ein gejailbreaktes iPhone bringen und dort als Kameraquelle in Preview, Foto, Videoaufnahme und möglichst Safari/WebRTC verwenden.

Referenz ist LordVCAM. LordVCAM dient nur zur Architektur- und Ablaufanalyse. Nicht aus Strings allein auf aktive Hooks schließen.

## 2. Hardware und Gerät

- Windows 11 PC
- ASUS Laptop, Ryzen 7 6800H, 32 GB RAM, RTX 3060 Laptop 6 GB
- OBS Virtual Camera installiert
- ffmpeg 9 im PATH
- iPhone: iOS 16.7.16
- Jailbreak: Dopamine2-roothide
- Architektur des tatsächlich installierten LordVCAM-Pakets: arm64e
- USB-SSH-Tunnel liegt unter `C:/iproxy/iproxy.exe`
- Gerätezugriff ist für die statische Analyse nicht erforderlich.

Wichtige Stabilitätswarnung: Wiederholte harte `killall -9 mediaserverd` haben bereits die Dopamine2-roothide-Injektionskette beschädigt. Ein kompletter Neustart plus Re-Jailbreak mit Dopamine hat die Injection bisher zuverlässig repariert. Keine Kill-Serie für normale Tests.

## 3. Projektpfade

### VCamUSB

Projektwurzel:

```text
C:/Users/shosh/VCamUSB/
```

Wichtige Dateien:

```text
C:/Users/shosh/VCamUSB/tweak/Inject.x
C:/Users/shosh/VCamUSB/tweak/Hub.x
C:/Users/shosh/VCamUSB/tweak/AVF.x
C:/Users/shosh/VCamUSB/tweak/Probe.x
C:/Users/shosh/VCamUSB/tweak/DeviceDump.x
C:/Users/shosh/VCamUSB/tweak/Makefile
C:/Users/shosh/VCamUSB/tweak/VCamInject.plist
C:/Users/shosh/VCamUSB/tweak/VCamHub.plist
C:/Users/shosh/VCamUSB/server/server.py
C:/Users/shosh/VCamUSB/server/usb_tunnel_8767.py
C:/Users/shosh/VCamUSB/server/send_mode.py
C:/Users/shosh/VCamUSB/server/dashboard.html
```

### Zentrale Übergabeberichte

```text
C:/Users/shosh/VCamUSB/DEEPSEEK_LORDVCAM_GESAMT_UEBERGABE.md
C:/Users/shosh/VCamUSB/ASTRA_SERVER_DYLIB_INTEGRATION.md
C:/Users/shosh/VCamUSB/ASTRA_VERIFIKATION_ERGEBNIS.md
C:/Users/shosh/VCamUSB/ASTRA_VERIFIKATION_ERGEBNIS.json
C:/Users/shosh/VCamUSB/ASTRA_ABDEFG_REPORT.md
C:/Users/shosh/VCamUSB/LORDVCAM_VOLLSTAENDIG_ANALYSE.md
C:/Users/shosh/VCamUSB/arm64e_hooks_report.md
C:/Users/shosh/VCamUSB/arm64e_transport_decoder_report.md
C:/Users/shosh/VCamUSB/arm64e_handoff_recording_report.md
C:/Users/shosh/VCamUSB/analysis_verified_stubs.md
```

## 4. LordVCAM-Dateien

### Deb und installierte Dylib

```text
C:/Users/shosh/Downloads/com.apple.avservicesd.roothide_2.0.995_iphoneos-arm64e (1).deb
C:/Users/shosh/VCamUSB/lordvcam_deb_analysis/data.tar.xz.dir/Library/MobileSubstrate/DynamicLibraries/AVServicesd.dylib
C:/Users/shosh/Downloads/AVServicesd_arm64e.dylib
```

Die Paket-Dylib ist eine Universal-Dylib mit arm64 und arm64e. Für die aktuelle Analyse ist ausschließlich dieser arm64e-Slice maßgeblich:

```text
C:/Users/shosh/Downloads/AVServicesd_arm64e.dylib
```

Ghidra-Projekt:

```text
C:/Users/shosh/VCamUSB/ghidra_arm64e_fresh/LordVCAM_arm64e
```

Frischer Ghidra-Export des arm64e-Slices:

```text
C:/Users/shosh/VCamUSB/ghidra_arm64e_fresh/export/
```

Der vollständige arm64e-Export liegt hier:

```text
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/
```

Dort existieren unter anderem:

```text
functions_all.txt
imports.txt
objc_methods.txt
decompiled/*.c
assembly/*.asm
```

Der Voll-Export enthält ca. 5499 Funktionen. Er ist die primäre Quelle für die aktuelle Verifikation.

### Alte arm64-Referenz

Nur Vergleichsmaterial, nicht für aktuelle arm64e-Adressen verwenden:

```text
C:/Users/shosh/VCamUSB/dev_AVServicesd_now.dylib
C:/Users/shosh/VCamUSB/analysis_ghidra/export/
```

## 5. LordVCAM-Serverpfade

Entpackter Server:

```text
C:/Users/shosh/Downloads/LordVCAM-Server/LordVCAM-Server.exe_extracted/
```

Python-Bytecode:

```text
C:/Users/shosh/Downloads/LordVCAM-Server/LordVCAM-Server.exe_extracted/server.pyc
C:/Users/shosh/Downloads/LordVCAM-Server/LordVCAM-Server.exe_extracted/PYZ-00.pyz_extracted/
```

Offene/analysierte Module:

```text
video_capture.pyc
transform_engine.pyc
filter_engine.pyc
audio_capture.pyc
image_loader.pyc
packet_framing.pyc
encoder.pyc
usb_manager.pyc
```

Dashboard:

```text
C:/Users/shosh/Downloads/LordVCAM-Server/LordVCAM-Server.exe_extracted/static/index.html
```

Zusätzlicher Bericht:

```text
C:/Users/shosh/lordvcam_server_dashboard_report.md
```

## 6. Verifizierte LordVCAM-Serverarchitektur

```text
Dashboard/Browser :8080
    -> LordVCAM HTTP API und Browser-WebSocket
        -> Videoquelle: lokale Kamera, Datei oder Browser/WebRTC-JPEG
            -> Transform Engine
            -> Filter Engine
            -> Audio Capture parallel
            -> zentraler H.264-Encoder
                -> WebSocket-Stream :8765
                    -> USBMux-Relay PC :8767
                        -> iPhone-Dylib
```

Verifizierte Ports:

```text
Dashboard HTTP: 8080
LordVCAM WS-Stream: 8765
PC-seitiger USBMux-Relay-Port: 8767
Windows usbmuxd/AMDS: 127.0.0.1:27015
```

Handshake:

```json
{"type":"hs"}
```

oder:

```json
{"type":"handshake"}
```

Mit Diagnosefeldern:

```json
{"format":"420v","width":1920,"height":1080,"fps":30}
```

Der Handshake konfiguriert den Masterstream nicht. `client_format: 420v, 0x0` bedeutet: Der Client hat width/height als 0 gemeldet, also keinen gültigen aktiven Capture-Buffer.

### Frame-Wire-Format

```text
[4 Byte unsigned Big-Endian Payload-Length]
[JSON-Header UTF-8]
[Payload]
```

Frame-Header:

```json
{"type":"frame","seq":N,"ts":MICROSECONDS,"ct":MICROSECONDS,"em":MILLISECONDS}
```

`ct` und `em` sind optional, wenn Capture-/Encode-Zeit vorhanden ist.

Audio analog:

```json
{"type":"audio","seq":N,"ts":MICROSECONDS,"rate":R,"ch":C}
```

Danach folgt PCM-Audio.

Encoder:

```text
Input: planar yuv420p
Default: 1920x1080 @ 30 fps
Server-Diagnoseformat: 420v
Bitrate: ca. 8 Mbit/s
Codec-Kaskade:
  h264_nvenc
  h264_videotoolbox
  h264_amf
  h264_qsv
  libx264
  libopenh264
```

## 7. Server-Features und VCamUSB-Vergleich

| Feature | LordVCAM | VCamUSB aktuell |
|---|---|---|
| Zoom/Pan/Move | Serverseitig in `transform_engine` | `compose_frame()` in `server/server.py` vorhanden |
| Horizontal spiegeln | Server | `flip_h` vorhanden |
| Vertikal spiegeln | Server unterstützt `flip_v` | fehlt aktuell |
| Rotation Quelle | Serverseitig | 90/180/270 in `compose_frame()` vorhanden |
| Consumer-Rotation | iPhone-Dylib abhängig vom Zielbuffer | eigener Tweak-Pfad vorhanden, noch nicht final kompatibel |
| Brightness | Server | vorhanden |
| Contrast | Server | vorhanden |
| Saturation | Server | vorhanden |
| Gamma | Server | vorhanden |
| Hintergrund/Letterbox | Server-Canvas | vorhanden |
| Audio Datei/Mikrofon | PCM-Queue und `type:audio` | fehlt als vollständiger E2E-Pfad |
| Dashboard | umfangreiches Static-Dashboard | eigenes kleineres `server/dashboard.html` vorhanden |
| USB | eingebauter usbmuxd-Manager | separater `usb_tunnel_8767.py` |
| Foto-Replacement | PhotoEncoder-/High-Resolution-Hooks | aktuell nur Foto-Guard, kein vollständiger Ersatz |
| Lizenz/Login | in LordVCAM vorhanden | nicht benötigt, weglassen |

Server-Transform-Reihenfolge laut Bytecode:

```text
Flip
-> Rotation
-> Resize/Scale
-> Positionierung auf Canvas
-> Hintergrund/Letterbox
-> Filter
-> YUV-Konvertierung / Encode
```

Filterreihenfolge:

```text
Brightness -> Contrast -> Saturation -> Gamma
```

Audio:

```text
AudioCapture -> PCM Int16 Chunks -> Queue
```

Bei voller Queue wird der älteste Chunk verworfen. Datei und Mikrofon werden auf die Zielrate resampelt. Der vollständige iPhone-Audio-Handoff ist in VCamUSB noch nicht vorhanden.

## 8. Verifizierte arm64e-Hooks

Quelle:

```text
C:/Users/shosh/VCamUSB/arm64e_hooks_report.md
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/decompiled/
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/objc_methods.txt
```

Registrierungsfunktion:

```text
FUN_0001dd7c
```

Belegte Hooks:

```text
BWGraph
  start
  stop
  beginConfiguration
  commitConfigurationWithID:error:

AVCapturePhotoOutput
  capturePhotoWithSettings:delegate:

FigCaptureClientSessionMonitor
  applicationID

BWPixelTransferNode
  renderSampleBuffer:forInput:

BWPhotoEncoderNode
  renderSampleBuffer:forInput:
  _encodePhotoForEncodingScheme:pixelBuffer:... 
  _generatePreviewForSampleBuffer:
  _addAuxImagesIfNeededForEncoding: (zwei Registrierungen/Signaturambiguität)
  _addThumbnailForEncodingScheme:thumbnailPixelBuffer:...

FBSOrientationUpdate
  initWithOrientation:sequenceNumber:...
```

Die genauen arm64e-Replacement-Adressen und Original-IMP-Speicher stehen in `arm64e_hooks_report.md`. Original-IMP-Werte sind Laufzeitwerte und statisch nicht auflösbar.

## 9. Verifizierter arm64e-Transport und Decoder

Quelle:

```text
C:/Users/shosh/VCamUSB/ASTRA_VERIFIKATION_ERGEBNIS.md
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/decompiled/20bb0.c
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/decompiled/37038.c
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/decompiled/60350.c
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/decompiled/60ca4.c
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/decompiled/61104.c
```

Transport-Kette:

```text
AVSLocalTransport
  readClientData: 0x60350
  tryParseHandshake: 0x60474
  tryParseFrames: 0x60ca4
  acceptClient: 0x5fea8
  handleBinaryMessage: 0x61104
  stats: 0x61c38
  startPingTimer: 0x61a64

AVSStreamTransport
  handleBinaryMessage: 0x20bb0

AVSRemoteDataProvider
  avs_tr_didRecvData:sequenceNumber:serverTimestamp:
  captureTimestamp:encodeTimeMs: 0x34a0c
  avs_tr_didRecvAudio:sampleRate:channels: 0x352c0

AVSMediaDecoder
  createDecompressionSession: 0x37038
```

### Parser F2

`AVSStreamTransport::handleBinaryMessage:` bei `0x20bb0`:

- liest 4 Bytes Länge,
- führt Byte-Swap auf Big-Endian-Länge aus,
- akzeptiert Header nur strikt kleiner als `0x401`, also maximal `0x400`,
- scannt JSON manuell statt `NSJSONSerialization`,
- erkennt `type:audio`, `type:frame`, `type:yuv`,
- Audio liest `rate` und `ch`,
- Frame liest `seq`, `ts`, `ct`, `em`,
- YUV liest zusätzlich `seq`, `ts`, `ct`, `w`, `h`,
- Payload ist `NSData` ab Offset `4 + headerLength` bis zum Ende,
- kein SPS/PPS-Dispatch und keine Startcode-Suche im Parser.

### Decoder F3

`AVSMediaDecoder::createDecompressionSession` bei `0x37038` ruft:

```c
CMVideoFormatDescriptionCreateFromH264ParameterSets(
    allocator,
    2,
    &sps,
    &pps,
    4,
    &formatDescription
);
```

Bedeutung:

```text
2 Parameter-Sets: SPS + PPS
NAL length size: 4 Bytes
H.264-Vertrag: AVCC, nicht Annex-B
```

Decoder-Attribute:

```text
Pixelbufferformat: 0x34323066 = '420f'
RealTime: true
IOSurface-Eigenschaften vorhanden
```

In der geprüften Decoderfunktion wurde keine Annex-B-Konvertierung und keine Suche nach `00 00 00 01` gefunden.

### Port F4

`8765` erscheint im Stats-/UI-Kontext. Der Local-Server bindet nicht nachweislich hart an einen Literalwert, sondern nutzt ein Laufzeitfeld des `AVSLocalTransport`-Objekts:

```text
AVSLocalTransport + 0x28
```

Bei `0x5fa2c` wird daraus `sockaddr` gebaut und danach `bind`/`listen` aufgerufen. Eine Pref-Quelle für den konkreten Wert 8765 ist nicht bewiesen. Für VCamUSB darf der Port nicht blind in den Dylib-Bindpfad gepatcht werden.

## 10. Verifizierter arm64e Pixelbuffer-/Handoff-Pfad

Quellen:

```text
C:/Users/shosh/VCamUSB/ASTRA_VERIFIKATION_ERGEBNIS.md
C:/Users/shosh/VCamUSB/arm64e_handoff_recording_report.md
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/decompiled/14f90.c
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/assembly/14f90.asm
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/decompiled/1edb0.c
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/decompiled/4cc9c.c
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/decompiled/4bc38.c
```

Belegt:

```text
CMSampleBuffer valid?
-> CMSampleBufferGetImageBuffer
-> CVPixelBuffer/IOSurface prüfen
-> Breite/Höhe/FourCC/Plane/Stride prüfen
-> IOSurface use count verwalten
-> Ziel-CVPixelBuffer neu erzeugen oder aus Cache nehmen
-> Y/UV-Planes kopieren/verarbeiten
-> CVBuffer-Attachments kopieren/setzen
-> VTPixelTransferSessionTransferImage bei Konvertierung/Scale
-> BWNodeOutput emitSampleBuffer:
```

LordVCAM verwendet für Transformationspfade separate Zielbuffer. Das ist nicht identisch mit dem aktuellen VCamUSB-In-place-Swap.

### F5-Verifikation

`BWNodeOutput emitSampleBuffer:` ist der belegte Ausgangs-/Handoff-Punkt:

```text
decompiled/14a1c.c:28–34
assembly/14f90.asm:748–752
```

Es wurden im Voll-Export keine Symbole für gefunden:

```text
AVAssetWriter
AVAssetWriterInput
AVAssetWriterInputPixelBufferAdaptor
VTCompressionSession
```

Daher wird kein eigener Movie-Writer-Feeder in der Dylib belegt. Recording-Hook-Suche kann vorerst eingestellt werden. Absolute Aussage „kein anderer Apple-Konsument existiert“ wäre trotzdem zu stark; downstream kann der Apple-Capturegraph weitere Konsumenten enthalten.

## 11. needsCCW90 F6

Quelle:

```text
C:/Users/shosh/VCamUSB/ghidra_arm64e_full/assembly/14f90.asm
```

Arm64e-Formel laut Datenfluss:

```text
aspect = width / height
needsCCW90 = (aspect > 1.5) && (width >= height)
```

Der Logstring enthält `camApp` und `front`, aber diese Werte sind im geprüften Predicate nur Kontext-/Logargumente. Zusätzliche `camApp`-/`front`-Gates sind nicht belegt.

## 12. Was noch offen ist

### A. Primär offen: vollständiger WS-Client → Decoder-Callgraph

Obwohl Parser und Decoderfunktionen verifiziert sind, muss für die endgültige Gesamtarchitektur noch die Verbindung zwischen diesen Funktionen als Callgraph dokumentiert werden:

```text
AVSLocalTransport/AVSStreamTransport
-> binary packet parser
-> AVSRemoteDataProvider
-> AVSMediaDecoder
-> VT callback
-> held CVPixelBuffer
```

### B. Exakter Handoff-Samplebuffer

Belegt ist der neue/normalisierte CVPixelBuffer und `emitSampleBuffer:`. Noch offen ist:

```text
Wird ein neuer CMSampleBuffer erzeugt?
Welche Timing-/PTS-/Duration-Felder werden kopiert?
Welche konkreten Attachment-Keys werden gesetzt?
```

### C. Preview/Foto/Recording/WebRTC-Laufzeitkorrelation

Statische Belege zeigen Hooks und Handoff-Grenzen. Noch nicht vollständig bewiesen ist, welcher konkrete Consumer in jeder App welchen `BWNodeOutput` nutzt. Dafür wären observe-only Laufzeitcounter und Sentinel-A/B-Tests nötig.

### D. Audio E2E

LordVCAM hat Audio-Parser und Audio-Feeder. VCamUSB hat aktuell keinen vollständigen Audio-Capture-/Wire-/iPhone-Handoff. Das ist ein separates Projekt nach stabilem Video-/Foto-Handoff.

## 13. Aktuelle Patchentscheidungen

Freigegeben durch arm64e-Voll-Export-Verifikation:

1. VCamUSB-Handoff auf `BWNodeOutput emitSampleBuffer:` ausrichten.
2. Kein eigener `AVAssetWriter`-/`VTCompressionSession`-Pfad.
3. Separate Recording-Hook-Suche vorerst einstellen.
4. Erst Handoff und PhotoEncoder-Pfad stabilisieren, danach Audio.

Nicht freigegeben:

- Wire-Format ändern, ohne VCamUSB und LordVCAM byteweise gegenzutesten.
- Port 8765 in der Dylib hart patchen.
- Foto-Handoff nur über `AVCapturePhotoOutput` implementieren.
- `p420` allein anhand FourCC als identisch zu `420f` behandeln.
- arm64e-Adressen aus dem alten arm64-Slice übernehmen.

## 14. Empfohlene Weiterarbeit für eine neue KI

### Schritt 1: Status lesen

Diese Datei vollständig lesen:

```text
C:/Users/shosh/VCamUSB/PROJEKT_UEBERGABE_KOMPLETT.md
```

Dann die Verifikation lesen:

```text
C:/Users/shosh/VCamUSB/ASTRA_VERIFIKATION_ERGEBNIS.md
```

### Schritt 2: Aktuellen Code prüfen

```text
C:/Users/shosh/VCamUSB/tweak/Inject.x
C:/Users/shosh/VCamUSB/server/server.py
```

### Schritt 3: Keine alten Annahmen verwenden

- arm64e ist maßgeblich.
- AVCC ist verifiziert.
- Output ist 420f.
- Parser ist manuell und hat Headerlimit `<0x401`.
- Handoff-Grenze ist `BWNodeOutput emitSampleBuffer:`.
- Kein eigener Movie-Writer in der Dylib belegt.

### Schritt 4: Vor Codeänderungen

Zuerst folgende Implementierung im aktuellen `Inject.x` mit dem Befund vergleichen:

```text
WS-/Frame-Vertrag
Decoder AVCC
420f-Ausgabe
separater Zielbuffer
Attachment-/Timing-Handoff
BWNodeOutput emitSampleBuffer:
```

### Schritt 5: Patchreihenfolge

```text
1. Transport/AVCC-Vertrag byteweise testen
2. Decoderstatus und 420f-Ausgabe prüfen
3. Preview-Handoff auf emitSampleBuffer ausrichten
4. p420/420v/420f-Layout und Range messen
5. FotoEncoder-/HI_RES-Pfad separat implementieren
6. Video-Preview und native Kamera testen
7. Audio erst danach
8. flip_v und Dashboard-Erweiterungen zuletzt
```

Jede Änderung erst hostseitig/CI bauen und Paketinhalt prüfen. Kein Gerät installieren, bevor Build und Scope verifiziert sind.

## 15. Kurzfazit

LordVCAM ist nicht primär eine neue virtuelle `AVCaptureDevice`, sondern eine systemweite mediaserverd-/Capturegraph-Integration:

```text
Serverquelle
-> Server-Transform/Filter/Audio
-> WS-Frame mit 4B-Länge + JSON + H.264
-> iPhone Local/Stream Transport
-> manueller Header-/Typparser
-> AVCC H.264
-> VideoToolbox Output 420f
-> separater/normalisierter IOSurface-CVPixelBuffer
-> Attachments/Transfer
-> BWNodeOutput emitSampleBuffer:
-> Apple Capturegraph für Preview/Foto/Recording/WebRTC
```

Die größten VCamUSB-Lücken sind:

1. vollständiger separater Buffer-/Samplebuffer-Handoff,
2. FotoEncoder-/High-Resolution-Replacement,
3. Audio-Ende-zu-Ende,
4. vertikales Spiegeln,
5. vollständige Dashboard-/USB-Integration.

Die nächste KI soll nicht erneut die gesamte Grundlagenanalyse starten, sondern den aktuellen `Inject.x` gegen diesen verifizierten Ablauf prüfen und die kleinsten, testbaren Patches in der genannten Reihenfolge umsetzen.
