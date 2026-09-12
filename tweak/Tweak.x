// VCamUSB — virtuelle Kamera über USB (v1: Transport + Decoder + Recon)
//
// Phase 1 (dieses Build):
//   - SpringBoard bindet WS-Server auf 127.0.0.1:8767
//   - Empfängt H.264-NAL-Units vom PC, dekodiert mit VideoToolbox
//   - Loggt Frames/Fehler über NSLog (oslog)
//   - Recon-Modus: dumped Methodennamen von AVCapture/FigCapture-Klassen,
//     damit der richtige Injektionspunkt aufm Gerät gefunden werden kann
// Phase 2 (nach Recon auf deinem Gerät):
//   - Hook des echten Kamera-Pfads (mediaserverd / AVCaptureVideoDataOutput)
//
// Kein Login, keine Lizenz, keine Cloud. iOS 15+ (16.7 roothide + 18.x Relaxin).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <CommonCrypto/CommonDigest.h>
#import <substrate.h>

#define WS_PORT 8767
#define MAX_PENDING (16*1024*1024)

static NSMutableArray<NSData *> *g_nalQueue = nil;
static NSLock *g_queueLock = nil;
static VTDecompressionSessionRef g_vtSession = NULL;
static CMFormatDescriptionRef g_fmtDesc = NULL;
static CVPixelBufferRef g_latestFrame = NULL;
static NSLock *g_frameLock = nil;
static int g_frameCount = 0;

static NSString *wsAcceptKey(NSString *key) {
    NSString *magic = [key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([magic UTF8String], (CC_LONG)strlen([magic UTF8String]), digest);
    return [[NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH] base64EncodedStringWithOptions:0];
}

static void enqueueNal(NSData *nal) {
    if (nal.length < 4) return;
    [g_queueLock lock];
    [g_nalQueue addObject:nal];
    if (g_nalQueue.count > 256) [g_nalQueue removeObjectsInRange:NSMakeRange(0, g_nalQueue.count - 256)];
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
    if (status != noErr || !imageBuffer) return;
    [g_frameLock lock];
    if (g_latestFrame) CVPixelBufferRelease(g_latestFrame);
    g_latestFrame = CVPixelBufferRetain(imageBuffer);
    g_frameCount++;
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
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    kCFAllocatorDefault, 2, ptrs, sizes, 4, &g_fmtDesc);
                if (g_fmtDesc) NSLog(@"[VCamUSB] FormatDescription OK (%zux)", sps.length, pps.length);
            }
            return;
        }

        if (g_vtSession == NULL) {
            VTDecompressionOutputCallbackRecord cb;
            cb.decompressionOutputCallback = decompressionOutputCallback;
            cb.decompressionOutputRefCon = NULL;
            NSDictionary *attrs = @{
                (__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                (__bridge id)kCVPixelBufferMetalCompatibilityKey: @YES,
            };
            OSStatus st = VTDecompressionSessionCreate(
                kCFAllocatorDefault, g_fmtDesc, NULL, (__bridge CFDictionaryRef)attrs, &cb, &g_vtSession);
            if (st != noErr || !g_vtSession) { NSLog(@"[VCamUSB] VT session failed %d", (int)st); return; }
            NSLog(@"[VCamUSB] Decode-Session OK");
        }

        static const uint8_t sc[4] = { 0, 0, 0, 1 };
        NSMutableData *block = [NSMutableData dataWithBytes:sc length:4];
        [block appendData:nal];

        CMBlockBufferRef bb = NULL;
        CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, block.length,
            kCFAllocatorDefault, NULL, 0, block.length, 0, &bb);
        memcpy(CMBlockBufferGetDataPointer(bb, NULL, NULL, NULL, NULL), block.bytes, block.length);

        CMSampleBufferRef sb = NULL;
        CMSampleBufferCreate(kCFAllocatorDefault, bb, true, NULL, NULL, g_fmtDesc, 1, 0, NULL, 0, NULL, &sb);
        CFRelease(bb);
        if (!sb) return;

        VTDecompressionSessionDecodeFrame(g_vtSession, sb, 0, NULL, NULL);
        CFRelease(sb);
    }
}

static void wsServerThread(void) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) return;
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(WS_PORT);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[VCamUSB] bind fehlgeschlagen: %s", strerror(errno));
        close(srv);
        return;
    }
    if (listen(srv, 4) < 0) { close(srv); return; }
    NSLog(@"[VCamUSB] WS-Server lauscht auf 127.0.0.1:%d", WS_PORT);

    while (1) {
        struct sockaddr_in cli = {0};
        socklen_t clen = sizeof(cli);
        int fd = accept(srv, (struct sockaddr *)&cli, &clen);
        if (fd < 0) continue;
        NSLog(@"[VCamUSB] Client verbunden");

        uint8_t *buf = malloc(MAX_PENDING);
        ssize_t n = recv(fd, buf, MAX_PENDING - 1, 0);
        if (n > 0) {
            buf[n] = 0;
            NSString *req = [NSString stringWithUTF8String:(const char *)buf];
            NSRange keyR = [req rangeOfString:@"Sec-WebSocket-Key: "];
            if (keyR.location != NSNotFound) {
                NSString *key = [req substringFromIndex:keyR.location + keyR.length];
                key = [[key componentsSeparatedByString:@"\r\n"].firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSString *resp = [NSString stringWithFormat:
                    @"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %@\r\n\r\n",
                    wsAcceptKey(key)];
                send(fd, [resp UTF8String], strlen([resp UTF8String]), 0);

                uint8_t hdr[2];
                while (recv(fd, hdr, 2, MSG_WAITALL) == 2) {
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
                    if (plen > MAX_PENDING) break;

                    uint8_t *payload = malloc((size_t)plen);
                    size_t got = 0;
                    while (got < plen) {
                        ssize_t r = recv(fd, payload + got, (size_t)(plen - got), 0);
                        if (r <= 0) break;
                        got += (size_t)r;
                    }
                    if (got < plen) { free(payload); break; }
                    if (masked) for (uint64_t i = 0; i < plen; i++) payload[i] ^= mask[i & 3];

                    if (opcode == 0x8) { free(payload); break; }
                    if (opcode == 0x2) {
                        enqueueNal([NSData dataWithBytesNoCopy:payload length:(NSUInteger)plen freeWhenDone:YES]);
                        continue;
                    }
                    if (opcode == 0x1) {
                        NSString *s = [[NSString alloc] initWithBytes:payload length:(NSUInteger)plen encoding:NSUTF8StringEncoding];
                        if (s) NSLog(@"[VCamUSB] ctrl: %@", s);
                        continue;
                    }
                    free(payload);
                }
            }
        }
        free(buf);
        close(fd);
        NSLog(@"[VCamUSB] Client getrennt");
    }
}

// ---------------------------------------------------------------------------
// Recon: Methodennamen der Kamera-Klassen dumpen (Phase-2-Vorbereitung)
// ---------------------------------------------------------------------------
static void reconDump(void) {
    @autoreleasepool {
        NSArray *candidates = @[
            @"AVCaptureVideoDataOutput", @"AVCaptureSession", @"AVCaptureDevice",
            @"AVCaptureDeviceInput", @"AVCaptureConnection", @"AVCapturePhotoOutput",
            @"FigCaptureSource", @"FigCaptureSessionProxy", @"AVFigCaptureSession",
        ];
        unsigned int count = 0;
        Class *all = objc_copyClassList(&count);
        for (unsigned int i = 0; i < count; i++) {
            Class cls = all[i];
            NSString *name = NSStringFromClass(cls);
            for (NSString *cand in candidates) {
                if ([name isEqualToString:cand] || [name hasPrefix:cand]) {
                    unsigned int mcount = 0;
                    Method *methods = class_copyMethodList(cls, &mcount);
                    NSMutableArray *names = [NSMutableArray array];
                    for (unsigned int m = 0; m < mcount; m++) {
                        [names addObject:NSStringFromSelector(method_getName(methods[m]))];
                    }
                    NSLog(@"[VCamUSB] RECON %@ (%u Methoden): %@", name, mcount,
                          [names componentsJoinedByString:@", "]);
                    free(methods);
                }
            }
        }
        free(all);
    }
}

%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSLog(@"[VCamUSB] injiziert in %@", proc);

    if ([proc isEqualToString:@"SpringBoard"]) {
        g_nalQueue = [NSMutableArray array];
        g_queueLock = [NSLock new];
        g_frameLock = [NSLock new];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            wsServerThread();
        });
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            while (1) {
                pumpDecoder();
                usleep(2000);
            }
        });
        // Periodischer Status + Recon-Dump
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            reconDump();
        });
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            while (1) {
                sleep(10);
                [g_frameLock lock];
                int fc = g_frameCount;
                [g_frameLock unlock];
                NSLog(@"[VCamUSB] decodierte Frames gesamt: %d", fc);
            }
        });
    }
}
