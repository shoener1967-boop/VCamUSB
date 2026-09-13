// TstLoad — minimaler Lade-Test exakt nach VoiceChangerX-Formel
#import <Foundation/Foundation.h>

__attribute__((constructor))
static void tstload_init(void) {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSString *msg = [NSString stringWithFormat:@"TSTLOAD loaded proc=%@ pid=%d\n", proc, getpid()];
    for (NSString *p in @[@"/tmp/tstload.txt", @"/var/mobile/Documents/tstload.txt"]) {
        FILE *f = fopen([p UTF8String], "a");
        if (f) { fputs([msg UTF8String], f); fclose(f); }
    }
}
