/* The runtime manifest parser (games/totk/runtime/runtime_manifest.c) against synthetic manifests; no game data.
   Built by tests/test_runtime_manifest.py with -fsanitize=undefined -fno-sanitize-recover=all.

     test-runtime-manifest              run the built-in cases
     test-runtime-manifest parse FILE   print the parsed fields (one per line), or the error and exit 1 */
#include "../games/totk/runtime/runtime_manifest.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define H64 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
#define F64 "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

static char good[4096];

static void build_good(void) {
    size_t n = (size_t)snprintf(good, sizeof good, "format\t1\nromfs_index_sha256\t" H64 "\n");
    for (int k = 0; k < RUNTIME_MANIFEST_FONTS; k++)
        n += (size_t)snprintf(good + n, sizeof good - n,
                              "font\t%d\textracted/firmware/shared-fonts/%d-font.bfttf\t%d\t%d\t" F64 "\n",
                              k, k, 1000 + k, 992 + k);
}

/* good with the first occurrence of `from` replaced by `to` */
static const char *variant(const char *from, const char *to) {
    static char out[8192];
    const char *at = strstr(good, from);
    if (!at) { fprintf(stderr, "test bug: %s not in the good manifest\n", from); exit(2); }
    size_t head = (size_t)(at - good);
    snprintf(out, sizeof out, "%.*s%s%s", (int)head, good, to, at + strlen(from));
    return out;
}

static int failures, cases;

static void expect(int ok_wanted, const char *text, size_t size, const char *name, const char *reason) {
    RuntimeManifest m;
    char err[256];
    memset(&m, 0x5a, sizeof m);
    int r = runtime_manifest_parse(text, size, &m, err, sizeof err);
    cases++;
    if ((r == 0) != ok_wanted) {
        failures++;
        printf("FAIL %s: %s (%s)\n", name, ok_wanted ? "rejected" : "accepted", r ? err : "no error");
        return;
    }
    if (r) {
        static const RuntimeManifest zero;
        if (memcmp(&m, &zero, sizeof m)) { failures++; printf("FAIL %s: output not zeroed on error\n", name); }
        if (!*err) { failures++; printf("FAIL %s: no error message\n", name); }
        if (reason && !strstr(err, reason)) { failures++; printf("FAIL %s: error '%s' lacks '%s'\n", name, err, reason); }
    }
}
#define ACCEPT(t, name) expect(1, (t), strlen(t), (name), NULL)
#define REJECT(t, name, why) expect(0, (t), strlen(t), (name), (why))

static int print_parsed(const char *path) {
    RuntimeManifest m;
    char err[256];
    if (runtime_manifest_read(path, &m, err, sizeof err)) { printf("error\t%s\n", err); return 1; }
    printf("romfs_index_sha256\t%s\n", m.romfs_index_sha256);
    for (int k = 0; k < RUNTIME_MANIFEST_FONTS; k++)
        printf("font\t%d\t%s\t%llu\t%llu\t%s\n", k, m.fonts[k].path, (unsigned long long)m.fonts[k].file_bytes,
               (unsigned long long)m.fonts[k].font_bytes, m.fonts[k].sha256);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "parse")) return print_parsed(argv[2]);
    if (argc != 1) { fprintf(stderr, "usage: %s [parse FILE]\n", argv[0]); return 2; }
    build_good();

    ACCEPT(good, "well-formed");
    {
        RuntimeManifest m;
        char err[256];
        if (runtime_manifest_parse(good, strlen(good), &m, err, sizeof err) || strcmp(m.romfs_index_sha256, H64) ||
            strcmp(m.fonts[5].path, "extracted/firmware/shared-fonts/5-font.bfttf") || m.fonts[5].file_bytes != 1005 ||
            m.fonts[5].font_bytes != 997 || strcmp(m.fonts[0].sha256, F64)) {
            failures++;
            printf("FAIL field values\n");
        }
        cases++;
    }
    ACCEPT(variant("extracted/firmware/shared-fonts/0-font.bfttf", "0-font.bfttf"), "bare file name");
    ACCEPT(variant("extracted/firmware/shared-fonts/0", "a..b/.x/0"), "dots inside names");
    ACCEPT(variant("\t1000\t992\t", "\t9\t1\t"), "smallest font");
    ACCEPT(variant("\t1000\t992\t", "\t67108864\t67108856\t"), "largest font");

    /* structure */
    REJECT("", "empty", "missing line");
    REJECT("format\t1", "no newline", "newline");
    REJECT(variant("format\t1\n", "format\t2\n"), "future format", "unsupported format");
    REJECT(variant("format\t1\n", "format\t01\n"), "leading zero format", "leading zero");
    REJECT(variant("format\t1\n", "Format\t1\n"), "keyword case", "format");
    REJECT(variant("format\t1\n", "format 1\n"), "space separator", "fields");
    REJECT(variant("format\t1\n", "format\t1\t\n"), "trailing tab", "fields");
    REJECT(variant("format\t1\n", "format\t1\r\n"), "CRLF", "carriage return");
    REJECT(variant("format\t1\n", "\nformat\t1\n"), "leading blank line", "empty field");
    REJECT(variant("format\t1\n", "# c\nformat\t1\n"), "comment", "fields");
    REJECT(variant("romfs_index_sha256\t", "romfs_index_sha\t"), "wrong key", "romfs_index_sha256");
    REJECT(variant(H64, "0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"), "upper hex", "lowercase");
    REJECT(variant(H64, "0123456789abcdef"), "short hex", "64 hex");
    REJECT(variant(H64, H64 "0"), "long hex", "64 hex");
    REJECT(variant(H64, "g123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"), "non-hex", "lowercase");

    /* font rows */
    REJECT(variant("font\t0\t", "font\t1\t"), "type out of order", "font type");
    REJECT(variant("font\t0\t", "font\t-0\t"), "signed type", "decimal");
    REJECT(variant("font\t0\t", "fonts\t0\t"), "font keyword", "font");
    REJECT(variant("extracted/firmware/shared-fonts/0-font.bfttf", "/abs/0-font.bfttf"), "absolute path", "absolute");
    REJECT(variant("extracted/firmware/shared-fonts/0", "../0"), "parent path", "'..'");
    REJECT(variant("extracted/firmware/shared-fonts/0", "a/../0"), "inner parent", "'..'");
    REJECT(variant("extracted/firmware/shared-fonts/0", "./0"), "dot component", "'.'");
    REJECT(variant("extracted/firmware/shared-fonts/0", "a//0"), "empty component", "empty component");
    REJECT(variant("extracted/firmware/shared-fonts/0-font.bfttf", "dir/"), "trailing slash", "empty component");
    REJECT(variant("extracted/firmware/shared-fonts/0", "a\\0"), "backslash", "backslash");
    REJECT(variant("\t1000\t992\t", "\t1000\t993\t"), "font size mismatch", "minus 8");
    REJECT(variant("\t1000\t992\t", "\t8\t0\t"), "too small", "out of range");
    REJECT(variant("\t1000\t992\t", "\t67108865\t67108857\t"), "too large", "out of range");
    REJECT(variant("\t1000\t992\t", "\t01000\t992\t"), "leading zero size", "leading zero");
    REJECT(variant("\t1000\t992\t", "\t+1000\t992\t"), "plus sign", "decimal");
    REJECT(variant("\t1000\t992\t", "\t1e3\t992\t"), "exponent", "decimal");
    REJECT(variant("\t1000\t992\t", "\t18446744073709551616\t992\t"), "overflow", "too large");
    REJECT(variant("\t1000\t992\t", "\t99999999999999999999999\t992\t"), "too many digits", "too large");
    REJECT(variant("\t1000\t992\t", "\t\t992\t"), "empty field", "empty field");
    REJECT(variant("\t1000\t992\t" F64 "\n", "\t1000\t992\t" F64 "\textra\n"), "extra field", "more than");
    REJECT(variant("\t1000\t992\t" F64 "\n", "\t1000\t992\n"), "missing field", "fields");
    REJECT(variant("\t1005\t997\t" F64 "\n", "\t1005\t997\t" F64), "last line without newline", "newline");
    REJECT(variant("\t1005\t997\t" F64 "\n", "\t1005\t997\t" F64 "\n\n"), "trailing blank line", "unexpected content");
    REJECT(variant("\t1005\t997\t" F64 "\n", "\t1005\t997\t" F64 "\nfont\t6\tx\t9\t1\t" F64 "\n"), "seventh font",
           "unexpected content");
    {   /* a manifest with only five fonts */
        char five[4096];
        snprintf(five, sizeof five, "%s", good);
        *strstr(five, "font\t5\t") = 0;
        REJECT(five, "five fonts", "missing line");
    }
    {   /* a path one byte longer than the limit, then one at the limit */
        static char longer[RUNTIME_MANIFEST_PATH_MAX + 1];
        memset(longer, 'a', RUNTIME_MANIFEST_PATH_MAX);
        longer[RUNTIME_MANIFEST_PATH_MAX] = 0;
        REJECT(variant("extracted/firmware/shared-fonts/0-font.bfttf", longer), "path too long", "too long");
        longer[RUNTIME_MANIFEST_PATH_MAX - 1] = 0;
        ACCEPT(variant("extracted/firmware/shared-fonts/0-font.bfttf", longer), "path at limit");
    }
    {   /* control bytes and embedded NUL */
        char text[4096];
        size_t n = strlen(good);
        memcpy(text, good, n + 1);
        text[3] = 0;
        expect(0, text, n, "embedded NUL", "NUL");
        memcpy(text, good, n + 1);
        text[3] = 0x01;
        expect(0, text, n, "control byte", "control");
        expect(0, good, n - 1, "truncated", "newline");
        expect(0, good, RUNTIME_MANIFEST_MAX_BYTES + 1, "oversized", "larger than");
    }
    {   /* API edges */
        RuntimeManifest m;
        char err[64];
        cases += 3;
        if (!runtime_manifest_parse(NULL, 0, &m, err, sizeof err)) { failures++; puts("FAIL NULL text accepted"); }
        if (!runtime_manifest_parse(good, strlen(good), NULL, err, sizeof err)) { failures++; puts("FAIL NULL output accepted"); }
        if (runtime_manifest_parse(good, strlen(good), &m, NULL, 0)) { failures++; puts("FAIL NULL error buffer"); }
        char tiny[8];
        cases++;
        if (!runtime_manifest_parse("", 0, &m, tiny, sizeof tiny) || strlen(tiny) >= sizeof tiny) {
            failures++;
            puts("FAIL small error buffer");
        }
        cases++;
        if (!runtime_manifest_read("/nonexistent/runtime-manifest.txt", &m, err, sizeof err) || !*err) {
            failures++;
            puts("FAIL missing file accepted");
        }
    }
    /* every prefix of the good manifest is rejected, and only the whole is accepted */
    size_t n = strlen(good);
    for (size_t k = 0; k < n; k++) expect(0, good, k, "prefix", NULL);

    if (failures) {
        printf("%d of %d runtime manifest cases failed\n", failures, cases);
        return 1;
    }
    printf("%d runtime manifest cases passed\n", cases);
    return 0;
}
