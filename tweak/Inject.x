// VCamInject — Frame-Swap in mediaserverd (Dopamine2-roothide)
//
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
#import <os/log.h>

#define WS_PORT 8767
#define STATUS_PORT 8769

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.shosh.vcaminject", "inject"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- Telemetrie (atomar)
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
static _Atomic uint64_t g_origCount = 0;
static _Atomic uint64_t g_hasLatestFrame = 0;
static _Atomic uint64_t g_vtSessionAttempts = 0;
static _Atomic int64_t g_vtSessionError = 0;
static char g_methodDump[4096] = {0};
static char g_methodDump2[4096] = {0};

// Modus-Steuerung über WS-Textnachrichten (Marker-Dateien funktionieren nicht,
// weil mediaserverd eine andere /tmp-Sicht hat als die SSH-Shell!)
static _Atomic int g_modeWrapOrig = 0;
static _Atomic int g_modeTestPattern = 0;

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
        NSData *nal = dequeueNal();
        if (!nal) return;
        const uint8_t *bytes = (const uint8_t *)nal.bytes;
        uint8_t nalType = bytes[0] & 0x1f;

        atomic_fetch_add(&g_rxNalCount, 1);
        if (nalType == 7) atomic_fetch_add(&g_spsCount, 1);
        else if (nalType == 8) atomic_fetch_add(&g_ppsCount, 1);
        else if (nalType == 5) atomic_fetch_add(&g_idrCount, 1);

        // --- Format-Description aus SPS+PPS aufbauen (AVCC, lengthSize=4) ---
        if (g_fmtDesc == NULL) {
            static NSMutableData *sps, *pps;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ sps = [NSMutableData data]; pps = [NSMutableData data]; });
            if (nalType == 7) [sps setData:nal];
            else if (nalType == 8) [pps setData:nal];
            if (sps.length && pps.length) {
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

        // --- VT-Session einmalig anlegen ---
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
                L("VT-Session FAIL: %d (attempt %llu)", (int)st,
                  (unsigned long long)atomic_load(&g_vtSessionAttempts));
                return;
            }
            L("Decode-Session OK");
        }

        // --- AVCC-Block bauen: [4-Byte-Länge][NAL] (KEIN Annex-B-Startcode!) ---
        uint32_t nalLen = htonl((uint32_t)nal.length);
        size_t blockLen = 4 + (size_t)nal.length;
        uint8_t *blockBuf = malloc(blockLen);
        if (!blockBuf) return;
        memcpy(blockBuf, &nalLen, 4);
        memcpy(blockBuf + 4, nal.bytes, nal.length);

        CMBlockBufferRef bb = NULL;
        OSStatus bbSt = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, blockBuf, blockLen,
            kCFAllocatorDefault, NULL, 0, blockLen, 0, &bb);
        if (bbSt != kCMBlockBufferNoErr || !bb) {
            L("BlockBuffer FAIL: %d", (int)bbSt);
            free(blockBuf);
            return;
        }
        CMSampleBufferRef sb = NULL;
        OSStatus sbSt = CMSampleBufferCreate(kCFAllocatorDefault, bb, true, NULL, NULL, g_fmtDesc, 1, 0, NULL, 0, NULL, &sb);
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

// ---------------------------------------------------------------- Range-Shift
// Decoder (libx264) liefert Video-Range (Y 16-235, UV 16-240). Der Kamera-
// Consumer erwartet Full-Range 420f (Y 0-255, UV 0-255).
// WICHTIG: KOPIE statt In-Place — der Decoder-Buffer gehört der VT-Session
// und wird recycled. LordVCAM nutzt dafür VCCopyPB/blendNV12 in eigenen Buffer.
static CVPixelBufferPoolRef g_shiftPool = NULL;

static CVPixelBufferRef copyShiftToFullRange(CVPixelBufferRef src) {
    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    if (!w || !h) return NULL;

    if (!g_shiftPool) {
        NSDictionary *attrs = @{
            (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            (__bridge id)kCVPixelBufferWidthKey: @(w),
            (__bridge id)kCVPixelBufferHeightKey: @(h),
            (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (__bridge id)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
            (__bridge CFDictionaryRef)attrs, &g_shiftPool);
    }
    CVPixelBufferRef dst = NULL;
    if (!g_shiftPool || CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, g_shiftPool, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);
    const uint8_t *sy = CVPixelBufferGetBaseAddressOfPlane(src, 0);
    const uint8_t *suv = CVPixelBufferGetBaseAddressOfPlane(src, 1);
    uint8_t *dy = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
    uint8_t *duv = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
    size_t syS = CVPixelBufferGetBytesPerRowOfPlane(src, 0);
    size_t suvS = CVPixelBufferGetBytesPerRowOfPlane(src, 1);
    size_t dyS = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
    size_t duvS = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);
    if (!sy || !suv || !dy || !duv) {
        CVPixelBufferUnlockBaseAddress(dst, 0);
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(dst);
        return NULL;
    }

    // Y: 16..235 -> 0..255 (Kopie + Shift)
    for (size_t r = 0; r < h; r++) {
        const uint8_t *srow = sy + r * syS;
        uint8_t *drow = dy + r * dyS;
        for (size_t x = 0; x < w; x++) {
            int v = ((int)srow[x] - 16) * 255 / 219;
            drow[x] = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
        }
    }
    // Cb/Cr: 16..240 -> 0..255 (Kopie + Shift)
    for (size_t r = 0; r < h / 2; r++) {
        const uint8_t *srow = suv + r * suvS;
        uint8_t *drow = duv + r * duvS;
        for (size_t x = 0; x < w; x++) {
            int v = ((int)srow[x] - 16) * 255 / 224;
            drow[x] = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return dst;
}

static CMSampleBufferRef buildSwapSampleBuffer(CMSampleBufferRef original) {
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
        // Decoder-Buffer sicher holen (Retain unter Lock), dann KOPIEREN + shiften
        [g_frameLock lock];
        if (g_latestFrame) px = CVPixelBufferRetain(g_latestFrame);
        [g_frameLock unlock];
        if (px) {
            CVPixelBufferRef shifted = copyShiftToFullRange(px);
            CVPixelBufferRelease(px);
            px = shifted;
        }
    }
    if (!px) {
        atomic_fetch_add(&g_passthroughOrig, 1);
        return NULL;
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

static void dumpHandoff(id sampleBuffer, CMSampleBufferRef replacement) {
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
static void dumpHookClass(id self) {
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
    CMSampleBufferRef fake = buildSwapSampleBuffer((__bridge CMSampleBufferRef)sampleBuffer);
    if (fake) {
        %orig((__bridge id)fake);
        CFRelease(fake);
        return;
    }
    atomic_fetch_add(&g_origCount, 1);
    %orig;
}

- (void)sendMediaServerdSampleAtPoint:(id)sampleBuffer {
    atomic_fetch_add(&g_sendCalls, 1);
    CMSampleBufferRef fake = buildSwapSampleBuffer((__bridge CMSampleBufferRef)sampleBuffer);
    if (fake) {
        %orig((__bridge id)fake);
        CFRelease(fake);
        return;
    }
    atomic_fetch_add(&g_origCount, 1);
    %orig;
}
%end

static _Atomic int64_t g_origPixelFormat = 0;
static _Atomic int64_t g_origWidth = 0;
static _Atomic int64_t g_origHeight = 0;

%hook BWNodeOutput
- (void)emitSampleBuffer:(id)sampleBuffer {
    atomic_fetch_add(&g_emitCalls, 1);

    // Einmalig: Original-Pixel-Format + Dimensionen erfassen (Diagnose)
    if (atomic_load(&g_origPixelFormat) == 0) {
        CMSampleBufferRef orig = (__bridge CMSampleBufferRef)sampleBuffer;
        if (orig) {
            CVPixelBufferRef px = CMSampleBufferGetImageBuffer(orig);
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

    CMSampleBufferRef fake = buildSwapSampleBuffer((__bridge CMSampleBufferRef)sampleBuffer);

    // Einmalig: Handoff-Diagnose (Original vs. Ersatz) + konkrete Klasse
    if (!atomic_load(&g_handoffDumped)) dumpHandoff(sampleBuffer, fake);
    if (!atomic_load(&g_hookClassChecked)) dumpHookClass(self);

    if (fake) {
        %orig((__bridge id)fake);
        CFRelease(fake);
        return;
    }
    atomic_fetch_add(&g_origCount, 1);
    %orig;
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
        char msg[5120];
        int w = snprintf(msg, sizeof(msg),
            "rxNal=%llu sps=%llu pps=%llu idr=%llu "
            "formatDesc=%llu submit=%llu output=%llu errors=%llu "
            "emit=%llu send=%llu build=%llu swap=%llu orig=%llu hasFrame=%llu "
            "vtAttempts=%llu vtError=%lld\n",
            (unsigned long long)atomic_load(&g_rxNalCount),
            (unsigned long long)atomic_load(&g_spsCount),
            (unsigned long long)atomic_load(&g_ppsCount),
            (unsigned long long)atomic_load(&g_idrCount),
            (unsigned long long)atomic_load(&g_formatDescCount),
            (unsigned long long)atomic_load(&g_decodeSubmitCount),
            (unsigned long long)atomic_load(&g_decodeOutputCount),
            (unsigned long long)atomic_load(&g_decodeErrorCount),
            (unsigned long long)atomic_load(&g_emitCalls),
            (unsigned long long)atomic_load(&g_sendCalls),
            (unsigned long long)atomic_load(&g_buildCalls),
            (unsigned long long)atomic_load(&g_swapCount),
            (unsigned long long)atomic_load(&g_origCount),
            (unsigned long long)atomic_load(&g_hasLatestFrame),
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
        if (atomic_load(&g_handoffDumped)) {
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
static void wsClientThread(void) {
    while (1) {
        @autoreleasepool {
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) { sleep(2); continue; }
            struct sockaddr_in addr = {0};
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            addr.sin_port = htons(WS_PORT);
            if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
                close(fd);
                sleep(2);
                continue;
            }
            char key[32];
            srand((unsigned)time(NULL));
            for (int i = 0; i < 24; i++) key[i] = "abcdefghijklmnopqrstuvwxyz0123456789"[rand() % 36];
            key[24] = 0;
            char req[512];
            snprintf(req, sizeof(req),
                "GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
                WS_PORT, key);
            if (send(fd, req, (int)strlen(req), 0) < 0) { close(fd); sleep(2); continue; }
            char resp[2048];
            ssize_t n = recv(fd, resp, sizeof(resp) - 1, 0);
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
                    enqueueNal([NSData dataWithBytesNoCopy:payload length:(NSUInteger)plen freeWhenDone:YES]);
                } else if (opcode == 0x1) {
                    // Text-Nachricht = Modus-Steuerung
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
                        } else if ([cmd isEqualToString:@"mode:normal"]) {
                            atomic_store(&g_modeWrapOrig, 0);
                            atomic_store(&g_modeTestPattern, 0);
                            L("Modus: NORMAL");
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
        if (strstr(name, "ample") || strstr(name, "emit") || strstr(name, "utput")
            || strstr(name, "eliver") || strstr(name, "endSample")) {
            int w = snprintf(dump + off, 4096 - off, "%s; ", name);
            if (w > 0) off += w;
        }
    }
    if (methods) free(methods);
    L("Methoden von %s erfasst", className);
}

// ---------------------------------------------------------------- copyNext-Klassen finden
static char g_copyClasses[4096] = {0};

static void dumpCopyNextClasses(void) {
    SEL sel = sel_registerName("copyNextSampleBuffer:");
    int count = objc_getClassList(NULL, 0);
    Class *classes = malloc(sizeof(Class) * count);
    count = objc_getClassList(classes, count);
    size_t off = 0;
    g_copyClasses[0] = 0;
    off += snprintf(g_copyClasses + off, sizeof(g_copyClasses) - off, "copyNextSampleBuffer Klassen: ");
    int found = 0;
    for (int i = 0; i < count && off < sizeof(g_copyClasses) - 200; i++) {
        Class cls = classes[i];
        unsigned int mc = 0;
        Method *methods = class_copyMethodList(cls, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            if (method_getName(methods[j]) == sel) {
                const char *enc = method_getTypeEncoding(methods[j]);
                int w = snprintf(g_copyClasses + off, sizeof(g_copyClasses) - off,
                    "%s|%s; ", class_getName(cls), enc ? enc : "?");
                if (w > 0) off += w;
                found++;
            }
        }
        free(methods);
    }
    free(classes);
    L("copyNextSampleBuffer: %d Klassen gefunden", found);
}

// ---------------------------------------------------------------- ctor
%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    L("injiziert in %@ (pid=%d)", proc, getpid());
    if (![proc isEqualToString:@"mediaserverd"]) return;

    // Methoden-Diagnose (einmalig nach kurzem Delay, damit Klassen geladen sind)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        logMethodsOfClass(NSClassFromString(@"BWNodeOutput"), "BWNodeOutput", g_methodDump);
        logMethodsOfClass(NSClassFromString(@"FigCaptureClientSessionMonitor"), "FigCaptureClientSessionMonitor", g_methodDump2);
        dumpCopyNextClasses();
    });

    g_nalQueue = [NSMutableArray array];
    g_queueLock = [NSLock new];
    g_frameLock = [NSLock new];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        wsClientThread();
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        while (1) {
            pumpDecoder();
            usleep(2500);
        }
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        statusServerThread();
    });
    L("bereit — verbinde mit Hub");
}
