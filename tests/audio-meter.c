// Run without Core Audio devices or permissions. Pass --benchmark to time synthetic callbacks.
#include "CBackstageAudio.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void test_meter_and_ring(void) {
    BSMeter *meter = bs_meter_create(2, 0.001);
    assert(meter);
    BSRingHeader ring = {.sampleRate = 1000, .channels = 2, .capacityFrames = 3};
    float pcm[6] = {0};
    meter->ring = &ring;
    meter->ringData = pcm;
    bs_meter_set_loud_threshold(meter, 0.4f);

    float samples[] = {NAN, INFINITY, 0.5f, -0.25f};
    AudioBufferList packed = {1, {{2, sizeof(samples), samples}}};
    AudioTimeStamp timestamp = {.mHostTime = 100, .mFlags = kAudioTimeStampHostTimeValid};
    bs_meter_ioproc(0, NULL, &packed, &timestamp, NULL, NULL, meter);
    assert(bs_meter_blocks_written(meter) == 1);
    BSMeterBlock block = bs_meter_block(meter, 0);
    assert(block.frames == 2 && block.peak == 0.5f && block.sumSquares == 0.15625);
    assert(block.firstLoud == 1 && block.lastLoud == 1);
    assert(ring.framesWritten == 2 && ring.writeSequence == 2 && ring.endHostTime == 102);
    assert(isnan(pcm[0]) && isinf(pcm[1]) && pcm[2] == 0.5f && pcm[3] == -0.25f);

    AudioBufferList *planar = calloc(1, offsetof(AudioBufferList, mBuffers) + 2 * sizeof(AudioBuffer));
    assert(planar);
    float left[] = {0.125f, 0.25f};
    float right[] = {-0.125f, -0.25f, -0.5f, -1.0f};
    planar->mNumberBuffers = 2;
    planar->mBuffers[0] = (AudioBuffer){1, sizeof(left), left};
    planar->mBuffers[1] = (AudioBuffer){1, sizeof(right), right};
    timestamp.mHostTime = 102;
    bs_meter_ioproc(0, NULL, planar, &timestamp, NULL, NULL, meter);
    block = bs_meter_block(meter, 1);
    assert(block.frames == 4 && block.peak == 1.0f && block.sumSquares == 0.703125);
    assert(block.firstLoud == 2 && block.lastLoud == 3);
    assert(ring.framesWritten == 6 && ring.writeSequence == 4 && ring.endHostTime == 106);
    const float wrapped[] = {0.25f, -0.25f, 0, -0.5f, 0, -1.0f};
    assert(memcmp(pcm, wrapped, sizeof(pcm)) == 0);

    planar->mBuffers[0] = (AudioBuffer){1, 0, NULL};
    timestamp.mHostTime = 106;
    bs_meter_ioproc(0, NULL, planar, &timestamp, NULL, NULL, meter);
    block = bs_meter_block(meter, 2);
    assert(block.frames == 4 && block.sumSquares == 0.6640625);
    assert(ring.framesWritten == 10 && ring.writeSequence == 6 && ring.endHostTime == 110);
    assert(pcm[0] == 0 && pcm[2] == 0 && pcm[4] == 0 && pcm[1] == -1.0f);

    bs_ring_fill_silence(meter, 8, 118);
    assert(ring.framesWritten == 18 && ring.writeSequence == 8 && ring.endHostTime == 118);
    for (size_t i = 0; i < sizeof(pcm) / sizeof(pcm[0]); i++) assert(pcm[i] == 0);
    free(planar);
    bs_meter_destroy(meter);
}

static void benchmark(void) {
    enum { buffers = 200000, frames = 256, channels = 2, rate = 48000, capacity = 15 * rate };
    BSMeter *meter = bs_meter_create(channels, 1e-9);
    assert(meter);
    BSRingHeader ring = {.sampleRate = rate, .channels = channels, .capacityFrames = capacity};
    float *pcm = calloc(capacity * channels, sizeof(float));
    assert(pcm);
    meter->ring = &ring;
    meter->ringData = pcm;
    bs_meter_set_loud_threshold(meter, 0.01f);
    float samples[frames * channels];
    for (int i = 0; i < frames * channels; i++) samples[i] = sinf((float)i * 0.25f) * 0.2f;
    AudioBufferList input = {1, {{channels, sizeof(samples), samples}}};
    for (int i = 0; i < capacity / frames + 1; i++) bs_meter_ioproc(0, NULL, &input, NULL, NULL, NULL, meter);
    for (int run = 0; run < 5; run++) {
        uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        for (int i = 0; i < buffers; i++) bs_meter_ioproc(0, NULL, &input, NULL, NULL, NULL, meter);
        printf("%.0f ns/callback\n", (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / buffers);
    }
    free(pcm);
    bs_meter_destroy(meter);
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--benchmark") == 0) benchmark();
    else test_meter_and_ring();
    return 0;
}
