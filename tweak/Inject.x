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

static CMSampleBufferRef buildSwapSampleBuffer(CMSampleBufferRef original) {
    atomic_fetch_add(&g_passthroughAttempts, 1);

    // Decoder-Buffer sicher holen (Retain unter Lock)
    CVPixelBufferRef px = NULL;
    [g_frameLock lock];
    if (g_latestFrame) px = CVPixelBufferRetain(g_latestFrame);
    [g_frameLock unlock];
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

// ---------------------------------------------------------------- Frame-Hooks
// LordVCAM-Referenz hookt BEIDE Klassen. Der aktive iOS-16-Kamerapfad ist
// BWNodeOutput (FigCaptureClientSessionMonitor.emitSampleBuffer: wird von der
// Kamera-App nicht aufgerufen — emit=0 in der Telemetrie).
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
