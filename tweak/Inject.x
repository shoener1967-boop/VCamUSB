// VCamInject — Frame-Swap in mediaserverd (Dopamine2-roothide)
//
// ---------------------------------------------------------------- Build-ID für Artefakt-Identifikation
#define VCAM_BUILD_ID "needsccw90-2026-09-15-01"

// Pipeline: WS-Client (8767) → NAL-Queue → H.264-Decode (VideoToolbox, AVCC)
//           → CVPixelBuffer → buildSwapSampleBuffer → FigCapture-Hook
//
// TELEMETRIE: Status-Server auf 127.0.0.1:8769 liefert atomare Zähler.
//   rxNal sps pps idr formatDesc decodeSubmit decodeOutput decodeError
//   emitCalls sendCalls buildCalls swapCount origCount hasLatestFrame
//
// WICHTIG (Decoder-Fix): Der PC sendet rohe NALs OHNE Startcode. Die
// Format-Description wird als AVCC erstellt (lengthSize=4). Deshalb müssen
// die Samples ebenfalls AVCC-formatiert sein: [4-Byte-Länge][NAL] — NICHT
// Annex-B (00 00 00 01). Vorher wurde Annex-B-Startcode an eine AVCC-Desc
// übergeben → Decoder lieferte nie Frames.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <stdatomic.h>
#import <time.h>
#import <os/log.h>
#import <pthread.h>

#define WS_PORT 8767
#define STATUS_PORT 8769

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.shosh.vcaminject", "inject"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- Telemetrie (atomar)
static _Atomic uint64_t g_wsBinaryCount = 0;
static _Atomic uint64_t g_wsTextCount = 0;
static _Atomic uint64_t g_wsBytesReceived = 0;
static _Atomic uint64_t g_wsFramesDropped = 0;
static _Atomic uint64_t g_rxNalCount = 0;
static _Atomic uint64_t g_spsCount = 0;
static _Atomic uint64_t g_ppsCount = 0;
static _Atomic uint64_t g_idrCount = 0;
static _Atomic uint64_t g_formatDescCount = 0;
static _Atomic uint64_t g_decodeSubmitCount = 0;
static _Atomic uint64_t g_decodeOutputCount = 0;
static _Atomic uint64_t g_decodeErrorCount = 0;
static _Atomic uint64_t g_emitCalls = 0;
static _Atomic uint64_t g_sendCalls = 0;
static _Atomic uint64_t g_buildCalls = 0;
static _Atomic uint64_t g_swapCount = 0;
static _Atomic uint64_t g_swapSizeMismatch = 0;
static _Atomic uint64_t g_origCount = 0;
static _Atomic uint64_t g_hasLatestFrame = 0;
static _Atomic uint64_t g_vtSessionAttempts = 0;
static _Atomic int64_t g_vtSessionError = 0;
static char g_methodDump[4096] = {0};
static char g_methodDump2[4096] = {0};
static char g_copyClasses[4096] = {0};
static char g_sinkClasses[8192] = {0};
static char g_selectorDump[8192] = {0};

// Modus-Steuerung über WS-Textnachrichten (Marker-Dateien funktionieren nicht,
// weil mediaserverd eine andere /tmp-Sicht hat als die SSH-Shell!)
static _Atomic int g_modeBW = 1;
static _Atomic int g_replacementEnabled = 1;
static _Atomic int g_photoInProgress = 0;
static _Atomic int g_recordingInProgress = 0;
static _Atomic uint64_t g_swapSkippedPhoto = 0;
static _Atomic uint64_t g_swapSkippedRecording = 0;
static _Atomic int g_modeWrapOrig = 0;
static _Atomic int g_modeTestPattern = 0;
static _Atomic int g_modeFigEmit = 0;
static _Atomic int g_modeFigSend = 0;
static _Atomic uint64_t g_figEmitReplacements = 0;
static _Atomic uint64_t g_figSendReplacements = 0;

// ---------------------------------------------------------------- Stufen-Isolation (Astra)
// stage 0: passiv — nur Status-Server, Hook läuft NICHT aktiv, kein WS/Decoder
// stage 1: BWNodeOutput-Hook passiv (Pro-Objekt-Telemetrie, KEIN Pixel-Swap)
// stage 2: zusätzlich WS-Client + Decoder aktiv (weiterhin KEIN Swap)
// stage 3: voller in-place Pixel-Swap
// Steuerung über TCP-Status-Port 8769: "stage=N" (unabhängig von WS/Hub!)
static _Atomic int g_stage = 0;

// ---------------------------------------------------------------- Sink-Beobachtung (Astra: Video-/Recording-/Foto-Pfade)
// Aus syslog_full.txt verifizierte echte Sink-Klassen in mediaserverd:
//   BWImageQueueSinkNode           -> renderSampleBuffer:forInput:  (PREVIEW, "Did display first frame")
//   BWQuickTimeMovieFileSinkNode   -> Recording-Pfad
//   BWStillImageSampleBufferSinkNode -> Foto-Pfad
static _Atomic uint64_t g_iqCalls = 0;
static _Atomic uint64_t g_iqWithImage = 0;
static _Atomic uint64_t g_iqSwaps = 0;
static _Atomic int64_t g_iqWidth = 0, g_iqHeight = 0, g_iqFmt = 0, g_iqSurf = 0;
static _Atomic uint64_t g_qtCalls = 0;
static _Atomic int64_t g_qtWidth = 0, g_qtHeight = 0, g_qtFmt = 0, g_qtSurf = 0;
static _Atomic uint64_t g_stCalls = 0;
static _Atomic int64_t g_stWidth = 0, g_stHeight = 0, g_stFmt = 0, g_stSurf = 0;

// Orientierungs-/Attachment-Diagnose (Astra: am Original-SampleBuffer des
// BWImageQueueSinkNode auslesen, um Rotation/Transform zu verstehen).
static char g_orientDump[4096] = {0};
static _Atomic int64_t g_orientDumped = 0;
// Zwei getrennte Dumps: Porträt-Größen 750x1000 (Foto) und 750x1334 (Video).
static char g_orientDump_video[4096] = {0};
static _Atomic int64_t g_orientDumped_video = 0;

// ---------------------------------------------------------------- Globals
static NSMutableArray<NSData *> *g_nalQueue = nil;
static NSLock *g_queueLock = nil;
static VTDecompressionSessionRef g_vtSession = NULL;
static CMFormatDescriptionRef g_fmtDesc = NULL;
static CVPixelBufferRef g_latestFrame = NULL;
static NSLock *g_frameLock = nil;

static void enqueueNal(NSData *nal) {
    if (nal.length < 4) return;
    [g_queueLock lock];
    [g_nalQueue addObject:nal];
    if (g_nalQueue.count > 128) [g_nalQueue removeObjectsInRange:NSMakeRange(0, g_nalQueue.count - 128)];
    [g_queueLock unlock];
}

static NSData *dequeueNal(void) {
    NSData *nal = nil;
    [g_queueLock lock];
    if (g_nalQueue.count) {
        nal = g_nalQueue.firstObject;
        [g_nalQueue removeObjectAtIndex:0];
    }
    [g_queueLock unlock];
    return nal;
}
// ---------------------------------------------------------------- Decoder
static _Atomic int64_t g_decodedFormat = 0;
static _Atomic int64_t g_decodedWidth = 0;
static _Atomic int64_t g_decodedHeight = 0;
static _Atomic int64_t g_decodedStride0 = 0;
static _Atomic int64_t g_decodedStride1 = 0;

static void decompressionOutputCallback(void *refCon, void *srcRef,
    OSStatus status, VTDecodeInfoFlags info, CVPixelBufferRef imageBuffer,
    CMTime pts, CMTime duration) {
    if (status != noErr) {
        atomic_fetch_add(&g_decodeErrorCount, 1);
        return;
    }
    if (!imageBuffer) return;
    atomic_fetch_add(&g_decodeOutputCount, 1);

    // Einmalig: tatsächliches Decoder-Output-Format messen (nicht raten)
    if (atomic_load(&g_decodedFormat) == 0) {
        OSType fmt = CVPixelBufferGetPixelFormatType(imageBuffer);
        size_t w = CVPixelBufferGetWidth(imageBuffer);
        size_t h = CVPixelBufferGetHeight(imageBuffer);
        size_t s0 = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);
        size_t s1 = CVPixelBufferGetPlaneCount(imageBuffer) > 1
            ? CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1) : 0;
        atomic_store(&g_decodedFormat, (int64_t)fmt);
        atomic_store(&g_decodedWidth, (int64_t)w);
        atomic_store(&g_decodedHeight, (int64_t)h);
        atomic_store(&g_decodedStride0, (int64_t)s0);
        atomic_store(&g_decodedStride1, (int64_t)s1);
        L("DECODED fmt=0x%08x (%c%c%c%c) %zux%zu stride=%zu/%zu",
          (unsigned)fmt, (int)(fmt>>24)&0xff, (int)(fmt>>16)&0xff,
          (int)(fmt>>8)&0xff, (int)fmt&0xff, w, h, s0, s1);
    }

    [g_frameLock lock];
    if (g_latestFrame) CVPixelBufferRelease(g_latestFrame);
    g_latestFrame = CVPixelBufferRetain(imageBuffer);
    [g_frameLock unlock];
    atomic_store(&g_hasLatestFrame, 1);
}

static void pumpDecoder(void) {
    @autoreleasepool {
        NSData *msg = dequeueNal();   // jetzt: SPS/PPS (roh) ODER komplette AU (AVCC)
        if (!msg) return;
        const uint8_t *bytes = (const uint8_t *)msg.bytes;
        uint8_t nalType = bytes[0] & 0x1f;

        atomic_fetch_add(&g_rxNalCount, 1);

        // SPS/PPS: rohe NAL, erstes Byte 0x67 (SPS) / 0x68 (PPS)
        if (nalType == 7 || nalType == 8) {
            if (nalType == 7) atomic_fetch_add(&g_spsCount, 1);
            else atomic_fetch_add(&g_ppsCount, 1);

            static NSMutableData *sps, *pps;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ sps = [NSMutableData data]; pps = [NSMutableData data]; });

            // Nur bei ÄNDERUNG speichern + Session neu aufbauen
            BOOL changed = NO;
            if (nalType == 7) {
                if (![sps isEqualToData:msg]) { [sps setData:msg]; changed = YES; }
            } else {
                if (![pps isEqualToData:msg]) { [pps setData:msg]; changed = YES; }
            }

            if (changed && sps.length && pps.length) {
                if (g_vtSession) { VTDecompressionSessionInvalidate(g_vtSession); CFRelease(g_vtSession); g_vtSession = NULL; }
                if (g_fmtDesc) { CFRelease(g_fmtDesc); g_fmtDesc = NULL; }

                const uint8_t *ptrs[2] = { (const uint8_t *)sps.bytes, (const uint8_t *)pps.bytes };
                size_t sizes[2] = { sps.length, pps.length };
                OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    kCFAllocatorDefault, 2, ptrs, sizes, 4, &g_fmtDesc);
                if (st == noErr && g_fmtDesc) {
                    atomic_fetch_add(&g_formatDescCount, 1);
                    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(g_fmtDesc);
                    L("FormatDescription OK %dx%d", (int)dims.width, (int)dims.height);
                } else {
                    L("FormatDescription FAIL: %d", (int)st);
                }
            }
            return;
        }

        // Komplette AU (AVCC: [4-byte len][NAL]...). NAL-Typ aus erster NAL nach Längenpräfix.
        if (g_fmtDesc == NULL) return;   // ohne SPS/PPS keine Decode möglich

        // --- VT-Session anlegen ---
        if (g_vtSession == NULL) {
            atomic_fetch_add(&g_vtSessionAttempts, 1);
            VTDecompressionOutputCallbackRecord cb;
            cb.decompressionOutputCallback = decompressionOutputCallback;
            cb.decompressionOutputRefCon = NULL;
            NSDictionary *attrs = @{
                (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            };
            OSStatus st = VTDecompressionSessionCreate(kCFAllocatorDefault, g_fmtDesc, NULL,
                (__bridge CFDictionaryRef)attrs, &cb, &g_vtSession);
            if (st != noErr || !g_vtSession) {
                atomic_store(&g_vtSessionError, st);
                L("VT-Session FAIL: %d", (int)st);
                return;
            }
            L("Decode-Session OK");
        }

        // AU ist bereits AVCC-formatiert -> direkt als BlockBuffer
        size_t auLen = (size_t)msg.length;
        uint8_t *blockBuf = malloc(auLen);
        if (!blockBuf) return;
        memcpy(blockBuf, msg.bytes, auLen);

        CMBlockBufferRef bb = NULL;
        OSStatus bbSt = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, blockBuf, auLen,
            kCFAllocatorDefault, NULL, 0, auLen, 0, &bb);
        if (bbSt != kCMBlockBufferNoErr || !bb) {
            L("BlockBuffer FAIL: %d", (int)bbSt);
            free(blockBuf);
            return;
        }

        // Samplegröße explizit angeben (Astras Korrektur)
        CMSampleTimingInfo timing = {
            .duration = CMTimeMake(1, 30),
            .presentationTimeStamp = CMTimeMake((int64_t)atomic_load(&g_decodeSubmitCount), 30),
            .decodeTimeStamp = kCMTimeInvalid,
        };
        size_t sampleSize = auLen;
        CMSampleBufferRef sb = NULL;
        OSStatus sbSt = CMSampleBufferCreate(kCFAllocatorDefault, bb, true, NULL, NULL, g_fmtDesc,
            1, 1, &timing, 1, &sampleSize, &sb);
        CFRelease(bb);
        if (sbSt != noErr || !sb) {
            L("SampleBuffer FAIL: %d", (int)sbSt);
            return;
        }
        atomic_fetch_add(&g_decodeSubmitCount, 1);
        VTDecompressionSessionDecodeFrame(g_vtSession, sb, 0, NULL, NULL);
        CFRelease(sb);
    }
}

// ---------------------------------------------------------------- Frame-Swap (PASSTHROUGH)
// LordVCAM-Referenz: Decoder-Buffer DIREKT durchreichen, kein Kopieren/Skalieren.
// PC encodiert dafür nativ 1440x1080. Retain+Lock für sichere Lifetime.

static _Atomic int64_t g_passthroughAttempts = 0;
static _Atomic int64_t g_passthroughCreated = 0;
static _Atomic int64_t g_passthroughFailures = 0;
static _Atomic int64_t g_passthroughOrig = 0;

// ---------------------------------------------------------------- Testmuster
// Wenn /tmp/vcam_testpattern existiert, wird statt des Decoder-Frames ein
// konstantes 1440x1080-420f-Graubild (Y=100, Cb=128, Cr=128) eingespeist.
// Das isoliert den Handoff-Pfad vom Decoder/Bitstream.
static CVPixelBufferRef g_testPattern = NULL;
static _Atomic int64_t g_testPatternUsed = 0;

static CVPixelBufferRef makeTestPattern(void) {
    NSDictionary *attrs = @{
        (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (__bridge id)kCVPixelBufferWidthKey: @(1440),
        (__bridge id)kCVPixelBufferHeightKey: @(1080),
        (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge id)kCVPixelBufferBytesPerRowAlignmentKey: @64,
    };
    CVPixelBufferRef pb = NULL;
    CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, 1440, 1080,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        (__bridge CFDictionaryRef)attrs, &pb);
    if (!pb) return NULL;

    // Diagnose: ist der Buffer IOSurface-backed?
    IOSurfaceRef surf = CVPixelBufferGetIOSurface(pb);
    L("Testmuster: IOSurface=%s (id=%u)", surf ? "JA" : "NEIN",
      surf ? IOSurfaceGetID(surf) : 0);
    size_t s0 = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    size_t s1 = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    L("Testmuster: stride=%zu/%zu", s0, s1);

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t yS = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    size_t uvS = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);

    for (size_t r = 0; r < h; r++) memset(y + r * yS, 100, w);
    for (size_t r = 0; r < h / 2; r++) {
        uint8_t *row = uv + r * uvS;
        for (size_t x = 0; x < w; x += 2) {
            row[x] = 128;      // Cb
            row[x + 1] = 128;  // Cr
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

// ---------------------------------------------------------------- Range-Shift (deaktiviert, entfernt)
// War ein In-Place-/Kopie-Shift, der den Decoder destabilisiert hat. Passthrough nutzt ihn nicht.

// ---------------------------------------------------------------- In-place Pixel-Swap (LordVCAM-Stil)
// Kopiert die Pixel von g_latestFrame in den ORIGINALEN CVPixelBuffer und lässt
// den original CMSampleBuffer (Timing/Attachments/Pool) komplett unangetastet.
// Das vermeidet den Crash, den ein NEUER SampleBuffer bei TikTok/WebRTC auslöst.
#import <Accelerate/Accelerate.h>

static _Atomic uint64_t g_inplaceSwap = 0;
static _Atomic uint64_t g_inplaceMismatch = 0;
static _Atomic uint64_t g_inplaceLockFail = 0;
static _Atomic uint64_t g_inplaceScaled = 0;
static _Atomic int64_t g_misDstFmt = 0, g_misDstW = 0, g_misDstH = 0;
static _Atomic int64_t g_misSrcFmt = 0, g_misSrcW = 0, g_misSrcH = 0;
static _Atomic int64_t g_fmtDumped = 0;

// Range-Helfer: Full->Video (219/224/255) und Video->Full.
// Ganzzahlig, keine Floats in der Hot-Loop.
static inline uint8_t fullToVideoY(uint8_t v)   { return (uint8_t)(((219u * v) / 255u) + 16u); }
static inline uint8_t fullToVideoC(uint8_t v)   { return (uint8_t)(((224u * v) / 255u) + 16u); }
static inline uint8_t videoToFullY(uint8_t v)   { return (uint8_t)((255u * (uint32_t)(v - 16u)) / 219u); }
static inline uint8_t videoToFullC(uint8_t v)   { return (uint8_t)((255u * (uint32_t)(v - 16u)) / 224u); }
typedef uint8_t (*ConvFn)(uint8_t);

// NV12 biplanar: Y-Plane + interleaved UV-Plane skalieren (Center-Crop).
// srcW/srcH = Quellgröße, dstW/dstH = Zielgröße. Stride-aware Zeilen-Kopie.
// NULL-safe: bei ungültigen Zeigern sofort abbrechen (kein Crash).
// conv: Range-Konvertierung pro Byte (NULL = 1:1 kopieren).
static void scaleNV12Plane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                           uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                           size_t cropX, size_t cropY, size_t cropW, size_t cropH,
                           ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    if (!cropW || !cropH) return;
    if (cropX + cropW > srcW || cropY + cropH > srcH) return;
    for (size_t y = 0; y < dstH; y++) {
        size_t sy = cropY + (y * cropH) / dstH;
        // KEIN cropX in der Zeilenbasis — sx addiert ihn exakt einmal.
        const uint8_t *srcRow = sp + sy * srcStride;
        uint8_t *dstRow = dp + y * dstStride;
        for (size_t x = 0; x < dstW; x++) {
            size_t sx = cropX + (x * cropW) / dstW;
            uint8_t v = srcRow[sx];
            dstRow[x] = conv ? conv(v) : v;
        }
    }
}

// UV-Plane in NV12 ist interleaved CbCr: 2 Bytes pro Pixel. Nicht byteweise skalieren!
// NULL-safe wie Y-Plane. conv für beide Bytes (Cb und Cr getrennt anwenden).
static void scaleNV12UVPlane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                             uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                             size_t cropX, size_t cropY, size_t cropW, size_t cropH,
                             ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    if (!cropW || !cropH) return;
    if (cropX + cropW > srcW || cropY + cropH > srcH) return;
    for (size_t y = 0; y < dstH; y++) {
        size_t sy = cropY + (y * cropH) / dstH;
        // KEIN cropX*2 in der Zeilenbasis — sx addiert exakt einmal.
        const uint8_t *srcRow = sp + sy * srcStride;
        uint8_t *dstRow = dp + y * dstStride;
        for (size_t x = 0; x < dstW; x++) {
            size_t sx = cropX + (x * cropW) / dstW;
            size_t srcOff = sx * 2;
            size_t dstOff = x * 2;
            uint8_t cb = srcRow[srcOff];
            uint8_t cr = srcRow[srcOff + 1];
            dstRow[dstOff] = conv ? conv(cb) : cb;           // Cb
            dstRow[dstOff + 1] = conv ? conv(cr) : cr;       // Cr
        }
    }
}

// 90°-Rotation via Accelerate/vImage — exakt LordVCAM-Pfad 2 (Disassembly verifiziert):
// Y:  vImageRotate90_Planar8  (bg 0)
// UV: vImageRotate90_Planar16U (bg 0x8080, CbCr-Paare bleiben zusammen!)
// Danach Scale, zuletzt LUT in-place auf dst (Range).
// Reihenfolge: Rotate90 -> Scale -> TableLookUp (LordVCAM 0x4d634/0x4d6c4/0x4d898)

// (makeLUT entfernt — Range-LUT wird direkt in rotateScalePlane erzeugt)

// Rotiert src (srcW x srcH) um 90° in einen TEMP-Buffer (srcH x srcW),
// skaliert dann auf dst (dstW x dstH), danach LUT in-place auf dst (Range).
// rotConst: vImage-Rotationskonstante (LordVCAM-Pfad 2):
//   rotDeg=90  -> 3 = kRotate270DegreesClockwise  (= 90° CCW)
//   rotDeg=180 -> 2 = kRotate180DegreesClockwise
//   rotDeg=270 -> 1 = kRotate90DegreesClockwise   (= 90° CW)
static void rotateScalePlane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                             uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                             uint8_t rotConst, ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    // Nach 90°: output width=srcH, output height=srcW.
    size_t rotW = srcH;
    size_t rotH = srcW;
    size_t tmpRowBytes = rotW;
    if (rotW > SIZE_MAX / rotH) return;
    uint8_t *tmp = malloc(tmpRowBytes * rotH);
    if (!tmp) return;
    // LordVCAM: vImage_Buffer height/width vertauscht gepflegt — hier:
    // src.height=srcH, src.width=srcW, rowBytes=srcStride (echte Stride!).
    vImage_Buffer srcBuf = { (void *)sp, srcH, srcW, srcStride };
    vImage_Buffer tmpBuf = { tmp, rotH, rotW, tmpRowBytes };
    vImage_Buffer dstBuf = { dp, dstH, dstW, dstStride };
    vImage_Error err = vImageRotate90_Planar8(&srcBuf, &tmpBuf, rotConst, 0, kvImageNoFlags);
    if (err != kvImageNoError) { free(tmp); return; }
    // Skalieren auf Ziel (LordVCAM: Scale NACH Rotate)
    err = vImageScale_Planar8(&tmpBuf, &dstBuf, NULL, kvImageNoFlags);
    if (err != kvImageNoError) { free(tmp); return; }
    // Range-Konvertierung zuletzt, in-place auf dst (LordVCAM: vImageTableLookUp in-place)
    if (conv) {
        static uint8_t lutY[256]; static BOOL lutYInit = NO;
        if (!lutYInit) { for (int i = 0; i < 256; i++) lutY[i] = conv((uint8_t)i); lutYInit = YES; }
        vImageTableLookUp_Planar8(&dstBuf, &dstBuf, lutY, kvImageNoFlags);
    }
    free(tmp);
}

// UV-Plane: interleaved CbCr, halbe Auflösung. LordVCAM rotiert sie als
// vImageRotate90_Planar16U mit background=0x8080 (neutrales CbCr-Paar) —
// dadurch bleiben CbCr-Paare zusammen. Danach byteweise Skalierung auf dst
// (2 Bytes/Pixel; Cb und Cr bekommen identische Behandlung).
static void rotateScaleUVPlane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                               uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                               uint8_t rotConst, ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    size_t rotW = srcH, rotH = srcW;
    if (rotW > SIZE_MAX / rotH) return;
    uint8_t *tmp = malloc(rotW * rotH * 2);
    if (!tmp) return;
    // 16-bit-Pixel: rowBytes muss gerade und >= width*2 sein
    size_t srcRow = srcStride & ~(size_t)1;
    size_t tmpRow = rotW * 2;
    vImage_Buffer srcBuf = { (void *)sp, srcH, srcW, srcRow };
    vImage_Buffer tmpBuf = { tmp, rotH, rotW, tmpRow };
    // LordVCAM: background 0x8080 für UV (neutrales CbCr)
    vImage_Error err = vImageRotate90_Planar16U(&srcBuf, &tmpBuf, rotConst, 0x8080, kvImageNoFlags);
    if (err != kvImageNoError) { free(tmp); return; }
    // Skalieren auf dst (Integer, interleaved 2-Byte-Pixel, Range inline)
    for (size_t y = 0; y < dstH; y++) {
        size_t ry = y * rotH / dstH;
        uint8_t *dstRow = dp + y * dstStride;
        const uint8_t *srcRow = tmp + ry * tmpRow;
        for (size_t x = 0; x < dstW; x++) {
            size_t rx = x * rotW / dstW;
            uint8_t cb = srcRow[rx * 2];
            uint8_t cr = srcRow[rx * 2 + 1];
            dstRow[x * 2]     = conv ? conv(cb) : cb;
            dstRow[x * 2 + 1] = conv ? conv(cr) : cr;
        }
    }
    free(tmp);
}

static BOOL swapPixelsInPlace(CMSampleBufferRef original) {
    if (!original) return NO;
    CVPixelBufferRef dst = CMSampleBufferGetImageBuffer(original);
    if (!dst) return NO;

    CVPixelBufferRef src = NULL;
    [g_frameLock lock];
    if (g_latestFrame) src = CVPixelBufferRetain(g_latestFrame);
    [g_frameLock unlock];
    if (!src) return NO;

    BOOL ok = NO;
    size_t dw = CVPixelBufferGetWidth(dst);
    size_t dh = CVPixelBufferGetHeight(dst);
    OSType dfmt = CVPixelBufferGetPixelFormatType(dst);
    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    OSType sfmt = CVPixelBufferGetPixelFormatType(src);

    // Einmalig das erste Mismatch-Format festhalten (Diagnose)
    if (!atomic_load(&g_fmtDumped) && (dw != sw || dh != sh || dfmt != sfmt)) {
        atomic_store(&g_fmtDumped, 1);
        atomic_store(&g_misDstFmt, (int64_t)dfmt);
        atomic_store(&g_misDstW, (int64_t)dw);
        atomic_store(&g_misDstH, (int64_t)dh);
        atomic_store(&g_misSrcFmt, (int64_t)sfmt);
        atomic_store(&g_misSrcW, (int64_t)sw);
        atomic_store(&g_misSrcH, (int64_t)sh);
    }

    // Nur NV12/420f/p420 biplanar unterstützen wir aktuell.
    // p420 wird als biplanarer 4:2:0-Kandidat akzeptiert, aber das Layout wird
    // ZUR LAUFZEIT pro Buffer verifiziert (PlaneCount, Strides, Plane-Höhen).
    // Quelle und Ziel müssen NICHT identisch sein (Decoder liefert 420f,
    // Preview-Sink nutzt p420) — beide müssen nur biplanar-420 sein.
    BOOL dst420 = (dfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || dfmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || dfmt == 0x70343230);   // 'p420' (big-endian FourCC)
    BOOL src420 = (sfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || sfmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || sfmt == 0x70343230);

    // Layout-Verifikation: beide Buffer müssen biplanar sein (2 Planes,
    // Y volle Höhe, UV halbe Höhe). Sonst Original durchlassen.
    BOOL layoutOK = NO;
    if (dst420 && src420) {
        size_t dstPlanes = CVPixelBufferGetPlaneCount(dst);
        size_t srcPlanes = CVPixelBufferGetPlaneCount(src);
        if (dstPlanes == 2 && srcPlanes == 2) {
            size_t dYH = CVPixelBufferGetHeightOfPlane(dst, 0);
            size_t dUVH = CVPixelBufferGetHeightOfPlane(dst, 1);
            size_t sYH = CVPixelBufferGetHeightOfPlane(src, 0);
            size_t sUVH = CVPixelBufferGetHeightOfPlane(src, 1);
            layoutOK = (dYH == dh && sYH == sh &&
                        dUVH == (dh + 1) / 2 && sUVH == (sh + 1) / 2);
            if (!layoutOK) {
                // Einmalig pro Format loggen (Diagnose)
                static _Atomic int64_t g_layoutDump = 0;
                if (!atomic_load(&g_layoutDump)) {
                    atomic_store(&g_layoutDump, 1);
                    L("LAYOUT-MISMATCH dst(planes=%zu Y=%zu/%zu UV=%zu/%zu) src(planes=%zu Y=%zu/%zu UV=%zu/%zu) fmt=0x%08x",
                      dstPlanes, dYH, CVPixelBufferGetBytesPerRowOfPlane(dst, 0),
                      dUVH, CVPixelBufferGetBytesPerRowOfPlane(dst, 1),
                      srcPlanes, sYH, CVPixelBufferGetBytesPerRowOfPlane(src, 0),
                      sUVH, CVPixelBufferGetBytesPerRowOfPlane(src, 1),
                      (unsigned)dfmt);
                }
            }
        }
    }

    if (dst420 && src420 && layoutOK) {
        // LOCK-ERFOLG prüfen: schlägt das Lock fehl (z.B. GPU-held Buffer
        // ohne CPU-Zugriff), NICHT auf die Pixel zugreifen — das war der
        // Respring-Crash.
        CVReturn lkDst = CVPixelBufferLockBaseAddress(dst, 0);
        CVReturn lkSrc = CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        if (lkDst != kCVReturnSuccess || lkSrc != kCVReturnSuccess) {
            if (lkDst == kCVReturnSuccess) CVPixelBufferUnlockBaseAddress(dst, 0);
            if (lkSrc == kCVReturnSuccess) CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
            atomic_fetch_add(&g_inplaceLockFail, 1);
            CVPixelBufferRelease(src);
            atomic_fetch_add(&g_inplaceMismatch, 1);
            return NO;
        }

        // Base-Addresses NACH dem Lock holen und prüfen (NULL -> abbrechen)
        const uint8_t *srcY = CVPixelBufferGetBaseAddressOfPlane(src, 0);
        const uint8_t *srcUV = CVPixelBufferGetBaseAddressOfPlane(src, 1);
        uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
        uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
        if (!srcY || !srcUV || !dstY || !dstUV) {
            CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferUnlockBaseAddress(dst, 0);
            atomic_fetch_add(&g_inplaceLockFail, 1);
            CVPixelBufferRelease(src);
            atomic_fetch_add(&g_inplaceMismatch, 1);
            return NO;
        }

        if (dw == sw && dh == sh) {
            // Same-size: stride-aware direkte Kopie (beide Planes)
            for (size_t p = 0; p < 2; p++) {
                const uint8_t *sp = CVPixelBufferGetBaseAddressOfPlane(src, p);
                uint8_t *dp = CVPixelBufferGetBaseAddressOfPlane(dst, p);
                if (!sp || !dp) continue;
                size_t sb = CVPixelBufferGetBytesPerRowOfPlane(src, p);
                size_t db = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
                size_t ph = CVPixelBufferGetHeightOfPlane(dst, p);
                size_t copy = db < sb ? db : sb;
                for (size_t y = 0; y < ph; y++) {
                    memcpy(dp + y * db, sp + y * sb, copy);
                }
            }
            ok = YES;
        } else {
            // Größen-Mismatch. Entscheidung anhand des Orientierungs-Attachments:
            // trägt der Ziel-Buffer "RotationDegrees" != 0, müssen wir rotieren.
            int rotDeg = 0;
            {
                // ShouldNotPropagate: nur DIESEN Buffer lesen, keine veralteten
                // Pool-Attachments (sonst rotiert Foto-Modus fälschlich).
                CFDictionaryRef pbAtts = CVBufferGetAttachments(dst, kCVAttachmentMode_ShouldNotPropagate);
                if (pbAtts) {
                    NSNumber *rd = (__bridge NSNumber *)CFDictionaryGetValue(
                        (CFDictionaryRef)pbAtts, (CFStringRef)@"RotationDegrees");
                    if (rd) rotDeg = [rd intValue];
                }
            }
            // LordVCAM-Fallback (arm64e-Datenfluss BELEGT, 14f90.asm:3936):
            //   needsCCW90 = (aspect > 1.5) && (width >= height)
            // Gemessen an der ZIEL-Buffer-Geometrie (der Buffer, den der
            // Capture-Graph liefert = unser dst). Passt zu den Messungen:
            // TikTok 1280x720 (16:9) -> CCW90, Kamera-App 1440x1080 (4:3) -> keine.
            if (rotDeg == 0) {
                double dstAspect = (double)dw / (double)dh;
                if (dstAspect > 1.5 && dw >= dh) rotDeg = 90;
            }
            // Range-Konvertierung: Quelle Full-Range (420f) -> Ziel Video-Range?
            BOOL srcFullRange = (sfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
            BOOL dstFullRange = (dfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
            ConvFn convY = NULL, convC = NULL;
            if (srcFullRange && !dstFullRange) {
                convY = fullToVideoY;
                convC = fullToVideoC;
            } else if (!srcFullRange && dstFullRange) {
                convY = videoToFullY;
                convC = videoToFullC;
            }

            if (rotDeg != 0) {
                // LordVCAM-Pfad 2 (Disassembly 0x4d590-0x4d5ac, verifiziert):
                //   90°  -> Konstante 3 = kRotate270DegreesClockwise (effektiv CCW)
                //   180° -> Konstante 2 = kRotate180DegreesClockwise
                //   270° -> Konstante 1 = kRotate90DegreesClockwise  (CW)
                uint8_t rotConst = 1;
                if (rotDeg == 90)  rotConst = 3;
                if (rotDeg == 180) rotConst = 2;
                if (rotDeg == 270) rotConst = 1;
                rotateScalePlane(CVPixelBufferGetBaseAddressOfPlane(src, 0),
                              CVPixelBufferGetBytesPerRowOfPlane(src, 0), sw, sh,
                              CVPixelBufferGetBaseAddressOfPlane(dst, 0),
                              CVPixelBufferGetBytesPerRowOfPlane(dst, 0), dw, dh,
                              rotConst, convY);
                rotateScaleUVPlane(CVPixelBufferGetBaseAddressOfPlane(src, 1),
                                CVPixelBufferGetBytesPerRowOfPlane(src, 1), sw / 2, sh / 2,
                                CVPixelBufferGetBaseAddressOfPlane(dst, 1),
                                CVPixelBufferGetBytesPerRowOfPlane(dst, 1), dw / 2, dh / 2,
                                rotConst, convC);
                ok = YES;
                atomic_fetch_add(&g_inplaceScaled, 1);
            } else {
            // KEINE Rotation (gleiche Orientierung): Center-Crop + Skalierung.
            double srcAR = (double)sw / (double)sh;
            double dstAR = (double)dw / (double)dh;
            size_t cropW, cropH, cropX, cropY;
            if (srcAR > dstAR) {
                // Quelle breiter -> horizontal croppen
                cropH = sh;
                cropW = (size_t)(sh * dstAR);
                cropX = (sw - cropW) / 2;
                cropY = 0;
            } else {
                // Quelle höher -> vertikal croppen
                cropW = sw;
                cropH = (size_t)(sw / dstAR);
                cropX = 0;
                cropY = (sh - cropH) / 2;
            }
            // NV12-Chroma: Crop-Koordinaten auf gerade Werte runden (Astra)
            cropX &= ~(size_t)1;
            cropY &= ~(size_t)1;
            cropW &= ~(size_t)1;
            cropH &= ~(size_t)1;
            // Y-Plane (volle Auflösung)
            scaleNV12Plane(CVPixelBufferGetBaseAddressOfPlane(src, 0),
                           CVPixelBufferGetBytesPerRowOfPlane(src, 0), sw, sh,
                           CVPixelBufferGetBaseAddressOfPlane(dst, 0),
                           CVPixelBufferGetBytesPerRowOfPlane(dst, 0), dw, dh,
                           cropX, cropY, cropW, cropH, convY);
            // UV-Plane (halbe Auflösung, interleaved CbCr)
            scaleNV12UVPlane(CVPixelBufferGetBaseAddressOfPlane(src, 1),
                           CVPixelBufferGetBytesPerRowOfPlane(src, 1), sw / 2, sh / 2,
                           CVPixelBufferGetBaseAddressOfPlane(dst, 1),
                           CVPixelBufferGetBytesPerRowOfPlane(dst, 1), dw / 2, dh / 2,
                           cropX / 2, cropY / 2, cropW / 2, cropH / 2, convC);
            ok = YES;
            atomic_fetch_add(&g_inplaceScaled, 1);
            }   // Ende Center-Crop-Zweig
        }

        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(dst, 0);
    } else if (dfmt == sfmt && dw == sw && dh == sh) {
        // Fallback: Nicht-NV12, aber gleiche Größe/Format -> reine Byte-Kopie
        CVPixelBufferLockBaseAddress(dst, 0);
        CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        size_t planes = CVPixelBufferGetPlaneCount(dst);
        if (planes == 0) {
            void *dp = CVPixelBufferGetBaseAddress(dst);
            const void *sp = CVPixelBufferGetBaseAddress(src);
            size_t db = CVPixelBufferGetBytesPerRow(dst);
            size_t sb = CVPixelBufferGetBytesPerRow(src);
            size_t h = CVPixelBufferGetHeight(dst);
            size_t copy = db < sb ? db : sb;
            for (size_t y = 0; y < h; y++) {
                memcpy((uint8_t *)dp + y * db, (const uint8_t *)sp + y * sb, copy);
            }
            ok = YES;
        }
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(dst, 0);
    }

    CVPixelBufferRelease(src);
    if (ok) atomic_fetch_add(&g_inplaceSwap, 1);
    else atomic_fetch_add(&g_inplaceMismatch, 1);
    return ok;
}

static CMSampleBufferRef buildSwapSampleBuffer(CMSampleBufferRef original) {
    atomic_fetch_add(&g_buildCalls, 1);
    atomic_fetch_add(&g_passthroughAttempts, 1);

    BOOL testMode = atomic_load(&g_modeTestPattern) != 0;
    BOOL wrapOrigMode = atomic_load(&g_modeWrapOrig) != 0;

    CVPixelBufferRef px = NULL;
    if (wrapOrigMode) {
        // Astras Test A: Original-PixelBuffer, neuer SampleBuffer
        CVPixelBufferRef origPB = original ? CMSampleBufferGetImageBuffer(original) : NULL;
        if (origPB) px = CVPixelBufferRetain(origPB);
        atomic_fetch_add(&g_testPatternUsed, 1);
    } else if (testMode) {
        if (!g_testPattern) g_testPattern = makeTestPattern();
        if (g_testPattern) px = CVPixelBufferRetain(g_testPattern);
        atomic_fetch_add(&g_testPatternUsed, 1);
    } else {
        // Decoder-Buffer direkt durchreichen (Passthrough, KEIN Range-Shift!)
        [g_frameLock lock];
        if (g_latestFrame) px = CVPixelBufferRetain(g_latestFrame);
        [g_frameLock unlock];
    }
    if (!px) {
        atomic_fetch_add(&g_passthroughOrig, 1);
        return NULL;
    }

    // SICHERHEITS-CHECK: Größe + Pixelformat müssen zum Original passen,
    // sonst crasht die App (TikTok/WebRTC verwerfen oder brechen bei Mismatch).
    CVPixelBufferRef origPB = original ? CMSampleBufferGetImageBuffer(original) : NULL;
    if (origPB) {
        size_t ow = CVPixelBufferGetWidth(origPB);
        size_t oh = CVPixelBufferGetHeight(origPB);
        OSType ofmt = CVPixelBufferGetPixelFormatType(origPB);
        size_t dw = CVPixelBufferGetWidth(px);
        size_t dh = CVPixelBufferGetHeight(px);
        OSType dfmt = CVPixelBufferGetPixelFormatType(px);
        if (ow != dw || oh != dh || ofmt != dfmt) {
            // Mismatch: NICHT ersetzen — Original durchlassen
            CVPixelBufferRelease(px);
            atomic_fetch_add(&g_swapSizeMismatch, 1);
            return NULL;
        }
    }

    // Format-Description aus dem tatsächlichen Decoder-Buffer (nicht raten)
    CMFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, px, &fmt);
    if (st != noErr || !fmt) {
        CVPixelBufferRelease(px);
        atomic_fetch_add(&g_passthroughFailures, 1);
        return NULL;
    }

    // Timing vom Original übernehmen
    CMSampleTimingInfo timing = {
        .duration = original ? CMSampleBufferGetDuration(original) : CMTimeMake(1, 30),
        .presentationTimeStamp = original ? CMSampleBufferGetPresentationTimeStamp(original) : CMTimeMake((int64_t)atomic_load(&g_swapCount), 30),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sb = NULL;
    st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, px, fmt, &timing, &sb);
    CFRelease(fmt);
    CVPixelBufferRelease(px);
    if (st != noErr || !sb) {
        atomic_fetch_add(&g_passthroughFailures, 1);
        return NULL;
    }
    atomic_fetch_add(&g_swapCount, 1);
    atomic_fetch_add(&g_passthroughCreated, 1);
    return sb;
}

// ---------------------------------------------------------------- Handoff-Diagnose
static _Atomic int64_t g_handoffDumped = 0;
// Diagnose-Werte als Globals (über Status-Port abrufbar)
static _Atomic int64_t d_origValid = 0, d_origReady = 0, d_origSamples = 0;
static _Atomic int64_t d_origHasImg = 0, d_origHasData = 0, d_origHasFmt = 0;
static _Atomic int64_t d_origSurfId = 0, d_origSurfSeed = 0;
static _Atomic int64_t d_origFullRange = 0;
static _Atomic int64_t d_replValid = 0, d_replReady = 0, d_replSamples = 0;
static _Atomic int64_t d_replHasImg = 0, d_replHasData = 0, d_replHasFmt = 0;
static _Atomic int64_t d_replSurfId = 0, d_replSurfSeed = 0;
static _Atomic int64_t d_replFullRange = 0;
static char d_hookClass[128] = {0};
static char d_hookEncoding[128] = {0};

__attribute__((unused)) static void dumpHandoff(id sampleBuffer, CMSampleBufferRef replacement) {
    if (atomic_load(&g_handoffDumped)) return;

    CMSampleBufferRef orig = (__bridge CMSampleBufferRef)sampleBuffer;
    if (!orig) return;

    CVPixelBufferRef oImg = CMSampleBufferGetImageBuffer(orig);
    CMBlockBufferRef oData = CMSampleBufferGetDataBuffer(orig);
    CMFormatDescriptionRef oFmt = CMSampleBufferGetFormatDescription(orig);
    IOSurfaceRef oSurf = oImg ? CVPixelBufferGetIOSurface(oImg) : NULL;

    atomic_store(&d_origValid, CMSampleBufferIsValid(orig));
    atomic_store(&d_origReady, CMSampleBufferDataIsReady(orig));
    atomic_store(&d_origSamples, (int64_t)CMSampleBufferGetNumSamples(orig));
    atomic_store(&d_origHasImg, oImg != NULL);
    atomic_store(&d_origHasData, oData != NULL);
    atomic_store(&d_origHasFmt, oFmt != NULL);
    atomic_store(&d_origSurfId, oSurf ? (int64_t)IOSurfaceGetID(oSurf) : 0);
    atomic_store(&d_origSurfSeed, oSurf ? (int64_t)IOSurfaceGetSeed(oSurf) : 0);
    if (oFmt) {
        CFDictionaryRef ext = CMFormatDescriptionGetExtensions(oFmt);
        atomic_store(&d_origFullRange,
            ext && CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_FullRangeVideo) ? 1 : 0);
    }

    CVPixelBufferRef rImg = replacement ? CMSampleBufferGetImageBuffer(replacement) : NULL;
    CMBlockBufferRef rData = replacement ? CMSampleBufferGetDataBuffer(replacement) : NULL;
    CMFormatDescriptionRef rFmt = replacement ? CMSampleBufferGetFormatDescription(replacement) : NULL;
    IOSurfaceRef rSurf = rImg ? CVPixelBufferGetIOSurface(rImg) : NULL;

    atomic_store(&d_replValid, replacement ? CMSampleBufferIsValid(replacement) : 0);
    atomic_store(&d_replReady, replacement ? CMSampleBufferDataIsReady(replacement) : 0);
    atomic_store(&d_replSamples, replacement ? (int64_t)CMSampleBufferGetNumSamples(replacement) : -1);
    atomic_store(&d_replHasImg, rImg != NULL);
    atomic_store(&d_replHasData, rData != NULL);
    atomic_store(&d_replHasFmt, rFmt != NULL);
    atomic_store(&d_replSurfId, rSurf ? (int64_t)IOSurfaceGetID(rSurf) : 0);
    atomic_store(&d_replSurfSeed, rSurf ? (int64_t)IOSurfaceGetSeed(rSurf) : 0);
    if (rFmt) {
        CFDictionaryRef ext = CMFormatDescriptionGetExtensions(rFmt);
        atomic_store(&d_replFullRange,
            ext && CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_FullRangeVideo) ? 1 : 0);
    }

    atomic_store(&g_handoffDumped, 1);
}

static _Atomic int64_t g_hookClassChecked = 0;
__attribute__((unused)) static void dumpHookClass(id self) {
    if (atomic_load(&g_hookClassChecked)) return;
    snprintf(d_hookClass, sizeof(d_hookClass), "%s", object_getClassName(self));
    Class cls = object_getClass(self);
    Method m = class_getInstanceMethod(cls, @selector(emitSampleBuffer:));
    if (m) {
        const char *enc = method_getTypeEncoding(m);
        if (enc) snprintf(d_hookEncoding, sizeof(d_hookEncoding), "%s", enc);
    }
    atomic_store(&g_hookClassChecked, 1);
}
%hook FigCaptureClientSessionMonitor
- (void)emitSampleBuffer:(id)sampleBuffer {
    atomic_fetch_add(&g_emitCalls, 1);
    if (atomic_load(&g_modeFigEmit)) {
        CMSampleBufferRef fake = buildSwapSampleBuffer((__bridge CMSampleBufferRef)sampleBuffer);
        if (fake) {
            atomic_fetch_add(&g_figEmitReplacements, 1);
            %orig((__bridge id)fake);
            CFRelease(fake);
            return;
        }
    }
    %orig;
}

- (void)sendMediaServerdSampleAtPoint:(id)sampleBuffer {
    atomic_fetch_add(&g_sendCalls, 1);
    if (atomic_load(&g_modeFigSend)) {
        CMSampleBufferRef fake = buildSwapSampleBuffer((__bridge CMSampleBufferRef)sampleBuffer);
        if (fake) {
            atomic_fetch_add(&g_figSendReplacements, 1);
            %orig((__bridge id)fake);
            CFRelease(fake);
            return;
        }
    }
    %orig;
}
%end

static _Atomic int64_t g_origPixelFormat = 0;
static _Atomic int64_t g_origWidth = 0;
static _Atomic int64_t g_origHeight = 0;

// Objekt-Instanz-Tracking: struct-Array statt String (kein memmove-Bug)
// NEU (Astra): pro Objekt Format, Größe, IOSurface-ID, letzte PTS.
typedef struct {
    uintptr_t object;
    uint64_t calls;
    uint64_t swaps;
    int64_t lastPTS;
    int64_t width;
    int64_t height;
    int64_t pixelFormat;
    int64_t iosurfaceID;
    char className[96];
} OutputEntry;

static OutputEntry g_outputs[128] = {0};
static pthread_mutex_t g_objMutex = PTHREAD_MUTEX_INITIALIZER;

static void trackObject(id self) {
    uintptr_t object = (uintptr_t)self;
    pthread_mutex_lock(&g_objMutex);
    for (size_t i = 0; i < 128; i++) {
        if (g_outputs[i].object == object) {
            g_outputs[i].calls++;
            pthread_mutex_unlock(&g_objMutex);
            return;
        }
    }
    for (size_t i = 0; i < 128; i++) {
        if (g_outputs[i].object == 0) {
            g_outputs[i].object = object;
            g_outputs[i].calls = 1;
            snprintf(g_outputs[i].className, sizeof(g_outputs[i].className), "%s",
                     object_getClassName(self));
            break;
        }
    }
    pthread_mutex_unlock(&g_objMutex);
}

// Pro-Objekt-Format/-Buffer-Daten aktualisieren (Astra: welcher Output ist sichtbar?)
static void trackObjectFrame(id self, CMSampleBufferRef sb, BOOL didSwap) {
    if (!sb) return;
    uintptr_t object = (uintptr_t)self;
    CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sb);
    if (!px) return;
    pthread_mutex_lock(&g_objMutex);
    for (size_t i = 0; i < 128; i++) {
        if (g_outputs[i].object == object) {
            g_outputs[i].width = (int64_t)CVPixelBufferGetWidth(px);
            g_outputs[i].height = (int64_t)CVPixelBufferGetHeight(px);
            g_outputs[i].pixelFormat = (int64_t)CVPixelBufferGetPixelFormatType(px);
            IOSurfaceRef surf = CVPixelBufferGetIOSurface(px);
            g_outputs[i].iosurfaceID = surf ? (int64_t)IOSurfaceGetID(surf) : -1;
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
            g_outputs[i].lastPTS = (int64_t)pts.value;
            if (didSwap) g_outputs[i].swaps++;
            break;
        }
    }
    pthread_mutex_unlock(&g_objMutex);
}

%hook BWNodeOutput
- (void)emitSampleBuffer:(id)sampleBuffer {
    atomic_fetch_add(&g_emitCalls, 1);
    trackObject(self);
    CMSampleBufferRef orig = (__bridge CMSampleBufferRef)sampleBuffer;
    trackObjectFrame(self, orig, NO);

    int stage = atomic_load(&g_stage);
    // stage 0: nur Zählen, kein weiterer Eingriff
    if (stage == 0) {
        atomic_fetch_add(&g_origCount, 1);
        %orig;
        return;
    }
    // stage 1+2: Telemetrie aktiv, aber KEIN Pixel-Swap
    if (stage < 3) {
        atomic_fetch_add(&g_origCount, 1);
        %orig;
        return;
    }
    if (!atomic_load(&g_modeBW)) {
        %orig;
        return;
    }
    // SICHERHEIT: Während Foto-/Recording-Capture KEIN in-place-Swap.
    // Der Original-Buffer wird dann für Still-/Movie-Verarbeitung weiterverwendet.
    if (!atomic_load(&g_replacementEnabled)) {
        %orig;
        return;
    }
    if (atomic_load(&g_photoInProgress)) {
        atomic_fetch_add(&g_swapSkippedPhoto, 1);
        atomic_fetch_add(&g_origCount, 1);
        %orig;
        return;
    }
    if (atomic_load(&g_recordingInProgress)) {
        atomic_fetch_add(&g_swapSkippedRecording, 1);
        atomic_fetch_add(&g_origCount, 1);
        %orig;
        return;
    }

    // Einmalig: Original-Pixel-Format + Dimensionen erfassen (Diagnose)
    if (atomic_load(&g_origPixelFormat) == 0) {
        CMSampleBufferRef origSB = (__bridge CMSampleBufferRef)sampleBuffer;
        if (origSB) {
            CVPixelBufferRef px = CMSampleBufferGetImageBuffer(origSB);
            if (px) {
                OSType fmt = CVPixelBufferGetPixelFormatType(px);
                size_t w = CVPixelBufferGetWidth(px);
                size_t h = CVPixelBufferGetHeight(px);
                atomic_store(&g_origPixelFormat, (int64_t)fmt);
                atomic_store(&g_origWidth, (int64_t)w);
                atomic_store(&g_origHeight, (int64_t)h);
                L("ORIGINAL format=0x%08x (%c%c%c%c) %zux%zu",
                  (unsigned)fmt, (int)(fmt>>24)&0xff, (int)(fmt>>16)&0xff,
                  (int)(fmt>>8)&0xff, (int)fmt&0xff, w, h);
            }
        }
    }

    // In-place Pixel-Swap: Fake-Pixel in den ORIGINALEN Buffer kopieren,
    // original SampleBuffer (Timing/Attachments) bleibt unangetastet.
    BOOL swapped = swapPixelsInPlace((__bridge CMSampleBufferRef)sampleBuffer);
    if (swapped) {
        trackObjectFrame(self, orig, YES);
        %orig;
        return;
    }

    atomic_fetch_add(&g_origCount, 1);
    %orig;
}
%end

// ---------------------------------------------------------------- Foto-Capture-State-Erkennung
// Setzt g_photoInProgress, damit der Preview-Hook während Still Capture
// NICHT den Original-Buffer in-place überschreibt (Freeze-Vermeidung).
// Da AVCapturePhotoOutput im App-Prozess läuft (nicht mediaserverd), wird
// der Hook hier evtl. nicht feuern. Deshalb zusätzlich zeitbasierter Auto-Reset:
// das Flag bleibt max. 2s aktiv, danach wieder Replacement erlaubt.
static _Atomic int64_t g_photoResetAt = 0;

static void armPhotoGuard(void) {
    atomic_store(&g_photoInProgress, 1);
    atomic_store(&g_photoResetAt, (int64_t)time(NULL) + 2);
    L("Foto-Capture START (Guard 2s)");
}

static void maybeResetPhotoGuard(void) {
    if (atomic_load(&g_photoInProgress) &&
        time(NULL) >= atomic_load(&g_photoResetAt)) {
        atomic_store(&g_photoInProgress, 0);
    }
}

static CMSampleBufferRef buildReplacementSampleBuffer(CMSampleBufferRef original, CVPixelBufferRef pcFrame) {
    size_t w = CVPixelBufferGetWidth(pcFrame);
    size_t h = CVPixelBufferGetHeight(pcFrame);
    OSType fmt = CVPixelBufferGetPixelFormatType(pcFrame);
    
    CVPixelBufferRef newBuf = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES
    };
    CVReturn cvr = CVPixelBufferCreate(NULL, w, h, fmt, (__bridge CFDictionaryRef)attrs, &newBuf);
    if (cvr != kCVReturnSuccess || !newBuf) return NULL;
    
    CVPixelBufferLockBaseAddress(pcFrame, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(newBuf, 0);
    
    size_t planes = CVPixelBufferGetPlaneCount(pcFrame);
    if (planes >= 2) {
        for (size_t p = 0; p < planes; p++) {
            void *src = CVPixelBufferGetBaseAddressOfPlane(pcFrame, p);
            void *dst = CVPixelBufferGetBaseAddressOfPlane(newBuf, p);
            size_t srcStride = CVPixelBufferGetBytesPerRowOfPlane(pcFrame, p);
            size_t dstStride = CVPixelBufferGetBytesPerRowOfPlane(newBuf, p);
            size_t planeH = CVPixelBufferGetHeightOfPlane(pcFrame, p);
            size_t copyW = (srcStride < dstStride) ? srcStride : dstStride;
            for (size_t row = 0; row < planeH; row++) {
                memcpy(dst + row * dstStride, src + row * srcStride, copyW);
            }
        }
    } else {
        void *src = CVPixelBufferGetBaseAddress(pcFrame);
        void *dst = CVPixelBufferGetBaseAddress(newBuf);
        size_t srcStride = CVPixelBufferGetBytesPerRow(pcFrame);
        size_t dstStride = CVPixelBufferGetBytesPerRow(newBuf);
        size_t copyW = (srcStride < dstStride) ? srcStride : dstStride;
        for (size_t row = 0; row < h; row++) {
            memcpy(dst + row * dstStride, src + row * srcStride, copyW);
        }
    }
    
    CVPixelBufferUnlockBaseAddress(newBuf, 0);
    CVPixelBufferUnlockBaseAddress(pcFrame, kCVPixelBufferLock_ReadOnly);
    
    CMSampleBufferRef newSB = NULL;
    CMSampleTimingInfo timing;
    CMSampleBufferGetSampleTimingInfo(original, 0, &timing);
    
    CMVideoFormatDescriptionRef fmt_desc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, newBuf, &fmt_desc);
    if (!fmt_desc) {
        CVPixelBufferRelease(newBuf);
        return NULL;
    }
    
    CMSampleBufferCreateReadyWithImageBuffer(NULL, newBuf, fmt_desc, &timing, &newSB);
    CFRelease(fmt_desc);
    CVPixelBufferRelease(newBuf);
    
    if (newSB) {
        CFDictionaryRef origAttach = CMGetAttachment(original, kCMSampleBufferAttachmentKey_SampleAttachments, NULL);
        if (origAttach) {
            CMSetAttachment(newSB, kCMSampleBufferAttachmentKey_SampleAttachments, origAttach, kCMAttachmentMode_ShouldPropagate);
        }
    }
    
    return newSB;
}

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)settings delegate:(id)delegate {
    armPhotoGuard();
    %orig;
}
- (void)capturePhotoWithSettings:(id)settings delegate:(id)delegate completionHandler:(id)handler {
    armPhotoGuard();
    %orig;
}
%end

// ---------------------------------------------------------------- BWPhotoEncoderNode (Foto-Replacement)
%hook BWPhotoEncoderNode
- (void)renderSampleBuffer:(opaqueCMSampleBuffer *)sbuf forInput:(id)input {
    if (!atomic_load(&g_enabled) || !atomic_load(&g_photoInProgress)) {
        %orig;
        return;
    }
    
    CVPixelBufferRef orig = CMSampleBufferGetImageBuffer(sbuf);
    if (!orig) { %orig; return; }
    
    CVPixelBufferRef pc = NULL;
    [g_frameLock lock];
    if (g_latestFrame) pc = CVPixelBufferRetain(g_latestFrame);
    [g_frameLock unlock];
    
    if (!pc) { %orig; return; }
    
    // Separater Buffer statt In-place (LordVCAM-Stil)
    CMSampleBufferRef replacement = buildReplacementSampleBuffer(sbuf, pc);
    CVPixelBufferRelease(pc);
    
    if (replacement) {
        atomic_fetch_add(&g_photoSwaps, 1);
        %orig(replacement, input);
        CFRelease(replacement);
    } else {
        %orig;
    }
}
%end

// ---------------------------------------------------------------- Status-Server (8769)
static void statusServerThread(void) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) return;
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(STATUS_PORT);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(srv); return; }
    if (listen(srv, 4) < 0) { close(srv); return; }
    L("Status-Server auf 127.0.0.1:%d", STATUS_PORT);
    while (1) {
        int c = accept(srv, NULL, NULL);
        if (c < 0) continue;
        // Kommando lesen (nicht-blockierend): "stage=N", "fulldump", sonst lesen.
        char cmd[64] = {0};
        struct timeval tv = { .tv_sec = 0, .tv_usec = 150000 };
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        ssize_t cr = recv(c, cmd, sizeof(cmd) - 1, 0);
        int wantFullDump = 0;
        if (cr > 0) {
            if (strncmp(cmd, "stage=", 6) == 0) {
                int ns = atoi(cmd + 6);
                if (ns >= 0 && ns <= 3) {
                    atomic_store(&g_stage, ns);
                    L("STAGE jetzt %d", ns);
                }
            } else if (strncmp(cmd, "fulldump", 8) == 0) {
                wantFullDump = 1;
            }
        }
        char msg[16384];
        int w = snprintf(msg, sizeof(msg),
            "build=%s stage=%d\n"
            "rxNal=%llu sps=%llu pps=%llu idr=%llu "
            "wsBin=%llu wsText=%llu wsBytes=%llu "
            "formatDesc=%llu submit=%llu output=%llu errors=%llu "
            "emit=%llu send=%llu figEmitRep=%llu figSendRep=%llu build=%llu swap=%llu swapMismatch=%llu inplace=%llu inplaceMis=%llu inplaceScale=%llu orig=%llu hasFrame=%llu "
            "photoState=%d recState=%d skipPhoto=%llu skipRec=%llu repl=%d "
            "vtAttempts=%llu vtError=%lld\n",
            VCAM_BUILD_ID,
            (int)atomic_load(&g_stage),
            (unsigned long long)atomic_load(&g_rxNalCount),
            (unsigned long long)atomic_load(&g_spsCount),
            (unsigned long long)atomic_load(&g_ppsCount),
            (unsigned long long)atomic_load(&g_idrCount),
            (unsigned long long)atomic_load(&g_wsBinaryCount),
            (unsigned long long)atomic_load(&g_wsTextCount),
            (unsigned long long)atomic_load(&g_wsBytesReceived),
            (unsigned long long)atomic_load(&g_formatDescCount),
            (unsigned long long)atomic_load(&g_decodeSubmitCount),
            (unsigned long long)atomic_load(&g_decodeOutputCount),
            (unsigned long long)atomic_load(&g_decodeErrorCount),
            (unsigned long long)atomic_load(&g_emitCalls),
            (unsigned long long)atomic_load(&g_sendCalls),
            (unsigned long long)atomic_load(&g_figEmitReplacements),
            (unsigned long long)atomic_load(&g_figSendReplacements),
            (unsigned long long)atomic_load(&g_buildCalls),
            (unsigned long long)atomic_load(&g_swapCount),
            (unsigned long long)atomic_load(&g_swapSizeMismatch),
            (unsigned long long)atomic_load(&g_inplaceSwap),
            (unsigned long long)atomic_load(&g_inplaceMismatch),
            (unsigned long long)atomic_load(&g_inplaceScaled),
            (unsigned long long)atomic_load(&g_origCount),
            (unsigned long long)atomic_load(&g_hasLatestFrame),
            (int)atomic_load(&g_photoInProgress),
            (int)atomic_load(&g_recordingInProgress),
            (unsigned long long)atomic_load(&g_swapSkippedPhoto),
            (unsigned long long)atomic_load(&g_swapSkippedRecording),
            (int)atomic_load(&g_replacementEnabled),
            (unsigned long long)atomic_load(&g_vtSessionAttempts),
            (long long)atomic_load(&g_vtSessionError));
        int fw = snprintf(msg + w, sizeof(msg) - w, " origFmt=0x%08x origSize=%lldx%lld decodedFmt=0x%08x decodedSize=%lldx%lld dStride=%lld/%lld pt=%llu/%llu/%llu/%llu\n",
            (unsigned)(long long)atomic_load(&g_origPixelFormat),
            (long long)atomic_load(&g_origWidth),
            (long long)atomic_load(&g_origHeight),
            (unsigned)(long long)atomic_load(&g_decodedFormat),
            (long long)atomic_load(&g_decodedWidth),
            (long long)atomic_load(&g_decodedHeight),
            (long long)atomic_load(&g_decodedStride0),
            (long long)atomic_load(&g_decodedStride1),
            (unsigned long long)atomic_load(&g_passthroughAttempts),
            (unsigned long long)atomic_load(&g_passthroughCreated),
            (unsigned long long)atomic_load(&g_passthroughFailures),
            (unsigned long long)atomic_load(&g_passthroughOrig));
        if (fw > 0) w += fw;
        // Sink-Beobachtung (Preview/Recording/Foto-Pfade)
        fw = snprintf(msg + w, sizeof(msg) - w,
            " SINK iq=%llu iqSwaps=%llu iqFmt=%lldx%lld fmt=0x%08llx surf=%lld | qt=%llu qtFmt=%lldx%lld fmt=0x%08llx surf=%lld | st=%llu stFmt=%lldx%lld fmt=0x%08llx surf=%lld\n",
            (unsigned long long)atomic_load(&g_iqCalls),
            (unsigned long long)atomic_load(&g_iqSwaps),
            (long long)atomic_load(&g_iqWidth), (long long)atomic_load(&g_iqHeight),
            (unsigned long long)atomic_load(&g_iqFmt), (long long)atomic_load(&g_iqSurf),
            (unsigned long long)atomic_load(&g_qtCalls),
            (long long)atomic_load(&g_qtWidth), (long long)atomic_load(&g_qtHeight),
            (unsigned long long)atomic_load(&g_qtFmt), (long long)atomic_load(&g_qtSurf),
            (unsigned long long)atomic_load(&g_stCalls),
            (long long)atomic_load(&g_stWidth), (long long)atomic_load(&g_stHeight),
            (unsigned long long)atomic_load(&g_stFmt), (long long)atomic_load(&g_stSurf));
        if (fw > 0) w += fw;
        if (atomic_load(&g_orientDumped)) {
            int mw = snprintf(msg + w, sizeof(msg) - w, " %s\n", g_orientDump);
            if (mw > 0) w += mw;
        }
        if (atomic_load(&g_orientDumped_video)) {
            int mw = snprintf(msg + w, sizeof(msg) - w, " %s\n", g_orientDump_video);
            if (mw > 0) w += mw;
        }
        if (atomic_load(&g_fmtDumped)) {
            int mw = snprintf(msg + w, sizeof(msg) - w, " MIS dst=0x%08x %lldx%lld src=0x%08x %lldx%lld\n",
                (unsigned)(long long)atomic_load(&g_misDstFmt),
                (long long)atomic_load(&g_misDstW),
                (long long)atomic_load(&g_misDstH),
                (unsigned)(long long)atomic_load(&g_misSrcFmt),
                (long long)atomic_load(&g_misSrcW),
                (long long)atomic_load(&g_misSrcH));
            if (mw > 0) w += mw;
        }
        if (wantFullDump) {
            if (g_methodDump[0]) {
                int mw = snprintf(msg + w, sizeof(msg) - w, "BW: %s\n", g_methodDump);
                if (mw > 0) w += mw;
            }
            if (g_methodDump2[0]) {
                int mw = snprintf(msg + w, sizeof(msg) - w, "FigCap: %s\n", g_methodDump2);
                if (mw > 0) w += mw;
            }
            if (g_copyClasses[0]) {
                int mw = snprintf(msg + w, sizeof(msg) - w, "COPYNEXT: %s\n", g_copyClasses);
                if (mw > 0) w += mw;
            }
            if (g_sinkClasses[0]) {
                int mw = snprintf(msg + w, sizeof(msg) - w, "SINKS: %s\n", g_sinkClasses);
                if (mw > 0) w += mw;
            }
            if (g_selectorDump[0]) {
                int mw = snprintf(msg + w, sizeof(msg) - w, "SELOWNER:\n%s\n", g_selectorDump);
                if (mw > 0) w += mw;
            }
        }
        {
            pthread_mutex_lock(&g_objMutex);
            int used = 0;
            for (int i = 0; i < 128; i++) {
                if (g_outputs[i].object == 0) break;
                used++;
            }
            for (int i = 0; i < used && w < (int)sizeof(msg) - 300; i++) {
                int mw = snprintf(msg + w, sizeof(msg) - w,
                    "OUT[%d]=0x%lx:%s:emits=%llu swaps=%llu %lldx%lld fmt=0x%08llx surf=%lld pts=%lld\n",
                    i, (unsigned long)g_outputs[i].object,
                    g_outputs[i].className,
                    (unsigned long long)g_outputs[i].calls,
                    (unsigned long long)g_outputs[i].swaps,
                    (long long)g_outputs[i].width,
                    (long long)g_outputs[i].height,
                    (unsigned long long)g_outputs[i].pixelFormat,
                    (long long)g_outputs[i].iosurfaceID,
                    (long long)g_outputs[i].lastPTS);
                if (mw > 0) w += mw;
            }
            pthread_mutex_unlock(&g_objMutex);
        }
        if (wantFullDump && atomic_load(&g_handoffDumped)) {
            int mw = snprintf(msg + w, sizeof(msg) - w,
                "HANDOFF orig(v=%lld r=%lld s=%lld img=%lld data=%lld fmt=%lld surf=%lld/%lld fr=%lld) "
                "repl(v=%lld r=%lld s=%lld img=%lld data=%lld fmt=%lld surf=%lld/%lld fr=%lld)\n"
                "HOOKCLASS=%s ENC=%s\n",
                (long long)atomic_load(&d_origValid), (long long)atomic_load(&d_origReady),
                (long long)atomic_load(&d_origSamples),
                (long long)atomic_load(&d_origHasImg), (long long)atomic_load(&d_origHasData),
                (long long)atomic_load(&d_origHasFmt),
                (long long)atomic_load(&d_origSurfId), (long long)atomic_load(&d_origSurfSeed),
                (long long)atomic_load(&d_origFullRange),
                (long long)atomic_load(&d_replValid), (long long)atomic_load(&d_replReady),
                (long long)atomic_load(&d_replSamples),
                (long long)atomic_load(&d_replHasImg), (long long)atomic_load(&d_replHasData),
                (long long)atomic_load(&d_replHasFmt),
                (long long)atomic_load(&d_replSurfId), (long long)atomic_load(&d_replSurfSeed),
                (long long)atomic_load(&d_replFullRange),
                d_hookClass, d_hookEncoding);
            if (mw > 0) w += mw;
        }
        send(c, msg, w, 0);
        close(c);
    }
}

// ---------------------------------------------------------------- WS-Client
// Forward-Declarations (Diagnose-Funktionen liegen weiter unten)
static void dumpWildcardClasses(void);
static void dumpCopyNextClasses(void);
static void logMethodsOfClass(Class cls, const char *className, char *dump);

static BOOL sendAllFD(int fd, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    while (len > 0) {
        ssize_t n = send(fd, p, len > (size_t)INT_MAX ? INT_MAX : (int)len, 0);
        if (n <= 0) return NO;
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

static ssize_t recvHTTPHeaders(int fd, char *buf, size_t cap) {
    size_t used = 0;
    while (used + 1 < cap) {
        ssize_t n = recv(fd, buf + used, cap - used - 1, 0);
        if (n <= 0) return n;
        used += (size_t)n;
        buf[used] = 0;
        if (strstr(buf, "\r\n\r\n")) return (ssize_t)used;
    }
    return -1;
}

static void wsClientThread(void) {
    L("wsClientThread gestartet");
    while (1) {
        L("WS-Verbindungsversuch");
        @autoreleasepool {
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) { L("socket fehlgeschlagen errno=%d %s", errno, strerror(errno)); sleep(2); continue; }
            struct sockaddr_in addr = {0};
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            addr.sin_port = htons(WS_PORT);
            L("vor connect fd=%d", fd);
            if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
                L("connect fehlgeschlagen errno=%d %s", errno, strerror(errno));
                close(fd);
                sleep(2);
                continue;
            }
            L("connect erfolgreich");
            char key[32];
            srand((unsigned)time(NULL));
            for (int i = 0; i < 24; i++) key[i] = "abcdefghijklmnopqrstuvwxyz0123456789"[rand() % 36];
            key[24] = 0;
            char req[512];
            snprintf(req, sizeof(req),
                "GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
                WS_PORT, key);
            if (!sendAllFD(fd, req, strlen(req))) { close(fd); sleep(2); continue; }
            L("Handshake gesendet — warte auf Antwort");
            char resp[2048];
            ssize_t n = recvHTTPHeaders(fd, resp, sizeof(resp));
            L("recvHTTPHeaders n=%zd err=%s", n, n < 0 ? strerror(errno) : "ok");
            if (n > 0) { resp[n < 2048 ? n : 2047] = 0; L("Antwort: %.120s", resp); }
            if (n <= 0 || strstr(resp, "101") == NULL) { close(fd); sleep(2); continue; }
            L("mit Hub verbunden");
            while (1) {
                uint8_t hdr[2];
                ssize_t g = recv(fd, hdr, 2, MSG_WAITALL);
                if (g != 2) break;
                uint8_t opcode = hdr[0] & 0x0f;
                uint8_t masked = (hdr[1] >> 7) & 1;
                uint64_t plen = hdr[1] & 0x7f;
                if (plen == 126) {
                    uint8_t ext[2];
                    if (recv(fd, ext, 2, MSG_WAITALL) != 2) break;
                    plen = ((uint64_t)ext[0] << 8) | ext[1];
                } else if (plen == 127) {
                    uint8_t ext[8];
                    if (recv(fd, ext, 8, MSG_WAITALL) != 8) break;
                    plen = 0;
                    for (int i = 0; i < 8; i++) plen = (plen << 8) | ext[i];
                }
                uint8_t mask[4] = {0};
                if (masked && recv(fd, mask, 4, MSG_WAITALL) != 4) break;
                if (plen > 8 * 1024 * 1024) break;
                uint8_t *payload = malloc((size_t)plen);
                size_t got = 0;
                while (got < plen) {
                    ssize_t r = recv(fd, payload + got, (size_t)(plen - got), 0);
                    if (r <= 0) break;
                    got += (size_t)r;
                }
                if (got < plen) { free(payload); break; }
                if (masked) for (uint64_t i = 0; i < plen; i++) payload[i] ^= mask[i & 3];
                if (opcode == 0x2) {
                    atomic_fetch_add(&g_wsBinaryCount, 1);
                    atomic_fetch_add(&g_wsBytesReceived, plen);
                    enqueueNal([NSData dataWithBytesNoCopy:payload length:(NSUInteger)plen freeWhenDone:YES]);
                } else if (opcode == 0x1) {
                    atomic_fetch_add(&g_wsTextCount, 1);
                    NSString *cmd = [[NSString alloc] initWithBytes:payload length:(NSUInteger)plen encoding:NSUTF8StringEncoding];
                    if (cmd) {
                        if ([cmd isEqualToString:@"mode:wrap_orig"]) {
                            atomic_store(&g_modeWrapOrig, 1);
                            atomic_store(&g_modeTestPattern, 0);
                            L("Modus: WRAP_ORIG");
                        } else if ([cmd isEqualToString:@"mode:testpattern"]) {
                            atomic_store(&g_modeTestPattern, 1);
                            atomic_store(&g_modeWrapOrig, 0);
                            L("Modus: TESTPATTERN");
                        } else if ([cmd isEqualToString:@"mode:bw_off"]) {
                            atomic_store(&g_modeBW, 0);
                            L("Modus: BW_OFF");
                        } else if ([cmd isEqualToString:@"mode:bw_on"]) {
                            atomic_store(&g_modeBW, 1);
                            atomic_store(&g_modeFigEmit, 0);
                            atomic_store(&g_modeFigSend, 0);
                            L("Modus: BW_ON");
                        } else if ([cmd isEqualToString:@"mode:fig_emit"]) {
                            atomic_store(&g_modeBW, 0);
                            atomic_store(&g_modeFigEmit, 1);
                            atomic_store(&g_modeFigSend, 0);
                            L("Modus: FIG_EMIT");
                        } else if ([cmd isEqualToString:@"mode:fig_send"]) {
                            atomic_store(&g_modeBW, 0);
                            atomic_store(&g_modeFigSend, 1);
                            L("Modus: FIG_SEND");
                        } else if ([cmd isEqualToString:@"mode:normal"]) {
                            atomic_store(&g_modeBW, 1);
                            atomic_store(&g_modeFigEmit, 0);
                            atomic_store(&g_modeFigSend, 0);
                            atomic_store(&g_modeWrapOrig, 0);
                            atomic_store(&g_modeTestPattern, 0);
                            L("Modus: NORMAL");
                        } else if ([cmd isEqualToString:@"mode:observe"]) {
                            atomic_store(&g_modeBW, 0);
                            atomic_store(&g_modeFigEmit, 0);
                            atomic_store(&g_modeFigSend, 0);
                            L("Modus: OBSERVE");
                        } else if ([cmd isEqualToString:@"mode:replacement_off"]) {
                            atomic_store(&g_replacementEnabled, 0);
                            L("Modus: REPLACEMENT_OFF");
                        } else if ([cmd isEqualToString:@"mode:replacement_on"]) {
                            atomic_store(&g_replacementEnabled, 1);
                            L("Modus: REPLACEMENT_ON");
                        } else if ([cmd isEqualToString:@"mode:redump"]) {
                            // Diagnose erneut ausführen (nach Kamera-Start, Klassen jetzt geladen)
                            dumpWildcardClasses();
                            logMethodsOfClass(NSClassFromString(@"BWNodeOutput"), "BWNodeOutput", g_methodDump);
                            dumpCopyNextClasses();
                            L("Modus: REDUMP");
                        }
                    }
                    free(payload);
                } else {
                    free(payload);
                }
            }
            close(fd);
            L("Hub-Verbindung verloren — Reconnect in 2s");
        }
        sleep(2);
    }
}

// ---------------------------------------------------------------- Methoden-Diagnose
static void logMethodsOfClass(Class cls, const char *className, char *dump) {
    if (!cls) {
        snprintf(dump, 4096, "%s: KLASSE FEHLT", className);
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    size_t off = 0;
    dump[0] = 0;
    off += snprintf(dump + off, 4096 - off, "%s (%u Methoden): ", className, count);
    for (unsigned int i = 0; i < count && off < 4096 - 200; i++) {
        SEL sel = method_getName(methods[i]);
        const char *name = sel_getName(sel);
        int w = snprintf(dump + off, 4096 - off, "%s; ", name);
        if (w > 0) off += w;
    }
    if (methods) free(methods);
    L("Methoden von %s erfasst", className);
}

// ---------------------------------------------------------------- copyNext-Klassen finden
static Class ClassThatImplementsSelector(Class cls, SEL sel) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        BOOL found = NO;
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(methods[i]) == sel) {
                found = YES;
                break;
            }
        }
        free(methods);
        if (found) return c;
    }
    return Nil;
}

static void dumpCopyNextClasses(void) {
    SEL sel = sel_registerName("copyNextSampleBuffer:");
    int count = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(classes, count);
    size_t off = 0;
    g_copyClasses[0] = 0;
    off += snprintf(g_copyClasses + off, sizeof(g_copyClasses) - off, "copyNext: ");
    int found = 0;
    for (int i = 0; i < count && off < sizeof(g_copyClasses) - 300; i++) {
        Class cls = classes[i];
        Method inherited = class_getInstanceMethod(cls, sel);
        if (inherited) {
            Class impl = ClassThatImplementsSelector(cls, sel);
            int w = snprintf(g_copyClasses + off, sizeof(g_copyClasses) - off,
                "%s(impl=%s)|%s; ", class_getName(cls),
                impl ? class_getName(impl) : "?",
                method_getTypeEncoding(inherited));
            if (w > 0) off += w;
            found++;
        }
    }
    free(classes);
    if (!found) {
        snprintf(g_copyClasses, sizeof(g_copyClasses), "copyNext: KEINE Klasse gefunden (auch nicht geerbt)");
    }
    L("copyNextSampleBuffer: %d Klassen (inkl. geerbt)", found);
}

// ---------------------------------------------------------------- LordVCAM-Selector-Besitzer finden
static void dumpSelectorOwners(void) {
    const char *sels[] = {
        "emitSampleBuffer:",
        "sendMediaServerdSampleAtPoint:",
        "setOriginalDelegate:",
        "emitStillImageReferenceFrameBracketedCaptureSequenceNumberMessageWithSequenceNumber:",
        "emitStillImagePrewarmMessageWithSettings:"
    };
    int nsels = sizeof(sels) / sizeof(sels[0]);
    int count = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(classes, count);
    size_t off = 0;
    g_selectorDump[0] = 0;

    for (int s = 0; s < nsels; s++) {
        SEL sel = sel_registerName(sels[s]);
        off += snprintf(g_selectorDump + off, sizeof(g_selectorDump) - off,
                        "[%s] -> ", sels[s]);
        int found = 0;
        for (int i = 0; i < count && off < sizeof(g_selectorDump) - 400; i++) {
            Class cls = classes[i];
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                Class impl = ClassThatImplementsSelector(cls, sel);
                int w = snprintf(g_selectorDump + off, sizeof(g_selectorDump) - off,
                    "%s; ", impl ? class_getName(impl) : class_getName(cls));
                if (w > 0) off += w;
                found++;
            }
        }
        if (!found) off += snprintf(g_selectorDump + off, sizeof(g_selectorDump) - off, "(keine)");
        off += snprintf(g_selectorDump + off, sizeof(g_selectorDump) - off, "\n");
    }
    free(classes);
    L("Selector-Besitzer-Diagnose fertig");
}

// ---------------------------------------------------------------- Foto/Video-Klassen finden
static void dumpWildcardClasses(void) {
    // In lokalen Puffer bauen, am Ende atomar in g_sinkClasses kopieren (kein Race).
    int count = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(classes, count);
    char tmp[8192];
    size_t off = 0;
    tmp[0] = 0;
    off += snprintf(tmp + off, sizeof(tmp) - off, "Sinks: ");

    const char *patterns[] = {
        "BWStillImage", "StillImage", "BWPhoto", "Photo", "Movie", "Recording",
        "BWVideo", "Capture", "Sink", "Scaler", "BWNode", "FigCapture", "FigStillImage"
    };
    int npat = sizeof(patterns) / sizeof(patterns[0]);
    int classCount = 0;

    for (int i = 0; i < count && off < sizeof(tmp) - 400; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        BOOL match = NO;
        for (int p = 0; p < npat; p++) {
            if (strstr(name, patterns[p])) { match = YES; break; }
        }
        if (!match) continue;
        classCount++;

        unsigned int mc = 0;
        Method *methods = class_copyMethodList(cls, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            const char *mn = sel_getName(method_getName(methods[j]));
            if (strstr(mn, "ample") || strstr(mn, "ixel") || strstr(mn, "emit")
                || strstr(mn, "utput") || strstr(mn, "eliver") || strstr(mn, "encode")
                || strstr(mn, "hotos") || strstr(mn, "humbnail")) {
                int w = snprintf(tmp + off, sizeof(tmp) - off,
                    "%s::%s; ", name, mn);
                if (w > 0) off += w;
            }
        }
        free(methods);
    }
    free(classes);
    if (off == (size_t)snprintf(tmp, 8, "Sinks: ")) {
        snprintf(tmp, sizeof(tmp),
            "Sinks: KEINE Klassen (%d Klassen insgesamt, %d gematcht)", count, classCount);
    }
    memcpy(g_sinkClasses, tmp, sizeof(tmp));
    L("Sink-Klassen-Diagnose fertig (%d gematcht)", classCount);
}

// ---------------------------------------------------------------- Sink-Beobachtung (Astra: Video-/Recording-/Foto-Pfade)
// Globals stehen oben bei der Telemetrie. Hier nur der Mess-Helper.

static void measureSinkAtomic(_Atomic uint64_t *calls, _Atomic int64_t *w,
                              _Atomic int64_t *h, _Atomic int64_t *fmt,
                              _Atomic int64_t *surf, CMSampleBufferRef sb) {
    atomic_fetch_add(calls, 1);
    if (!sb) return;
    CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sb);
    if (!px) return;
    atomic_store(w, (int64_t)CVPixelBufferGetWidth(px));
    atomic_store(h, (int64_t)CVPixelBufferGetHeight(px));
    atomic_store(fmt, (int64_t)CVPixelBufferGetPixelFormatType(px));
    IOSurfaceRef s = CVPixelBufferGetIOSurface(px);
    atomic_store(surf, s ? (int64_t)IOSurfaceGetID(s) : -1);
}

// Von Astra gefordert: Orientierung/Transform-Attachments des ORIGINAL-
// SampleBuffers UND dessen CVPixelBuffer-Attachments auslesen.
// Getrennte Dumps: 750x1000 (Foto) und 750x1334 (Video).
static void dumpOrientationAttachments(CMSampleBufferRef sb) {
    if (!sb) return;
    CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sb);
    if (!px) return;
    int w = (int)CVPixelBufferGetWidth(px);
    int h = (int)CVPixelBufferGetHeight(px);

    char *buf;
    _Atomic int64_t *guard;
    if (w == 750 && h == 1334) { buf = g_orientDump_video; guard = &g_orientDumped_video; }
    else { buf = g_orientDump; guard = &g_orientDumped; }
    if (atomic_load(guard)) return;
    atomic_store(guard, 1);

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    size_t off = 0;
    off += snprintf(buf + off, 4096 - off, "ORIENT w=%d h=%d fmt=0x%08x ", w, h,
                    (unsigned)CVPixelBufferGetPixelFormatType(px));

    // 1) CVPixelBuffer-Attachments (dort steckt meist die Orientierung!)
    CFDictionaryRef pbAtts = CVBufferGetAttachments(px, kCVAttachmentMode_ShouldPropagate);
    if (pbAtts) {
        NSDictionary *d = (__bridge NSDictionary *)pbAtts;
        for (NSString *k in d) {
            id v = d[k];
            off += snprintf(buf + off, 4096 - off, "PB[%s]=%s; ",
                            [k UTF8String], [[v description] UTF8String]);
        }
    }

    // 2) SampleBuffer-Attachments
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sb, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef att0 = CFArrayGetValueAtIndex(attachments, 0);
        if (att0) {
            NSDictionary *d = (__bridge NSDictionary *)att0;
            for (NSString *k in d) {
                id v = d[k];
                off += snprintf(buf + off, 4096 - off, "SB[%s]=%s; ",
                                [k UTF8String], [[v description] UTF8String]);
            }
        }
    }

    // 3) Clean Aperture + Pixel Aspect Ratio + Rotation aus Format-Extensions
    if (fmt) {
        CFDictionaryRef ext = CMFormatDescriptionGetExtensions(fmt);
        if (ext) {
            CFDictionaryRef cleanAperture = CFDictionaryGetValue(
                ext, kCMFormatDescriptionExtension_CleanAperture);
            if (cleanAperture) {
                NSString *s = [(__bridge NSDictionary *)cleanAperture description];
                off += snprintf(buf + off, 4096 - off, "CleanAperture=%s; ", [s UTF8String]);
            }
            CFDictionaryRef par = CFDictionaryGetValue(
                ext, kCMFormatDescriptionExtension_PixelAspectRatio);
            if (par) {
                NSString *s = [(__bridge NSDictionary *)par description];
                off += snprintf(buf + off, 4096 - off, "PixelAspectRatio=%s; ", [s UTF8String]);
            }
            // Rotation key ausprobieren (kCMFormatDescriptionKey und alte iOS-Schlüssel)
            NSNumber *rot = (__bridge NSNumber *)CFDictionaryGetValue(ext, @"Rotation");
            if (!rot) rot = (__bridge NSNumber *)CFDictionaryGetValue(ext, @"Orientation");
            if (rot) {
                off += snprintf(buf + off, 4096 - off, "Rot=%s; ", [[rot stringValue] UTF8String]);
            }
        }
    }
    L("Orient-Dump(%dx%d): %s", w, h, buf);
}

// ---- BWImageQueueSinkNode (PREVIEW-Pfad!) ----
// Beobachtung immer; Replacement NUR in stage 3 (und nur wenn kein
// Foto/Recording läuft). Der Preview-Sink nutzt p420 — swapPixelsInPlace
// verifiziert das Layout zur Laufzeit.
%hook BWImageQueueSinkNode
- (void)renderSampleBuffer:(id)sampleBuffer forInput:(id)input {
    CMSampleBufferRef sb = (__bridge CMSampleBufferRef)sampleBuffer;
    measureSinkAtomic(&g_iqCalls, &g_iqWidth, &g_iqHeight, &g_iqFmt, &g_iqSurf, sb);
    dumpOrientationAttachments(sb);
    if (atomic_load(&g_stage) >= 3 && atomic_load(&g_replacementEnabled) &&
        !atomic_load(&g_photoInProgress) && !atomic_load(&g_recordingInProgress)) {
        if (swapPixelsInPlace(sb)) {
            atomic_fetch_add(&g_iqSwaps, 1);
            %orig;
            return;
        }
    }
    %orig;
}
%end

// ---- BWQuickTimeMovieFileSinkNode (Recording-Pfad) ----
// NUR Beobachtung (Astra: fmt=0 deutet auf anderen Handoff — Replacement
// bleibt deaktiviert, bis der echte Movie-Bildpfad identifiziert ist).
%hook BWQuickTimeMovieFileSinkNode
- (void)renderSampleBuffer:(id)sampleBuffer forInput:(id)input {
    measureSinkAtomic(&g_qtCalls, &g_qtWidth, &g_qtHeight, &g_qtFmt, &g_qtSurf,
                      (__bridge CMSampleBufferRef)sampleBuffer);
    %orig;
}
%end

// ---- BWStillImageSampleBufferSinkNode (Foto-Pfad) ----
// NUR Beobachtung (Astra: 4032x3024 Still-/Sensorpfad — NICHT mit
// Preview-Logik überschreiben, bis der Still-Pfad separat verstanden ist).
%hook BWStillImageSampleBufferSinkNode
- (void)renderSampleBuffer:(id)sampleBuffer forInput:(id)input {
    measureSinkAtomic(&g_stCalls, &g_stWidth, &g_stHeight, &g_stFmt, &g_stSurf,
                      (__bridge CMSampleBufferRef)sampleBuffer);
    %orig;
}
%end

// ---------------------------------------------------------------- ctor
%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    L("injiziert in %@ (pid=%d)", proc, getpid());
    if (![proc isEqualToString:@"mediaserverd"]) return;

    // Diagnose EINMALIG nach kurzer Verzögerung (Astra: keine 5s-Dauerlast mehr).
    // Wiederholung nur auf explizites Kommando (redump / über Status-Port).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        logMethodsOfClass(NSClassFromString(@"BWNodeOutput"), "BWNodeOutput", g_methodDump);
        logMethodsOfClass(NSClassFromString(@"FigCaptureClientSessionMonitor"), "FigCaptureClientSessionMonitor", g_methodDump2);
        dumpWildcardClasses();
        dumpCopyNextClasses();
        dumpSelectorOwners();
        L("einmalige Diagnose fertig (stage=%d)", (int)atomic_load(&g_stage));
    });

    g_nalQueue = [NSMutableArray array];
    g_queueLock = [NSLock new];
    g_frameLock = [NSLock new];

    L("VCamInject build=%s", VCAM_BUILD_ID);
    L("START stage=0 (passiv — nur Status-Server + Zähler). Steuerung: Port 8769 'stage=N'");

    // WS-Client + Decoder nur ab stage 2 (wird zur Laufzeit umgeschaltet).
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // warten, bis stage >= 2 gesetzt wird
        while (atomic_load(&g_stage) < 2) sleep(1);
        L("WS-Block betreten (stage>=2)");
        wsClientThread();
        L("WS-Thread beendet");
    });

    L("nach WS-Dispatch");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        while (1) {
            if (atomic_load(&g_stage) >= 2) pumpDecoder();
            maybeResetPhotoGuard();
            usleep(2500);
        }
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        statusServerThread();
    });
    L("bereit — stage 0 aktiv");
}
