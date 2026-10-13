// Runs LiveContainer's own executable patcher on a file, so Harbor's port can
// be compared with it byte for byte. Built and run only by
// scripts/differential-machopatch.sh; not part of the app.
//
//   harness <path-to-thin-arm64-mach-o> <inject: 0|1>
//
// Patches the file in place and prints the patcher's result code.

@import Darwin;
@import Foundation;
@import MachO;
#include <libgen.h>
#include <mach-o/fixup-chains.h>

// Both files are taken unmodified from the pinned LiveContainer commit.
#include "LCMachOUtils.h"
#include "lc_patch_extract.inc"

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: harness <mach-o> <inject 0|1>\n");
        return 2;
    }
    const char *path = argv[1];
    bool inject = atoi(argv[2]) != 0;

    int fd = open(path, O_RDWR);
    if (fd < 0) {
        perror("open");
        return 2;
    }
    struct stat info;
    fstat(fd, &info);
    void *map = mmap(NULL, info.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        perror("mmap");
        return 2;
    }
    if (*(uint32_t *)map != MH_MAGIC_64) {
        fprintf(stderr, "expected a thin 64-bit Mach-O\n");
        return 2;
    }

    int result = LCPatchExecSlice(path, (struct mach_header_64 *)map, inject);

    msync(map, info.st_size, MS_SYNC);
    munmap(map, info.st_size);
    close(fd);

    printf("%d\n", result);
    return 0;
}
