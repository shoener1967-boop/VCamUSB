# LordVCAM — Vollständige Demaskierung (statische Analyse)

Quelle: `dev_AVServicesd_now.dylib` (2.9 MB, arm64, vom iPhone gezogen)
Werkzeuge: LIEF 1.0 + Capstone (PC-seitig), Strings + ObjC-Sektions-Analyse

## Kernbefund

LordVCAM registriert KEIN neues `AVCaptureDevice`. Es hookt die komplette
BW-Capture-Graph-Kette in `mediaserverd` und ersetzt dort Frames. Deshalb wirkt
es für alle Apps wie eine virtuelle Kamera, ohne dass eine neue Device-ID auftaucht.

## Gehookte Klassen (aus __cstring, eindeutig)

- `BWNode`                      — Basis-Node
- `BWNodeOutput`                — Haupt-Frame-Punkt (emitSampleBuffer:) ← WIR HABEN NUR DIESEN
- `BWGraph`                     — Capture-Graph
- `BWStillImageScalerNode`      — Foto-Skalierung
- `BWPhotoEncoderNode`          — Foto-Encoding
- `BWPixelTransferNode`         — Pixel-Transfer / Format-Konvertierung
- `BWMetadataSourceNode`        — Metadaten
- `BWVideoOrientationMetadataNode` — Rotation/Orientierung
- `BWMetadataDetectorGatingNode`
- `FigCapture`                  — Client-Verwaltung
- `FigCaptureClientSessionMonitor` — Client-Session-Tracking
- `AVCapturePhotoOutput`        — Foto-Ausgabe
- `AVCaptureConnection`

## Gehookte Methoden (Selektoren, belegt)

Frame-Zustellung:
- `emitSampleBuffer:`
- `sendMediaServerdSampleAtPoint:`
- `markEndOfLiveOutput`
- `shouldDeferBWNodeInvalidation`

Foto:
- `capturePhotoWithSettings:delegate:`
- `_addThumbnailForEncodingScheme:thumbnailPixelBuffer:metadata:...`
- `_addAuxImagesIfNeededForEncodingScheme:sampleBuffer:metadata:...`

## Eigene Hook-Hilfsfunktionen (VC*)

- `VCInitSpringBoard`
- `VCApplyFTENoise`            (Film-Noise/Grain)
- `VCCopyPB`                   (PixelBuffer-Kopie)
- `VCInvalidateCacheEntries`
- `VCInvalidateCacheRendered`
- `VCInvalidateHookCacheEntries`
- `VCInvalidateSourceBuffers`
- `VCMapPicker`
- `VCHandleMenuShortcut`

## Flüssigkeits-Mechanismus (warum LordVCAM ruckelfrei ist)

Metal-Render-Pipeline statt CPU-Kopie:
- `MTLCommandQueue`, `nv12Pipeline`, `bgraPipeline`
- `renderNV12Pipeline`, `renderBGRAtoNV12Pipeline`
- `renderSampleBuffer:forInput:`
- `blendNV12:to:output:width:height:alpha:invAlpha:`
- `blendBGRA:to:output:...`

Frame-Store / Ring-Puffer:
- `storeLatestFrame:`, `latestFrame`, `lastBlendedBuffer`, `streamBlendBuffer`
- `framesCachedReturn`, `framesAdvanced`, `fpsFrameCount`

Strategie-Klassen (pro Modus):
- `VCPipelineStrategy`, `VCDefaultStrategy`
- `renderResolutionForSource:mode:`
- `backpressureInFlightThresholdForMode:`
- `backpressureOutstandingMaxForMode:`
- `staleFrameDropThresholdForMode:`
- `gpuTimeoutNsForMode:`

## Eigene Framework-Klassen (AVS*)

AVSStreamTransport, AVSFrameCoordinator, AVSLocalDataProvider, AVSRemoteDataProvider,
AVSMediaDecoder (eigener H.264-Decoder), AVSFormatAnalyzer, AVSRenderPipeline,
AVSDisplayLayer, AVSLocalTransport, AVSAudioBridge, AVSServiceConfiguration

## Imports, die den Mechanismus belegen

- `MSHookMessageEx` (ObjC-Hooks)
- `VTDecompressionSessionCreate` + `DecodeFrameWithOutputHandler` (eigener H.264-Decoder)
- `VTPixelTransferSessionCreate` + `TransferImage` (Pixel-Transfer/Format-Wandlung)
- `vImage*` (Skalierung/Rotation)
- `CMSampleBufferCreateForImageBuffer` / `CreateReady` (neuer SampleBuffer)
- `IOSurface*` (Zero-Copy-Shared-Memory)
- `CVMetalTextureCache*` (Metal-Textur-Cache)
- `CVBufferPropagateAttachments` (Attachments erhalten!)

## Schlussfolgerung für VCamUSB

Unser Ansatz ist richtig (mediaserverd + BWNodeOutput), aber unvollständig:

1. Wir hooken NUR `BWNodeOutput.emitSampleBuffer:` — LordVCAM hookt zusätzlich
   BWGraph, BWPixelTransferNode, BWStillImageScalerNode, BWPhotoEncoderNode,
   BWVideoOrientationMetadataNode → deckt Foto/Video/Rotation ab.

2. Wir kopieren Pixel per CPU (memcpy) — LordVCAM nutzt Metal-Pipeline →
   ruckelfrei bei 60fps, keine CPU-Last.

3. Wir haben keinen Frame-Store/Ring-Puffer — LordVCAM hält `latestFrame`
   + blendet, was Ruckeln bei Paket-Jitter vermeidet.

4. Wir propagieren keine CVBuffer-Attachments — LordVCAM nutzt
   `CVBufferPropagateAttachments`.

## Nächste Schritte (Priorität)

1. `BWPixelTransferNode` hooken → deckt Format-Konvertierung ab (Foto/Video-Formate)
2. `BWStillImageScalerNode` + `BWPhotoEncoderNode` → Foto-Pfad
3. Frame-Store (letzter Frame halten) + monotone PTS → Flüssigkeit
4. Optional: Metal-Pipeline statt CPU-Kopie
