// zstd's decompression (vendored by Tools/vendor-zstd.sh) behind one call, so its
// headers stay out of Swift.

#include "ch_zstd.h"
#include "zstd/zstd.h"

long ch_zstd_decompress(void *destination, size_t capacity, const void *source, size_t size) {
    // One context a thread, made once: a frame a call would make one each time.
    static _Thread_local ZSTD_DCtx *context = NULL;
    if (context == NULL) context = ZSTD_createDCtx();
    if (context == NULL) return -1;
    size_t written = ZSTD_decompressDCtx(context, destination, capacity, source, size);
    return ZSTD_isError(written) ? -1 : (long)written;
}
