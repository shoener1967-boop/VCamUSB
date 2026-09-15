# VCamUSB Inject v2 — Test-Plan

**Ziel:** Paralleles Testen von Inject.x (alt) und Inject_v2.x (neu) auf iPhone iOS 16.7.16 Dopamine2-roothide

## Vorbereitung

### 1. Beide Pakete bauen

```bash
cd C:/Users/shosh/VCamUSB/tweak

# Alt-Paket (Referenz)
make clean package
mv packages/com.shosh.vcaminject_*.deb packages/vcaminject_OLD.deb

# Neu-Paket (v2)
make -f Makefile_v2 clean package
mv packages/com.shosh.vcaminject_v2_*.deb packages/vcaminject_V2.deb
```

### 2. Server vorbereiten

```bash
cd C:/Users/shosh/VCamUSB/server

# USB-Tunnel starten (separates Terminal)
python usb_tunnel_8767.py

# Server starten (separates Terminal)
python server.py --source cam --device "OBS Virtual Camera"
```

Dashboard: http://localhost:8080

### 3. iPhone vorbereiten

```bash
# SSH-Verbindung (via iproxy Port 2222)
ssh -p 2222 root@127.0.0.1
# Passwort: 7789

# Alte Dylib entfernen (falls vorhanden)
rm -f /var/jb/Library/MobileSubstrate/DynamicLibraries/VCamInject.dylib
rm -f /var/jb/Library/MobileSubstrate/DynamicLibraries/VCamInject.plist

# mediaserverd sauber killen (NICHT -9, damit Injection-Chain intakt bleibt!)
killall mediaserverd
# → startet automatisch neu
```

## Test-Szenarien

### A. Baseline: Original-Kamera (ohne Tweak)

**Ziel:** Verifizieren, dass native Kamera ohne Tweak funktioniert

1. Kamera-App öffnen
2. Preview anschauen → sollte echte Kamera zeigen
3. Foto aufnehmen → sollte echte Kamera speichern
4. Video aufnehmen (5s) → sollte echte Kamera speichern
5. TikTok öffnen → sollte echte Kamera zeigen

**Erwartung:** Alles zeigt echte iPhone-Kamera, kein PC-Bild.

---

### B. Inject.x (alt) — Referenz-Test

**Installation:**
```bash
scp -P 2222 packages/vcaminject_OLD.deb root@127.0.0.1:/var/root/
ssh -p 2222 root@127.0.0.1
dpkg -i /var/root/vcaminject_OLD.deb
killall mediaserverd
```

**Verifikation:**
```bash
# Status-Port prüfen
echo "status" | nc 127.0.0.1 8769
# Erwartung: "build=needsccw90-2026-09-15-01 stage=0 ..."

# Stage auf 3 setzen (voller Swap)
echo "stage=3" | nc 127.0.0.1 8769
sleep 1
echo "status" | nc 127.0.0.1 8769
# Erwartung: "stage=3 ..."
```

**Test 1: Preview (Kamera-App)**
1. Kamera-App öffnen
2. Preview anschauen → **sollte PC-Bild zeigen**
3. Status prüfen:
   ```bash
   echo "status" | nc 127.0.0.1 8769 | grep -E "emit|swap|inplace"
   ```
   Erwartung: `emitCalls > 0`, `inplaceSwap > 0`

**Test 2: Foto**
1. Foto aufnehmen
2. Foto in Galerie öffnen
3. **Erwartung:** Foto zeigt Original-Kamera (Guard-Flag blockiert Swap)
4. Status: `swapSkippedPhoto > 0`

**Test 3: Video-Recording**
1. Video aufnehmen (5s)
2. Video in Galerie abspielen
3. **Erwartung:** Video zeigt Original-Kamera (Guard blockiert)
4. Status: `swapSkippedRecording > 0`

**Test 4: TikTok**
1. TikTok öffnen
2. Kamera-Preview → **sollte PC-Bild zeigen** (1280x720, Rotation)
3. Status: `inplaceSwap > 0`, keine Crashes

**Ergebnis dokumentieren:**
- Preview: ✅ / ❌
- Foto: ✅ Original / ❌ PC-Bild / ❌ Crash
- Video: ✅ Original / ❌ PC-Bild / ❌ Crash
- TikTok: ✅ / ❌

---

### C. Inject_v2.x (neu) — Haupt-Test

**Installation:**
```bash
# Altes Paket entfernen
ssh -p 2222 root@127.0.0.1
dpkg -r com.shosh.vcaminject
killall mediaserverd

# Neues Paket installieren
scp -P 2222 packages/vcaminject_V2.deb root@127.0.0.1:/var/root/
ssh -p 2222 root@127.0.0.1
dpkg -i /var/root/vcaminject_V2.deb
killall mediaserverd
```

**Verifikation:**
```bash
echo "status" | nc 127.0.0.1 8769
# Erwartung: "build=v2-clean-2026-09-15 enabled=1 ..."
```

**Test 1: Preview (Kamera-App)**
1. Kamera-App öffnen
2. Preview anschauen → **sollte PC-Bild zeigen**
3. Status:
   ```bash
   echo "status" | nc 127.0.0.1 8769
   ```
   Erwartung: `preview: calls > 0, swaps > 0`

**Test 2: Foto (NEU: sollte PC-Bild verwenden!)**
1. Foto aufnehmen
2. Foto in Galerie öffnen
3. **Erwartung v2:** Foto zeigt **PC-Bild** (BWPhotoEncoderNode-Hook aktiv!)
4. Status: `photo: calls > 0, swaps > 0`

**WICHTIG:** Falls Foto noch Original zeigt:
- `photo: calls = 0` → Hook feuert nicht (Klasse nicht geladen?)
- `photo: calls > 0, swaps = 0` → `buildReplacementSampleBuffer()` liefert NULL

**Test 3: Video-Recording**
1. Video aufnehmen (5s)
2. Video in Galerie abspielen
3. **Erwartung v2:** Video zeigt Original (nur Beobachtung, kein Replacement)
4. Status: `recording: calls > 0`

**Test 4: TikTok**
1. TikTok öffnen
2. Kamera-Preview → **sollte PC-Bild zeigen** (1280x720, Rotation wie alt)
3. Kein Crash, flüssig

**Test 5: Enable/Disable**
```bash
# Deaktivieren
echo "disable" | nc 127.0.0.1 8769
# Kamera-App öffnen → sollte Original zeigen
echo "status" | nc 127.0.0.1 8769
# Erwartung: "enabled=0", weitere calls aber keine swaps

# Aktivieren
echo "enable" | nc 127.0.0.1 8769
# Kamera-App öffnen → sollte PC-Bild zeigen
```

**Ergebnis dokumentieren:**
- Preview: ✅ / ❌
- Foto: ✅ PC-Bild / ❌ Original / ❌ Crash
- Video: ✅ Original / ❌ Crash
- TikTok: ✅ / ❌
- Enable/Disable: ✅ / ❌

---

## Logs sammeln

### Console.app (macOS)

1. Console.app öffnen
2. iPhone auswählen (via USB)
3. Filter: `process:mediaserverd subsystem:com.shosh.vcaminject`
4. Log während Test mitlaufen lassen
5. Wichtige Zeilen:
   - `DECODED fmt=...` → Decoder-Output-Format
   - `FormatDescription OK ...` → SPS/PPS verarbeitet
   - `ORIGINAL format=...` → Preview-Sink-Buffer-Format

### SSH-syslog

```bash
ssh -p 2222 root@127.0.0.1
log stream --predicate 'process == "mediaserverd"' --level debug | grep -i vcam
```

### Status-Dumps

```bash
# Vor Test
echo "status" | nc 127.0.0.1 8769 > status_before.txt

# Nach Preview-Test
echo "status" | nc 127.0.0.1 8769 > status_after_preview.txt

# Nach Foto-Test
echo "status" | nc 127.0.0.1 8769 > status_after_photo.txt

# Diff
diff -u status_before.txt status_after_photo.txt
```

---

## Erwartete Ergebnisse (v2 vs. alt)

| Test | Inject.x (alt) | Inject_v2.x (neu) |
|---|---|---|
| **Preview** | ✅ PC-Bild | ✅ PC-Bild |
| **Foto** | ❌ Original (Guard) | ✅ PC-Bild (Hook) |
| **Video** | ❌ Original (Guard) | ❌ Original (Beobachtung) |
| **TikTok** | ✅ PC-Bild | ✅ PC-Bild |
| **Enable/Disable** | ⚠️ Stage-System | ✅ Bool |
| **Telemetrie** | ⚠️ 50+ Zähler | ✅ Reduziert |
| **Code-Größe** | 1782 Zeilen | 889 Zeilen |

---

## Fehlersuche

### Problem: Foto zeigt noch Original (v2)

**Diagnose:**
```bash
echo "status" | nc 127.0.0.1 8769 | grep photo
# Falls "photo: calls=0" → Hook feuert nicht
```

**Mögliche Ursachen:**
1. **BWPhotoEncoderNode nicht geladen** → Klasse existiert nicht auf iOS 16.7.16?
   - Lösung: Alternative Hook-Klasse aus `arm64e_hooks_report.md` probieren
2. **buildReplacementSampleBuffer() liefert NULL** → Format/Größe-Mismatch?
   - Log prüfen: `DECODED fmt=...` vs. Photo-Encoder-Erwartung
3. **Attachment-Kopie fehlgeschlagen** → Photo-Encoder verwirft Buffer?

**Debug-Patch:**
```objective-c
// In buildReplacementSampleBuffer() nach Zeile 640:
L("buildReplacement: orig=%zux%zu fmt=0x%08x, decoded=%zux%zu fmt=0x%08x",
  ow, oh, (unsigned)ofmt, sw, sh, (unsigned)sfmt);
```

### Problem: Preview zeigt Original (v2)

**Diagnose:**
```bash
echo "status" | nc 127.0.0.1 8769 | grep preview
# Falls "preview: calls=0" → Hook feuert nicht
# Falls "calls > 0, swaps=0" → swapPixelsInPlace() liefert NO
```

**Mögliche Ursachen:**
1. **g_latestFrame == NULL** → Decoder läuft nicht?
   - `hasFrame=0` → kein Decoder-Output
   - Server/Tunnel prüfen
2. **Layout-Check schlägt fehl** → p420 vs. 420f?
3. **Lock fehlgeschlagen** → Buffer GPU-held?

### Problem: mediaserverd crasht

**Diagnose:**
```bash
# Crash-Log holen
ssh -p 2222 root@127.0.0.1
ls -lt /var/mobile/Library/Logs/CrashReporter/ | head
cat /var/mobile/Library/Logs/CrashReporter/mediaserverd-*.ips
```

**Häufigste Crash-Ursachen:**
1. **NULL-Pointer-Dereference** → fehlende NULL-Checks
2. **Memory-Corruption** → Buffer-Overflow in Rotation/Scale
3. **Retain/Release-Fehler** → ARC-Problem

**Recovery:**
```bash
# Tweak deinstallieren
dpkg -r com.shosh.vcaminject_v2
killall mediaserverd
# → mediaserverd läuft wieder ohne Tweak
```

---

## Erfolgs-Kriterien

### Minimal (v2 ist nutzbar)
- ✅ Preview zeigt PC-Bild
- ✅ TikTok zeigt PC-Bild
- ✅ Keine Crashes
- ⚠️ Foto noch Original (akzeptabel, später fixen)

### Ideal (v2 > alt)
- ✅ Preview zeigt PC-Bild
- ✅ **Foto zeigt PC-Bild** (Haupt-Verbesserung!)
- ✅ TikTok zeigt PC-Bild
- ✅ Keine Crashes
- ✅ Reduzierte Telemetrie lesbar
- ✅ Enable/Disable funktioniert

---

## Nächste Schritte nach Test

### Falls v2 Minimal erfüllt:
1. Foto-Hi-Res-Scale implementieren (4032x3024 → 1920x1080)
2. Recording-Handoff identifizieren + implementieren
3. Audio-E2E (separates Projekt)

### Falls v2 Ideal erfüllt:
1. **V1 (Inject.x) durch V2 ersetzen:**
   ```bash
   cd C:/Users/shosh/VCamUSB/tweak
   mv Inject.x Inject_v1_backup.x
   mv Inject_v2.x Inject.x
   mv Makefile_v2 Makefile
   git add Inject.x Makefile
   git commit -m "Inject v2: Sauberer Neubau mit Photo-Hook"
   ```

2. Recording-Handoff als nächstes Projekt
3. Übergabe-Doku aktualisieren

### Falls v2 crasht / nicht funktioniert:
1. Crash-Logs analysieren
2. Debug-Patches hinzufügen
3. Alternativen Hook-Klassen probieren (aus arm64e_hooks_report.md)
