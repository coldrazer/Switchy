#include "game_patches.h"
#include "aspect_patch.h"
#include "game_version.h"
#include "world_survey.h"
#include <TargetConditionals.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdatomic.h>
#include <math.h>
#include <pthread.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>

/* 60 FPS.
   TOTK's adaptive present-interval controller (main+0x8f6bec, called once per frame from main+0x8f68b4) turns the main
   thread's measured frame work time (system object +0x118, written at main+0x8f6a44 just before the present) into a
   number of 60 Hz ticks, clamps it to the controller's [minimum, maximum] interval and hands the result both to
   nvnWindowSetPresentInterval and to the variable-frame-rate step (main+0x7a83e4: ratio = interval * 0.5, frame time =
   interval / 60). Shipping code uses a minimum of 2 (30 fps), so game speed follows whatever interval is chosen.
   The patch lowers the minimum to 1 (60 fps). The controller still raises the interval to 2 or 3 when a frame's work
   does not fit, with its own hysteresis, so slow scenes fall back to 30 or 20 fps at correct speed.
   Two further sites make the lowering robust: the controller now tries a lower interval when the measured work fits
   it (instead of waiting for a stored candidate that shipping code initialises to the old minimum), and the lowered
   result is floored at 1 so an interval of 0 can never reach the window or the frame-rate step.
   TOTK_FPS60=0 leaves the shipping controller untouched. */
typedef struct { uint64_t offset; uint32_t original, replacement; const char *what; } GamePatch;

static const GamePatch fps60_sites[] = {
    {GAME_ADDR(0x8f6c60), 0x6b08015f, 0x7100055f, "clamp: cmp w10, #1 (was cmp w10, w8 = minimum)"},
    {GAME_ADDR(0x8f6c64), 0x1a89b10a, 0x1a9fa52a, "clamp: csinc w10, w9, wzr, ge (desired = max(desired, 1))"},
    {GAME_ADDR(0x8f6c88), 0xb9401a8a, 0xd503201f, "lower trigger: nop the stored-candidate load (try lower when desired < current)"},
    {GAME_ADDR(0x8f6d18), 0x6b08015f, 0x7100055f, "raise path: cmp w10, #1"},
    {GAME_ADDR(0x8f6d28), 0x1a88c1ac, 0x1a9fc5ac, "raise path: csinc w12, w13, wzr, gt (next lower candidate floors at 1)"},
    {GAME_ADDR(0x8f6d7c), 0xb9400288, 0x52800028, "lower path: mov w8, #1 (minimum interval 1)"},
    {GAME_ADDR(0x8f6d98), 0x2a0a03f5, 0x1a9fa555, "lower path: csinc w21, w10, wzr, ge (result never below 1)"},
};

static int fps60_enabled(void) {
    const char *e = getenv("TOTK_FPS60");
    return !(e && !strcmp(e, "0"));
}

/* One atomic 64-bit value holds ratio (low float) and frame seconds (high
   float). The guest reads the two lanes independently; both always remain
   finite and in range, including if an update falls between the reads. */
static _Atomic uint64_t *frame_step_data;
static uint64_t last_present_ns;
static double frame_samples[5];
static unsigned frame_sample_count, frame_sample_next;

static int realtime_enabled(void) {
    const char *e = getenv("TOTK_REALTIME");
    return !(e && !strcmp(e, "0"));
}

static uint64_t frame_step_bits(float seconds) {
    float ratio = seconds * 30.0f;
    uint32_t lo, hi;
    memcpy(&lo, &ratio, 4);
    memcpy(&hi, &seconds, 4);
    return (uint64_t)lo | ((uint64_t)hi << 32);
}

/* Diagnostics (TOTK_INPUT_FILE "framestep <ms>"): pin the frame step to a fixed length, 0 back to real time. 2026-10-17
   this showed the game over "retry" waiting on a step of at least one 30 fps frame. */
static _Atomic uint32_t pinned_step_us;
void runtime_frame_step_pin(double ms) {
    uint32_t us = ms > 0 ? (uint32_t)(ms * 1000.0 + 0.5) : 0;
    atomic_store(&pinned_step_us, us);
    if (frame_step_data && us) atomic_store_explicit(frame_step_data, frame_step_bits((float)(us / 1e6)), memory_order_release);
    if (!us) fprintf(stderr, "[totk] frame step back to real time\n");
    else fprintf(stderr, "[totk] frame step pinned at %.3f ms (ratio %.3f, diagnostics)%s\n", us / 1000.0, us / 1e6 * 30.0,
                 frame_step_data ? "" : " -- but the real-time patch is off, nothing changes");
}
void runtime_frame_step_update(uint64_t now_ns) {
    if (!frame_step_data || !now_ns) return;
    if (atomic_load_explicit(&pinned_step_us, memory_order_relaxed)) { last_present_ns = now_ns; return; }
    if (!last_present_ns) { last_present_ns = now_ns; return; }
    double dt = (double)(now_ns - last_present_ns) * 1e-9;
    last_present_ns = now_ns;
    if (dt > 0.25 || dt < 0.001) { frame_sample_count = frame_sample_next = 0; return; }
    if (dt < 1.0 / 120.0) dt = 1.0 / 120.0;
    if (dt > 1.0 / 15.0) dt = 1.0 / 15.0;
    frame_samples[frame_sample_next++ % 5] = dt;
    if (frame_sample_count < 5) frame_sample_count++;
    double sum = 0;
    for (unsigned i = 0; i < frame_sample_count; i++) sum += frame_samples[i];
    atomic_store_explicit(frame_step_data, frame_step_bits((float)(sum / frame_sample_count)), memory_order_release);
}

static uint32_t adrp_reg(unsigned rd, uint64_t site, uint64_t target) {
    int64_t pages = (int64_t)(target >> 12) - (int64_t)(site >> 12);
    if (pages < -(1 << 20) || pages >= (1 << 20)) runtime_fail("real-time frame-step data outside ADRP range");
    uint32_t imm = (uint32_t)pages & 0x1fffff;
    return 0x90000000u | ((imm & 3u) << 29) | ((imm >> 2) << 5) | (rd & 31u);
}
static uint32_t adrp_x9(uint64_t site, uint64_t target) { return adrp_reg(9, site, target); }

/* iOS cannot write code pages at run time: tools/export (TOTK_EXPORT_IOS, runtime/loader.c) runs these same patches on the
   Mac and the patched text is embedded in the app. On the device the loader only checks that the patched words are there. */
#if TARGET_OS_IPHONE
#define CODE_PATCHED_AT_BUILD 1
#else
#define CODE_PATCHED_AT_BUILD 0
#endif

static void put_word(Module *m, uint64_t off, uint32_t word, const char *what) {
    if (!CODE_PATCHED_AT_BUILD) { memcpy(m->base + off, &word, 4); return; }
    uint32_t have;
    memcpy(&have, m->base + off, 4);
    if (have != word) {
        fprintf(stderr, "[totk] %s main+%#llx: embedded %08x, expected patched %08x\n", what, (unsigned long long)off, have, word);
        runtime_fail("embedded main text was not patched at build time (ios/tools/build_embed.sh)");
    }
}

static void patch_realtime(Module *m) {
    /* The loader reserved a writable page immediately after main's image.
       No game allocation or rewritten-code veneer can overlap this page. */
    uint64_t data_off = (m->file_size + 0x3fff) & ~0x3fffULL;
    if (data_off + 0x4000 != m->size || data_off & 0xfff) runtime_fail("real-time frame-step page layout");
    static const struct { uint64_t off; uint32_t original; } sites[] = {
        {GAME_ADDR(0x7a83f4),0x1e220020}, {GAME_ADDR(0x7a83f8),0x52a84e08}, {GAME_ADDR(0x7a83fc),0x1e270101},
        {GAME_ADDR(0x7a8400),0x1e2c1002}, {GAME_ADDR(0x7a840c),0x1e211801}, {GAME_ADDR(0x7a8410),0x1e220800},
        {GAME_ADDR(0x8f68b8),0xbd425e60}, {GAME_ADDR(0x8f68bc),0x1e2c1001},
        {GAME_ADDR(0x8f68cc),0x5e21d800}, {GAME_ADDR(0x8f68d0),0x1e210800}
    };
    for (size_t i = 0; i < sizeof sites / sizeof *sites; i++) {
        uint32_t word = 0;
        if (sites[i].off + 4 > m->text_end) runtime_fail("real-time frame-step site outside main text");
        memcpy(&word, m->base + sites[i].off, 4);
        if (CODE_PATCHED_AT_BUILD) break;   /* checked against the patched words below */
        if (word != sites[i].original) {
            fprintf(stderr,"[totk] real-time frame-step main+%#llx: found %08x expected %08x\n",
                    (unsigned long long)sites[i].off, word, sites[i].original);
            runtime_fail("real-time frame-step requires matching game-version original instructions");
        }
    }
    const uint32_t nop = 0xd503201f;
    uint32_t repl[] = {
        adrp_x9((uintptr_t)m->base + GAME_ADDR(0x7a83f4), (uintptr_t)m->base + data_off),
        0xbd400120, /* ldr s0, [x9]       : ratio = dt * 30 */
        0xbd400521, /* ldr s1, [x9, #4]   : dt in seconds  */
        nop, nop, nop,
        adrp_x9((uintptr_t)m->base + GAME_ADDR(0x8f68b8), (uintptr_t)m->base + data_off),
        0xbd400120, /* global ratio, same shared value */
        nop, nop
    };
    for (size_t i = 0; i < sizeof sites / sizeof *sites; i++)
        put_word(m, sites[i].off, repl[i], "real-time frame step");
    frame_step_data = (_Atomic uint64_t *)(void *)(m->base + data_off);
    atomic_store(frame_step_data, frame_step_bits(1.0f / 60.0f));
    fprintf(stderr,"[totk] real-time frame step: %zu verified instructions; initial 16.67 ms, sampled at each present\n",
            sizeof sites / sizeof *sites);
}

/* Render resolution (TOTK_RENDER_RES=<w>x<h>, e.g. 960x540).
   main+0xc63064 reads the scene render size {w, h} from the game's parameter tree (main+0xc6325c: handheld 1280x720,
   docked 1600x900), converts it to floats and stores it in the renderer at +0xcc4 / +0xcc8; every scene render target
   is sized from there (traced with TOTK_SIZE_CHAIN: the per-frame render-target requests at main+0xa2818c take their
   size from this view). The community 1008p / 1080p exefs patches change the same place. Here the size comes from the
   loader's data page after main (the real-time frame-step page, +16): three instructions,
     main+0xc630bc  scvtf s0, s8              -> adrp x9, <page>
     main+0xc630c4  str s0, [x19, #0xcc4]     -> ldp s0, s1, [x9, #16]
     main+0xc630c8  scvtf s1, s9              -> str s0, [x19, #0xcc4]
   and the store of s1 at main+0xc630d8 stays. The size read from the parameter is then not used. The host writes the
   page at load, so on the phone (code patched at build) the size is still chosen at run time: TOTK_RENDER_RES, or the
   game's handheld 1280x720 when unset / 0 (the phone always reports handheld mode). The game's final passes scale the
   scene to its output (1280x720 handheld). */
static const GamePatch render_res_sites[3] = {
    {GAME_ADDR(0xc630bc), 0x5e21d900, 0, "scvtf s0, s8 -> adrp x9, <data page>"},
    {GAME_ADDR(0xc630c4), 0xbd0cc660, 0x2d420520, "str s0, [x19, #0xcc4] -> ldp s0, s1, [x9, #16]"},
    {GAME_ADDR(0xc630c8), 0x5e21d921, 0xbd0cc660, "scvtf s1, s9 -> str s0, [x19, #0xcc4]"},
};
static int render_res(unsigned *w, unsigned *h) {
    const char *e = getenv("TOTK_RENDER_RES");
    if (!e || !*e || !strcmp(e, "0")) return 0;
    if (sscanf(e, "%ux%u", w, h) != 2 || *w < 64 || *h < 64 || *w > 4096 || *h > 4096) runtime_fail("TOTK_RENDER_RES must be <width>x<height>");
    return 1;
}
static void patch_render_res(Module *m) {
    uint64_t data_off = (m->file_size + 0x3fff) & ~0x3fffULL;
    unsigned w = 1280, h = 720; int set = render_res(&w, &h);
    if (!CODE_PATCHED_AT_BUILD && !set) return;   /* Mac: the game's own size unless asked */
    uint32_t want[3] = {adrp_x9((uintptr_t)m->base + render_res_sites[0].offset, (uintptr_t)m->base + data_off),
                        render_res_sites[1].replacement, render_res_sites[2].replacement};
    if (CODE_PATCHED_AT_BUILD) {
        uint32_t have; memcpy(&have, m->base + render_res_sites[0].offset, 4);
        if (have == render_res_sites[0].original) { fprintf(stderr, "[totk] render resolution: the game's own (not patched at build)\n"); return; }
        for (int i = 0; i < 3; i++) put_word(m, render_res_sites[i].offset, want[i], "render resolution");   /* checks */
    } else {
        for (int i = 0; i < 3; i++) {
            uint32_t word; memcpy(&word, m->base + render_res_sites[i].offset, 4);
            if (word != render_res_sites[i].original) {
                fprintf(stderr, "[totk] render resolution patch main+%#llx: found %08x, expected %08x (%s)\n",
                        (unsigned long long)render_res_sites[i].offset, word, render_res_sites[i].original, render_res_sites[i].what);
                runtime_fail("render resolution patch: main does not match the selected game version");
            }
        }
        for (int i = 0; i < 3; i++) memcpy(m->base + render_res_sites[i].offset, &want[i], 4);
    }
    float v[2] = {(float)w, (float)h};
    memcpy(m->base + data_off + 16, v, sizeof v);
    fprintf(stderr, "[totk] render resolution patch: scene render size %ux%u%s (3 instructions at main+0xc630bc, value on the data page)\n",
            w, h, set ? "" : " (the game's handheld size; TOTK_RENDER_RES not set)");
}

/* Output resolution ("true 2K", 2026-10-17; key 3 switches it while playing). Two sizes are 1920x1080 in the game:
   1. The swapchain. nnMain writes the framework's display size as a constant before creating the graphics framework
      ("NvInitializeGraphics"); the framework's system object keeps it at +0x9c / +0xa0 and creates the swapchain from it
      (main+0xe9d8c0). It is made the largest output size (2560x1440), fixed for the run:
        main+0xe996ac  mov  x8, #0x780            (1920)   -> mov  x8, #w
        main+0xe996b0  movk x8, #0x438, lsl #32   (1080)   -> movk x8, #h, lsl #32
   2. The output size of the graphics parameters (docked and handheld entries, with inheritance: +0x38 of the entry, getter
      main+0xc632b0; +0x30 is the scene render size, 1600x900 docked). main+0xc63064 reads it for the current mode and gives it
      to the window crop and to the renderer's display slot 0 (main+0xc631e0 -> main+0xc6322c, renderer +0x388); the canvas the
      game composes the frame in is that slot times the display scale (main+0x93b9c4, scale 1.0), and the final copy to the
      swapchain draws that size. It is read from the loader's data page instead (+32, {w, h}), and the renderer the routine
      works on is stored next to it (+40) so the host can ask for a new layout (the getter has no side effects):
        main+0xc630a4  mov  x0, x20               -> adrp x21, <data page>
        main+0xc630a8  bl   main+0xc632b0         -> str  x19, [x21, #40]   (x19 = the renderer)
        main+0xc630ac  ldr  x21, [x0]             -> ldr  x21, [x21, #32]   (the output size)
   Switching while playing (key 3, runtime_output_res_toggle): main+0x1185358 (called from main+0x1185310, an event handler
   the renderer registers by name hash at main+0xec86c8; also main+0xc5fd00) re-runs main+0xc63064 when the operation mode
   changed or bit 0x200 of the renderer's +0xca4 is set, then clears the bit and flags the displays for rebuilding (+0xca0
   bit 0) -- the path a Switch takes when it is docked or undocked. The host writes the other size to the data page, sets
   that bit and posts the "operation mode changed" notification (oe message 30; the mode itself stays docked) so that the
   handler runs; the game lays out its crop, canvas and UI again at the new size. At 1920x1080 the picture fills the
   swapchain's top-left (the crop says so) and the present scales it to the window (MetalFX when the window is bigger: the
   2K output). The scene keeps its render size either way; its final upscale (MetalFX on the Mac, shader a3a570eb) writes
   the canvas.
   TOTK_OUTPUT_RES: auto (the Mac default) = a 2560x1440 swapchain and heaps so that key 3 can switch at any time, starting at
   1920x1080 (the user's choice, 2026-10-17: "default 1080p"; needs the HeapDef overlay built by make romfs-patches; without
   it the game's own 1920x1080, no switching); <w>x<h> = that largest size, starting there (TOTK_OUTPUT_RES=2560x1440 starts
   in true 2K); 0 = the game's own 1920x1080, no switching. iOS and the iOS export (TOTK_EXPORT_IOS) keep the game's own size. Decided once;
   every caller sees the same answer. Mac only. */
static int output_full_at_start = 1;
static int output_res_auto(unsigned *w, unsigned *h) {
#if TARGET_OS_OSX
    if (getenv("TOTK_EXPORT_IOS")) return 0;
    const char *dir = getenv("TOTK_ROMFS_PATCHES_OUT"); char path[4096];
    snprintf(path, sizeof path, "%s/2560x1440/manifest.tsv", dir ? dir : "extracted/" TOTK_GAME_DIR "/romfs-patches-out");
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "[totk] true 2K (TOTK_OUTPUT_RES=auto): off, %s is missing (make romfs-patches)\n", path); return 0; }
    fclose(f);
    *w = 2560; *h = 1440; output_full_at_start = 0;
    fprintf(stderr, "[totk] true 2K (TOTK_OUTPUT_RES=auto): starts at 1920x1080 (the default); key 3 switches between 1920x1080 and 2560x1440\n");
    return 1;
#else
    (void)w; (void)h; return 0;
#endif
}
static int output_res(unsigned *w, unsigned *h) {
    static int decided, on; static unsigned cw, ch;
    if (!decided) {
        const char *e = getenv("TOTK_OUTPUT_RES");
        /* iOS shows 720p only (the user, 2026-10-18), auto or not; the iOS export (TOTK_EXPORT_IOS) makes the phone's
           embedded code on the Mac, so it follows the same rule. */
        if (TARGET_OS_IPHONE || getenv("TOTK_EXPORT_IOS")) {
            on = 0;
            if (e && *e && strcmp(e, "0") && strcmp(e, "auto")) fprintf(stderr, "[totk] TOTK_OUTPUT_RES=%s ignored: iOS shows 720p only\n", e);
        } else if (e && !strcmp(e, "0")) on = 0;
        else if (!e || !*e || !strcmp(e, "auto")) on = output_res_auto(&cw, &ch);
        else if (sscanf(e, "%ux%u", &cw, &ch) != 2 || cw < 640 || ch < 360 || cw > 7680 || ch > 4320) runtime_fail("TOTK_OUTPUT_RES must be <width>x<height> (640x360 .. 7680x4320), auto or 0");
        else on = 1;
        decided = 1;
    }
    if (on) { *w = cw; *h = ch; }
    return on;
}
int runtime_output_res(unsigned *w, unsigned *h) { return !CODE_PATCHED_AT_BUILD && output_res(w, h); }
/* The canvas-sized render targets come from agl::utl::DynamicTextureAllocator (initialised once, main+0x8e1a98): a single
   heap of the HeapDef size "DynamicTextureAllocatorMem" (113664 KiB), carved from the "Graphics" heap (201728 KiB, the heap
   of gsys::SystemTask), with no parent to grow from. At 2560x1440 the title runs out of it (the allocator main+0x798934
   then dereferences the null block, main+0x799390). The HeapDef overlay for the output size (scripts/make_output_res_overlay.py,
   loaded by runtime/romfs.c) scales DynamicTextureAllocatorMem with the output pixels, rounded up to whole MiB, and grows
   Graphics by the same amount; the application pool grows by it too (rounded up to 2 MiB), so no other heap shrinks. */
uint64_t runtime_output_res_extra_bytes(void) {
    unsigned w, h;
    if (!runtime_output_res(&w, &h)) return 0;
    double ratio = (double)w * h / (1920.0 * 1080.0);
    if (ratio <= 1.0) return 0;
    uint64_t kib = (uint64_t)ceil(113664.0 * ratio / 1024.0) * 1024 - 113664;
    return kib << 10;
}
enum { DP_OUTPUT_SIZE = 32, DP_RENDERER = 40 };   /* data page: the output size {w, h} the game reads; the renderer it stores */
static _Atomic(uint8_t *) output_page;
static unsigned output_w, output_h;   /* the largest output size (the swapchain) */
static uint64_t pack_size(unsigned w, unsigned h) { return (uint64_t)h << 32 | w; }
uint64_t runtime_output_size_current(void) {
    uint8_t *page = atomic_load(&output_page);
    return page ? atomic_load((_Atomic uint64_t *)(void *)(page + DP_OUTPUT_SIZE)) : pack_size(1920, 1080);
}
static void patch_output_res(Module *m) {
    unsigned w, h;
    if (CODE_PATCHED_AT_BUILD || !output_res(&w, &h)) return;
    uint64_t data_off = (m->file_size + 0x3fff) & ~0x3fffULL;
    if (data_off + 0x4000 != m->size || data_off & 0xfff) runtime_fail("output resolution data page layout");
    const GamePatch sites[5] = {
        {GAME_ADDR(0xe996ac), 0xd280f008, 0xd2800000u | (w << 5) | 8u, "mov x8, #0x780 (1920) -> mov x8, #w (the swapchain)"},
        {GAME_ADDR(0xe996b0), 0xf2c08708, 0xf2c00000u | (h << 5) | 8u, "movk x8, #0x438, lsl #32 (1080) -> movk x8, #h, lsl #32"},
        {GAME_ADDR(0xc630a4), 0xaa1403e0, adrp_reg(21, (uintptr_t)m->base + GAME_ADDR(0xc630a4), (uintptr_t)m->base + data_off), "mov x0, x20 -> adrp x21, <data page>"},
        {GAME_ADDR(0xc630a8), GAME_OUTPUT_CALL_WORD, 0xf90016b3, "bl main+0xc632b0 (the parameters' output size) -> str x19, [x21, #40] (the renderer)"},
        {GAME_ADDR(0xc630ac), 0xf9400015, 0xf94012b5, "ldr x21, [x0] -> ldr x21, [x21, #32] (the output size)"},
    };
    for (int i = 0; i < 5; i++) {
        uint32_t word; memcpy(&word, m->base + sites[i].offset, 4);
        if (word != sites[i].original) {
            fprintf(stderr, "[totk] output resolution patch main+%#llx: found %08x, expected %08x (%s)\n", (unsigned long long)sites[i].offset, word, sites[i].original, sites[i].what);
            runtime_fail("output resolution patch: main does not match the selected game version");
        }
    }
    uint8_t *page = m->base + data_off; output_w = w; output_h = h;
    atomic_store((_Atomic uint64_t *)(void *)(page + DP_OUTPUT_SIZE), output_full_at_start ? pack_size(w, h) : pack_size(1920, 1080));
    atomic_store((_Atomic uint64_t *)(void *)(page + DP_RENDERER), 0);
    for (int i = 0; i < 5; i++) memcpy(m->base + sites[i].offset, &sites[i].replacement, 4);
    atomic_store(&output_page, page);   /* Publish initialized state to the HUD on the main thread. */
    fprintf(stderr, "[totk] output resolution patch: swapchain %ux%u (main+0xe996ac), the game's output %s from the data page (main+0xc630a4); texture heap and Graphics +%llu KiB (HeapDef overlay)\n",
            w, h, output_full_at_start ? "at that size" : "1920x1080 for now", (unsigned long long)(runtime_output_res_extra_bytes() >> 10));
}
/* Two-state output-size helper retained for internal use: switch between the largest size and 1920x1080. The renderer
   lays out again at the next frame (see patch_output_res). */
int runtime_output_res_toggle(void) {
    if (!output_page) { fprintf(stderr, "[totk] key 3: switching the output size needs a 2K-capable start (TOTK_OUTPUT_RES auto with the HeapDef overlay, or <w>x<h>)\n"); return 0; }
    _Atomic uint64_t *size = (_Atomic uint64_t *)(void *)(output_page + DP_OUTPUT_SIZE);
    int full = atomic_load(size) != pack_size(output_w, output_h);
    atomic_store(size, full ? pack_size(output_w, output_h) : pack_size(1920, 1080));
    uint64_t renderer = atomic_load((_Atomic uint64_t *)(void *)(output_page + DP_RENDERER));
    const char *before = "";
    if (renderer) {
        uint32_t old = __atomic_fetch_or((uint32_t *)(uintptr_t)(renderer + 0xca4), 0x200u, __ATOMIC_SEQ_CST);
        before = old & 0x200u ? " (the previous switch was still pending)" : "";
        runtime_oe_push_message(30);   /* nn::oe "operation mode changed": the game runs its display handler (main+0x1185310) */
    }
    fprintf(stderr, "[totk] key 3: the game's output %ux%u (%s)%s%s\n", full ? output_w : 1920u, full ? output_h : 1080u,
            full ? "true 2K: the canvas and the UI at that size" : "the 2K output: 1080p canvas, MetalFX scales it at present",
            renderer ? " from the next layout" : "; the game has not laid out its displays yet, it takes this size when it does", before);
    return 1;
}
/* Key 3: cycle the active 2K presentation path. The normal startup is 1080p game output with the MetalFX output scaler
   enabled; native 2K switches the game's canvas/UI to 2560x1440; off returns to 1080p and disables the output scaler. */
int runtime_output_mode_cycle(void) {
    if (!output_page) {
        fprintf(stderr, "[totk] key 3: 2K mode cycling needs a 2K-capable start (TOTK_OUTPUT_RES=auto with the HeapDef overlay, or <w>x<h>)\n");
        return 0;
    }
    _Atomic uint64_t *size = (_Atomic uint64_t *)(void *)(output_page + DP_OUTPUT_SIZE);
    int full = atomic_load(size) == pack_size(output_w, output_h);
    extern int mfxup_output_enabled(void);
    extern void dm_gfx_set_flag(const char *name, int value);
    int next_full, next_mfx;
    const char *name;
    if (full) { next_full = 0; next_mfx = 0; name = "关闭 2K"; }
    else if (mfxup_output_enabled()) { next_full = 1; next_mfx = 0; name = "原生 2K"; }
    else { next_full = 0; next_mfx = 1; name = "MetalFX 2K"; }
    if (full != next_full) runtime_output_res_toggle();
    dm_gfx_set_flag("mfx_output", next_mfx);
    dm_gfx_set_flag("mfx_upscale", next_mfx);
    fprintf(stderr, "[totk] key 3: %s\n", name);
    return 1;
}

/* Diagnostic (Mac): TOTK_TRAP_AT=<main offset> writes brk #0 there; the crash handler (runtime/loader.c, SIGTRAP) then prints
   the registers and the call chain at that moment, plus what TOTK_CRASH_MEM / TOTK_CRASH_HEAPFIND / TOTK_CRASH_HEAPWALK ask for,
   and exits: "stop here and show me the state" without a debugger. */
static void patch_trap(Module *m) {
    const char *e = getenv("TOTK_TRAP_AT");
    if (CODE_PATCHED_AT_BUILD || !e || !*e) return;
    uint64_t off = strtoull(e, NULL, 0);
    if (off & 3 || off + 4 > m->text_end) runtime_fail("TOTK_TRAP_AT must be a 4-byte aligned offset in main's text");
    uint32_t brk = 0xd4200000, was;
    memcpy(&was, m->base + off, 4);
    memcpy(m->base + off, &brk, 4);
    fprintf(stderr, "[totk] TOTK_TRAP_AT: brk at main+%#llx (was %08x); the game stops there with a register dump\n", (unsigned long long)off, was);
}

static void check_site(const Module *m, const GamePatch *p) {
    if (p->offset + 4 > m->text_end) runtime_fail("60 FPS patch site outside the main text segment");
    uint32_t word;
    memcpy(&word, m->base + p->offset, sizeof word);
    if (word != p->original) {
        fprintf(stderr, "[totk] 60 FPS patch main+%#llx: found %08x, expected %08x (%s)\n",
                (unsigned long long)p->offset, word, p->original, p->what);
        runtime_fail("60 FPS patch: main does not match the selected game version");
    }
}

/* TOTK_PCHTXT=<file>: an emulator ExeFS patch for main in pchtxt form, as community mods ship them (for example
   TOTK-Ultrawide's aspect-ratio patch), for trying them here. Mac only: the phone's code is patched at build. Its
   @nsobid must be main's build id, read from the extracted ExeFS (extracted/<version>/exefs/main at 0x40); the lines
   between @enabled and @stop are "<main address> <bytes>" (offset_shift 0x100 is the NSO header only the IPS form
   counts). It is applied before this runtime's own patches, whose checks of the original words then refuse a file that
   overlaps them. */
static void patch_pchtxt(Module *m) {
    const char *path = getenv("TOTK_PCHTXT");
    if (!path || !*path) return;
    FILE *f = fopen(path, "r");
    if (!f) runtime_fail("TOTK_PCHTXT: cannot open the file");
    char nso[256], want[41] = {0}; uint8_t id[20];
    snprintf(nso, sizeof nso, "extracted/%s/exefs/main", TOTK_GAME_DIR);
    FILE *n = fopen(nso, "rb");
    if (!n || fseek(n, 0x40, SEEK_SET) || fread(id, 1, sizeof id, n) != sizeof id) runtime_fail("TOTK_PCHTXT: cannot read main's build id from extracted/<version>/exefs/main");
    fclose(n);
    for (int i = 0; i < 20; i++) snprintf(want + 2 * i, 3, "%02X", id[i]);
    char line[1024]; int enabled = 0, matched = 0; unsigned count = 0, bytes = 0;
    while (fgets(line, sizeof line, f)) {
        if (!strncmp(line, "@nsobid-", 8)) {
            if (strncasecmp(line + 8, want, 40)) runtime_fail("TOTK_PCHTXT is for another build of main");
            matched = 1; continue;
        }
        if (!strncmp(line, "@enabled", 8)) { enabled = 1; continue; }
        if (!strncmp(line, "@stop", 5)) break;
        unsigned long long at; char hex[512];
        if (!enabled || line[0] == '@' || sscanf(line, "%llx %511s", &at, hex) != 2) continue;
        size_t len = strlen(hex);
        if (!matched) runtime_fail("TOTK_PCHTXT: patches before its @nsobid line");
        if (len % 2 || at + len / 2 > m->file_size) runtime_fail("TOTK_PCHTXT: a patch line is malformed or outside main");
        for (size_t i = 0; i < len / 2; i++) { unsigned v; sscanf(hex + 2 * i, "%2x", &v); m->base[at + i] = (uint8_t)v; }
        count++; bytes += (unsigned)(len / 2);
    }
    fclose(f);
    if (!matched) runtime_fail("TOTK_PCHTXT has no @nsobid line");
    fprintf(stderr, "[totk] TOTK_PCHTXT %s: %u patches, %u bytes in main (build id %s)\n", path, count, bytes, want);
}

/* Cheats, from the 1.0.0 build's public cheat table (build 082CE09B06E33A12): the same verified-write shape as the
   patches above. Every cheat is off unless its TOTK_CHEAT_* variable is 1. A site is written only while it still holds
   the original instruction the table was made against, and a cheat whose writes overlap another enabled cheat's with a
   different value is refused instead of half-applied. 1.0.0 only: other versions have their own tables. */
#if defined(TOTK_GAME_V112) || defined(TOTK_GAME_V121) || defined(TOTK_GAME_V143)
static void apply_cheats(Module *m) { (void)m; }
static void start_cheat_vm(Module *m) { (void)m; }
#else
typedef struct { uint32_t offset, word; } CheatWrite;
typedef struct { const char *env, *label; const CheatWrite *writes; size_t count; } Cheat;

static const CheatWrite cheat_health[] = {   /* infinite health */
    {0x02AA6FF8u, 0x176EA507u},
    {0x02AA6FFCu, 0xF9400008u},
    {0x02AA6FF0u, 0xB9000808u},
    {0x02AA6FF4u, 0x34000048u},
    {0x02AA6FECu, 0xB9401808u},
    {0x00650414u, 0x14915AF6u},
};

static const CheatWrite cheat_stamina[] = {   /* infinite stamina */
    {0x0096EF40u, 0xBD405E61u},
    {0x00B1EFDCu, 0xF290000Fu},
    {0x00B1EFE0u, 0xD2A8B76Fu},
    {0x00B1EFE4u, 0xB900026Fu},
};

static const CheatWrite cheat_durability[] = {   /* infinite weapon durability */
    {0x02AA6FE4u, 0x177471F1u},
    {0x02AA6FE8u, 0xB9000901u},
    {0x02AA6FE0u, 0xB9401901u},
    {0x007C37A8u, 0x148B8E0Eu},
};

static const CheatWrite cheat_battery[] = {   /* infinite battery */
    {0x00B6B4A4u, 0xBD004669u},
    {0x00B6B51Cu, 0xBD004669u},
};

static const CheatWrite cheat_eat[] = {   /* items are not consumed when eaten */
    {0x02AA6FDCu, 0x00000001u},
    {0x02AA6FD0u, 0x17E3B1D1u},
    {0x02AA6FD4u, 0x0B01014Au},
    {0x02AA6FC8u, 0x1B057C21u},
    {0x02AA6FCCu, 0x34000045u},
    {0x02AA6FC0u, 0x5400006Du},
    {0x02AA6FC4u, 0x3100043Fu},
    {0x02AA6FB8u, 0x180000E5u},
    {0x02AA6FBCu, 0x540000EDu},
    {0x02AA6FB0u, 0x3100043Fu},
    {0x02AA6FB4u, 0x34000065u},
    {0x02AA6FACu, 0x18000185u},
    {0x02393714u, 0x141C4E26u},
};

static const CheatWrite cheat_item10[] = {   /* picked-up items count ten times */
    {0x02AA6FD8u, 0x0000000Au},
    {0x02AA6FD0u, 0x17E3B1D1u},
    {0x02AA6FD4u, 0x0B01014Au},
    {0x02AA6FC8u, 0x1B057C21u},
    {0x02AA6FCCu, 0x34000045u},
    {0x02AA6FC0u, 0x5400006Du},
    {0x02AA6FC4u, 0x3100043Fu},
    {0x02AA6FB8u, 0x180000E5u},
    {0x02AA6FBCu, 0x540000EDu},
    {0x02AA6FB0u, 0x3100043Fu},
    {0x02AA6FB4u, 0x34000065u},
    {0x02AA6FACu, 0x18000185u},
    {0x02393714u, 0x141C4E26u},
};

static const CheatWrite cheat_maxstamina[] = {   /* maximum stamina (three rings) */
    {0x02AA6FF8u, 0x453B8000u},
    {0x02AA6FFCu, 0xD65F03C0u},
    {0x02AA6FF0u, 0xBD001D00u},
    {0x02AA6FF4u, 0x1C000060u},
    {0x0096ED24u, 0x9484E0B3u},
};

typedef struct { uint32_t offset, word; } CheatOriginal;
/* The original words at the patched sites, from the table's Restore Code. */
static const CheatOriginal cheat_originals[] = {
    {0x00650414u, 0xF9400008u}, {0x0096EF40u, 0x1E212841u},
    {0x00B1EFDCu, 0xBD401D00u}, {0x00B1EFE0u, 0x9B292908u}, {0x00B1EFE4u, 0xBD000260u},
    {0x007C37A8u, 0xB9400901u}, {0x00B6B4A4u, 0xBD004668u}, {0x00B6B51Cu, 0xBD004668u},
};

static const Cheat cheats[] = {
    {"TOTK_CHEAT_HEALTH", "infinite health", cheat_health, sizeof cheat_health / sizeof cheat_health[0]},
    {"TOTK_CHEAT_STAMINA", "infinite stamina", cheat_stamina, sizeof cheat_stamina / sizeof cheat_stamina[0]},
    {"TOTK_CHEAT_DURABILITY", "infinite weapon durability", cheat_durability, sizeof cheat_durability / sizeof cheat_durability[0]},
    {"TOTK_CHEAT_BATTERY", "infinite battery", cheat_battery, sizeof cheat_battery / sizeof cheat_battery[0]},
    {"TOTK_CHEAT_EAT", "items are not consumed when eaten", cheat_eat, sizeof cheat_eat / sizeof cheat_eat[0]},
    {"TOTK_CHEAT_ITEM10", "picked-up items count ten times", cheat_item10, sizeof cheat_item10 / sizeof cheat_item10[0]},
    {"TOTK_CHEAT_MAXSTAMINA", "maximum stamina (three rings)", cheat_maxstamina, sizeof cheat_maxstamina / sizeof cheat_maxstamina[0]},
};

static void apply_cheats(Module *m) {
    uint32_t written[128], word[128];
    size_t written_count = 0;
    for (size_t c = 0; c < sizeof cheats / sizeof cheats[0]; c++) {
        const Cheat *cheat = &cheats[c];
        const char *env = getenv(cheat->env);
        if (!env || strcmp(env, "1")) continue;
        int ok = 1;
        for (size_t w = 0; w < cheat->count && ok; w++) {
            for (size_t o = 0; o < sizeof cheat_originals / sizeof cheat_originals[0]; o++) {
                if (cheat_originals[o].offset != cheat->writes[w].offset) continue;
                uint32_t have;
                memcpy(&have, m->base + cheat->writes[w].offset, sizeof have);
                if (have != cheat_originals[o].word) {
                    fprintf(stderr, "[totk] cheat %s: main+%#x holds %08x, expected %08x; left off\n",
                            cheat->label, cheat->writes[w].offset, have, cheat_originals[o].word);
                    ok = 0;
                }
            }
            for (size_t b = 0; b < written_count; b++)
                if (written[b] == cheat->writes[w].offset && word[b] != cheat->writes[w].word) {
                    fprintf(stderr, "[totk] cheat %s: main+%#x conflicts with another enabled cheat; left off\n",
                            cheat->label, cheat->writes[w].offset);
                    ok = 0;
                }
        }
        if (!ok) continue;
        for (size_t w = 0; w < cheat->count; w++) {
            if (written_count < sizeof written / sizeof written[0]) {
                written[written_count] = cheat->writes[w].offset;
                word[written_count++] = cheat->writes[w].word;
            }
            memcpy(m->base + cheat->writes[w].offset, &cheat->writes[w].word, sizeof(uint32_t));
        }
        fprintf(stderr, "[totk] cheat on: %s (%zu words)\n", cheat->label, cheat->count);
    }
}

/* ---- cheat VM (1.0.0 only) ----
   The pointer and loop cheats from the same table, executed by a small interpreter with Atmosphere's opcode
   semantics: StoreStatic, EndConditional, ControlLoop, LoadRegisterMemory (including pointer chases), 
   StoreStaticToAddress, PerformArithmeticStatic/Register, StoreRegisterToAddress, keypress and register
   conditionals. Memory access goes through mach so a pointer that the game has not set up yet cannot crash the
   process; reads and writes that fail are skipped, exactly like the reference VM. */
typedef struct { const char *env, *label; const uint32_t *code; size_t count; int started; } VmCheat;

static const uint32_t vm_zonai[] = {   /* Zonai devices x98 */
    0x580F0000u, 0x04646C60u, 0x580F1000u, 0x00000138u, 0x580F1000u, 0x000011A8u, 0x300C0000u, 0x0000003Cu,
    0x989BF000u, 0x540B1000u, 0x00000000u, 0xC046B400u, 0xFFFFFFFFu, 0x640F1000u, 0x00000000u, 0x00000062u,
    0x21000000u, 0x780F0000u, 0x00000008u, 0x20000000u, 0x310C0000u,
};

static const uint32_t vm_materials_all[] = {   /* all materials x98 */
    0x580F0000u, 0x04646C60u, 0x580F1000u, 0x00000138u, 0x580F1000u, 0x00000F28u, 0x300C0000u, 0x000001FEu,
    0x989BF000u, 0x540B1000u, 0x00000000u, 0xC046B400u, 0xFFFFFFFFu, 0x640F1000u, 0x00000000u, 0x00000062u,
    0x21000000u, 0x780F0000u, 0x00000008u, 0x20000000u, 0x310C0000u,
};

static const uint32_t vm_food_all[] = {   /* all cooked food x98 */
    0x580F0000u, 0x04646C60u, 0x580F1000u, 0x00000138u, 0x580F1000u, 0x00000E68u, 0x300C0000u, 0x00000078u,
    0x989BF000u, 0x540B1000u, 0x00000000u, 0xC046B400u, 0xFFFFFFFFu, 0x640F1000u, 0x00000000u, 0x00000062u,
    0x21000000u, 0x780F0000u, 0x00000008u, 0x20000000u, 0x310C0000u,
};

static const uint32_t vm_jump[] = {   /* jump high while holding X — keypress */
    0x580F0000u, 0x04642D88u, 0x580F1000u, 0x000000C8u, 0x580F1000u, 0x00000178u, 0x580F1000u, 0x00000030u,
    0x780F0000u, 0x000000FCu, 0x80000004u, 0x640F01D0u, 0x00000000u, 0x41200000u, 0x20000000u,
};

static const uint32_t vm_maxheart[] = {   /* maximum hearts (40) */
    0x580F0000u, 0x045D6750u, 0x580F1000u, 0x00000480u, 0x580F1000u, 0x00000220u, 0x580F1000u, 0x000002F8u,
    0x580F1000u, 0x00001830u, 0x780F0000u, 0x00000008u, 0x640F1000u, 0x00000000u, 0x000000A0u,
};

static const uint32_t vm_heartfill[] = {   /* hearts always full */
    0x580F0000u, 0x045D6750u, 0x580F1000u, 0x00000480u, 0x580F1000u, 0x00000220u, 0x580F1000u, 0x000002F8u,
    0x989AF000u, 0x580F1000u, 0x00001838u, 0x540F1000u, 0x00000008u, 0x580A1000u, 0x00001830u, 0xA4FA0200u,
    0x00000008u,
};

static const uint32_t vm_staminafill[] = {   /* stamina always full */
    0x580F0000u, 0x045D6750u, 0x580F1000u, 0x00000480u, 0x580F1000u, 0x00000220u, 0x580F1000u, 0x000003A8u,
    0x780F0000u, 0x000013CCu, 0x640F1000u, 0x00000000u, 0x453B8000u,
};

static const uint32_t vm_weapon[] = {   /* weapon durability max */
    0x580F0000u, 0x045D6750u, 0x580F1000u, 0x00000480u, 0x580F1000u, 0x00000220u, 0x580F1000u, 0x00000230u,
    0x580F1000u, 0x00000028u, 0x580F1000u, 0x00000040u, 0x580F1000u, 0x00000220u, 0x580F1000u, 0x000002F8u,
    0x989AF000u, 0x580F1000u, 0x00001838u, 0x540F1000u, 0x00000008u, 0x580A1000u, 0x00001830u, 0xA4FA0200u,
    0x00000008u,
};

static const uint32_t vm_bow[] = {   /* bow durability max */
    0x580F0000u, 0x045D6750u, 0x580F1000u, 0x00000480u, 0x580F1000u, 0x00000220u, 0x580F1000u, 0x00000230u,
    0x580F1000u, 0x00000070u, 0x580F1000u, 0x00000040u, 0x580F1000u, 0x00000220u, 0x580F1000u, 0x000002F8u,
    0x989AF000u, 0x580F1000u, 0x00001838u, 0x540F1000u, 0x00000008u, 0x580A1000u, 0x00001830u, 0xA4FA0200u,
    0x00000008u,
};

static const uint32_t vm_shield[] = {   /* shield durability max */
    0x580F0000u, 0x045D6750u, 0x580F1000u, 0x00000480u, 0x580F1000u, 0x00000220u, 0x580F1000u, 0x00000230u,
    0x580F1000u, 0x00000088u, 0x580F1000u, 0x00000040u, 0x580F1000u, 0x00000220u, 0x580F1000u, 0x000002F8u,
    0x989AF000u, 0x580F1000u, 0x00001838u, 0x540F1000u, 0x00000008u, 0x580A1000u, 0x00001830u, 0xA4FA0200u,
    0x00000008u,
};

static const uint32_t vm_arrows[] = {   /* 998 arrows */
    0x580F0000u, 0x04646C60u, 0x580F1000u, 0x00000138u, 0x580F1000u, 0x00000BE8u, 0x780F0000u, 0x00000000u,
    0x640F1000u, 0x00000000u, 0x000003E6u,
};

static const uint32_t vm_rupees[] = {   /* 99,999,999 rupees */
    0x580F0000u, 0x04646C60u, 0x580F1000u, 0x000000D8u, 0x780F0000u, 0x00028EA4u, 0x640F1000u, 0x00000000u,
    0x05F5E0FFu,
};

static const uint32_t vm_materials[] = {   /* materials x98 */
    0x580F0000u, 0x04646C60u, 0x580F1000u, 0x00000138u, 0x580F1000u, 0x00000F28u, 0x780F0000u, 0x00000000u,
    0x300C0000u, 0x000001F4u, 0x989BF000u, 0x540B1000u, 0x00000000u, 0xC046B400u, 0xFFFFFFFFu, 0x640F1000u,
    0x00000000u, 0x00000062u, 0x20000000u, 0x310C0000u,
};

static const uint32_t vm_food[] = {   /* cooked food x98 */
    0x580F0000u, 0x04646C60u, 0x580F1000u, 0x00000138u, 0x580F1000u, 0x00000E68u, 0x780F0000u, 0x00000000u,
    0x300C0000u, 0x00000078u, 0x989BF000u, 0x540B1000u, 0x00000000u, 0xC046B400u, 0xFFFFFFFFu, 0x640F1000u,
    0x00000000u, 0x00000062u, 0x20000000u, 0x310C0000u,
};

static const uint32_t vm_moonjump[] = {   /* moon jump while holding X — keypress */
    0x580F0000u, 0x04642D88u, 0x580F1000u, 0x000000C8u, 0x580F1000u, 0x00000178u, 0x580F1000u, 0x00000030u,
    0x780F0000u, 0x000000FCu, 0x80000004u, 0x640F1000u, 0x00000000u, 0x41200000u, 0x20000000u,
};

static const uint32_t vm_move2x[] = {   /* run 2x while holding B — keypress */
    0x580F0000u, 0x045D6750u, 0x580F1000u, 0x00000480u, 0x580F1000u, 0x00000220u, 0x580F1000u, 0x00000040u,
    0x780F0000u, 0x00000098u, 0x640F0000u, 0x00000000u, 0x3F800000u, 0x80000002u, 0x640F1000u, 0x00000000u,
    0x40000000u, 0x20000000u,
};

static VmCheat vm_cheats[] = {
    {"TOTK_CHEAT_ZONAI", "Zonai devices x98", vm_zonai, sizeof vm_zonai / sizeof vm_zonai[0], 0},
    {"TOTK_CHEAT_MATERIALS_ALL", "all materials x98", vm_materials_all, sizeof vm_materials_all / sizeof vm_materials_all[0], 0},
    {"TOTK_CHEAT_FOOD_ALL", "all cooked food x98", vm_food_all, sizeof vm_food_all / sizeof vm_food_all[0], 0},
    {"TOTK_CHEAT_JUMP", "jump high while holding X", vm_jump, sizeof vm_jump / sizeof vm_jump[0], 0},
    {"TOTK_CHEAT_MAXHEART", "maximum hearts (40)", vm_maxheart, sizeof vm_maxheart / sizeof vm_maxheart[0], 0},
    {"TOTK_CHEAT_HEARTFILL", "hearts always full", vm_heartfill, sizeof vm_heartfill / sizeof vm_heartfill[0], 0},
    {"TOTK_CHEAT_STAMINAFILL", "stamina always full", vm_staminafill, sizeof vm_staminafill / sizeof vm_staminafill[0], 0},
    {"TOTK_CHEAT_WEAPON", "weapon durability max", vm_weapon, sizeof vm_weapon / sizeof vm_weapon[0], 0},
    {"TOTK_CHEAT_BOW", "bow durability max", vm_bow, sizeof vm_bow / sizeof vm_bow[0], 0},
    {"TOTK_CHEAT_SHIELD", "shield durability max", vm_shield, sizeof vm_shield / sizeof vm_shield[0], 0},
    {"TOTK_CHEAT_ARROWS", "998 arrows", vm_arrows, sizeof vm_arrows / sizeof vm_arrows[0], 0},
    {"TOTK_CHEAT_RUPEES", "99,999,999 rupees", vm_rupees, sizeof vm_rupees / sizeof vm_rupees[0], 0},
    {"TOTK_CHEAT_MATERIALS", "materials x98", vm_materials, sizeof vm_materials / sizeof vm_materials[0], 0},
    {"TOTK_CHEAT_FOOD", "cooked food x98", vm_food, sizeof vm_food / sizeof vm_food[0], 0},
    {"TOTK_CHEAT_MOONJUMP", "moon jump while holding X", vm_moonjump, sizeof vm_moonjump / sizeof vm_moonjump[0], 0},
    {"TOTK_CHEAT_MOVE2X", "run 2x while holding B", vm_move2x, sizeof vm_move2x / sizeof vm_move2x[0], 0},
};
static uint64_t vm_base, vm_text_end;

typedef struct { const uint32_t *code; size_t n, pc; uint64_t r[16], loops[16]; int depth; } Vm;

static uint64_t cvm_mask(unsigned bw) { return bw == 8 ? ~0ULL : ((1ULL << (bw * 8)) - 1); }

static int cvm_read(uint64_t addr, void *out, size_t n) {
    mach_vm_size_t got = 0;
    if (!addr) return 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)addr, (mach_vm_size_t)n,
                                              (mach_vm_address_t)(uintptr_t)out, &got);
    return kr == KERN_SUCCESS && got == (mach_vm_size_t)n;
}

/* Text is read-only by the time the cheats run: mach refuses the write, so the page is opened just for it. */
static int cvm_write(uint64_t addr, const void *in, size_t n) {
    if (!addr) return 0;
    if (mach_vm_write(mach_task_self(), (mach_vm_address_t)addr, (vm_offset_t)(uintptr_t)in, (mach_msg_type_number_t)n) == KERN_SUCCESS)
        return 1;
    if (addr >= vm_base && addr + n <= vm_text_end) {
        uintptr_t page = (uintptr_t)addr & ~(uintptr_t)0xFFF;
        size_t len = (((size_t)(addr - page)) + n + 0xFFF) & ~(size_t)0xFFF;
        if (mprotect((void *)page, len, PROT_READ | PROT_WRITE | PROT_EXEC) == 0) {
            memcpy((void *)(uintptr_t)addr, in, n);
            mprotect((void *)page, len, PROT_READ | PROT_EXEC);
            return 1;
        }
    }
    return 0;
}

static uint64_t cvm_addr(uint32_t mem, uint64_t rel) { return mem == 4 ? rel : vm_base + rel; }

/* Advance past one opcode and its operands without executing it (conditional skipping). */
static int cvm_advance(Vm *vm, uint32_t first, uint32_t op) {
    uint32_t bw = (first >> 24) & 0xF;
    vm->pc++;
    switch (op) {
    case 0: case 1: vm->pc += 1 + (size_t)(bw == 8 ? 2 : 1); break;
    case 2: break;
    case 3: if (((first >> 24) & 0xF) == 0) vm->pc += 1; break;
    case 4: vm->pc += 2; break;
    case 5: vm->pc += 1; break;
    case 6: vm->pc += 2; break;
    case 7: vm->pc += 1; break;
    case 8: break;
    case 9: if ((first >> 8) & 0xF) vm->pc += (size_t)(bw == 8 ? 2 : 1); break;
    case 10: { uint32_t ot = (first >> 8) & 0xF; if (ot == 2 || ot == 4 || ot == 5) vm->pc += 1; break; }
    case 0xC0: { uint32_t ct = (first >> 8) & 0xF; if (ct == 0 || ct == 2) vm->pc += 1; else if (ct == 4) vm->pc += (size_t)(((first >> 20) & 0xF) == 8 ? 2 : 1); break; }
    default: return 0;
    }
    return vm->pc <= vm->n;
}

static int cvm_skip(Vm *vm, int is_if) {
    if (vm->depth <= 0) return 0;
    int desired = vm->depth - 1;
    while (vm->depth > desired && vm->pc < vm->n) {
        uint32_t first = vm->code[vm->pc];
        uint32_t op = (first >> 28) & 0xF;
        if (op >= 12) op = (op << 4) | ((first >> 24) & 0xF);
        int begins = (op == 1 || op == 8 || op == 0xC0);
        if (!cvm_advance(vm, first, op)) return 0;
        if (begins) vm->depth++;
        else if (op == 2) {
            int is_else = ((first >> 24) & 0xF) == 1;
            if (!is_else) vm->depth--;
            else if (is_if && vm->depth - 1 == desired) break;
        }
    }
    return 1;
}

static int cvm_run(const VmCheat *cheat, uint32_t keys) {
    Vm vm;
    memset(&vm, 0, sizeof vm);
    vm.code = cheat->code; vm.n = cheat->count;
    int steps = 0;
    while (vm.pc < vm.n) {
        if (++steps > 100000) return -1;
        uint32_t first = vm.code[vm.pc++];
        uint32_t op = (first >> 28) & 0xF;
        if (op >= 12) op = (op << 4) | ((first >> 24) & 0xF);
        uint32_t bw = (first >> 24) & 0xF, mem = (first >> 20) & 0xF, R = (first >> 16) & 0xF;
        switch (op) {
        case 0: {
            uint64_t rel = ((uint64_t)(first & 0xFF) << 32) | vm.code[vm.pc++];
            uint64_t value;
            if (bw == 8) { value = ((uint64_t)vm.code[vm.pc] << 32) | vm.code[vm.pc + 1]; vm.pc += 2; }
            else value = vm.code[vm.pc++];
            value &= cvm_mask(bw);
            uint64_t addr = cvm_addr(mem, rel) + vm.r[R];
            cvm_write(addr, &value, bw);
            break;
        }
        case 2:
            if (((first >> 24) & 0xF) == 1) { if (!cvm_skip(&vm, 0)) return -1; }
            else if (vm.depth > 0) vm.depth--;
            break;
        case 3:
            if (((first >> 24) & 0xF) == 0) { vm.r[R] = vm.code[vm.pc++]; vm.loops[R] = vm.pc; }
            else if (--vm.r[R] != 0) vm.pc = (size_t)vm.loops[R];
            break;
        case 5: {
            uint64_t rel = ((uint64_t)(first & 0xFF) << 32) | vm.code[vm.pc++];
            uint32_t from = (first >> 12) & 0xF, ofs = (first >> 8) & 0xF;
            uint64_t addr;
            if (from == 1) addr = vm.r[R] + rel;
            else if (from == 2) addr = vm.r[ofs] + rel;
            else if (from == 3) addr = cvm_addr(mem, vm.r[ofs] + rel);
            else addr = cvm_addr(mem, rel);
            uint64_t value;
            if (cvm_read(addr, &value, bw)) vm.r[R] = value & cvm_mask(bw);
            break;
        }
        case 6: {
            uint64_t value = ((uint64_t)vm.code[vm.pc] << 32) | vm.code[vm.pc + 1];
            vm.pc += 2;
            uint64_t addr = vm.r[R];
            if ((first >> 8) & 0xF) addr += vm.r[(first >> 4) & 0xF];
            cvm_write(addr, &value, bw);
            if ((first >> 12) & 0xF) vm.r[R] += bw;
            break;
        }
        case 7: {
            uint32_t value = vm.code[vm.pc++];
            switch ((first >> 12) & 0xF) {
            case 0: vm.r[R] += value; break;
            case 1: vm.r[R] -= value; break;
            case 2: vm.r[R] *= value; break;
            case 3: vm.r[R] <<= value; break;
            case 4: vm.r[R] >>= value; break;
            default: break;
            }
            vm.r[R] &= cvm_mask(bw);
            break;
        }
        case 8: {
            uint32_t mask = first & 0x0FFFFFFF;
            vm.depth++;
            if ((keys & mask) != mask) { if (!cvm_skip(&vm, 1)) return -1; }
            break;
        }
        case 9: {
            uint32_t math = (first >> 20) & 0xF, dst = R, src = (first >> 12) & 0xF;
            uint32_t imm = (first >> 8) & 0xF;
            uint64_t a = vm.r[src], b;
            if (imm) {
                b = (bw == 8) ? (((uint64_t)vm.code[vm.pc] << 32) | vm.code[vm.pc + 1]) : vm.code[vm.pc];
                vm.pc += (size_t)(bw == 8 ? 2 : 1);
            } else b = vm.r[(first >> 4) & 0xF];
            switch (math) {
            case 0: a += b; break;
            case 1: a -= b; break;
            case 2: a *= b; break;
            case 3: a <<= b; break;
            case 4: a >>= b; break;
            case 5: a &= b; break;
            case 6: a |= b; break;
            case 7: a = ~a; break;
            case 8: a ^= b; break;
            case 9: break;
            default: break;
            }
            vm.r[dst] = a & cvm_mask(bw);
            break;
        }
        case 10: {
            uint32_t src = (first >> 20) & 0xF, areg = R;
            uint64_t value = vm.r[src], addr = vm.r[areg];
            uint32_t ofs = (first >> 8) & 0xF;
            if (ofs == 1) addr += vm.r[(first >> 4) & 0xF];
            else if (ofs == 2) { uint64_t rel = ((uint64_t)(first & 0xF) << 32) | vm.code[vm.pc++]; addr += rel; }
            else if (ofs == 3) addr = cvm_addr((first >> 4) & 0xF, vm.r[areg]);
            else if (ofs == 4) { uint64_t rel = ((uint64_t)(first & 0xF) << 32) | vm.code[vm.pc++]; addr = cvm_addr((first >> 4) & 0xF, rel); }
            else if (ofs == 5) { uint64_t rel = ((uint64_t)(first & 0xF) << 32) | vm.code[vm.pc++]; addr = cvm_addr((first >> 4) & 0xF, vm.r[areg] + rel); }
            cvm_write(addr, &value, bw);
            if ((first >> 12) & 0xF) vm.r[areg] += bw;
            break;
        }
        case 0xC0: {
            uint32_t cbw = (first >> 20) & 0xF, cond = (first >> 16) & 0xF;
            uint32_t vr = (first >> 12) & 0xF, comp = (first >> 8) & 0xF;
            uint64_t sv = vm.r[vr] & cvm_mask(cbw), cv = 0;
            if (comp == 0) {
                uint64_t rel = ((uint64_t)(first & 0xF) << 32) | vm.code[vm.pc++];
                cvm_read(cvm_addr((first >> 4) & 0xF, rel), &cv, cbw);
            } else if (comp == 1) {
                cvm_read(cvm_addr((first >> 4) & 0xF, vm.r[first & 0xF]), &cv, cbw);
            } else if (comp == 2) {
                uint64_t rel = ((uint64_t)(first & 0xF) << 32) | vm.code[vm.pc++];
                cvm_read(vm.r[(first >> 4) & 0xF] + rel, &cv, cbw);
            } else if (comp == 3) {
                cvm_read(vm.r[(first >> 4) & 0xF] + vm.r[first & 0xF], &cv, cbw);
            } else if (comp == 4) {
                cv = (cbw == 8) ? (((uint64_t)vm.code[vm.pc] << 32) | vm.code[vm.pc + 1]) : vm.code[vm.pc];
                vm.pc += (size_t)(cbw == 8 ? 2 : 1);
            } else if (comp == 5) {
                cv = vm.r[(first >> 4) & 0xF] & cvm_mask(cbw);
            }
            cv &= cvm_mask(cbw);
            int met = 0;
            switch (cond) {
            case 1: met = sv > cv; break;
            case 2: met = sv >= cv; break;
            case 3: met = sv < cv; break;
            case 4: met = sv <= cv; break;
            case 5: met = sv == cv; break;
            case 6: met = sv != cv; break;
            default: met = 1; break;
            }
            vm.depth++;
            if (!met) { if (!cvm_skip(&vm, 1)) return -1; }
            break;
        }
        default:
            return -1;
        }
    }
    return 0;
}

static void *cheat_vm_thread(void *arg) {
    (void)arg;
    usleep(20 * 1000 * 1000);
    for (;;) {
        uint32_t keys = runtime_input_held();
        for (size_t i = 0; i < sizeof vm_cheats / sizeof vm_cheats[0]; i++) {
            VmCheat *cheat = &vm_cheats[i];
            const char *env = getenv(cheat->env);
            if (!env || strcmp(env, "1")) continue;
            if (cvm_run(cheat, keys) == 0 && !cheat->started) {
                cheat->started = 1;
                fprintf(stderr, "[totk] cheat on: %s (pointer)\n", cheat->label);
            }
        }
        usleep(250 * 1000);
    }
    return NULL;
}

static void start_cheat_vm(Module *m) {
    static int started;
    if (started) return;
    started = 1;
    vm_base = (uint64_t)(uintptr_t)m->base;
    vm_text_end = vm_base + m->text_end;
    pthread_t thread;
    if (pthread_create(&thread, NULL, cheat_vm_thread, NULL) == 0) pthread_detach(thread);
    fprintf(stderr, "[totk] cheat VM ready; pointer cheats apply from 20 s after start\n");
}

#endif

void runtime_game_patches(Module *m) {
    runtime_survey_init(m);
    const size_t n = sizeof fps60_sites / sizeof fps60_sites[0];
    if (strcmp(m->name, "main")) runtime_fail("game patches expect the main module");
    if (CODE_PATCHED_AT_BUILD) {
        /* Embedded variant: the code was patched at build time (ios/tools/build_app.sh exports with the real-time frame
           step and the 60 FPS patch), so the phone is not held at the shipping 30 fps; here we only verify the words. */
        patch_realtime(m);
        patch_render_res(m);
        for (size_t i = 0; i < n; i++) {
            uint32_t word;
            memcpy(&word, m->base + fps60_sites[i].offset, sizeof word);
            if (word != fps60_sites[i].replacement) {
                fprintf(stderr, "[totk] 60 FPS patch main+%#llx: found %08x, expected the patched %08x (%s)\n",
                        (unsigned long long)fps60_sites[i].offset, word, fps60_sites[i].replacement, fps60_sites[i].what);
                runtime_fail("60 FPS patch: embedded main was not exported with TOTK_FPS60 on");
            }
        }
        fprintf(stderr, "[totk] embedded main: real-time frame step and 60 FPS patch (%zu instructions) applied at build time\n", n);
        return;
    }
    patch_pchtxt(m);   /* first: the runtime's own patches check the original words they replace */
    apply_cheats(m);
    start_cheat_vm(m);
    if (realtime_enabled()) patch_realtime(m);
    else fprintf(stderr,"[totk] real-time frame step off (TOTK_REALTIME=0)\n");
    patch_render_res(m);
    patch_output_res(m);
    patch_trap(m);
#if defined(TOTK_GAME_V121)
    { static const uint64_t sites[] = {0xcb4b10, 0x12521cc, 0x19b36f0, 0x1ecdf68};   /* camera x2, viewport x2 (aspect_patch.h) */
      aspect_install(m, "1.2.1", sites, 4, (m->text_end + 15) & ~15ULL, (m->file_size + 0x3fff) & ~0x3fffULL); }
#else
    if (aspect_requested()) runtime_fail("TOTK_ASPECT: only 1.2.1 and 1.4.3 so far");
#endif
    if (!fps60_enabled()) {
        fprintf(stderr, "[totk] 60 FPS patch off (TOTK_FPS60=0): shipping present interval range 2..3\n");
        return;
    }
    for (size_t i = 0; i < n; i++) check_site(m, &fps60_sites[i]);   /* verify all before writing any */
    for (size_t i = 0; i < n; i++) memcpy(m->base + fps60_sites[i].offset, &fps60_sites[i].replacement, 4);
    fprintf(stderr, "[totk] %s 60 FPS patch: %zu instructions (interval range 1..3)\n", TOTK_GAME_VERSION, n);
}
