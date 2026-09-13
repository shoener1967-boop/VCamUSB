// VCamHub — WS-Server + schwebender Status-Banner in SpringBoard (Dopamine2-roothide)
//
// Referenz-Muster (aus LordVCAM, funktioniert nachweislich auf iOS 16):
//   - Eigener UIWindow (buttonWindow), makeKeyAndVisible, hoher windowLevel
//   - Observer auf UIApplicationDidFinishLaunchingNotification
//   - Button als Subview des Windows
//   - WS-Server in eigenem Thread

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

// ---------------------------------------------------------------- Banner
static UIWindow *g_buttonWindow = nil;
static UIButton *g_floatingButton = nil;

static void bannerUpdateStatus(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_floatingButton) return;
        int clients = g_clientCount;
        UIColor *c = clients > 0
            ? [UIColor colorWithRed:0.16 green:0.78 blue:0.34 alpha:0.95]
            : [UIColor colorWithRed:0.90 green:0.30 blue:0.30 alpha:0.95];
        g_floatingButton.backgroundColor = c;
    });
}

static void hubAddClient(int fd) {
    pthread_mutex_lock(&g_cliMutex);
    for (int i = 0; i < 16; i++) {
        if (g_clients[i] == -1) { g_clients[i] = fd; g_clientCount++; break; }
    }
    pthread_mutex_unlock(&g_cliMutex);
    L("client+ total=%d", g_clientCount);
    bannerUpdateStatus();
}

static void hubRemoveClient(int fd) {
    pthread_mutex_lock(&g_cliMutex);
    for (int i = 0; i < 16; i++) {
        if (g_clients[i] == fd) { g_clients[i] = -1; g_clientCount--; break; }
    }
    pthread_mutex_unlock(&g_cliMutex);
    L("client- total=%d", g_clientCount);
    bannerUpdateStatus();
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
            if (send(fd, hdr, (int)hl, 0) != (ssize_t)hl) continue;
            if (send(fd, data, (int)len, 0) != (ssize_t)len) continue;
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

static void *hubClientThread(void *arg) {
    int fd = (int)(intptr_t)arg;
    @autoreleasepool {
        uint8_t *buf = malloc(MAX_PENDING);
        ssize_t n = recv(fd, buf, MAX_PENDING - 1, 0);
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

// ---------------------------------------------------------------- Floating Button
static void setupFloatingButton(void) {
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat size = 60.0;
    CGFloat margin = 18.0;

    g_buttonWindow = [[UIWindow alloc] initWithFrame:screen];
    g_buttonWindow.windowLevel = UIWindowLevelAlert + 100.0;
    g_buttonWindow.backgroundColor = [UIColor clearColor];

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    g_buttonWindow.rootViewController = root;

    g_floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    g_floatingButton.frame = CGRectMake(screen.size.width - size - margin, 150, size, size);
    g_floatingButton.layer.cornerRadius = size / 2.0;
    g_floatingButton.layer.borderWidth = 3.0;
    g_floatingButton.layer.borderColor = [UIColor whiteColor].CGColor;
    g_floatingButton.layer.shadowColor = [UIColor blackColor].CGColor;
    g_floatingButton.layer.shadowOpacity = 0.4;
    g_floatingButton.layer.shadowRadius = 6.0;
    g_floatingButton.layer.shadowOffset = CGSizeMake(0, 2);
    [g_floatingButton setTitle:@"●" forState:UIControlStateNormal];
    [g_floatingButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    g_floatingButton.titleLabel.font = [UIFont boldSystemFontOfSize:26];
    [root.view addSubview:g_floatingButton];

    [g_buttonWindow makeKeyAndVisible];
    bannerUpdateStatus();
    L("Floating-Button erstellt (makeKeyAndVisible)");
}

// ---------------------------------------------------------------- Entry
__attribute__((constructor))
static void vcamhub_init(void) {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    L("ctor in %@ (pid=%d)", proc, getpid());
    if (![proc isEqualToString:@"SpringBoard"]) return;

    // WS-Server sofort
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        hubServerThread();
    });

    // Floating-Button nach UIApplicationDidFinishLaunchingNotification (LordVCAM-Muster)
    [[NSNotificationCenter defaultCenter] addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            L("UIApplicationDidFinishLaunchingNotification empfangen");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                setupFloatingButton();
            });
        }];
    L("Hub bereit (Observer registriert)");
}
