// Real-time pieces of backstage's audio taps, in C so the IOProc and the crash handler never
// allocate, lock, or touch Objective-C/Swift runtime state.
#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include <sys/types.h>

// ---------------------------------------------------------------------------------------------
// The published ring: audio/<pid>-<birth>.pcm (mode 0600), the last 15 s of an app's muted tap.
//
// Layout (little-endian, 64-byte header, then samples):
//   offset  size  field
//        0     4  magic           "BSAR"
//        4     4  version         uint32, 1
//        8     8  sampleRate      float64, frames per second (the tap's format)
//       16     4  channels        uint32 (2: the tap is a stereo mixdown)
//       20     4  capacityFrames  uint32 (15 s at sampleRate)
//       24     8  framesWritten   uint64, total frames ever written. Frame k (0-based, counting
//                                 from the first frame written) lives at ring index
//                                 k % capacityFrames. Updated last, with release ordering.
//       32     8  endHostTime     uint64, mach_absolute_time just after the newest frame
//       40     8  endUptime       float64, the same instant in seconds (mach_absolute_time scaled
//                                 by the timebase): the clock of `backstage audio`'s `time`
//       48     8  levelGain       float64, linear gain the daemon applies to levels for display
//                                 (multichannel compensation, see docs/AUDIO_PLAN.md); the
//                                 samples themselves are stored as tapped, without it
//       56     8  reserved        0
//       64     …  samples         float32, interleaved, capacityFrames × channels
//
// The newest frame (framesWritten - 1) ends at endUptime; frame framesWritten - 1 - j started at
// endUptime - (j + 1) / sampleRate. The timeline is continuous: when IO restarts after a pause
// (no output running), the daemon first writes the pause as zeros (up to the capacity), so
// "the last N seconds" is always the N seconds before endUptime. Anything after endUptime is
// silence: nothing has played since. Readers: read framesWritten, copy the frames, read
// framesWritten again; if it moved by more than capacityFrames minus the frames you copied,
// retry. The daemon creates the file at the app's first sound and removes it with the tap.
// ---------------------------------------------------------------------------------------------
typedef struct {
    char magic[4];
    uint32_t version;
    double sampleRate;
    uint32_t channels;
    uint32_t capacityFrames;
    uint64_t framesWritten;
    uint64_t endHostTime;
    double endUptime;
    double levelGain;
    uint64_t reserved;
} BSRingHeader;

#define BS_METER_BLOCKS 1024

/// Per-IO-buffer statistics, written by the IOProc and drained by the daemon's 20 Hz worker.
typedef struct {
    uint64_t hostTime;     // mach_absolute_time of the buffer's first frame
    uint32_t frames;
    float peak;            // max |sample| over all channels (raw tap level)
    double sumSquares;     // sum over frames of the mean square across channels
    int32_t firstLoud;     // first frame with |sample| >= loudThreshold, or -1
    int32_t lastLoud;      // last such frame, or -1
} BSMeterBlock;

typedef struct {
    BSRingHeader *ring;    // NULL until the first sound; set only while IO is stopped
    float *ringData;
    uint32_t channels;
    double secondsPerTick; // mach timebase
    float loudThreshold;   // raw amplitude of the `playing` floor (floor / levelGain)
    uint64_t blocksWritten;   // monotonic; release ordering
    BSMeterBlock blocks[BS_METER_BLOCKS];
} BSMeter;

BSMeter *bs_meter_create(uint32_t channels, double secondsPerTick);
void bs_meter_destroy(BSMeter *meter);
uint64_t bs_meter_blocks_written(const BSMeter *meter);
BSMeterBlock bs_meter_block(const BSMeter *meter, uint64_t index);

/// The tap aggregate's IOProc. `client` is a BSMeter*.
OSStatus bs_meter_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                         const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime,
                         void *client);

/// Append `frames` frames of silence to the ring, ending at `endHostTime` (IO stopped only).
void bs_ring_fill_silence(BSMeter *meter, uint64_t frames, uint64_t endHostTime);

uint64_t bs_load_acquire_u64(const uint64_t *p);
void bs_store_release_u64(uint64_t *p, uint64_t v);

// ---------------------------------------------------------------------------------------------
// Crash handler: on a fatal signal, SIGKILL every managed app (checked against its start time)
// before the daemon dies, so their windows don't land on the user's screen and their audio
// doesn't come out unmuted. Two independently written segments of a fixed table.
// ---------------------------------------------------------------------------------------------
#define BS_CRASH_SEGMENTS 2
#define BS_CRASH_MAX 512
void bs_crash_install(void);
void bs_crash_set(int segment, const int32_t *pids, const uint64_t *births, int count);
