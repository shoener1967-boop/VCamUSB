// VCamHub — WS-Server + Floating-Status-Button in SpringBoard (Dopamine2-roothide)
//
// Architektur (final, nach Astra-Analyse):
//   - Scene-gebundenes Fullscreen-UIWindow (initWithWindowScene:)
//   - VCamOverlayWindow-Subklasse: hitTest:withEvent: gibt außerhalb des
//     Button-/Panel-Bereichs nil zurück -> ALLE Touches gehen durch
//   - Lockscreen-Sicherheitsnetz: bei Lock wird das Overlay sofort hidden
//     und passThrough=YES, erst nach Unlock wieder sichtbar
//   - Status-Server (8768) meldet auch locked=0/1 für Diagnose

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <CommonCrypto/CommonDigest.h>
#import <os/log.h>
#import <pthread.h>

#define WS_PORT 8767
#define MAX_PENDING (16 * 1024 * 1024)

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.shosh.vcamhub", "hub"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- Client-Liste
static int g_clients[16] = { -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 };
static pthread_mutex_t g_cliMutex = PTHREAD_MUTEX_INITIALIZER;
static int g_clientCount = 0;

// ---------------------------------------------------------------- Overlay-Globals
static UIWindow *g_overlayWindow = nil;
static UIView *g_buttonContainer = nil;
static int g_overlayCreated = 0;
static int g_overlayCalls = 0;
static BOOL g_locked = NO;

// ---------------------------------------------------------------- Pass-Through Window
@interface VCamOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *interactiveView;
@property (nonatomic, weak) UIView *interactivePanel;
@property (nonatomic, assign) BOOL passThrough;
@end
@implementation VCamOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha <= 0.01 || !self.userInteractionEnabled) return nil;
    if (self.passThrough) return nil;

    UIView *target = self.interactiveView;
    if (!target || target.hidden || target.alpha <= 0.01) return nil;

    CGRect buttonRect = [target.superview convertRect:target.frame toView:self];
    buttonRect = CGRectInset(buttonRect, -8.0, -8.0);   // Touch-Toleranz

    CGRect panelRect = CGRectNull;
    if (self.interactivePanel && !self.interactivePanel.hidden) {
        panelRect = [self.interactivePanel.superview convertRect:self.interactivePanel.frame toView:self];
    }

    if (CGRectContainsPoint(buttonRect, point) ||
        (!CGRectIsNull(panelRect) && CGRectContainsPoint(panelRect, point))) {
        return [super hitTest:point withEvent:event];
    }
    return nil;   // alles andere geht durch
}
@end

// ---------------------------------------------------------------- Hub: Client-Verwaltung
static void hubAddClient(int fd) {
    pthread_mutex_lock(&g_cliMutex);
    for (int i = 0; i < 16; i++) {
        if (g_clients[i] == -1) { g_clients[i] = fd; g_clientCount++; break; }
    }
    pthread_mutex_unlock(&g_cliMutex);
    L("client+ total=%d", g_clientCount);
}

static void hubRemoveClient(int fd) {
    pthread_mutex_lock(&g_cliMutex);
    for (int i = 0; i < 16; i++) {
        if (g_clients[i] == fd) { g_clients[i] = -1; g_clientCount--; break; }
    }
    pthread_mutex_unlock(&g_cliMutex);
    L("client- total=%d", g_clientCount);
}

static BOOL hubSendAll(int fd, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    while (len > 0) {
        ssize_t n = send(fd, p, len > (size_t)INT_MAX ? INT_MAX : (int)len, 0);
        if (n <= 0) return NO;
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

static void hubBroadcastExcept(int fromFd, const uint8_t *data, size_t len) {
    pthread_mutex_lock(&g_cliMutex);
    for (int i = 0; i < 16; i++) {
        int fd = g_clients[i];
        if (fd != -1 && fd != fromFd) {
            uint8_t hdr[10];
            size_t hl = 2;
            hdr[0] = 0x82;
            if (len < 126) {
                hdr[1] = (uint8_t)len;
            } else if (len < 65536) {
                hdr[1] = 126;
                hdr[2] = (uint8_t)(len >> 8);
                hdr[3] = (uint8_t)(len & 0xff);
                hl = 4;
            } else {
                hdr[1] = 127;
                for (int b = 0; b < 8; b++) hdr[2 + b] = (uint8_t)(len >> (56 - b * 8));
                hl = 10;
            }
            if (!hubSendAll(fd, hdr, hl) || !hubSendAll(fd, data, len)) continue;
        }
    }
    pthread_mutex_unlock(&g_cliMutex);
}

// ---------------------------------------------------------------- WS Util
static NSString *wsAcceptKey(NSString *key) {
    NSString *magic = [key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([magic UTF8String], (CC_LONG)strlen([magic UTF8String]), digest);
    return [[NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH] base64EncodedStringWithOptions:0];
}

static ssize_t hubRecvHeaders(int fd, char *buf, size_t cap) {
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

static void *hubClientThread(void *arg) {
    int fd = (int)(intptr_t)arg;
    @autoreleasepool {
        uint8_t *buf = malloc(MAX_PENDING);
        ssize_t n = hubRecvHeaders(fd, (char *)buf, MAX_PENDING);
        if (n > 0) {
            buf[n] = 0;
            NSString *req = [NSString stringWithUTF8String:(const char *)buf];
            NSRange keyR = [req rangeOfString:@"Sec-WebSocket-Key: "];
            if (keyR.location != NSNotFound) {
                NSString *key = [req substringFromIndex:keyR.location + keyR.length];
                key = [[key componentsSeparatedByString:@"\r\n"].firstObject
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSString *resp = [NSString stringWithFormat:
                    @"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %@\r\n\r\n",
                    wsAcceptKey(key)];
                send(fd, [resp UTF8String], strlen([resp UTF8String]), 0);
                hubAddClient(fd);
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
                    if (opcode == 0x9) {
                        uint8_t pong_hdr[2] = {0x8A, (uint8_t)(plen & 0x7f)};
                        send(fd, pong_hdr, 2, 0);
                        if (plen > 0) send(fd, payload, (int)plen, 0);
                        free(payload);
                        continue;
                    }
                    if (opcode == 0x2 || opcode == 0x1) {
                        hubBroadcastExcept(fd, payload, (size_t)plen);
                        free(payload);
                        continue;
                    }
                    free(payload);
                }
                hubRemoveClient(fd);
            }
        }
        free(buf);
    }
    close(fd);
    return NULL;
}

static void statusServerThread(void) {
    int srv2 = socket(AF_INET, SOCK_STREAM, 0);
    if (srv2 < 0) { L("status socket fail: %s", strerror(errno)); return; }
    int one2 = 1;
    setsockopt(srv2, SOL_SOCKET, SO_REUSEADDR, &one2, sizeof(one2));
    struct sockaddr_in a2 = {0};
    a2.sin_family = AF_INET;
    a2.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a2.sin_port = htons(8768);
    if (bind(srv2, (struct sockaddr *)&a2, sizeof(a2)) < 0) {
        L("status bind fail: %s", strerror(errno));
        close(srv2);
        return;
    }
    if (listen(srv2, 4) < 0) { close(srv2); return; }
    L("Status-Server auf 127.0.0.1:8768");
    while (1) {
        int c = accept(srv2, NULL, NULL);
        if (c < 0) continue;
        char msg[512];
        snprintf(msg, sizeof(msg),
            "overlayCalls=%d overlayCreated=%d window=%p clients=%d "
            "locked=%d hidden=%d passThrough=%d\n",
            g_overlayCalls, g_overlayCreated, g_overlayWindow, g_clientCount,
            (int)g_locked,
            g_overlayWindow ? (int)g_overlayWindow.hidden : -1,
            g_overlayWindow && [g_overlayWindow isKindOfClass:[VCamOverlayWindow class]]
                ? (int)((VCamOverlayWindow *)g_overlayWindow).passThrough : -1);
        send(c, msg, strlen(msg), 0);
        close(c);
    }
}

static void hubServerThread(void) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { L("socket fail: %s", strerror(errno)); return; }
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(WS_PORT);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        L("bind fail: %s", strerror(errno));
        close(srv);
        return;
    }
    if (listen(srv, 8) < 0) { close(srv); return; }
    L("WS-Server auf 127.0.0.1:%d", WS_PORT);
    while (1) {
        struct sockaddr_in cli = {0};
        socklen_t clen = sizeof(cli);
        int fd = accept(srv, (struct sockaddr *)&cli, &clen);
        if (fd < 0) continue;
        pthread_t t;
        pthread_create(&t, NULL, hubClientThread, (void *)(intptr_t)fd);
        pthread_detach(t);
    }
}

// ---------------------------------------------------------------- Overlay
static UIWindowScene *ActiveScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive ||
                ws.activationState == UISceneActivationStateForegroundInactive) {
                return ws;
            }
        }
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.hidden && w.alpha > 0.0 && w.windowScene != nil) return w.windowScene;
        }
    }
    return nil;
}

static BOOL IsLocked(void) {
    @try {
        id value = [[UIApplication sharedApplication] valueForKey:@"hasBlankedScreen"];
        return [value boolValue];
    } @catch (NSException *e) {
        return NO;
    }
}

static void HideOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_locked = YES;
        if (g_overlayWindow && [g_overlayWindow isKindOfClass:[VCamOverlayWindow class]]) {
            VCamOverlayWindow *w = (VCamOverlayWindow *)g_overlayWindow;
            w.passThrough = YES;
            w.hidden = YES;
        }
        L("Overlay versteckt (locked)");
    });
}

static void ShowOverlayIfUnlocked(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_locked) return;
        if (g_overlayWindow && [g_overlayWindow isKindOfClass:[VCamOverlayWindow class]]) {
            VCamOverlayWindow *w = (VCamOverlayWindow *)g_overlayWindow;
            w.passThrough = NO;
            w.hidden = NO;
        }
        L("Overlay sichtbar (unlocked)");
    });
}

// ---------------------------------------------------------------- Banner-Target
@interface VCamBannerTarget : NSObject
- (void)buttonTapped:(UIButton *)btn;
- (void)pan:(UIPanGestureRecognizer *)pan;
@end
@implementation VCamBannerTarget {
    CGPoint _panStart;
}
- (void)buttonTapped:(UIButton *)btn {
    L("Button getippt — Panel togglen");
    VCamOverlayWindow *w = (VCamOverlayWindow *)g_overlayWindow;
    if (![w isKindOfClass:[VCamOverlayWindow class]]) return;

    UIView *panel = w.interactivePanel;
    if (panel && !panel.hidden) {
        panel.hidden = YES;   // Panel schließen
        return;
    }
    if (!panel) {
        // Info-Panel einmalig erstellen
        panel = [[UIView alloc] initWithFrame:CGRectMake(16, 70, 280, 90)];
        panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.95];
        panel.layer.cornerRadius = 14;
        panel.layer.borderWidth = 1.0;
        panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, 252, 30)];
        lbl.text = @"VCamUSB aktiv";
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont boldSystemFontOfSize:16];
        [panel addSubview:lbl];

        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(14, 42, 252, 40)];
        sub.text = [NSString stringWithFormat:@"Clients: %d\nWebSocket 127.0.0.1:%d", g_clientCount, WS_PORT];
        sub.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
        sub.font = [UIFont systemFontOfSize:12];
        sub.numberOfLines = 2;
        [panel addSubview:sub];

        [w.rootViewController.view addSubview:panel];
        w.interactivePanel = panel;
    }
    panel.hidden = NO;
}
- (void)pan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    if (pan.state == UIGestureRecognizerStateBegan) {
        _panStart = v.center;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:g_overlayWindow];
        v.center = CGPointMake(_panStart.x + t.x, _panStart.y + t.y);
    }
}
@end
static VCamBannerTarget *g_bannerTarget = nil;

static void showOverlay(void) {
    g_overlayCalls++;
    if (g_overlayWindow != nil) return;   // idempotent

    // Sicherheits-Check: bei gesperrtem Gerät nichts anzeigen
    if (IsLocked()) {
        L("Gerät gesperrt — Overlay nicht erstellen");
        return;
    }

    UIWindowScene *scene = ActiveScene();
    VCamOverlayWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        if (scene != nil) {
            win = [[VCamOverlayWindow alloc] initWithWindowScene:scene];
        } else {
            win = [[VCamOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
    } else {
        win = [[VCamOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }

    if (@available(iOS 13.0, *)) {
        win.frame = scene.coordinateSpace.bounds;
    }
    win.windowLevel = UIWindowLevelAlert + 1.0;
    win.backgroundColor = [UIColor clearColor];
    win.alpha = 1.0;
    win.hidden = NO;
    win.userInteractionEnabled = YES;
    win.passThrough = NO;

    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor clearColor];
    root.view.userInteractionEnabled = YES;

    // Grüner Status-Button (Container 64x64 oben rechts)
    CGFloat size = 64.0;
    CGFloat margin = 16.0;
    CGRect screenB = [UIScreen mainScreen].bounds;
    g_buttonContainer = [[UIView alloc] initWithFrame:
        CGRectMake(screenB.size.width - size - margin, 120, size, size)];
    g_buttonContainer.backgroundColor = [UIColor clearColor];
    g_buttonContainer.userInteractionEnabled = YES;

    g_bannerTarget = [[VCamBannerTarget alloc] init];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = g_buttonContainer.bounds;
    button.backgroundColor = [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:0.95];
    button.layer.cornerRadius = size / 2.0;
    button.layer.borderWidth = 3.0;
    button.layer.borderColor = [UIColor whiteColor].CGColor;
    button.userInteractionEnabled = YES;
    [button addTarget:g_bannerTarget action:@selector(buttonTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    [g_buttonContainer addSubview:button];

    // Drag-Geste auf dem Container (Pan verschiebt den Button)
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:g_bannerTarget action:@selector(pan:)];
    [g_buttonContainer addGestureRecognizer:pan];

    [root.view addSubview:g_buttonContainer];
    win.rootViewController = root;
    win.interactiveView = g_buttonContainer;

    g_overlayWindow = win;
    [g_overlayWindow makeKeyAndVisible];

    g_overlayCreated = 1;
    L("Overlay erstellt: window=%p scene=%p button=%p locked=%d",
      g_overlayWindow, (__bridge void *)scene, g_buttonContainer, (int)IsLocked());
}

// ---------------------------------------------------------------- Entry
__attribute__((constructor))
static void vcamhub_init(void) {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    L("ctor in %@ (pid=%d)", proc, getpid());
    if (![proc isEqualToString:@"SpringBoard"]) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        hubServerThread();
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        statusServerThread();
    });

    // Lockscreen-Observer (mehrere Signale kombinieren)
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:@"SBDashBoardLockStateChangedNotification"
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            BOOL locked = [note.userInfo[@"locked"] boolValue];
            if (locked) HideOverlay();
            else { g_locked = NO; ShowOverlayIfUnlocked(); }
        }];
    [nc addObserverForName:@"SBLockScreenManagerLockCompleteNotification"
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) { HideOverlay(); }];
    [nc addObserverForName:@"SBLockScreenManagerUnlockCompleteNotification"
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) { g_locked = NO; ShowOverlayIfUnlocked(); }];

    // Overlay-Start (Notification + Fallback, idempotent)
    [nc addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            L("DidFinishLaunching empfangen");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ showOverlay(); });
        }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ showOverlay(); });

    L("Hub bereit");
}
