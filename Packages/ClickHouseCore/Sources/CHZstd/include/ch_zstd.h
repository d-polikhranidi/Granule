#ifndef CH_ZSTD_H
#define CH_ZSTD_H

#include <stddef.h>

/// A zstd frame (ClickHouse's method 0x90) decompressed into `destination`: the bytes
/// written, or -1 when it isn't one that fits. A context of its own a thread, kept.
long ch_zstd_decompress(void *destination, size_t capacity, const void *source, size_t size);

#endif
