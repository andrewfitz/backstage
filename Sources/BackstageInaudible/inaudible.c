// libbackstage-inaudible.dylib: injected by `backstage launch` (DYLD_INSERT_LIBRARIES) into
// apps that accept it (dev builds, test runners; see Inaudible.swift). Before the app's own code
// runs, it marks the process inaudible to Core Audio (kAudioHardwarePropertyProcessIsAudible =
// 0). The HAL then zeroes the process's output before any tap, so nothing it plays reaches the
// speakers, ScreenCaptureKit (screen sharing, remote desktop), global or device taps, or
// recordings. Only the process itself can set this (docs/AUDIO_PLAN.md, capture spike).
//
// Children inherit the environment, so non-platform helpers load this too. It never writes to
// the app's stdout or stderr (test runners capture them) unless BACKSTAGE_INAUDIBLE_LOG is set.
#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char *ack_path;          // the root process's acknowledgement file (see bs_acknowledge)
static int log_enabled;
static dispatch_queue_t recovery_queue;
static int retry_pending;      // accessed only on recovery_queue

static OSStatus bs_set_inaudible(void) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyProcessIsAudible, kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain };
    UInt32 audible = 0;
    OSStatus err = AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof audible, &audible);
    if (log_enabled) fprintf(stderr, "backstage-inaudible: pid %d ProcessIsAudible=0 -> %d\n", getpid(), (int)err);
    return err;
}

// Tell `backstage launch` the outcome: "<pid> <OSStatus>\n" in the file BACKSTAGE_INAUDIBLE_ACK
// names, written atomically. Only the launched process does this (the variable is removed from
// its environment once read, so its children don't). A sandboxed app may not be able to write
// the acknowledgement, in which case the launcher cannot confirm inaudibility.
static void bs_acknowledge(OSStatus err, int replace) {
    if (!ack_path) return;
    char tmp[1100], line[64];
    int path_length = snprintf(tmp, sizeof tmp, "%s.XXXXXX", ack_path);
    if (path_length < 0 || path_length >= (int)sizeof tmp) return;
    int n = snprintf(line, sizeof line, "%d %d\n", getpid(), (int)err);
    if (n < 0 || n >= (int)sizeof line) return;
    int fd = mkstemp(tmp);
    if (fd < 0) return;
    size_t used = 0;
    while (used < (size_t)n) {
        ssize_t written = write(fd, line + used, (size_t)n - used);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) break;
        used += (size_t)written;
    }
    close(fd);
    // A retry can update the pending status, but must not recreate a file the launcher removed.
    if (used == (size_t)n && !replace && rename(tmp, ack_path) == 0) return;
    if (used == (size_t)n && replace) renamex_np(tmp, ack_path, RENAME_SWAP);
    unlink(tmp);
}

static void bs_finish_acknowledgement(OSStatus err, int replace) {
    bs_acknowledge(err, replace);
    free(ack_path);
    ack_path = NULL;
}

// Core Audio may be unavailable during startup or a server restart. Coalesce retries.
static void bs_retry(int attempt) {
    retry_pending = 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), recovery_queue, ^{
        retry_pending = 0;
        OSStatus err = bs_set_inaudible();
        if (err == noErr || attempt >= 100) bs_finish_acknowledgement(err, 1);
        else bs_retry(attempt + 1);
    });
}

__attribute__((constructor)) static void bs_inaudible_init(void) {
    log_enabled = getenv("BACKSTAGE_INAUDIBLE_LOG") != NULL;
    const char *ack = getenv("BACKSTAGE_INAUDIBLE_ACK");
    if (ack && *ack && strlen(ack) < 1024) ack_path = strdup(ack);
    unsetenv("BACKSTAGE_INAUDIBLE_ACK");
    recovery_queue = dispatch_queue_create("backstage.inaudible.recovery", DISPATCH_QUEUE_SERIAL);
    OSStatus err = bs_set_inaudible();
    if (err == noErr) bs_finish_acknowledgement(err, 0);
    else {
        bs_acknowledge(err, 0);
        dispatch_async(recovery_queue, ^{ bs_retry(1); });
    }
    // A coreaudiod restart forgets the setting: set it again on the new server.
    AudioObjectPropertyAddress restarted = { kAudioHardwarePropertyServiceRestarted, kAudioObjectPropertyScopeGlobal,
                                             kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &restarted,
                                        recovery_queue,
                                        ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        (void)count; (void)addresses;
        if (!retry_pending && bs_set_inaudible() != noErr) bs_retry(1);
    });
}
