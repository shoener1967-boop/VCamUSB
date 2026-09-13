#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: %s <dylib>\n", argv[0]); return 1; }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) {
        printf("DLOPEN FAILED: %s\n", dlerror());
        return 1;
    }
    printf("DLOPEN OK: %s\n", argv[1]);
    return 0;
}
