// VCamUSB — virtuelle Kamera über USB (Phase 2)
//
// Läuft NUR in SpringBoard (kein mediaserverd-Injection → kein Crash):
//   - Schwebender Kreis (draggable), Tap öffnet Menü: USB / WLAN / Album
//   - WS-Server auf 127.0.0.1:8767, empfängt H.264 vom PC
//   - H.264-Decode via VideoToolbox
//
// Kein Login, keine Lizenz, keine Cloud. iOS 15+ (16.7 roothide + 18.x Relaxin).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
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

// ---------------------------------------------------------------- WS Util
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

// ---------------------------------------------------------------- Decoder
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
                if (g_fmtDesc) NSLog(@"[VCamUSB] FormatDescription OK");
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
            OSStatus st = VTDecompressionSessionCreate(kCFAllocatorDefault, g_fmtDesc, NULL,
                (__bridge CFDictionaryRef)attrs, &cb, &g_vtSession);
            if (st != noErr || !g_vtSession) return;
            NSLog(@"[VCamUSB] Decode-Session OK");
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
        OSStatus dpst = CMBlockBufferGetDataPointer(bb, 0, &lenAtOffset, &totalLen, &dst);
        if (dpst != kCMBlockBufferNoErr || !dst || lenAtOffset < block.length) {
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

// ---------------------------------------------------------------- WS Server
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
        close(srv); return;
    }
    if (listen(srv, 4) < 0) { close(srv); return; }
    NSLog(@"[VCamUSB] WS-Server auf 127.0.0.1:%d", WS_PORT);

    while (1) {
        struct sockaddr_in cli = {0};
        socklen_t clen = sizeof(cli);
        int fd = accept(srv, (struct sockaddr *)&cli, &clen);
        if (fd < 0) continue;
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
                    if (opcode == 0x9) { // ping -> pong (sonst killt der Client die Verbindung)
                        uint8_t pong_hdr[2] = {0x8A, (uint8_t)(plen & 0x7f)};
                        send(fd, pong_hdr, 2, 0);
                        if (plen > 0) send(fd, payload, (int)plen, 0);
                        free(payload);
                        continue;
                    }
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
    }
}

// ---------------------------------------------------------------- Floating Circle
// Pass-through-Window: fängt Touches nur auf echten Controls ab, Rest geht durch.
@interface VCamWindow : UIWindow
@end

@implementation VCamWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) {
        return nil; // durchlassen
    }
    return hit;
}
@end

@interface VCamFloatVC : UIViewController
@end

@implementation VCamFloatVC {
    UIView *_menuView;
    BOOL _menuOpen;
    UIButton *_circleBtn;
    CGPoint _circleCenter;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.view.backgroundColor = [UIColor clearColor];

    _circleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _circleBtn.frame = CGRectMake(0, 0, 60, 60);
    _circleBtn.layer.cornerRadius = 30;
    _circleBtn.backgroundColor = [UIColor colorWithRed:0.1 green:0.45 blue:0.95 alpha:0.92];
    _circleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [_circleBtn setTitle:@"VC" forState:UIControlStateNormal];
    [_circleBtn addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
    _circleCenter = CGPointMake([UIScreen mainScreen].bounds.size.width - 40, 230);
    _circleBtn.center = _circleCenter;
    [self.view addSubview:_circleBtn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
    [_circleBtn addGestureRecognizer:pan];
    _menuOpen = NO;
}

- (void)onTap {
    vlog([NSString stringWithFormat:@"[VCamUSB] Tap! Frames=%d", g_frameCount]);
    if (_menuOpen) {
        [_menuView removeFromSuperview];
        _menuView = nil;
        _menuOpen = NO;
        return;
    }
    _menuOpen = YES;
    // Menü unterhalb/neben dem Kreis platzieren (clamped an den Screen)
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat mx = _circleBtn.center.x - 125;
    CGFloat my = _circleBtn.center.y + 40;
    if (mx < 10) mx = 10;
    if (mx + 250 > screen.size.width - 10) mx = screen.size.width - 260;
    if (my + 190 > screen.size.height - 10) my = _circleBtn.center.y - 230;

    _menuView = [[UIView alloc] initWithFrame:CGRectMake(mx, my, 250, 180)];
    _menuView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
    _menuView.layer.cornerRadius = 14;
    _menuView.clipsToBounds = YES;

    NSArray *items = @[
        @{@"t": @"USB (PC-Server)", @"a": @"usb"},
        @{@"t": @"WLAN (PC-Server)", @"a": @"wlan"},
        @{@"t": @"Album (Video)", @"a": @"album"},
        @{@"t": [NSString stringWithFormat:@"Frames: %d", g_frameCount], @"a": @"status"},
    ];
    for (int i = 0; i < items.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(0, i * 44, 250, 44);
        [b setTitle:items[i][@"t"] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.tag = i;
        [b addTarget:self action:@selector(menuAction:) forControlEvents:UIControlEventTouchUpInside];
        [_menuView addSubview:b];
    }
    [self.view addSubview:_menuView];
}

- (void)menuAction:(UIButton *)sender {
    switch (sender.tag) {
        case 0: vlog(@"[VCamUSB] Modus: USB"); break;
        case 1: vlog(@"[VCamUSB] Modus: WLAN"); break;
        case 2: vlog(@"[VCamUSB] Modus: Album"); break;
        default: break;
    }
    [_menuView removeFromSuperview];
    _menuView = nil;
    _menuOpen = NO;
}

- (void)onDrag:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        _circleCenter = _circleBtn.center;
    }
    CGPoint t = [pan translationInView:self.view];
    CGPoint c = CGPointMake(_circleCenter.x + t.x, _circleCenter.y + t.y);
    CGRect sb = [UIScreen mainScreen].bounds;
    if (c.x < 40) c.x = 40;
    if (c.x > sb.size.width - 40) c.x = sb.size.width - 40;
    if (c.y < 60) c.y = 60;
    if (c.y > sb.size.height - 40) c.y = sb.size.height - 40;
    _circleBtn.center = c;
    if (pan.state == UIGestureRecognizerStateEnded) {
        if (c.x < sb.size.width / 2) c.x = 40;
        else c.x = sb.size.width - 40;
        [UIView animateWithDuration:0.2 animations:^{ _circleBtn.center = CGPointMake(c.x, _circleBtn.center.y); }];
        _circleCenter = _circleBtn.center;
    }
}
@end

// Datei-Logging für Diagnose (SpringBoard NSLog ist oft gefiltert)
static void vlog(NSString *msg) {
    NSLog(@"%@", msg);
    @autoreleasepool {
        NSString *path = @"/var/mobile/Documents/vcam.log";
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        [fh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static VCamWindow *g_floatWindow = nil;
static VCamFloatVC *g_floatVC = nil;

static void setupFloatingCircle(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        vlog(@"[VCamUSB] setupFloatingCircle start");
        if (g_floatVC) return; // nicht doppelt
        CGRect screen = [UIScreen mainScreen].bounds;

        // Pass-through-Fenster (Vollbild, fängt nur Kreis/Menü-Touches)
        VCamWindow *win = [[VCamWindow alloc] initWithFrame:screen];
        win.windowLevel = UIWindowLevelStatusBar + 100;
        win.backgroundColor = [UIColor clearColor];
        g_floatVC = [VCamFloatVC new];
        win.rootViewController = g_floatVC;
        win.hidden = NO;
        g_floatWindow = win;
        vlog(@"[VCamUSB] Pass-through-Window aktiv (level 1100)");
    });
}

%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    vlog([NSString stringWithFormat:@"[VCamUSB] injiziert in %@", proc]);

    if (![proc isEqualToString:@"SpringBoard"]) return;

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
    // UI nach 5 Sekunden Verzögerung zeigen (SpringBoard muss erst voll starten)
    vlog(@"[VCamUSB] %ctor fertig, UI kommt in 5s");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        setupFloatingCircle();
    });
}
