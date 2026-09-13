// VCamProbe — Minimal-Test: lädt ElleKit überhaupt etwas in mediaserverd/SpringBoard?
#import <Foundation/Foundation.h>
#import <os/log.h>

__attribute__((constructor))
static void probe_init(void) {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSString *marker = [NSString stringWithFormat:@"PROBE loaded proc=%@ pid=%d\n", proc, getpid()];
    [marker writeToFile:@"/tmp/vcamprobe_loaded.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [marker writeToFile:@"/var/mobile/Documents/vcamprobe_loaded.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[VCamProbe] %@", marker);
}
