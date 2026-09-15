# VCamUSB v2 — Sauberer Neubau: Zusammenfassung

**Erstellt:** 2026-09-15  
**Basis:** Verifizierter LordVCAM arm64e-Ablauf (PROJEKT_UEBERGABE_KOMPLETT.md, ASTRA_VERIFIKATION_ERGEBNIS.md)

---

## Was wurde erstellt

### 1. Inject_v2.x (889 Zeilen, −50% Code)

**Neue Datei:** `C:/Users/shosh/VCamUSB/tweak/Inject_v2.x`

**Architektur (9 Sections):**
```
1. Globals & Telemetrie        (reduziert auf Essentials)
2. Decoder                      (AVCC, 420f, aus alt übernommen)
3. Pixel-Helpers                (Rotation/Scale/Range, LordVCAM-Stil)
4. In-place Pixel-Swap          (Preview-Pfad, wie alt)
5. Separate-Buffer-Handoff      (Photo-Pfad, NEU!)
6. Hooks                        (Preview/Photo/Recording)
7. Status-Server                (Port 8769, vereinfacht)
8. WS-Client                    (aus alt übernommen)
9. Constructor                  (ohne Diagnose-Overhead)
```

**Hauptverbesserungen:**
- ✅ **BWPhotoEncoderNode-Hook** (Zeile 704–721) → Foto sollte jetzt PC-Bild verwenden
- ✅ **buildReplacementSampleBuffer()** (Zeile 572–698) → Separater Buffer + Attachments
- ✅ **Einfaches Enable/Disable** → `g_enabled` Bool statt Stage-System
- ✅ **Reduzierte Telemetrie** → Preview/Photo/Recording + Decoder, keine 50+ Zähler mehr

**Entfernt:**
- ❌ Stage-System 0–3
- ❌ FigCaptureClientSessionMonitor-Hooks (feuern nie)
- ❌ buildSwapSampleBuffer + Passthrough-Modi
- ❌ Testmuster/wrap_orig-Debug-Modi
- ❌ Hunderte tote Telemetrie-Zähler
- ❌ Methodendump/Wildcard-Scan

### 2. Makefile_v2

**Neue Datei:** `C:/Users/shosh/VCamUSB/tweak/Makefile_v2`

Baut `VCamInject_v2.dylib` mit Paket-ID `com.shosh.vcaminject_v2` (parallel zum alten installierbar).

### 3. Dokumentation

**INJECT_V2_CHANGES.md** — Änderungslog, Architektur, offene Punkte  
**TEST_PLAN_V2.md** — Vollständiger Test-Plan für paralleles Testen alt vs. neu

---

## Nächster Schritt: Testen

### Build & Installation

```bash
cd C:/Users/shosh/VCamUSB/tweak

# V2 bauen
make -f Makefile_v2 clean package

# Auf iPhone installieren
scp -P 2222 packages/com.shosh.vcaminject_v2_*.deb root@127.0.0.1:/var/root/
ssh -p 2222 root@127.0.0.1
dpkg -i /var/root/com.shosh.vcaminject_v2_*.deb
killall mediaserverd
```

### Schnelltest

```bash
# Server starten (separates Terminal)
cd C:/Users/shosh/VCamUSB/server
python usb_tunnel_8767.py &
python server.py --source cam --device "OBS Virtual Camera"

# Status prüfen (auf iPhone via SSH)
echo "status" | nc 127.0.0.1 8769
# Erwartung: "build=v2-clean-2026-09-15 enabled=1"

# Kamera-App öffnen
# → Preview sollte PC-Bild zeigen

# Foto aufnehmen
# → WICHTIG: Foto sollte jetzt PC-Bild verwenden (nicht Original!)
#   Falls Foto noch Original zeigt: photo: calls=? swaps=? prüfen
```

### Kritische Tests

1. **Preview** → PC-Bild (wie alt)
2. **Foto** → **PC-Bild** (NEU, Haupt-Verbesserung!)
3. **TikTok** → PC-Bild mit Rotation (wie alt)
4. **Keine Crashes** → mediaserverd stabil

Vollständiger Test-Plan: `TEST_PLAN_V2.md`

---

## Offene Punkte (dokumentiert in INJECT_V2_CHANGES.md)

### 1. Photo-Hi-Res-Scale (TODO)

**Problem:** `buildReplacementSampleBuffer()` unterstützt aktuell nur same-size (Zeile 653–658).

**Foto-Sensor:** 4032x3024 (12MP)  
**Decoder-Output:** 1920x1080

**Lösung:** Scale/Crop-Logik aus Preview-Pfad (Zeile 520–563) in `buildReplacementSampleBuffer()` integrieren.

### 2. Recording-Handoff (offen)

**Status:** `BWQuickTimeMovieFileSinkNode` nur Beobachtung (Zeile 728–735).

**Übergabe:** "fmt=0 deutet auf anderen Handoff — erst Laufzeit-Korrelation."

**Nächster Schritt:** Counter beobachten, echten Movie-Bildpfad identifizieren.

### 3. Audio-E2E (offen)

Server sendet `type:audio`, Tweak empfängt es nicht. Separates Projekt nach stabilem Video/Foto.

### 4. flip_v (offen)

Server unterstützt es nicht (server.py:143).

---

## Vergleich: V1 vs. V2

| Metrik | Inject.x (alt) | Inject_v2.x (neu) |
|---|---|---|
| **Zeilen** | 1782 | 889 (−50%) |
| **Dateigröße** | 81 KB | 37 KB |
| **Preview-Swap** | ✅ In-place | ✅ In-place |
| **Foto-Replacement** | ❌ Guard-Flag (Original) | ✅ Hook (PC-Bild) |
| **Recording** | ❌ Guard-Flag (Original) | ⚠️ Beobachtung (Original) |
| **TikTok** | ✅ | ✅ (sollte gleich sein) |
| **Enable/Disable** | ⚠️ Stage 0–3 | ✅ Bool |
| **Telemetrie** | ⚠️ 50+ Zähler | ✅ Reduziert |
| **Overhead** | ⚠️ Diagnose/Dump/Stage | ✅ Minimal |

---

## Erfolgs-Kriterien

### Minimal (v2 ist nutzbar)
- ✅ Preview zeigt PC-Bild
- ✅ TikTok zeigt PC-Bild
- ✅ Keine Crashes
- ⚠️ Foto noch Original → akzeptabel, später fixen

### Ideal (v2 besser als v1)
- ✅ Preview zeigt PC-Bild
- ✅ **Foto zeigt PC-Bild** ← Haupt-Verbesserung
- ✅ TikTok zeigt PC-Bild
- ✅ Keine Crashes
- ✅ Reduzierte Telemetrie lesbar
- ✅ Enable/Disable funktioniert

---

## Was du jetzt machen solltest

### Option A: Sofort testen (empfohlen)

1. **Build:**
   ```bash
   cd C:/Users/shosh/VCamUSB/tweak
   make -f Makefile_v2 clean package
   ```

2. **Installieren:**
   ```bash
   scp -P 2222 packages/*.deb root@127.0.0.1:/var/root/
   ssh -p 2222 root@127.0.0.1
   dpkg -i /var/root/com.shosh.vcaminject_v2_*.deb
   killall mediaserverd
   ```

3. **Schnelltest:** Kamera-App öffnen + Foto aufnehmen

4. **Ergebnis melden:**
   - Preview: ✅ / ❌
   - Foto: ✅ PC-Bild / ❌ Original / ❌ Crash
   - TikTok: ✅ / ❌

### Option B: Code-Review zuerst

`Inject_v2.x` durchlesen, speziell:
- **Zeile 572–698:** `buildReplacementSampleBuffer()` (Photo-Pfad)
- **Zeile 704–721:** `BWPhotoEncoderNode`-Hook
- **Zeile 393–565:** `swapPixelsInPlace()` (Preview-Pfad, unverändert)

Fragen/Änderungswünsche → ich patche sofort.

### Option C: Paralleles Testen (sicherste Methode)

Vollständigen Test-Plan abarbeiten (`TEST_PLAN_V2.md`):
1. Baseline ohne Tweak
2. Inject.x (alt) als Referenz
3. Inject_v2.x (neu) vs. Referenz
4. Logs sammeln, Diff

---

## Zusammenfassung

**Erstellt:**
- ✅ `Inject_v2.x` (889 Zeilen, sauberer Neubau)
- ✅ `Makefile_v2` (paralleles Build)
- ✅ `INJECT_V2_CHANGES.md` (Änderungslog)
- ✅ `TEST_PLAN_V2.md` (vollständiger Test-Plan)
- ✅ Diese Zusammenfassung

**Haupt-Verbesserung:**
BWPhotoEncoderNode-Hook → Foto sollte jetzt PC-Bild verwenden (nicht mehr nur Preview).

**Nächster Schritt:**
Bauen, installieren, testen. Bei Erfolg → Recording-Handoff als nächstes Projekt.

**Frage an dich:**
Willst du sofort bauen und testen, oder soll ich noch was am Code ändern/ergänzen?
