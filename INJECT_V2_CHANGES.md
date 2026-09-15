# Inject_v2.x — Sauberer Neubau nach verifiziertem LordVCAM-Ablauf

**Erstellt:** 2026-09-15  
**Basis:** `PROJEKT_UEBERGABE_KOMPLETT.md`, `ASTRA_VERIFIKATION_ERGEBNIS.md`  
**Ziel:** Reduzierter, verifizierbarer Code ohne historischen Overhead

## Änderungen gegenüber Inject.x

### ✅ Entfernt (historischer Overhead)

1. **Stage-System (0–3)** → einfaches `g_enabled` Bool
2. **FigCaptureClientSessionMonitor-Hooks** → feuern nie in mediaserverd, entfernt
3. **buildSwapSampleBuffer + Passthrough-Modi** → In-place-Swap ist der einzige Weg für Preview
4. **Test-Pattern/wrap_orig-Modi** → Debug-Features raus
5. **Hunderte Telemetrie-Zähler** → reduziert auf Essentials (Preview/Photo/Recording + Decoder)
6. **Methodendump/Wildcard-Scan** → nicht mehr im Produktionscode
7. **Sink-Beobachtung BWStillImageSampleBufferSinkNode** → nur Recording-Sink bleibt

### ✅ Neu implementiert

1. **BWPhotoEncoderNode-Hook** (Zeile 704–721)
   - Separater Buffer statt Guard-Flag
   - `buildReplacementSampleBuffer()` erzeugt neuen CVPixelBuffer + CMSampleBuffer
   - Attachments vom Original kopieren (wichtig für Photo-Encoder!)
   
2. **Saubere Hook-Struktur**
   - Preview: `BWImageQueueSinkNode` → In-place-Swap
   - Photo: `BWPhotoEncoderNode` → Separate Buffer
   - Recording: `BWQuickTimeMovieFileSinkNode` → nur Beobachtung

3. **Vereinfachte Enable/Disable-Steuerung**
   - Status-Port: `echo "enable" | nc 127.0.0.1 8769`
   - WS-Text-Command: `"enable"` / `"disable"`

### ✅ Übernommen (funktioniert)

1. **Decoder-Block** (Zeile 99–239) — AVCC, 420f, aus Inject.x 1:1
2. **Rotation/Scale-Helfer** (Zeile 246–392) — vImage LordVCAM-Stil
3. **WS-Client** (Zeile 802–889) — Annex-B-Parser, robust
4. **Status-Server** (Zeile 728–770) — Telemetrie über Port 8769

## Dateigröße

- **Inject.x:** 1782 Zeilen, 81 KB
- **Inject_v2.x:** 889 Zeilen, 37 KB (−50%)

## Architektur

```
┌─────────────────────────────────────────────────┐
│ Section 1: Globals & Telemetrie (Zeile 1–71)    │
├─────────────────────────────────────────────────┤
│ Section 2: Decoder (72–239)                     │
│   - WS → NAL-Queue → VT-Session → g_latestFrame │
├─────────────────────────────────────────────────┤
│ Section 3: Pixel-Helpers (240–392)              │
│   - Rotation/Scale/Range (vImage)               │
├─────────────────────────────────────────────────┤
│ Section 4: In-place Swap (393–565)              │
│   - Preview-Pfad: Original-Buffer modifizieren  │
├─────────────────────────────────────────────────┤
│ Section 5: Separate Buffer (566–698)            │
│   - Photo-Pfad: Neuer CVPixelBuffer/SampleBuffer│
├─────────────────────────────────────────────────┤
│ Section 6: Hooks (699–735)                      │
│   - BWImageQueueSinkNode (Preview)              │
│   - BWPhotoEncoderNode (Photo) ← NEU            │
│   - BWQuickTimeMovieFileSinkNode (Recording)    │
├─────────────────────────────────────────────────┤
│ Section 7: Status-Server (736–800)              │
├─────────────────────────────────────────────────┤
│ Section 8: WS-Client (801–889)                  │
├─────────────────────────────────────────────────┤
│ Section 9: Constructor (890–925)                │
└─────────────────────────────────────────────────┘
```

## Offene Punkte (wie in Übergabe dokumentiert)

1. **Photo-Hi-Res-Scale** (Zeile 653–658)
   - Aktuell: nur same-size (1920x1080 → 1920x1080)
   - TODO: 4032x3024 (Sensor) → 1920x1080 (Encoder) Scale
   - Übergabe Sektion 12: "FotoEncoder-/HI_RES-Pfad separat implementieren"

2. **Recording-Handoff** (Zeile 728–735)
   - Nur Beobachtung (`g_recordingCalls++`)
   - Übergabe Sektion 12: "fmt=0 deutet auf anderen Handoff"
   - Erst Laufzeit-Korrelation, dann Replacement

3. **Audio-E2E** (nicht implementiert)
   - Server sendet `type:audio`, Tweak empfängt es nicht
   - Übergabe Sektion 12: "fehlt als vollständiger E2E-Pfad"

4. **flip_v** (nicht implementiert)
   - Server unterstützt es nicht (server.py:143)
   - Übergabe Sektion 7: "fehlt aktuell"

## Build & Test

```bash
# V2 bauen
cd C:/Users/shosh/VCamUSB/tweak
make -f Makefile_v2 clean package

# Paket liegt in packages/com.shosh.vcaminject_v2_*.deb

# Auf iPhone installieren (via SSH/iproxy)
scp -P 2222 packages/*.deb root@127.0.0.1:/var/root/
ssh -p 2222 root@127.0.0.1
dpkg -i /var/root/com.shosh.vcaminject_v2_*.deb
killall -9 mediaserverd
# → mediaserverd startet automatisch neu, Dylib lädt

# Status prüfen
echo "status" | nc 127.0.0.1 8769
# → sollte "build=v2-clean-2026-09-15 enabled=1" zeigen

# Preview testen
# → Native Kamera-App öffnen, sollte PC-Bild zeigen

# Photo testen
# → Foto aufnehmen, sollte PC-Bild verwenden (nicht Original-Kamera)
```

## Nächste Schritte (Priorität)

1. **Photo-Hi-Res-Scale implementieren** (höchste Priorität)
   - `buildReplacementSampleBuffer()` erweitern für 4032x3024 → 1920x1080
   - Rotation/Crop wie Preview-Pfad

2. **Recording-Sink identifizieren**
   - Laufzeit-Counter beobachten: welcher Sink feuert bei Video-Recording?
   - Dann Replacement analog Photo-Pfad

3. **Audio-Handoff**
   - Nach stabilem Video/Foto
   - Separates Mini-Projekt

4. **V2 vs. V1 parallel testen**
   - Beide Pakete bauen, auf iPhone installieren
   - Bei Erfolg: V1 entfernen, V2 als `Inject.x` committen
