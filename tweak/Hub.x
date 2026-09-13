// VCamHub — WS-Server + Fan-out in SpringBoard
//
// SpringBoard darf bind() (Sandbox erlaubt es — bereits mehrfach bewiesen).
// Der Hub nimmt den PC-Feed (usbmuxd-Tunnel) auf Port 8767 entgegen und
// verteilt jede Binary-Message an alle ANDEREN Clients (Fan-out) — d.h.
// an VCamInject in mediaserverd, das sich per Loopback verbindet.
//
// Kein Decode hier, kein UI-Hook, kein Crash-Potenzial: nur Sockets.

#import <Foundation/Foundation.h>
#import <substrate.h>
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
// Simpel & lockfrei genug: ein Mutex, Array von fds.
static int g_clients[8] = { -1, -1, -1, -1, -1, -1, -1, -1 };
static pthread_mutex_t g_cliMutex = PTHREAD_MUTEX_INITIALIZER;

static void hubAddClient(int fd) {
    pthread_mutex_lock(&g_cliMutex);
    for (int i = 0; i < 8; i++) {
        if (g_clients[i] == -1) { g_clients[i] = fd; break; }
    }
    pthread_mutex_unlock(&g_cliMutex);
}

static void hubRemoveClient(int fd) {
    pthread_mutex_lock(&g_cliMutex);
    for (int i = 0; i < 8; i++) {
        if (g_clients[i] == fd) { g_clients[i] = -1; break; }
    }
    pthread_mutex_unlock(&g_cliMutex);
}

static void hubBroadcastExcept(int fromFd, const uint8_t *data, size_t len) {
    pthread_mutex_lock(&g_cliMutex);
    for (int i = 0; i < 8; i++) {
        int fd = g_clients[i];
        if (fd != -1 && fd != fromFd) {
            // Frame: FIN=1, Opcode=binary, kein Mask, Länge
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

// ---------------------------------------------------------------- Client-Thread
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
                L("Client verbunden (fd=%d)", fd);
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
                    if (opcode == 0x9) { // ping -> pong
                        uint8_t pong_hdr[2] = {0x8A, (uint8_t)(plen & 0x7f)};
                        send(fd, pong_hdr, 2, 0);
                        if (plen > 0) send(fd, payload, (int)plen, 0);
                        free(payload);
                        continue;
                    }
                    if (opcode == 0x2 || opcode == 0x1) {
                        // Binary/Text an alle anderen weiterreichen (Fan-out)
                        hubBroadcastExcept(fd, payload, (size_t)plen);
                        free(payload);
                        continue;
                    }
                    free(payload);
                }
                hubRemoveClient(fd);
                L("Client getrennt (fd=%d)", fd);
            }
        }
        free(buf);
    }
    close(fd);
    return NULL;
}

// ---------------------------------------------------------------- Server
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
    L("Hub-WS-Server auf 127.0.0.1:%d", WS_PORT);

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

// ---------------------------------------------------------------- ctor
%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    L("injiziert in %@ (pid=%d)", proc, getpid());
    // Marker: an MEHREREN Orten schreiben (roothide redirectet Pfade für
    // Jailbreak-Prozesse — wir wissen nicht, wo /var/mobile wirklich liegt)
    NSString *marker = [NSString stringWithFormat:@"hub loaded proc=%@ pid=%d\n", proc, getpid()];
    [marker writeToFile:@"/var/mobile/Documents/vcamhub_loaded.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [marker writeToFile:@"/tmp/vcamhub_loaded.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (![proc isEqualToString:@"SpringBoard"]) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        hubServerThread();
    });
    L("Hub bereit");
}
