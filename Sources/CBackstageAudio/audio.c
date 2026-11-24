#include "CBackstageAudio.h"
#include <math.h>
#include <signal.h>
#include <string.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/proc.h>

#include <stdlib.h>

uint64_t bs_load_acquire_u64(const uint64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
void bs_store_release_u64(uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }

BSMeter *bs_meter_create(uint32_t channels, double secondsPerTick) {
    BSMeter *m = calloc(1, sizeof(BSMeter));
    if (!m) return NULL;
    m->channels = channels;
    m->secondsPerTick = secondsPerTick;
    return m;
}
void bs_meter_destroy(BSMeter *meter) { free(meter); }
uint64_t bs_meter_blocks_written(const BSMeter *meter) { return __atomic_load_n(&meter->blocksWritten, __ATOMIC_ACQUIRE); }
BSMeterBlock bs_meter_block(const BSMeter *meter, uint64_t index) { return meter->blocks[index % BS_METER_BLOCKS]; }

static void ring_append(BSMeter *m, const float *data, uint32_t frames, uint64_t endHostTime) {
    BSRingHeader *r = m->ring;
    uint32_t cap = r->capacityFrames, ch = r->channels;
    if (cap == 0 || ch == 0) return;
    if (frames > cap) { if (data) data += (size_t)(frames - cap) * ch; frames = cap; }
    uint64_t written = r->framesWritten;            // only this writer stores it
    uint32_t pos = (uint32_t)(written % cap);
    uint32_t first = frames < cap - pos ? frames : cap - pos;
    if (data) {
        memcpy(m->ringData + (size_t)pos * ch, data, (size_t)first * ch * sizeof(float));
        if (frames > first) memcpy(m->ringData, data + (size_t)first * ch, (size_t)(frames - first) * ch * sizeof(float));
    } else {
        memset(m->ringData + (size_t)pos * ch, 0, (size_t)first * ch * sizeof(float));
        if (frames > first) memset(m->ringData, 0, (size_t)(frames - first) * ch * sizeof(float));
    }
    r->endHostTime = endHostTime;
    r->endUptime = (double)endHostTime * m->secondsPerTick;
    bs_store_release_u64(&r->framesWritten, written + frames);
}

void bs_ring_fill_silence(BSMeter *m, uint64_t frames, uint64_t endHostTime) {
    if (!m || !m->ring || frames == 0) return;
    while (frames > 0) {
        uint32_t chunk = frames > m->ring->capacityFrames ? m->ring->capacityFrames : (uint32_t)frames;
        ring_append(m, NULL, chunk, endHostTime);
        frames -= chunk;
    }
}

OSStatus bs_meter_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                         const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime,
                         void *client) {
    (void)device; (void)output; (void)outputTime;
    BSMeter *m = (BSMeter *)client;
    if (!m || !input || input->mNumberBuffers == 0) return 0;
    const AudioBuffer *b0 = &input->mBuffers[0];
    uint32_t ch0 = b0->mNumberChannels ? b0->mNumberChannels : 1;
    uint32_t frames = b0->mDataByteSize / (uint32_t)(sizeof(float) * ch0);
    if (frames == 0) return 0;
    uint64_t host = (inputTime && (inputTime->mFlags & kAudioTimeStampHostTimeValid)) ? inputTime->mHostTime
                  : (now ? now->mHostTime : 0);
    float peak = 0, threshold = m->loudThreshold;
    double sum = 0;
    int32_t firstLoud = -1, lastLoud = -1;
    uint32_t totalChannels = 0;
    for (uint32_t b = 0; b < input->mNumberBuffers; b++) {
        const AudioBuffer *buf = &input->mBuffers[b];
        const float *d = (const float *)buf->mData;
        uint32_t ch = buf->mNumberChannels ? buf->mNumberChannels : 1;
        if (!d) continue;
        uint32_t n = buf->mDataByteSize / (uint32_t)(sizeof(float) * ch);
        if (n > frames) n = frames;
        for (uint32_t i = 0; i < n; i++) {
            for (uint32_t c = 0; c < ch; c++) {
                float x = d[(size_t)i * ch + c];
                float ax = fabsf(x);
                if (ax > peak) peak = ax;
                sum += (double)x * (double)x;
                if (threshold > 0 && ax >= threshold) {
                    if (firstLoud < 0 || (int32_t)i < firstLoud) firstLoud = (int32_t)i;
                    if ((int32_t)i > lastLoud) lastLoud = (int32_t)i;
                }
            }
        }
        totalChannels += ch;
    }
    if (totalChannels == 0) return 0;
    if (m->ring && input->mNumberBuffers == 1 && ch0 == m->ring->channels && b0->mData && m->ring->sampleRate > 0) {
        double seconds = (double)frames / m->ring->sampleRate;
        uint64_t end = host + (uint64_t)(seconds / m->secondsPerTick);
        ring_append(m, (const float *)b0->mData, frames, end);
    }
    uint64_t n = m->blocksWritten;
    BSMeterBlock *blk = &m->blocks[n % BS_METER_BLOCKS];
    blk->hostTime = host;
    blk->frames = frames;
    blk->peak = peak;
    blk->sumSquares = sum / (double)totalChannels;
    blk->firstLoud = firstLoud;
    blk->lastLoud = lastLoud;
    bs_store_release_u64(&m->blocksWritten, n + 1);
    return 0;
}

// --------------------------------------------------------------------------------------------
static volatile int32_t g_pids[BS_CRASH_SEGMENTS][BS_CRASH_MAX];
static volatile uint64_t g_births[BS_CRASH_SEGMENTS][BS_CRASH_MAX];
static volatile int g_counts[BS_CRASH_SEGMENTS];

void bs_crash_set(int segment, const int32_t *pids, const uint64_t *births, int count) {
    if (segment < 0 || segment >= BS_CRASH_SEGMENTS) return;
    if (count > BS_CRASH_MAX) count = BS_CRASH_MAX;
    if (count < 0) count = 0;
    __atomic_store_n(&g_counts[segment], 0, __ATOMIC_SEQ_CST);
    for (int i = 0; i < count; i++) { g_pids[segment][i] = pids[i]; g_births[segment][i] = births[i]; }
    __atomic_store_n(&g_counts[segment], count, __ATOMIC_SEQ_CST);
}

static uint64_t birth_of(pid_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof info) != (int)sizeof info) return 0;
    if (info.pbi_status == SZOMB) return 0;
    return (uint64_t)info.pbi_start_tvsec * 1000000ULL + (uint64_t)info.pbi_start_tvusec;
}

static void crash_handler(int sig) {
    for (int s = 0; s < BS_CRASH_SEGMENTS; s++) {
        int count = __atomic_load_n(&g_counts[s], __ATOMIC_SEQ_CST);
        for (int i = 0; i < count; i++) {
            pid_t pid = g_pids[s][i];
            uint64_t birth = g_births[s][i];
            if (pid > 1 && (birth == 0 || birth_of(pid) == birth)) kill(pid, SIGKILL);
        }
    }
    // SA_RESETHAND restored the default action: die with the original signal.
    raise(sig);
}

void bs_crash_install(void) {
    static char altstack[128 * 1024];
    stack_t ss;
    ss.ss_sp = altstack;
    ss.ss_size = sizeof altstack;
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = crash_handler;
    sa.sa_flags = SA_ONSTACK | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP, SIGSYS };
    for (unsigned i = 0; i < sizeof sigs / sizeof sigs[0]; i++) sigaction(sigs[i], &sa, NULL);
}
