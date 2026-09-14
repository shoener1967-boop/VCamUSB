// VCamAVF — App-seitiger Diagnose-Hook (Dritt-Apps: TikTok, Safari, etc.)
//
// Zählt AVCaptureVideoDataOutput-Delegate-Registrierungen und
// captureOutput:didOutputSampleBuffer:fromConnection:-Aufrufe.
// Kein Frame-Ersatz — nur Messung, welcher App-Prozess den AVFoundation-Pfad nutzt.
//
// Status-Server auf 127.0.0.1:8770 (atomic counters + Delegate-Klassen).

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <stdatomic.h>
#import <os/log.h>
#import <pthread.h>
#import <string.h>

#define STATUS_PORT 8770

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.shosh.vcamavf", "avf"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)

// ---------------------------------------------------------------- Telemetrie
static _Atomic uint64_t g_delegateSetterCalls = 0;
static _Atomic uint64_t g_captureOutputCalls = 0;
static _Atomic uint64_t g_distinctDelegates = 0;
static char g_delegateList[4096] = {0};
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static void trackDelegate(id delegate) {
    pthread_mutex_lock(&g_lock);
    const char *cls = delegate ? object_getClassName(delegate) : "(nil)";
    char entry[192];
    snprintf(entry, sizeof(entry), "%s(%p);", cls, delegate);
    if (strstr(g_delegateList, entry) == NULL) {
        size_t cur = strlen(g_delegateList);
        if (cur + strlen(entry) < sizeof(g_delegateList) - 1) {
            strncat(g_delegateList, entry, sizeof(g_delegateList) - cur - 1);
        }
    }
    pthread_mutex_unlock(&g_lock);
    atomic_fetch_add(&g_distinctDelegates, 1);
}

// ---------------------------------------------------------------- Dynamischer Delegate-Hook
static void (*orig_didOutput)(id, SEL, id, id, id) = NULL;
static Class g_hookedDelegateCls = Nil;

static void hooked_didOutput(id self, SEL sel, id output, id sampleBuffer, id connection) {
    atomic_fetch_add(&g_captureOutputCalls, 1);
    if (orig_didOutput) {
        orig_didOutput(self, sel, output, sampleBuffer, connection);
    }
}

static void installDelegateHook(Class delegateCls) {
    if (!delegateCls || g_hookedDelegateCls == delegateCls) return;
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(delegateCls, sel);
    if (!m) return;   // Delegate implementiert den Callback nicht

    orig_didOutput = (void (*)(id, SEL, id, id, id))method_getImplementation(m);
    MSHookMessageEx(delegateCls, sel, (IMP)hooked_didOutput, (IMP *)&orig_didOutput);
    g_hookedDelegateCls = delegateCls;
    L("Delegate-Hook installiert auf %s", class_getName(delegateCls));
}

// ---------------------------------------------------------------- Hook: Delegate-Setter
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    atomic_fetch_add(&g_delegateSetterCalls, 1);
    trackDelegate(delegate);
    if (delegate) {
        installDelegateHook([delegate class]);
    }
    L("setSampleBufferDelegate: delegate=%s queue=%p",
      delegate ? object_getClassName(delegate) : "(nil)", queue);
    %orig(delegate, queue);
}
%end

// ---------------------------------------------------------------- Status-Server
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
        char msg[4608];
        pthread_mutex_lock(&g_lock);
        snprintf(msg, sizeof(msg),
            "delegateSetters=%llu captureOutputCalls=%llu delegates=%s\n",
            (unsigned long long)atomic_load(&g_delegateSetterCalls),
            (unsigned long long)atomic_load(&g_captureOutputCalls),
            g_delegateList);
        pthread_mutex_unlock(&g_lock);
        send(c, msg, strlen(msg), 0);
        close(c);
    }
}

// ---------------------------------------------------------------- Entry
%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    L("VCamAVF injiziert in %@ (pid=%d)", proc, getpid());

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        statusServerThread();
    });
    L("VCamAVF bereit");
}