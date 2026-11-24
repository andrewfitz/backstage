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

_Static_assert(sizeof(float) == sizeof(uint32_t), "meter threshold size");

void bs_meter_set_loud_threshold(BSMeter *meter, float threshold) {
    uint32_t bits;
    memcpy(&bits, &threshold, sizeof bits);
    __atomic_store_n(&meter->loudThresholdBits, bits, __ATOMIC_RELAXED);
}

_Static_assert(sizeof(BSMeterBlock) == sizeof(((BSMeterSlot *)0)->words), "meter slot size");
_Static_assert(sizeof(BSRingHeader) == 64, "PCM ring header size");
_Static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0), "meter requires lock-free atomics");

BSMeterBlock bs_meter_block(const BSMeter *meter, uint64_t index) {
    const BSMeterSlot *slot = &meter->blocks[index % BS_METER_BLOCKS];
    uint64_t sequence = (index + 1) * 2;
    uint64_t words[4];
    if (__atomic_load_n(&slot->sequence, __ATOMIC_SEQ_CST) != sequence) return (BSMeterBlock){0};
    for (size_t i = 0; i < sizeof words / sizeof words[0]; i++) {
        words[i] = __atomic_load_n(&slot->words[i], __ATOMIC_SEQ_CST);
    }
    if (__atomic_load_n(&slot->sequence, __ATOMIC_SEQ_CST) != sequence) return (BSMeterBlock){0};
    BSMeterBlock block;
    memcpy(&block, words, sizeof block);
    return block;
}

static void meter_append(BSMeter *m, BSMeterBlock block) {
    uint64_t index = __atomic_load_n(&m->blocksWritten, __ATOMIC_RELAXED);
    BSMeterSlot *slot = &m->blocks[index % BS_METER_BLOCKS];
    uint64_t sequence = (index + 1) * 2;
    uint64_t words[4];
    memcpy(words, &block, sizeof words);
    // A stalled reader can be lapped. Publish atomic fields between distinct sequence values
    // so it can reject an overwritten slot without racing the IOProc.
    __atomic_store_n(&slot->sequence, sequence - 1, __ATOMIC_SEQ_CST);
    for (size_t i = 0; i < sizeof words / sizeof words[0]; i++) {
        __atomic_store_n(&slot->words[i], words[i], __ATOMIC_SEQ_CST);
    }
    __atomic_store_n(&slot->sequence, sequence, __ATOMIC_SEQ_CST);
    bs_store_release_u64(&m->blocksWritten, index + 1);
}

static void ring_append(BSMeter *m, const float *data, uint64_t frameCount, uint64_t endHostTime) {
    BSRingHeader *r = m->ring;
    uint32_t cap = r->capacityFrames, ch = r->channels;
    if (cap == 0 || ch == 0) return;
    uint32_t frames = frameCount > cap ? cap : (uint32_t)frameCount;
    uint64_t skipped = frameCount - frames;
    if (data) data += (size_t)skipped * ch;
    uint64_t written = __atomic_load_n(&r->framesWritten, __ATOMIC_RELAXED);
    uint32_t pos = (uint32_t)((written + skipped) % cap);
    uint32_t first = frames < cap - pos ? frames : cap - pos;
    uint64_t sequence = __atomic_load_n(&r->writeSequence, __ATOMIC_RELAXED);
    __atomic_store_n(&r->writeSequence, sequence + 1, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    if (data) {
        memcpy(m->ringData + (size_t)pos * ch, data, (size_t)first * ch * sizeof(float));
        if (frames > first) memcpy(m->ringData, data + (size_t)first * ch, (size_t)(frames - first) * ch * sizeof(float));
    } else {
        memset(m->ringData + (size_t)pos * ch, 0, (size_t)first * ch * sizeof(float));
        if (frames > first) memset(m->ringData, 0, (size_t)(frames - first) * ch * sizeof(float));
    }
    r->endHostTime = endHostTime;
    r->endUptime = (double)endHostTime * m->secondsPerTick;
    bs_store_release_u64(&r->framesWritten, written + frameCount);
    bs_store_release_u64(&r->writeSequence, sequence + 2);
}

void bs_ring_fill_silence(BSMeter *m, uint64_t frames, uint64_t endHostTime) {
    if (!m || !m->ring || frames == 0) return;
    ring_append(m, NULL, frames, endHostTime);
}

OSStatus bs_meter_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                         const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime,
                         void *client) {
    (void)device; (void)output; (void)outputTime;
    BSMeter *m = (BSMeter *)client;
    if (!m || !input || input->mNumberBuffers == 0) return 0;
    const AudioBuffer *b0 = &input->mBuffers[0];
    uint32_t ch0 = b0->mNumberChannels ? b0->mNumberChannels : 1;
    uint32_t frames = b0->mDataByteSize / sizeof(float) / ch0;
    if (frames == 0) return 0;
    uint64_t host = (inputTime && (inputTime->mFlags & kAudioTimeStampHostTimeValid)) ? inputTime->mHostTime
                  : (now ? now->mHostTime : 0);
    uint32_t thresholdBits = __atomic_load_n(&m->loudThresholdBits, __ATOMIC_RELAXED);
    float peak = 0, threshold;
    memcpy(&threshold, &thresholdBits, sizeof threshold);
    double sum = 0;
    int32_t firstLoud = -1, lastLoud = -1;
    uint32_t totalChannels = 0;
    for (uint32_t b = 0; b < input->mNumberBuffers; b++) {
        const AudioBuffer *buf = &input->mBuffers[b];
        const float *d = (const float *)buf->mData;
        uint32_t ch = buf->mNumberChannels ? buf->mNumberChannels : 1;
        if (!d) continue;
        uint32_t n = buf->mDataByteSize / sizeof(float) / ch;
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
    meter_append(m, (BSMeterBlock){
        .hostTime = host,
        .frames = frames,
        .peak = peak,
        .sumSquares = sum / (double)totalChannels,
        .firstLoud = firstLoud,
        .lastLoud = lastLoud,
    });
    return 0;
}

// --------------------------------------------------------------------------------------------
typedef struct {
    int32_t pid;
    uint64_t birth;
} BSCrashEntry;

typedef struct {
    uint64_t generation;
    int counts[2];
    BSCrashEntry entries[2][BS_CRASH_MAX];
} BSCrashSegment;

static BSCrashSegment g_crash[BS_CRASH_SEGMENTS];

void bs_crash_set(int segment, const int32_t *pids, const uint64_t *births, int count) {
    if (segment < 0 || segment >= BS_CRASH_SEGMENTS) return;
    if (count > BS_CRASH_MAX) count = BS_CRASH_MAX;
    if (count < 0) count = 0;
    BSCrashSegment *table = &g_crash[segment];
    uint64_t next = __atomic_load_n(&table->generation, __ATOMIC_RELAXED) + 1;
    unsigned bank = next % 2;
    for (int i = 0; i < count; i++) {
        __atomic_store_n(&table->entries[bank][i].pid, pids[i], __ATOMIC_SEQ_CST);
        __atomic_store_n(&table->entries[bank][i].birth, births[i], __ATOMIC_SEQ_CST);
    }
    __atomic_store_n(&table->counts[bank], count, __ATOMIC_SEQ_CST);
    __atomic_store_n(&table->generation, next, __ATOMIC_SEQ_CST);
}

static uint64_t birth_of(pid_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof info) != (int)sizeof info) return 0;
    if (info.pbi_status == SZOMB) return 0;
    return (uint64_t)info.pbi_start_tvsec * 1000000ULL + (uint64_t)info.pbi_start_tvusec;
}

static void crash_handler(int sig) {
    BSCrashEntry entries[BS_CRASH_MAX];
    for (int s = 0; s < BS_CRASH_SEGMENTS; s++) {
        const BSCrashSegment *table = &g_crash[s];
        // An interrupted setter leaves the most recent committed bank intact. A setter on
        // another thread can lap this read, so verify the generation before signaling.
        for (int attempt = 0; attempt < 3; attempt++) {
            uint64_t generation = __atomic_load_n(&table->generation, __ATOMIC_SEQ_CST);
            unsigned bank = generation % 2;
            int count = __atomic_load_n(&table->counts[bank], __ATOMIC_SEQ_CST);
            for (int i = 0; i < count; i++) {
                entries[i].pid = __atomic_load_n(&table->entries[bank][i].pid, __ATOMIC_SEQ_CST);
                entries[i].birth = __atomic_load_n(&table->entries[bank][i].birth, __ATOMIC_SEQ_CST);
            }
            if (__atomic_load_n(&table->generation, __ATOMIC_SEQ_CST) != generation) continue;
            for (int i = 0; i < count; i++) {
                pid_t pid = entries[i].pid;
                uint64_t birth = entries[i].birth;
                if (pid > 1 && (birth == 0 || birth_of(pid) == birth)) kill(pid, SIGKILL);
            }
            break;
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
