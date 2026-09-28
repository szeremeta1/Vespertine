#include "CNocturneRT.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NRTRing *concurrent_ring;
static NRTRenderContext *concurrent_context;
static void *producer(void *unused) {
    (void)unused;
    for (unsigned i = 0; i < 200000; i++) {
        float sample = (float)i;
        while (!nrt_ring_write(concurrent_ring, &sample, 1)) {}
    }
    return NULL;
}
static void *tap_reader(void *unused) {
    (void)unused;
    float tap[1024];
    for (int i = 0; i < 10000; i++) nrt_context_copy_tap(concurrent_context, tap, 1024);
    return NULL;
}
int main(void) {
    alarm(30);
    concurrent_ring = nrt_ring_create(256, 1);
    assert(concurrent_ring);
    pthread_t thread;
    assert(!pthread_create(&thread, NULL, producer, NULL));
    for (unsigned i = 0; i < 200000; i++) {
        float sample;
        while (!nrt_ring_read(concurrent_ring, &sample, 1)) {}
        assert(sample == (float)i);
    }
    pthread_join(thread, NULL);
    nrt_ring_destroy(concurrent_ring);

    NRTRing *ring = nrt_ring_create(1024, 2);
    NRTRenderContext *ctx = nrt_context_create(ring, 512);
    concurrent_context = ctx;
    assert(!pthread_create(&thread, NULL, tap_reader, NULL));
    float data[2048] = {0}, output[2048];
    for (int i = 0; i < 10000; i++) {
        nrt_ring_write(ring, data, 1024);
        nrt_context_render_interleaved(ctx, output, 1024, 2);
    }
    pthread_join(thread, NULL);

    AudioTimeStamp timestamp = {0};
    AudioBufferList input = {.mNumberBuffers = 0};
    AudioBufferList *list = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    list->mNumberBuffers = 2;
    list->mBuffers[0] = (AudioBuffer){.mNumberChannels = 1, .mDataByteSize = 8 * sizeof(float), .mData = calloc(8, sizeof(float))};
    list->mBuffers[1] = (AudioBuffer){.mNumberChannels = 1, .mDataByteSize = 4 * sizeof(float), .mData = calloc(4, sizeof(float))};
    nrt_device_ioproc(0, &timestamp, &input, &timestamp, list, &timestamp, ctx);
    free(list->mBuffers[0].mData); free(list->mBuffers[1].mData);
    list->mNumberBuffers = 1;
    list->mBuffers[0] = (AudioBuffer){.mNumberChannels = 2, .mDataByteSize = 16, .mData = NULL};
    nrt_device_ioproc(0, &timestamp, &input, &timestamp, list, &timestamp, ctx);
    free(list);
    nrt_context_destroy(ctx); nrt_ring_destroy(ring);
    return 0;
}
