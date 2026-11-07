#ifndef CH_BCRYPT_H
#define CH_BCRYPT_H

#include <stddef.h>
#include <stdint.h>

/// OpenBSD's bcrypt_pbkdf, as OpenSSH derives the key and IV of a private key
/// with a passphrase ("bcrypt" KDF): `keylen` bytes into `key`. 0 on success.
int ch_bcrypt_pbkdf(const char *pass, size_t passlen, const uint8_t *salt, size_t saltlen,
                    uint8_t *key, size_t keylen, unsigned int rounds);

#endif
