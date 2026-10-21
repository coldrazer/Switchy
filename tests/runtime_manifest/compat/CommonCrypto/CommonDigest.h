/* The CommonCrypto SHA-256 calls the runtime uses, for building tests/runtime_manifest/harness.c off macOS. On a Mac
   the real header is found first and this file is not used. FIPS 180-4 SHA-256; test use only. */
#pragma once
#include <stdint.h>
#include <string.h>

typedef uint32_t CC_LONG;
typedef struct { uint32_t h[8]; uint64_t bits; uint8_t block[64]; uint32_t used; } CC_SHA256_CTX;

static inline uint32_t cc_ror(uint32_t x, unsigned n) { return (x >> n) | (x << (32 - n)); }

static inline void cc_sha256_block(CC_SHA256_CTX *c, const uint8_t *p) {
    static const uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
    uint32_t w[64], a, b, cc, d, e, f, g, h;
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t)p[i * 4] << 24 | (uint32_t)p[i * 4 + 1] << 16 | (uint32_t)p[i * 4 + 2] << 8 | p[i * 4 + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = cc_ror(w[i - 15], 7) ^ cc_ror(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = cc_ror(w[i - 2], 17) ^ cc_ror(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = c->h[0]; b = c->h[1]; cc = c->h[2]; d = c->h[3]; e = c->h[4]; f = c->h[5]; g = c->h[6]; h = c->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + (cc_ror(e, 6) ^ cc_ror(e, 11) ^ cc_ror(e, 25)) + ((e & f) ^ (~e & g)) + k[i] + w[i];
        uint32_t t2 = (cc_ror(a, 2) ^ cc_ror(a, 13) ^ cc_ror(a, 22)) + ((a & b) ^ (a & cc) ^ (b & cc));
        h = g; g = f; f = e; e = d + t1; d = cc; cc = b; b = a; a = t1 + t2;
    }
    c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += d; c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += h;
}

static inline int CC_SHA256_Init(CC_SHA256_CTX *c) {
    static const uint32_t iv[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(c->h, iv, sizeof iv);
    c->bits = 0;
    c->used = 0;
    return 1;
}

static inline int CC_SHA256_Update(CC_SHA256_CTX *c, const void *data, CC_LONG n) {
    const uint8_t *p = data;
    c->bits += (uint64_t)n * 8;
    while (n) {
        uint32_t take = 64 - c->used < n ? 64 - c->used : n;
        memcpy(c->block + c->used, p, take);
        c->used += take; p += take; n -= take;
        if (c->used == 64) { cc_sha256_block(c, c->block); c->used = 0; }
    }
    return 1;
}

static inline int CC_SHA256_Final(unsigned char *out, CC_SHA256_CTX *c) {
    uint64_t bits = c->bits;
    uint8_t pad = 0x80, zero = 0, len[8];
    CC_SHA256_Update(c, &pad, 1);
    while (c->used != 56) CC_SHA256_Update(c, &zero, 1);
    for (int i = 0; i < 8; i++) len[i] = (uint8_t)(bits >> (56 - 8 * i));
    CC_SHA256_Update(c, len, 8);
    for (int i = 0; i < 8; i++) {
        out[i * 4] = (uint8_t)(c->h[i] >> 24); out[i * 4 + 1] = (uint8_t)(c->h[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(c->h[i] >> 8); out[i * 4 + 3] = (uint8_t)c->h[i];
    }
    return 1;
}

static inline unsigned char *CC_SHA256(const void *data, CC_LONG n, unsigned char *out) {
    CC_SHA256_CTX c;
    CC_SHA256_Init(&c);
    CC_SHA256_Update(&c, data, n);
    CC_SHA256_Final(out, &c);
    return out;
}
