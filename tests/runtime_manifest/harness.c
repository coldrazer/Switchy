/* Starts the production RomFS backend (runtime/romfs.c) and shared fonts (runtime/shared_font.c) against a synthetic
   RomFS directory and runtime-manifest.txt, with the rest of the runtime stubbed; no game data. tests/test_runtime_manifest.py
   builds it with a generated romfs_config.h for the synthetic image and checks that tampering stops the start.

     harness <romfs dir> <proof dir>    prints "ok files=<n> fonts=<bytes> first=<bytes of the first file>"
   A failure is runtime_fail: "FAIL: <message>" on stderr and exit status 7. */
#include "runtime.h"
#include "fs_host.h"
#include "runtime_manifest.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

_Noreturn void runtime_fail(const char *message) { fprintf(stderr, "FAIL: %s\n", message); fflush(stderr); _Exit(7); }
void runtime_boot_progress(const char *stage, uint64_t done, uint64_t total) { (void)stage; (void)done; (void)total; }
void runtime_boot_status(const char *stage, const char *detail) { (void)stage; (void)detail; }
uint64_t runtime_now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
void dm_guest_write_prepare(void *addr, size_t n) { (void)addr; (void)n; }
void *runtime_fs_host_override(const char *name) { (void)name; return NULL; }
int runtime_output_res(unsigned *w, unsigned *h) { (void)w; (void)h; return 0; }
uint64_t runtime_output_res_extra_bytes(void) { return 0; }

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s <romfs dir> <proof dir>\n", argv[0]); return 2; }
    setenv("TOTK_ROMFS", argv[1], 1);
    setenv("TOTK_ROMFS_PROOF_DIR", argv[2], 1);
    setenv("TOTK_ROMFS_PATCHES", "0", 1);
    unsetenv("TOTK_ROMFS_MODS");
    runtime_fs_init();
    /* The shared fonts load on first use, as when the game asks nn::pl for them. */
    size_t (*font_size)(int) = (size_t (*)(int))runtime_font_override("_ZN2nn2pl17GetSharedFontSizeENS0_14SharedFontTypeE");
    if (!font_size) runtime_fail("no shared-font override");
    size_t fonts = 0;
    for (int k = 0; k < RUNTIME_MANIFEST_FONTS; k++) fonts += font_size(k);
    /* One read through the production mount/open/read path, as the game does it. */
    unsigned (*mount)(const char *, void *, uint64_t) =
        (unsigned (*)(const char *, void *, uint64_t))runtime_fs_override("_ZN2nn2fs8MountRomEPKcPvm");
    if (!mount || mount("rom", NULL, 0)) runtime_fail("mount RomFS");
    uint64_t handle = 0, got = 0;
    unsigned rc = runtime_romfs_open(&handle, "rom:/a.txt", 1);
    char buffer[64] = {0};
    if (!rc) rc = runtime_romfs_read(&got, handle, 0, buffer, sizeof buffer - 1);
    if (rc) { fprintf(stderr, "FAIL: RomFS open/read returned 0x%x\n", rc); return 7; }
    printf("ok fonts=%zu first=%llu:%s\n", fonts, (unsigned long long)got, buffer);
    return 0;
}
