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
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char *ack_path;          // the root process's acknowledgement file (see bs_acknowledge)
static int log_enabled;

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
// its environment once read, so its children don't); a sandboxed app may not be able to, and
// launch then falls back to checking that the library is mapped.
static void bs_acknowledge(OSStatus err) {
    if (!ack_path) return;
    char tmp[1100], line[64];
    if (snprintf(tmp, sizeof tmp, "%s.%d.tmp", ack_path, getpid()) >= (int)sizeof tmp) return;
    int fd = open(tmp, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) return;
    int n = snprintf(line, sizeof line, "%d %d\n", getpid(), (int)err);
    ssize_t written = write(fd, line, (size_t)n);
    close(fd);
    if (written != n || rename(tmp, ack_path) != 0) unlink(tmp);
}

// Core Audio wasn't reachable at startup (coreaudiod restarting, say): keep trying for a while.
static void bs_retry(int attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        OSStatus err = bs_set_inaudible();
        if (err == noErr || attempt >= 100) bs_acknowledge(err);
        else bs_retry(attempt + 1);
    });
}

__attribute__((constructor)) static void bs_inaudible_init(void) {
    log_enabled = getenv("BACKSTAGE_INAUDIBLE_LOG") != NULL;
    const char *ack = getenv("BACKSTAGE_INAUDIBLE_ACK");
    if (ack && *ack && strlen(ack) < 1024) ack_path = strdup(ack);
    unsetenv("BACKSTAGE_INAUDIBLE_ACK");
    OSStatus err = bs_set_inaudible();
    bs_acknowledge(err);
    if (err != noErr) bs_retry(1);
    // A coreaudiod restart forgets the setting: set it again on the new server.
    AudioObjectPropertyAddress restarted = { kAudioHardwarePropertyServiceRestarted, kAudioObjectPropertyScopeGlobal,
                                             kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &restarted,
                                        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                                        ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        (void)count; (void)addresses;
        bs_set_inaudible();
    });
}
