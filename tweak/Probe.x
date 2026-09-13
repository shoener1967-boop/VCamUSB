// VCamProbe — wie das funktionierende Original: MIT Substrate (%ctor)
#import <Foundation/Foundation.h>
#import <substrate.h>

%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSString *msg = [NSString stringWithFormat:@"PROBE-SUBSTRATE proc=%@ pid=%d\n", proc, getpid()];
    for (NSString *p in @[@"/tmp/vcamprobe_s.txt", @"/var/mobile/Documents/vcamprobe_s.txt"]) {
        FILE *f = fopen([p UTF8String], "a");
        if (f) { fputs([msg UTF8String], f); fclose(f); }
    }
    NSLog(@"[VCamProbe] %@", msg);
}
