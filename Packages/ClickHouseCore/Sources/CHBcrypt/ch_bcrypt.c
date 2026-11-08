// bcrypt_pbkdf as OpenBSD and OpenSSH define it (bcrypt_pbkdf.c, blf.c),
// written again from their description: Blowfish's expensive key schedule
// (EksBlowfish) hashing "OxychromaticBlowfishSwatDynamite" 64 times, mixed
// into a PBKDF2-like construction over SHA-512.

#define __STDC_WANT_LIB_EXT1__ 1
#include "ch_bcrypt.h"
#include <CommonCrypto/CommonDigest.h>
#include <string.h>

// What the passphrase made goes: memset_s, which the compiler keeps (a plain memset of
// memory no one reads again it may leave out).
static void wipe(void *bytes, size_t count) { memset_s(bytes, count, 0, count); }
#include "blowfish_tables.h"

typedef struct {
    uint32_t s[4][256];
    uint32_t p[18];
} blowfish;

static inline uint32_t f(const blowfish *c, uint32_t x) {
    return ((c->s[0][x >> 24] + c->s[1][(x >> 16) & 0xff]) ^ c->s[2][(x >> 8) & 0xff]) + c->s[3][x & 0xff];
}

static void encipher(const blowfish *c, uint32_t *left, uint32_t *right) {
    uint32_t l = *left, r = *right;
    l ^= c->p[0];
    for (int i = 1; i <= 16; i += 2) {
        r ^= f(c, l) ^ c->p[i];
        l ^= f(c, r) ^ c->p[i + 1];
    }
    *left = r ^ c->p[17];
    *right = l;
}

/// The next four bytes of `data` (cycled), big-endian.
static uint32_t stream_word(const uint8_t *data, size_t length, size_t *at) {
    uint32_t word = 0;
    for (int i = 0; i < 4; i++) {
        if (*at >= length) *at = 0;
        word = (word << 8) | data[*at];
        (*at)++;
    }
    return word;
}

/// The key schedule: P mixed with `key`, then P and S replaced by encrypting
/// (with `data` mixed in when given, salt-like).
static void expand(blowfish *c, const uint8_t *data, size_t datalength, const uint8_t *key, size_t keylength) {
    size_t at = 0;
    for (int i = 0; i < 18; i++) c->p[i] ^= stream_word(key, keylength, &at);
    at = 0;
    uint32_t l = 0, r = 0;
    for (int i = 0; i < 18; i += 2) {
        if (data) {
            l ^= stream_word(data, datalength, &at);
            r ^= stream_word(data, datalength, &at);
        }
        encipher(c, &l, &r);
        c->p[i] = l;
        c->p[i + 1] = r;
    }
    for (int box = 0; box < 4; box++) {
        for (int k = 0; k < 256; k += 2) {
            if (data) {
                l ^= stream_word(data, datalength, &at);
                r ^= stream_word(data, datalength, &at);
            }
            encipher(c, &l, &r);
            c->s[box][k] = l;
            c->s[box][k + 1] = r;
        }
    }
}

enum { HASH_WORDS = 8, HASH_SIZE = HASH_WORDS * 4 };

static void bcrypt_hash(const uint8_t *sha2pass, const uint8_t *sha2salt, uint8_t *out) {
    static const uint8_t magic[HASH_SIZE] = "OxychromaticBlowfishSwatDynamite";
    blowfish c;
    memcpy(c.p, ch_blowfish_initial_p, sizeof c.p);
    memcpy(c.s, ch_blowfish_initial_s, sizeof c.s);
    expand(&c, sha2salt, CC_SHA512_DIGEST_LENGTH, sha2pass, CC_SHA512_DIGEST_LENGTH);
    for (int i = 0; i < 64; i++) {
        expand(&c, NULL, 0, sha2salt, CC_SHA512_DIGEST_LENGTH);
        expand(&c, NULL, 0, sha2pass, CC_SHA512_DIGEST_LENGTH);
    }
    uint32_t words[HASH_WORDS];
    size_t at = 0;
    for (int i = 0; i < HASH_WORDS; i++) words[i] = stream_word(magic, sizeof magic, &at);
    for (int i = 0; i < 64; i++) {
        for (int block = 0; block < HASH_WORDS; block += 2) encipher(&c, &words[block], &words[block + 1]);
    }
    // Little-endian out, as OpenBSD's does.
    for (int i = 0; i < HASH_WORDS; i++) {
        out[4 * i + 3] = (uint8_t)(words[i] >> 24);
        out[4 * i + 2] = (uint8_t)(words[i] >> 16);
        out[4 * i + 1] = (uint8_t)(words[i] >> 8);
        out[4 * i + 0] = (uint8_t)words[i];
    }
    wipe(&c, sizeof c);
    wipe(words, sizeof words);
}

int ch_bcrypt_pbkdf(const char *pass, size_t passlen, const uint8_t *salt, size_t saltlen,
                    uint8_t *key, size_t keylen, unsigned int rounds) {
    if (rounds < 1 || passlen == 0 || saltlen == 0 || keylen == 0 || keylen > HASH_SIZE * HASH_SIZE) return -1;
    uint8_t sha2pass[CC_SHA512_DIGEST_LENGTH], sha2salt[CC_SHA512_DIGEST_LENGTH];
    uint8_t out[HASH_SIZE], tmpout[HASH_SIZE];
    size_t stride = (keylen + HASH_SIZE - 1) / HASH_SIZE;
    size_t amount = (keylen + stride - 1) / stride;
    size_t original = keylen;
    CC_SHA512(pass, (CC_LONG)passlen, sha2pass);
    for (uint32_t count = 1; keylen > 0; count++) {
        uint8_t countsalt[4] = { (uint8_t)(count >> 24), (uint8_t)(count >> 16), (uint8_t)(count >> 8), (uint8_t)count };
        CC_SHA512_CTX context;
        CC_SHA512_Init(&context);
        CC_SHA512_Update(&context, salt, (CC_LONG)saltlen);
        CC_SHA512_Update(&context, countsalt, sizeof countsalt);
        CC_SHA512_Final(sha2salt, &context);
        wipe(&context, sizeof context);
        bcrypt_hash(sha2pass, sha2salt, tmpout);
        memcpy(out, tmpout, sizeof out);
        for (unsigned int round = 1; round < rounds; round++) {
            CC_SHA512(tmpout, sizeof tmpout, sha2salt);
            bcrypt_hash(sha2pass, sha2salt, tmpout);
            for (size_t j = 0; j < sizeof out; j++) out[j] ^= tmpout[j];
        }
        // Not PBKDF2's order: the key's bytes are spread (OpenBSD's "deviation").
        if (amount > keylen) amount = keylen;
        size_t i;
        for (i = 0; i < amount; i++) {
            size_t dest = i * stride + (count - 1);
            if (dest >= original) break;
            key[dest] = out[i];
        }
        keylen -= i;
    }
    wipe(out, sizeof out);
    wipe(tmpout, sizeof tmpout);
    wipe(sha2pass, sizeof sha2pass);
    wipe(sha2salt, sizeof sha2salt);
    return 0;
}
