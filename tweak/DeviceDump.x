// DeviceDump — Diagnose: AVCaptureDevice-Liste beim App-Start ausgeben.
// Schreibt zusätzlich in eine Datei (deterministisch, ohne os_log-Kanal-Probleme).
#import <AVFoundation/AVFoundation.h>
#import <os/log.h>

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.shosh.vcam", "devdump"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)

static NSMutableString *g_out = nil;
static void W(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [g_out appendString:s];
    [g_out appendString:@"\n"];
    L("%@", s);
}

%ctor {
    @autoreleasepool {
        g_out = [NSMutableString string];
        NSString *proc = [[NSProcessInfo processInfo] processName];
        W(@"injiziert in %@ (pid=%d)", proc, getpid());

        @try {
            AVCaptureDeviceDiscoverySession *sess = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera,
                                                  AVCaptureDeviceTypeBuiltInUltraWideCamera,
                                                  AVCaptureDeviceTypeBuiltInTelephotoCamera]
                mediaType:AVMediaTypeVideo
                position:AVCaptureDevicePositionUnspecified];
            NSArray *devs = sess.devices;
            W(@"== AVCaptureDevice (Video) count=%lu ==", (unsigned long)devs.count);
            for (AVCaptureDevice *d in devs) {
                W(@"device=%@ uniqueID=%@ name=%@ model=%@ pos=%ld connected=%d",
                  d, d.uniqueID, d.localizedName, d.modelID,
                  (long)d.position, (int)d.connected);
            }
            AVCaptureDevice *def = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
            W(@"default=%@ id=%@", def, def.uniqueID);
        } @catch (NSException *e) {
            W(@"FEHLER: %@", e);
        }

        // In Datei schreiben (jbroot, für SSH-Lesezugriff)
        NSString *path = @"/var/mobile/Library/Caches/devdump.txt";
        [g_out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        L(@"geschrieben nach %@", path);
    }
}
