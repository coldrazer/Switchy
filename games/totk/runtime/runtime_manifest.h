/* runtime-manifest.txt: the per-player facts the runtime used to have compiled in (docs/ultimate-app-blueprint.md §3).

   The RomFS image's size and SHA-256 are facts about the game version, pinned by assets/expected-v*.json and compiled
   in (build/romfs_config.h). Two things belong to the player's build instead and are read from this file, written by
   scripts/prepare_runtime_manifest.py into the RomFS directory (the one directory the runtime already resolves):

     format\t1
     romfs_index_sha256\t<64 lowercase hex>
     font\t<type 0..5>\t<path>\t<file bytes>\t<font bytes>\t<64 lowercase hex>     (six rows, types in order)

   Every line ends in '\n'; nothing else is accepted (no comments, blank lines, CR, extra fields or rows). The parser
   depends on nothing else in the runtime so that tests/test_runtime_manifest.c compiles it standalone. */
#pragma once
#include <stddef.h>
#include <stdint.h>

#define RUNTIME_MANIFEST_NAME "runtime-manifest.txt"
#define RUNTIME_MANIFEST_FORMAT 1
#define RUNTIME_MANIFEST_FONTS 6
#define RUNTIME_MANIFEST_MAX_BYTES (64u * 1024u)
#define RUNTIME_MANIFEST_PATH_MAX 1024
/* A shared font is a few MiB; anything far beyond that is not one. */
#define RUNTIME_MANIFEST_FONT_MAX_BYTES (64ull * 1024ull * 1024ull)

typedef struct {
    char path[RUNTIME_MANIFEST_PATH_MAX];   /* relative to the game's working folder; no "..", no leading '/' */
    uint64_t file_bytes;                     /* the BFTTF file */
    uint64_t font_bytes;                     /* the decoded font: file_bytes - 8 */
    char sha256[65];                         /* of the whole BFTTF file */
} RuntimeManifestFont;

typedef struct {
    char romfs_index_sha256[65];
    RuntimeManifestFont fonts[RUNTIME_MANIFEST_FONTS];
} RuntimeManifest;

/* 0 on success. On failure returns -1, leaves *out zeroed and writes a one-line reason (with its line number) to err. */
int runtime_manifest_parse(const char *text, size_t size, RuntimeManifest *out, char *err, size_t err_size);
/* Reads at most RUNTIME_MANIFEST_MAX_BYTES from path and parses it. */
int runtime_manifest_read(const char *path, RuntimeManifest *out, char *err, size_t err_size);
/* The game's manifest, read once from <TOTK_ROMFS or extracted/<version>/romfs>/runtime-manifest.txt; a missing or
   invalid file stops the game. Defined in romfs.c (the parser above does not need it). */
const RuntimeManifest *runtime_manifest(void);
