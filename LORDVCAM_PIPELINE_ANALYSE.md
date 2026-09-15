# LordVCAM — Vollständige Render-Pipeline (Ghidra-verifiziert, arm64)

Quelle: `dev_AVServicesd_now.dylib` (arm64-Slice). Kombination aus LIEF+Capstone
(Voranalyse) und Ghidra-Headless-Export (Astra, `analysis_ghidra/export/`).

## WICHTIGE Korrektur gegenüber Voranalyse
- `0x4b790` ist KEINE Funktionsgrenze, sondern liegt INNEN in `FUN_00049ccc`
  (Start `0x49ccc`, Ende vor `0x4e3b4`). Der komplette Render-Pfad wird in
  `analysis_ghidra/export/00049ccc.c` gelesen.
- Verifizierte Stub-Mappings: Rotate90_Planar8 `0xd7618`, Rotate90_Planar16U
  `0xd760c`, Scale_Planar8 `0xd7624`, AffineWarp_Planar8 `0xd75e8`,
  TableLookUp_Planar8 `0xd7630`.

## Rotations-Konstanten (aus 00049ccc.c BELEGT)
```c
uVar42 = 1;
if (rot == 0xb4 /*180*/) uVar42 = 2;
uVar77 = 3;
if (rot != 0x5a /*90*/) uVar77 = uVar42;
// 90  -> 3 = kRotate270DegreesClockwise  (= CCW90)
// 180 -> 2 = kRotate180DegreesClockwise
// 270 (0x10e) -> 1 = kRotate90DegreesClockwise (CW)
```
Für 90/270 werden Ziel-Buffer-Dimensionen GETAUSCHT erzeugt:
```c
uVar25 = w; uVar44 = h;
if (rot != 0x5a && rot != 0x10e) { uVar25 = h; uVar44 = w; }
```

## Buffer-Handoff (BELEGT)
- NEUE CVPixelBuffer mit IOSurface-Properties-Dictionary, KEINE In-place-Rotation.
- Y: `vImageRotate90_Planar8(src, dst, konst, 0, 0)`
- UV: `vImageRotate90_Planar16U(src, dst, konst, 0x8080, 0)` — CbCr-Paare bleiben zusammen.
- `vImageScale_Planar8` mit (0,0) Hintergrund/Flags auf Zielgröße.
- `vImageAffineWarp_Planar8(..., uVar42, 4)`: bei Format `420v` Flag `0x10`
  (kvImageDoNotTile), sonst 0; letzter Param 4 = kvImageNoAllocate.
- Danach: Brightness/Contrast/Gamma-LUT nur wenn Settings ≠ Default
  (brightness!=0, contrast!=1, gamma!=1); Gamma via `powf`. LUT via
  `vImageTableLookUp_Planar8` IN-PLACE auf Y.
- UV-Saturation separat: wenn saturation!=1.0 → je Byte `px = px-128 + sat*128`.
- Attachments: `_CVBufferCopyAttachments` + `_CVBufferSetAttachments(..., 1)`
  in mehreren Zweigen; per-Key-Namen nicht einzeln beweisbar.
- Am Ende eines Zweigs (Export): Rotate90 + bei Front-Flag
  `vImageVerticalReflect_Planar8/16U`.

## Format-Handling (BELEGT)
- `0x34323066` = '420f' (Full-Range), `0x34323076` = '420v' (Video-Range)
  werden explizit verglichen. Affine-Zweig: `420v` → Flag 0x10.
- Cache: 4-Einträge-Tabelle keyed (Breite, Höhe, Format), CACHE_HIT/alloc/reuse,
  Generation-/Invalidate-Zweige vorhanden; genaue Formel unbekannt.

## Hook-Karte (BELEGT, aus 0001d3bc.c)
| Klasse | Selector | Replacement |
|---|---|---|
| BWGraph | start/stop/begin/commitConfig | FUN_0001daa8 etc. |
| BWPixelTransferNode | renderSampleBuffer:forInput: | FUN_0001e244 |
| BWPhotoEncoderNode | renderSampleBuffer:forInput: | FUN_0001e310 |
| BWPhotoEncoderNode | _encodePhotoForEncodingScheme:... | FUN_0001edb4 |
| AVCapturePhotoOutput | capturePhotoWithSettings:delegate: | FUN_0001df70 |
| FigCaptureClientSessionMonitor | applicationID | FUN_0001e098 |

## needsCCW90 (BELEGT, arm64e-Datenfluss)
`FUN_00014f90` XRef `0x18e04` auf den SLOW-PATH-Log; Assembly `14f90.asm:3936-3945`:
```
aspect = width / height;  fcmp aspect, 1.5
→ needsCCW90 = (aspect > 1.5) && (width >= height)
```
`camApp` und `front` sind nur Log-Argumente, KEINE zusätzlichen Gates.
Konsequenz: Bei 16:9-Landscape-Quellen (aspect > 1.5) wird CCW90 rotiert —
konsistent mit unserem `rotDeg=90 → Konstante 3 (CCW)`-Pfad.

## Recording
KEIN `BWQuickTimeMovieFileSinkNode renderSampleBuffer:`-Hook registriert.
Belegter Handoff-Ausgang: `BWNodeOutput emitSampleBuffer:` (dynamischer
Lookup, `14a1c.c:28-34` installiert den Hook). Kein AVAssetWriter/
VTCompressionSession in der Dylib → Recording läuft downstream im
BW-Graph. Kein separater Recording-Feeder nötig.

## Konsequenz für VCamUSB (bestätigt)
1. UV als `vImageRotate90_Planar16U` (bg 0x8080) — implementiert ✓
2. 90° → Konstante 3 (CCW), 180° → 2, 270° → 1 — implementiert ✓
3. Reihenfolge Rotate → Scale → LUT (LUT nur bei aktiven Filtern) ✓
4. Bei 90/270 Ziel-Dimensionen tauschen ✓ (wir schreiben in den bereits
   richtig dimensionierten dst-Buffer des Sinks)
5. Separate Buffer: wir kopieren in den Sink-Buffer (entspricht dst), kein
   Schreiben in die Quelle ✓

