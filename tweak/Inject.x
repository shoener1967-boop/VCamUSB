// VCamInject v2 — Sauberer Neubau nach verifiziertem LordVCAM arm64e-Ablauf
//
// Architektur:
//   PC-Server → H.264 (AVCC) → WS 8767 → Decoder (420f) → g_latestFrame
//   Preview:  BWImageQueueSinkNode  → In-place Pixel-Swap
//   Photo:    BWPhotoEncoderNode    → Separate Buffer + neuer SampleBuffer
//   Status:   TCP 8769              → Telemetrie, enable/disable
//
// Verifizierte Referenz: PROJEKT_UEBERGABE_KOMPLETT.md, ASTRA_VERIFIKATION_ERGEBNIS.md
// Build-ID für Artefakt-Identifikation
#define VCAM_BUILD_ID "v2-clean-2026-09-15"

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Accelerate/Accelerate.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <stdatomic.h>
#import <pthread.h>
#import <os/log.h>

#define WS_PORT 8767
#define STATUS_PORT 8769

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.shosh.vcaminject", "v2"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)


// ================================================================
// SECTION 1: GLOBALS & TELEMETRIE
// ================================================================

// Enable/Disable (atomares Bool, kein Stage-System)
static _Atomic int g_enabled = 1;

// Decoder-State
static NSMutableArray<NSData *> *g_nalQueue = nil;
static NSLock *g_queueLock = nil;
static VTDecompressionSessionRef g_vtSession = NULL;
static CMFormatDescriptionRef g_fmtDesc = NULL;
static CVPixelBufferRef g_latestFrame = NULL;
static NSLock *g_frameLock = nil;

// Telemetrie (reduziert auf Essentials)
static _Atomic uint64_t g_rxNal = 0;
static _Atomic uint64_t g_spsCount = 0;
static _Atomic uint64_t g_ppsCount = 0;
static _Atomic uint64_t g_decodeSubmit = 0;
static _Atomic uint64_t g_decodeOutput = 0;
static _Atomic uint64_t g_decodeError = 0;
static _Atomic uint64_t g_hasFrame = 0;

// Hook-Zähler
static _Atomic uint64_t g_previewCalls = 0;
static _Atomic uint64_t g_previewSwaps = 0;
static _Atomic uint64_t g_photoCalls = 0;
static _Atomic uint64_t g_photoSwaps = 0;
static _Atomic uint64_t g_recordingCalls = 0;

// Decoder-Output-Format (einmalig gemessen)
static _Atomic int64_t g_decodedFmt = 0;
static _Atomic int64_t g_decodedW = 0;
static _Atomic int64_t g_decodedH = 0;

// WS-Client-State
static _Atomic uint64_t g_wsBinary = 0;
static _Atomic uint64_t g_wsText = 0;
static _Atomic uint64_t g_wsBytes = 0;


// ================================================================
// SECTION 2: DECODER (aus Inject.x übernommen, vereinfacht)
// ================================================================

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

static void decompressionOutputCallback(void *refCon, void *srcRef,
    OSStatus status, VTDecodeInfoFlags info, CVPixelBufferRef imageBuffer,
    CMTime pts, CMTime duration) {
    if (status != noErr) {
        atomic_fetch_add(&g_decodeError, 1);
        return;
    }
    if (!imageBuffer) return;
    atomic_fetch_add(&g_decodeOutput, 1);

    // Einmalig: tatsächliches Decoder-Output-Format messen
    if (atomic_load(&g_decodedFmt) == 0) {
        OSType fmt = CVPixelBufferGetPixelFormatType(imageBuffer);
        size_t w = CVPixelBufferGetWidth(imageBuffer);
        size_t h = CVPixelBufferGetHeight(imageBuffer);
        atomic_store(&g_decodedFmt, (int64_t)fmt);
        atomic_store(&g_decodedW, (int64_t)w);
        atomic_store(&g_decodedH, (int64_t)h);
        L("DECODED fmt=0x%08x (%c%c%c%c) %zux%zu",
          (unsigned)fmt, (int)(fmt>>24)&0xff, (int)(fmt>>16)&0xff,
          (int)(fmt>>8)&0xff, (int)fmt&0xff, w, h);
    }

    [g_frameLock lock];
    if (g_latestFrame) CVPixelBufferRelease(g_latestFrame);
    g_latestFrame = CVPixelBufferRetain(imageBuffer);
    [g_frameLock unlock];
    atomic_store(&g_hasFrame, 1);
}

static void pumpDecoder(void) {
    @autoreleasepool {
        NSData *msg = dequeueNal();
        if (!msg) return;
        const uint8_t *bytes = (const uint8_t *)msg.bytes;
        uint8_t nalType = bytes[0] & 0x1f;
        atomic_fetch_add(&g_rxNal, 1);

        // SPS/PPS: roh, erstes Byte 0x67 (SPS) / 0x68 (PPS)
        if (nalType == 7 || nalType == 8) {
            if (nalType == 7) atomic_fetch_add(&g_spsCount, 1);
            else atomic_fetch_add(&g_ppsCount, 1);

            static NSMutableData *sps, *pps;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ sps = [NSMutableData data]; pps = [NSMutableData data]; });

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
                    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(g_fmtDesc);
                    L("FormatDescription OK %dx%d", (int)dims.width, (int)dims.height);
                } else {
                    L("FormatDescription FAIL: %d", (int)st);
                }
            }
            return;
        }

        // AU (AVCC: [4-byte len][NAL]...)
        if (g_fmtDesc == NULL) return;

        if (g_vtSession == NULL) {
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
                L("VT-Session FAIL: %d", (int)st);
                return;
            }
            L("Decode-Session OK");
        }

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

        CMSampleTimingInfo timing = {
            .duration = CMTimeMake(1, 30),
            .presentationTimeStamp = CMTimeMake((int64_t)atomic_load(&g_decodeSubmit), 30),
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
        atomic_fetch_add(&g_decodeSubmit, 1);
        VTDecompressionSessionDecodeFrame(g_vtSession, sb, 0, NULL, NULL);
        CFRelease(sb);
    }
}


// ================================================================
// SECTION 3: PIXEL-HELPERS (Rotation/Scale/Range, aus Inject.x übernommen)
// ================================================================

// Range-Konvertierung: Full->Video (219/224/255) und Video->Full
static inline uint8_t fullToVideoY(uint8_t v)   { return (uint8_t)(((219u * v) / 255u) + 16u); }
static inline uint8_t fullToVideoC(uint8_t v)   { return (uint8_t)(((224u * v) / 255u) + 16u); }
static inline uint8_t videoToFullY(uint8_t v)   { return (uint8_t)((255u * (uint32_t)(v - 16u)) / 219u); }
static inline uint8_t videoToFullC(uint8_t v)   { return (uint8_t)((255u * (uint32_t)(v - 16u)) / 224u); }
typedef uint8_t (*ConvFn)(uint8_t);

// NV12 biplanar Y-Plane skalieren (Center-Crop)
static void scaleNV12Plane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                           uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                           size_t cropX, size_t cropY, size_t cropW, size_t cropH,
                           ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    if (!cropW || !cropH) return;
    if (cropX + cropW > srcW || cropY + cropH > srcH) return;
    for (size_t y = 0; y < dstH; y++) {
        size_t sy = cropY + (y * cropH) / dstH;
        const uint8_t *srcRow = sp + sy * srcStride;
        uint8_t *dstRow = dp + y * dstStride;
        for (size_t x = 0; x < dstW; x++) {
            size_t sx = cropX + (x * cropW) / dstW;
            uint8_t v = srcRow[sx];
            dstRow[x] = conv ? conv(v) : v;
        }
    }
}

// NV12 UV-Plane skalieren (interleaved CbCr, 2 Bytes/Pixel)
static void scaleNV12UVPlane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                             uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                             size_t cropX, size_t cropY, size_t cropW, size_t cropH,
                             ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    if (!cropW || !cropH) return;
    if (cropX + cropW > srcW || cropY + cropH > srcH) return;
    for (size_t y = 0; y < dstH; y++) {
        size_t sy = cropY + (y * cropH) / dstH;
        const uint8_t *srcRow = sp + sy * srcStride;
        uint8_t *dstRow = dp + y * dstStride;
        for (size_t x = 0; x < dstW; x++) {
            size_t sx = cropX + (x * cropW) / dstW;
            size_t srcOff = sx * 2;
            size_t dstOff = x * 2;
            uint8_t cb = srcRow[srcOff];
            uint8_t cr = srcRow[srcOff + 1];
            dstRow[dstOff] = conv ? conv(cb) : cb;
            dstRow[dstOff + 1] = conv ? conv(cr) : cr;
        }
    }
}

// 90°-Rotation via vImage (LordVCAM-Pfad 2: Rotate -> Scale -> LUT)
// rotConst: 3=CCW90, 2=180, 1=CW90
static void rotateScalePlane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                             uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                             uint8_t rotConst, ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    size_t rotW = srcH;
    size_t rotH = srcW;
    size_t tmpRowBytes = rotW;
    if (rotW > SIZE_MAX / rotH) return;
    uint8_t *tmp = malloc(tmpRowBytes * rotH);
    if (!tmp) return;
    vImage_Buffer srcBuf = { (void *)sp, srcH, srcW, srcStride };
    vImage_Buffer tmpBuf = { tmp, rotH, rotW, tmpRowBytes };
    vImage_Buffer dstBuf = { dp, dstH, dstW, dstStride };
    vImage_Error err = vImageRotate90_Planar8(&srcBuf, &tmpBuf, rotConst, 0, kvImageNoFlags);
    if (err != kvImageNoError) { free(tmp); return; }
    err = vImageScale_Planar8(&tmpBuf, &dstBuf, NULL, kvImageNoFlags);
    if (err != kvImageNoError) { free(tmp); return; }
    if (conv) {
        static uint8_t lutY[256]; static BOOL lutYInit = NO;
        if (!lutYInit) { for (int i = 0; i < 256; i++) lutY[i] = conv((uint8_t)i); lutYInit = YES; }
        vImageTableLookUp_Planar8(&dstBuf, &dstBuf, lutY, kvImageNoFlags);
    }
    free(tmp);
}

// UV-Plane Rotation (16-bit CbCr-Paare, background 0x8080)
static void rotateScaleUVPlane(const uint8_t *sp, size_t srcStride, size_t srcW, size_t srcH,
                               uint8_t *dp, size_t dstStride, size_t dstW, size_t dstH,
                               uint8_t rotConst, ConvFn conv) {
    if (!sp || !dp || !srcStride || !dstStride || !srcW || !srcH || !dstW || !dstH) return;
    size_t rotW = srcH, rotH = srcW;
    if (rotW > SIZE_MAX / rotH) return;
    uint8_t *tmp = malloc(rotW * rotH * 2);
    if (!tmp) return;
    size_t srcRow = srcStride & ~(size_t)1;
    size_t tmpRow = rotW * 2;
    vImage_Buffer srcBuf = { (void *)sp, srcH, srcW, srcRow };
    vImage_Buffer tmpBuf = { tmp, rotH, rotW, tmpRow };
    vImage_Error err = vImageRotate90_Planar16U(&srcBuf, &tmpBuf, rotConst, 0x8080, kvImageNoFlags);
    if (err != kvImageNoError) { free(tmp); return; }
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


// ================================================================
// SECTION 4: IN-PLACE PIXEL-SWAP (Preview-Pfad)
// ================================================================

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

    // Nur NV12/420f/p420 biplanar
    BOOL dst420 = (dfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || dfmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || dfmt == 0x70343230);   // 'p420'
    BOOL src420 = (sfmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || sfmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || sfmt == 0x70343230);

    // Layout-Verifikation: beide Buffer müssen biplanar sein
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
        }
    }

    if (dst420 && src420 && layoutOK) {
        CVReturn lkDst = CVPixelBufferLockBaseAddress(dst, 0);
        CVReturn lkSrc = CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        if (lkDst != kCVReturnSuccess || lkSrc != kCVReturnSuccess) {
            if (lkDst == kCVReturnSuccess) CVPixelBufferUnlockBaseAddress(dst, 0);
            if (lkSrc == kCVReturnSuccess) CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferRelease(src);
            return NO;
        }

        const uint8_t *srcY = CVPixelBufferGetBaseAddressOfPlane(src, 0);
        const uint8_t *srcUV = CVPixelBufferGetBaseAddressOfPlane(src, 1);
        uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
        uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
        if (!srcY || !srcUV || !dstY || !dstUV) {
            CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferUnlockBaseAddress(dst, 0);
            CVPixelBufferRelease(src);
            return NO;
        }

        if (dw == sw && dh == sh) {
            // Same-size: stride-aware direkte Kopie
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
            // Größen-Mismatch: Rotation/Scale
            int rotDeg = 0;
            {
                CFDictionaryRef pbAtts = CVBufferGetAttachments(dst, kCVAttachmentMode_ShouldNotPropagate);
                if (pbAtts) {
                    NSNumber *rd = (__bridge NSNumber *)CFDictionaryGetValue(
                        (CFDictionaryRef)pbAtts, (CFStringRef)@"RotationDegrees");
                    if (rd) rotDeg = [rd intValue];
                }
            }
            // LordVCAM-Fallback (arm64e F6): aspect > 1.5 && width >= height
            if (rotDeg == 0) {
                double dstAspect = (double)dw / (double)dh;
                if (dstAspect > 1.5 && dw >= dh) rotDeg = 90;
            }
            // Range-Konvertierung
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
                // LordVCAM-Pfad 2: Rotation (90/180/270)
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
            } else {
                // Center-Crop + Skalierung
                double srcAR = (double)sw / (double)sh;
                double dstAR = (double)dw / (double)dh;
                size_t cropW, cropH, cropX, cropY;
                if (srcAR > dstAR) {
                    cropH = sh;
                    cropW = (size_t)(sh * dstAR);
                    cropX = (sw - cropW) / 2;
                    cropY = 0;
                } else {
                    cropW = sw;
                    cropH = (size_t)(sw / dstAR);
                    cropX = 0;
                    cropY = (sh - cropH) / 2;
                }
                cropX &= ~(size_t)1;
                cropY &= ~(size_t)1;
                cropW &= ~(size_t)1;
                cropH &= ~(size_t)1;
                scaleNV12Plane(CVPixelBufferGetBaseAddressOfPlane(src, 0),
                               CVPixelBufferGetBytesPerRowOfPlane(src, 0), sw, sh,
                               CVPixelBufferGetBaseAddressOfPlane(dst, 0),
                               CVPixelBufferGetBytesPerRowOfPlane(dst, 0), dw, dh,
                               cropX, cropY, cropW, cropH, convY);
                scaleNV12UVPlane(CVPixelBufferGetBaseAddressOfPlane(src, 1),
                               CVPixelBufferGetBytesPerRowOfPlane(src, 1), sw / 2, sh / 2,
                               CVPixelBufferGetBaseAddressOfPlane(dst, 1),
                               CVPixelBufferGetBytesPerRowOfPlane(dst, 1), dw / 2, dh / 2,
                               cropX / 2, cropY / 2, cropW / 2, cropH / 2, convC);
                ok = YES;
            }
        }

        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(dst, 0);
    }

    CVPixelBufferRelease(src);
    return ok;
}


// ================================================================
// SECTION 5: SEPARATE-BUFFER-HANDOFF (Photo-Pfad, NEU)
// ================================================================

// Erzeugt einen NEUEN CVPixelBuffer + CMSampleBuffer mit g_latestFrame-Pixel,
// OHNE den original SampleBuffer zu modifizieren.
// Timing + Attachments vom Original übernehmen (LordVCAM-Stil).
static CMSampleBufferRef buildReplacementSampleBuffer(CMSampleBufferRef original) {
    if (!original) return NULL;

    CVPixelBufferRef src = NULL;
    [g_frameLock lock];
    if (g_latestFrame) src = CVPixelBufferRetain(g_latestFrame);
    [g_frameLock unlock];
    if (!src) return NULL;

    // Original-Dimension/Format holen (Photo-Encoder erwartet spezifische Größe)
    CVPixelBufferRef origPB = CMSampleBufferGetImageBuffer(original);
    if (!origPB) {
        CVPixelBufferRelease(src);
        return NULL;
    }
    size_t ow = CVPixelBufferGetWidth(origPB);
    size_t oh = CVPixelBufferGetHeight(origPB);
    OSType ofmt = CVPixelBufferGetPixelFormatType(origPB);

    // Neuen Zielbuffer mit Original-Dimensionen erzeugen
    NSDictionary *attrs = @{
        (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(ofmt),
        (__bridge id)kCVPixelBufferWidthKey: @(ow),
        (__bridge id)kCVPixelBufferHeightKey: @(oh),
        (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef dst = NULL;
    CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, ow, oh, ofmt,
        (__bridge CFDictionaryRef)attrs, &dst);
    if (cr != kCVReturnSuccess || !dst) {
        CVPixelBufferRelease(src);
        return NULL;
    }

    // Pixel von src nach dst kopieren (analog swapPixelsInPlace, aber separate Buffer)
    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    OSType sfmt = CVPixelBufferGetPixelFormatType(src);

    CVReturn lkDst = CVPixelBufferLockBaseAddress(dst, 0);
    CVReturn lkSrc = CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    if (lkDst != kCVReturnSuccess || lkSrc != kCVReturnSuccess) {
        if (lkDst == kCVReturnSuccess) CVPixelBufferUnlockBaseAddress(dst, 0);
        if (lkSrc == kCVReturnSuccess) CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(dst);
        CVPixelBufferRelease(src);
        return NULL;
    }

    // Center-Crop/Scale (wie Preview, aber auf neuen Buffer)
    // TODO: Rotation? Für Foto-Pfad müssen wir die Attachments prüfen.
    BOOL copied = NO;
    if (ow == sw && oh == sh && ofmt == sfmt) {
        // Same-size/format: direkte Kopie
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
        copied = YES;
    } else {
        // TODO: Scale/Crop für Hi-Res-Foto (4032x3024 → 1920x1080 ist unwahrscheinlich;
        // vermutlich will Photo-Encoder das Original-Format beibehalten).
        // Vorerst: nur same-size unterstützen.
    }

    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferRelease(src);

    if (!copied) {
        CVPixelBufferRelease(dst);
        return NULL;
    }

    // Neuen CMSampleBuffer mit dem neuen PixelBuffer erzeugen
    CMFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, dst, &fmt);
    if (st != noErr || !fmt) {
        CVPixelBufferRelease(dst);
        return NULL;
    }

    // Timing vom Original übernehmen
    CMSampleTimingInfo timing = {
        .duration = CMSampleBufferGetDuration(original),
        .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(original),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sb = NULL;
    st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, dst, fmt, &timing, &sb);
    CFRelease(fmt);
    CVPixelBufferRelease(dst);
    if (st != noErr || !sb) {
        return NULL;
    }

    // Attachments vom Original kopieren (wichtig für Photo-Encoder!)
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(original, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef origAtts = CFArrayGetValueAtIndex(attachments, 0);
        CFArrayRef newAtts = CMSampleBufferGetSampleAttachmentsArray(sb, true);
        if (newAtts && CFArrayGetCount(newAtts) > 0) {
            CFMutableDictionaryRef newAtts0 = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(newAtts, 0);
            if (newAtts0) {
                // Alle Keys vom Original kopieren (NSDictionary-Brücke statt CFDictionaryApplyFunction)
                NSDictionary *origDict = (__bridge NSDictionary *)origAtts;
                for (id key in origDict) {
                    CFDictionarySetValue(newAtts0, (__bridge const void *)key, (__bridge const void *)origDict[key]);
                }
            }
        }
    }

    return sb;
}


// ================================================================
// SECTION 6: HOOKS (Preview/Photo/Recording)
// ================================================================

// ---- Preview-Hook: BWImageQueueSinkNode ----
%hook BWImageQueueSinkNode
- (void)renderSampleBuffer:(id)sampleBuffer forInput:(id)input {
    atomic_fetch_add(&g_previewCalls, 1);
    if (!atomic_load(&g_enabled)) {
        %orig;
        return;
    }
    if (swapPixelsInPlace((__bridge CMSampleBufferRef)sampleBuffer)) {
        atomic_fetch_add(&g_previewSwaps, 1);
    }
    %orig;
}
%end

// ---- Photo-Hook: BWPhotoEncoderNode ----
// Verifiziert aus arm64e_hooks_report.md; ersetzt den SampleBuffer komplett.
%hook BWPhotoEncoderNode
- (void)renderSampleBuffer:(id)sampleBuffer forInput:(id)input {
    atomic_fetch_add(&g_photoCalls, 1);
    if (!atomic_load(&g_enabled)) {
        %orig;
        return;
    }
    CMSampleBufferRef replacement = buildReplacementSampleBuffer((__bridge CMSampleBufferRef)sampleBuffer);
    if (replacement) {
        atomic_fetch_add(&g_photoSwaps, 1);
        %orig((__bridge id)replacement, input);
        CFRelease(replacement);
        return;
    }
    %orig;
}
%end

// ---- Recording-Sink: BWQuickTimeMovieFileSinkNode (NUR Beobachtung) ----
// Übergabe Sektion 12: "fmt=0 deutet auf anderen Handoff — Replacement bleibt
// deaktiviert, bis der echte Movie-Bildpfad identifiziert ist."
%hook BWQuickTimeMovieFileSinkNode
- (void)renderSampleBuffer:(id)sampleBuffer forInput:(id)input {
    atomic_fetch_add(&g_recordingCalls, 1);
    %orig;
}
%end


// ================================================================
// SECTION 7: STATUS-SERVER (8769)
// ================================================================

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
        // Kommando lesen: "enable", "disable", "status"
        char cmd[64] = {0};
        struct timeval tv = { .tv_sec = 0, .tv_usec = 150000 };
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        ssize_t cr = recv(c, cmd, sizeof(cmd) - 1, 0);
        if (cr > 0) {
            if (strncmp(cmd, "enable", 6) == 0) {
                atomic_store(&g_enabled, 1);
                L("ENABLED");
            } else if (strncmp(cmd, "disable", 7) == 0) {
                atomic_store(&g_enabled, 0);
                L("DISABLED");
            }
        }
        char msg[4096];
        int w = snprintf(msg, sizeof(msg),
            "build=%s enabled=%d\n"
            "rxNal=%llu sps=%llu pps=%llu submit=%llu output=%llu errors=%llu hasFrame=%llu\n"
            "wsBin=%llu wsText=%llu wsBytes=%llu\n"
            "preview: calls=%llu swaps=%llu\n"
            "photo: calls=%llu swaps=%llu\n"
            "recording: calls=%llu\n"
            "decoded: fmt=0x%08x %lldx%lld\n",
            VCAM_BUILD_ID,
            (int)atomic_load(&g_enabled),
            (unsigned long long)atomic_load(&g_rxNal),
            (unsigned long long)atomic_load(&g_spsCount),
            (unsigned long long)atomic_load(&g_ppsCount),
            (unsigned long long)atomic_load(&g_decodeSubmit),
            (unsigned long long)atomic_load(&g_decodeOutput),
            (unsigned long long)atomic_load(&g_decodeError),
            (unsigned long long)atomic_load(&g_hasFrame),
            (unsigned long long)atomic_load(&g_wsBinary),
            (unsigned long long)atomic_load(&g_wsText),
            (unsigned long long)atomic_load(&g_wsBytes),
            (unsigned long long)atomic_load(&g_previewCalls),
            (unsigned long long)atomic_load(&g_previewSwaps),
            (unsigned long long)atomic_load(&g_photoCalls),
            (unsigned long long)atomic_load(&g_photoSwaps),
            (unsigned long long)atomic_load(&g_recordingCalls),
            (unsigned)atomic_load(&g_decodedFmt),
            (long long)atomic_load(&g_decodedW),
            (long long)atomic_load(&g_decodedH));
        send(c, msg, w, 0);
        close(c);
    }
}


// ================================================================
// SECTION 8: WS-CLIENT (aus Inject.x übernommen, vereinfacht)
// ================================================================

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
            char resp[2048];
            ssize_t n = recvHTTPHeaders(fd, resp, sizeof(resp));
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
                    atomic_fetch_add(&g_wsBinary, 1);
                    atomic_fetch_add(&g_wsBytes, plen);
                    enqueueNal([NSData dataWithBytesNoCopy:payload length:(NSUInteger)plen freeWhenDone:YES]);
                } else if (opcode == 0x1) {
                    atomic_fetch_add(&g_wsText, 1);
                    NSString *cmd = [[NSString alloc] initWithBytes:payload length:(NSUInteger)plen encoding:NSUTF8StringEncoding];
                    if (cmd) {
                        if ([cmd isEqualToString:@"enable"]) {
                            atomic_store(&g_enabled, 1);
                            L("WS: ENABLE");
                        } else if ([cmd isEqualToString:@"disable"]) {
                            atomic_store(&g_enabled, 0);
                            L("WS: DISABLE");
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


// ================================================================
// SECTION 9: CONSTRUCTOR
// ================================================================

%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    L("injiziert in %@ (pid=%d)", proc, getpid());
    if (![proc isEqualToString:@"mediaserverd"]) return;

    g_nalQueue = [NSMutableArray array];
    g_queueLock = [NSLock new];
    g_frameLock = [NSLock new];

    L("VCamInject v2 build=%s", VCAM_BUILD_ID);

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

    L("bereit — enabled=%d", (int)atomic_load(&g_enabled));
}
}
