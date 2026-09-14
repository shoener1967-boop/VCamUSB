// DeviceDump — Diagnose: AVCaptureDevice-Liste beim App-Start ausgeben.
// Zeigt, ob LordVCAM/VCamUSB eine neue Device-ID registrieren oder nur Frames ersetzen.
#import <AVFoundation/AVFoundation.h>
#import <os/log.h>

static os_log_t LOG = NULL;
#define L(FMT, ...) do { if (!LOG) LOG = os_log_create("com.shosh.vcam", "devdump"); \
    os_log(LOG, "%s: " FMT, __func__, ##__VA_ARGS__); } while (0)

%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        L("injiziert in %@ (pid=%d)", proc, getpid());

        @try {
            NSArray *devs = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
            L("== AVCaptureDevice (Video) count=%lu ==", (unsigned long)devs.count);
            for (AVCaptureDevice *d in devs) {
                L("device=%@ uniqueID=%@ name=%@ model=%@ pos=%ld connected=%d",
                  d, d.uniqueID, d.localizedName, d.modelID,
                  (long)d.position, (int)d.connected);
            }
            AVCaptureDevice *def = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
            L("default=%@ id=%@", def, def.uniqueID);
        } @catch (NSException *e) {
            L("FEHLER: %@", e);
        }
    }
}
