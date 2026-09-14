// DeviceDump — Diagnose: AVCaptureDevice-Liste beim App-Start in Datei schreiben.
#import <AVFoundation/AVFoundation.h>
#import <os/log.h>

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.shosh.vcam", "devdump"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)

static NSMutableString *g_out = nil;
static void W(NSString *s) {
    [g_out appendString:s];
    [g_out appendString:@"\n"];
    NSLog(@"[devdump] %@", s);
}

%ctor {
    @autoreleasepool {
        g_out = [NSMutableString string];
        NSString *proc = [[NSProcessInfo processInfo] processName];
        [g_out appendFormat:@"injiziert in %@ (pid=%d)\n", proc, getpid()];

        @try {
            AVCaptureDeviceDiscoverySession *sess = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera,
                                                  AVCaptureDeviceTypeBuiltInUltraWideCamera,
                                                  AVCaptureDeviceTypeBuiltInTelephotoCamera]
                mediaType:AVMediaTypeVideo
                position:AVCaptureDevicePositionUnspecified];
            NSArray *devs = sess.devices;
            [g_out appendFormat:@"== AVCaptureDevice (Video) count=%lu ==\n", (unsigned long)devs.count];
            for (AVCaptureDevice *d in devs) {
                [g_out appendFormat:@"device=%@ uniqueID=%@ name=%@ model=%@ pos=%ld connected=%d\n",
                  d, d.uniqueID, d.localizedName, d.modelID,
                  (long)d.position, (int)d.connected];
            }
            AVCaptureDevice *def = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
            [g_out appendFormat:@"default=%@ id=%@\n", def, def.uniqueID];
        } @catch (NSException *e) {
            [g_out appendFormat:@"FEHLER: %@\n", e];
        }

        NSString *path = @"/var/mobile/Library/Caches/devdump.txt";
        NSError *err = nil;
        [g_out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
        NSLog(@"[devdump] geschrieben nach %@ err=%@", path, err);
        L("devdump.txt geschrieben (err=%@)", err);
    }
}
