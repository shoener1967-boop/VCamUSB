// dylib_probe — listet geladene Dylibs eines Zielprozesses (via dyld-all-image-infos)
// Compile: clang -arch arm64 -isysroot <iphoneos sdk> -o dylib_probe dylib_probe.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <mach-o/dyld_images.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <pid> [filter]\n", argv[0]); return 1; }
    pid_t pid = atoi(argv[1]);
    const char *filter = argc > 2 ? argv[2] : NULL;

    task_t task;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "task_for_pid(%d) failed: %s (kr=%d)\n", pid, mach_error_string(kr), kr);
        return 1;
    }

    task_dyld_info_data_t dyld_info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kr = task_info(task, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "task_info(TASK_DYLD_INFO) failed: %s\n", mach_error_string(kr));
        return 1;
    }

    struct dyld_all_image_infos *infos = (struct dyld_all_image_infos *)dyld_info.all_image_info_addr;
    if (!infos) { fprintf(stderr, "no all_image_info\n"); return 1; }

    uint32_t imageCount = 0;
    kr = mach_vm_read_overwrite(task, (mach_vm_address_t)&infos->infoArrayCount,
        sizeof(imageCount), (mach_vm_address_t)&imageCount, &count);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "read count failed\n"); return 1; }

    uint64_t arrayAddr = 0;
    kr = mach_vm_read_overwrite(task, (mach_vm_address_t)&infos->infoArray,
        sizeof(arrayAddr), (mach_vm_address_t)&arrayAddr, &count);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "read array failed\n"); return 1; }

    printf("imageCount=%u\n", imageCount);
    for (uint32_t i = 0; i < imageCount; i++) {
        // dyld_image_info: mach_header* (8), path* (8), modification (8)
        uint64_t entry[3] = {0};
        kr = mach_vm_read_overwrite(task, (mach_vm_address_t)(arrayAddr + i * 24),
            sizeof(entry), (mach_vm_address_t)entry, &count);
        if (kr != KERN_SUCCESS) continue;

        char path[512] = {0};
        kr = mach_vm_read_overwrite(task, (mach_vm_address_t)entry[1],
            sizeof(path) - 1, (mach_vm_address_t)path, &count);
        if (kr != KERN_SUCCESS) continue;
        path[511] = 0;

        if (!filter || strstr(path, filter)) {
            printf("  [%u] %s\n", i, path);
        }
    }
    return 0;
}
