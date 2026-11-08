// zstd's decompression (vendored by Tools/vendor-zstd.sh) behind one call, so its
// headers stay out of Swift.

#include "ch_zstd.h"
#include "zstd/zstd.h"
#include <pthread.h>

// One context a thread, made once (a frame a call would make one each time), freed with its
// thread: results are read on worker threads the system makes and ends as it likes, and a
// `_Thread_local` pointer left each one's context behind.
static pthread_key_t key;
static pthread_once_t once = PTHREAD_ONCE_INIT;

static void free_context(void *context) { ZSTD_freeDCtx(context); }
static void make_key(void) { pthread_key_create(&key, free_context); }

long ch_zstd_decompress(void *destination, size_t capacity, const void *source, size_t size) {
    pthread_once(&once, make_key);
    ZSTD_DCtx *context = pthread_getspecific(key);
    if (context == NULL) {
        context = ZSTD_createDCtx();
        if (context == NULL) return -1;
        pthread_setspecific(key, context);
    }
    size_t written = ZSTD_decompressDCtx(context, destination, capacity, source, size);
    return ZSTD_isError(written) ? -1 : (long)written;
}
