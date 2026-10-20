/* Strict reader of runtime-manifest.txt (runtime_manifest.h). No dependency on the rest of the runtime. */
#include "runtime_manifest.h"
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char *text;
    size_t size, at;
    unsigned line;
    char *err;
    size_t err_size;
} Reader;

static int fail(Reader *r, const char *fmt, ...) {
    if (r->err && r->err_size) {
        int n = snprintf(r->err, r->err_size, "runtime manifest line %u: ", r->line);
        if (n >= 0 && (size_t)n < r->err_size) {
            va_list ap;
            va_start(ap, fmt);
            vsnprintf(r->err + n, r->err_size - (size_t)n, fmt, ap);
            va_end(ap);
        }
    }
    return -1;
}

/* The next line without its '\n'; every line must end in '\n'. */
static int next_line(Reader *r, const char **line, size_t *len) {
    r->line++;
    if (r->at >= r->size) return fail(r, "missing line");
    const char *start = r->text + r->at;
    const char *nl = memchr(start, '\n', r->size - r->at);
    if (!nl) return fail(r, "line does not end in a newline");
    *line = start;
    *len = (size_t)(nl - start);
    r->at += *len + 1;
    for (size_t i = 0; i < *len; i++) {
        unsigned char c = (unsigned char)start[i];
        if (c == '\r') return fail(r, "carriage return");
        if (c < 0x20 && c != '\t') return fail(r, "control character");
    }
    return 0;
}

/* Split a line at tabs into exactly `want` fields (each non-empty). */
static int split(Reader *r, const char *line, size_t len, const char **field, size_t *flen, unsigned want) {
    unsigned n = 0;
    size_t begin = 0;
    for (size_t i = 0; i <= len; i++) {
        if (i == len || line[i] == '\t') {
            if (n == want) return fail(r, "more than %u fields", want);
            if (i == begin) return fail(r, "empty field %u", n + 1);
            field[n] = line + begin;
            flen[n] = i - begin;
            n++;
            begin = i + 1;
        }
    }
    if (n != want) return fail(r, "%u fields, expected %u", n, want);
    return 0;
}

static int equals(const char *field, size_t len, const char *word) {
    return strlen(word) == len && !memcmp(field, word, len);
}

static int hex64(Reader *r, const char *field, size_t len, char out[65], const char *what) {
    if (len != 64) return fail(r, "%s is not 64 hex digits", what);
    for (size_t i = 0; i < 64; i++) {
        char c = field[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return fail(r, "%s is not lowercase hex", what);
        out[i] = c;
    }
    out[64] = 0;
    return 0;
}

/* A canonical unsigned decimal: digits only, no sign, no leading zero (except "0"), no overflow. */
static int decimal(Reader *r, const char *field, size_t len, uint64_t *out, const char *what) {
    if (len > 20) return fail(r, "%s is too large", what);
    if (len > 1 && field[0] == '0') return fail(r, "%s has a leading zero", what);
    uint64_t v = 0;
    for (size_t i = 0; i < len; i++) {
        char c = field[i];
        if (c < '0' || c > '9') return fail(r, "%s is not a decimal number", what);
        unsigned d = (unsigned)(c - '0');
        if (v > (UINT64_MAX - d) / 10) return fail(r, "%s is too large", what);
        v = v * 10 + d;
    }
    *out = v;
    return 0;
}

/* Relative, no empty / "." / ".." components, no backslash. */
static int relative_path(Reader *r, const char *field, size_t len, char out[RUNTIME_MANIFEST_PATH_MAX]) {
    if (len >= RUNTIME_MANIFEST_PATH_MAX) return fail(r, "font path is too long");
    if (field[0] == '/') return fail(r, "font path is absolute");
    size_t begin = 0;
    for (size_t i = 0; i <= len; i++) {
        if (i < len && field[i] == '\\') return fail(r, "font path contains a backslash");
        if (i == len || field[i] == '/') {
            size_t n = i - begin;
            if (n == 0) return fail(r, "font path has an empty component");
            if ((n == 1 && field[begin] == '.') || (n == 2 && field[begin] == '.' && field[begin + 1] == '.'))
                return fail(r, "font path has a '.' or '..' component");
            begin = i + 1;
        }
    }
    memcpy(out, field, len);
    out[len] = 0;
    return 0;
}

int runtime_manifest_parse(const char *text, size_t size, RuntimeManifest *out, char *err, size_t err_size) {
    Reader r = {text, size, 0, 0, err, err_size};
    if (err && err_size) err[0] = 0;
    if (!out) return fail(&r, "no output");
    memset(out, 0, sizeof *out);
    RuntimeManifest m;
    memset(&m, 0, sizeof m);
    if (!text) return fail(&r, "no input");
    if (size > RUNTIME_MANIFEST_MAX_BYTES) return fail(&r, "file is larger than %u bytes", RUNTIME_MANIFEST_MAX_BYTES);
    if (memchr(text, 0, size)) return fail(&r, "NUL byte");

    const char *line, *f[6];
    size_t len, fl[6];

    if (next_line(&r, &line, &len) || split(&r, line, len, f, fl, 2)) return -1;
    if (!equals(f[0], fl[0], "format")) return fail(&r, "expected 'format'");
    uint64_t format;
    if (decimal(&r, f[1], fl[1], &format, "format")) return -1;
    if (format != RUNTIME_MANIFEST_FORMAT) return fail(&r, "unsupported format %llu", (unsigned long long)format);

    if (next_line(&r, &line, &len) || split(&r, line, len, f, fl, 2)) return -1;
    if (!equals(f[0], fl[0], "romfs_index_sha256")) return fail(&r, "expected 'romfs_index_sha256'");
    if (hex64(&r, f[1], fl[1], m.romfs_index_sha256, "romfs_index_sha256")) return -1;

    for (unsigned k = 0; k < RUNTIME_MANIFEST_FONTS; k++) {
        RuntimeManifestFont *font = &m.fonts[k];
        if (next_line(&r, &line, &len) || split(&r, line, len, f, fl, 6)) return -1;
        if (!equals(f[0], fl[0], "font")) return fail(&r, "expected 'font'");
        uint64_t type;
        if (decimal(&r, f[1], fl[1], &type, "font type")) return -1;
        if (type != k) return fail(&r, "font type %llu, expected %u", (unsigned long long)type, k);
        if (relative_path(&r, f[2], fl[2], font->path)) return -1;
        if (decimal(&r, f[3], fl[3], &font->file_bytes, "font file size") ||
            decimal(&r, f[4], fl[4], &font->font_bytes, "font size")) return -1;
        if (font->file_bytes <= 8 || font->file_bytes > RUNTIME_MANIFEST_FONT_MAX_BYTES)
            return fail(&r, "font file size out of range");
        if (font->font_bytes != font->file_bytes - 8) return fail(&r, "font size is not the file size minus 8");
        if (hex64(&r, f[5], fl[5], font->sha256, "font sha256")) return -1;
    }
    if (r.at != r.size) {
        r.line++;
        return fail(&r, "unexpected content after the last font");
    }
    *out = m;
    return 0;
}

int runtime_manifest_read(const char *path, RuntimeManifest *out, char *err, size_t err_size) {
    if (out) memset(out, 0, sizeof *out);
    if (err && err_size) err[0] = 0;
    if (!path) {
        if (err && err_size) snprintf(err, err_size, "runtime manifest: no path");
        return -1;
    }
    FILE *f = fopen(path, "rb");
    if (!f) {
        if (err && err_size) snprintf(err, err_size, "runtime manifest %s: %s", path, strerror(errno));
        return -1;
    }
    char *buffer = malloc(RUNTIME_MANIFEST_MAX_BYTES + 1);
    if (!buffer) {
        fclose(f);
        if (err && err_size) snprintf(err, err_size, "runtime manifest: out of memory");
        return -1;
    }
    size_t n = fread(buffer, 1, RUNTIME_MANIFEST_MAX_BYTES + 1, f);
    int bad = ferror(f);
    fclose(f);
    int result;
    if (bad) {
        if (err && err_size) snprintf(err, err_size, "runtime manifest %s: read error", path);
        result = -1;
    } else {
        result = runtime_manifest_parse(buffer, n, out, err, err_size);
    }
    free(buffer);
    return result;
}
