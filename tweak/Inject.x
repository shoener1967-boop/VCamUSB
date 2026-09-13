// VCamInject — Frame-Swap in mediaserverd (läuft neben VCamHub in SpringBoard)
//
// Verbindet sich per Loopback-WebSocket (Client!) zum Hub (127.0.0.1:8767),
// empfängt H.264, decodiert zu CVPixelBuffer (420v — das native Kamera-Format),
// und ersetzt in FigCaptureClientSessionMonitor die echten Frames.
//
// KEIN bind(), KEIN Server hier — nur connect() als Client, das ist in
// mediaserverds Sandbox erlaubt (genau wie LordVCAM/chmp4 es machen).

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <substrate.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <CommonCrypto/CommonDigest.h>
#import <os/log.h>

#define WS_PORT 8767

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.shosh.vcaminject", "inject"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- Globals
static NSMutableArray<NSData *> *g_nalQueue = nil;
static NSLock *g_queueLock = nil;
static VTDecompressionSessionRef g_vtSession = NULL;
static CMFormatDescriptionRef g_fmtDesc = NULL;
static CVPixelBufferRef g_latestFrame = NULL;
static NSLock *g_frameLock = nil;
static int g_swapCount = 0;

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
static void decompressionOutputCallback(void *refCon, void *srcRef,
    OSStatus status, VTDecodeInfoFlags info, CVPixelBufferRef imageBuffer,
    CMTime pts, CMTime duration) {
    if (status != noErr || !imageBuffer) return;
    [g_frameLock lock];
    if (g_latestFrame) CVPixelBufferRelease(g_latestFrame);
    g_latestFrame = CVPixelBufferRetain(imageBuffer);
    [g_frameLock unlock];
}

static void pumpDecoder(void) {
    @autoreleasepool {
        NSData *nal = dequeueNal();
        if (!nal) return;
        const uint8_t *bytes = (const uint8_t *)nal.bytes;
        uint8_t nalType = bytes[0] & 0x1f;

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
                    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(g_fmtDesc);
                    L("FormatDescription OK %dx%d", (int)dims.width, (int)dims.height);
                }
            }
            return;
        }
        if (g_vtSession == NULL) {
            VTDecompressionOutputCallbackRecord cb;
            cb.decompressionOutputCallback = decompressionOutputCallback;
            cb.decompressionOutputRefCon = NULL;
            NSDictionary *attrs = @{
                (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            };
            OSStatus st = VTDecompressionSessionCreate(kCFAllocatorDefault, g_fmtDesc, NULL,
                (__bridge CFDictionaryRef)attrs, &cb, &g_vtSession);
            if (st != noErr || !g_vtSession) return;
            L("Decode-Session OK");
        }
        static const uint8_t sc[4] = { 0, 0, 0, 1 };
        NSMutableData *block = [NSMutableData dataWithBytes:sc length:4];
        [block appendData:nal];
        CMBlockBufferRef bb = NULL;
        CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, block.length,
            kCFAllocatorDefault, NULL, 0, block.length, 0, &bb);
        if (!bb) return;
        char *dst = NULL;
        size_t lenAtOffset = 0, totalLen = 0;
        if (CMBlockBufferGetDataPointer(bb, 0, &lenAtOffset, &totalLen, &dst) != kCMBlockBufferNoErr
            || !dst || lenAtOffset < block.length) {
            CFRelease(bb);
            return;
        }
        memcpy(dst, block.bytes, block.length);
        CMSampleBufferRef sb = NULL;
        CMSampleBufferCreate(kCFAllocatorDefault, bb, true, NULL, NULL, g_fmtDesc, 1, 0, NULL, 0, NULL, &sb);
        CFRelease(bb);
        if (!sb) return;
        VTDecompressionSessionDecodeFrame(g_vtSession, sb, 0, NULL, NULL);
        CFRelease(sb);
    }
}

// ---------------------------------------------------------------- Frame-Swap
static CMSampleBufferRef buildSwapSampleBuffer(void) {
    CVPixelBufferRef px = NULL;
    [g_frameLock lock];
    if (g_latestFrame) px = CVPixelBufferRetain(g_latestFrame);
    [g_frameLock unlock];
    if (!px) return NULL;

    CMFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, px, &fmt);
    if (st != noErr || !fmt) { CVPixelBufferRelease(px); return NULL; }

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMake(g_swapCount, 30),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sb = NULL;
    st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, px, fmt, &timing, &sb);
    CFRelease(fmt);
    CVPixelBufferRelease(px);
    if (st != noErr || !sb) return NULL;
    return sb;
}

// ---------------------------------------------------------------- FigCapture-Hook
%hook FigCaptureClientSessionMonitor
- (void)emitSampleBuffer:(id)sampleBuffer {
    CMSampleBufferRef fake = buildSwapSampleBuffer();
    if (fake) {
        g_swapCount++;
        %orig((__bridge id)fake);
        CFRelease(fake);
        if (g_swapCount % 300 == 1) L("swap# %d", g_swapCount);
        return;
    }
    %orig;
}

- (void)sendMediaServerdSampleAtPoint:(id)sampleBuffer {
    CMSampleBufferRef fake = buildSwapSampleBuffer();
    if (fake) {
        g_swapCount++;
        %orig((__bridge id)fake);
        CFRelease(fake);
        return;
    }
    %orig;
}
%end

// ---------------------------------------------------------------- WS-Client (Loopback zum Hub)
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

// ---------------------------------------------------------------- ctor
%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    L("injiziert in %@ (pid=%d)", proc, getpid());
    if (![proc isEqualToString:@"mediaserverd"]) return;

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
    L("bereit — verbinde mit Hub");
}
