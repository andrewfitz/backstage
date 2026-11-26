// libbackstage-inaudible.dylib: injected by `backstage launch` (DYLD_INSERT_LIBRARIES) into
// apps that accept it (dev builds, test runners; see Inaudible.swift). It also keeps their windows
// off the user's screen (window placement, below). Before the app's own code runs, it marks the
// process inaudible to Core Audio (kAudioHardwarePropertyProcessIsAudible =
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

// MARK: - window placement
//
// A window an agent's app shows must never be drawn on the user's screen, not even for the few
// milliseconds the daemon's Accessibility observer takes to move it. BACKSTAGE_PLACEMENT names a
// file holding "serial N" (the backstage display this launch's windows belong on) or "off" (the
// app was handed to the user). Just before AppKit orders a window in for the first time, the
// window is moved onto that display, keeping its size and its position relative to the screen
// it would have appeared on. Windows attached to another (sheets, popovers, child windows) and
// windows already on a backstage display are left alone.
//
// Nothing here is linked: the Objective-C runtime and CoreGraphics are looked up with dlsym once
// AppKit is in the process, so processes without AppKit (command-line children) load nothing more.

#include <CoreGraphics/CGDirectDisplay.h>
#include <CoreGraphics/CGDisplayConfiguration.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <objc/runtime.h>
#include <pthread.h>

#define BS_VENDOR 0xB57Au
#define BS_MODEL 0x0001u

static char *place_path;
static int place_hooked;
static pthread_mutex_t place_lock = PTHREAD_MUTEX_INITIALIZER;

static struct {
    Class (*lookUpClass)(const char *);
    Method (*instanceMethod)(Class, SEL);
    IMP (*getImplementation)(Method);
    IMP (*setImplementation)(Method, IMP);
    SEL (*sel)(const char *);
    const char *(*className)(id);
    void *msgSend;
#if defined(__x86_64__)
    void *msgSendStret;
#endif
    __typeof__(&CGGetActiveDisplayList) activeDisplays;
    __typeof__(&CGGetDisplaysWithPoint) displaysWithPoint;
    __typeof__(&CGDisplayBounds) bounds;
    __typeof__(&CGMainDisplayID) mainDisplay;
    __typeof__(&CGDisplayVendorNumber) vendor;
    __typeof__(&CGDisplayModelNumber) model;
    __typeof__(&CGDisplaySerialNumber) serial;
} rt;

static struct {
    SEL frame, setFrameOrigin, isVisible, parentWindow, sheetParent, isSheet;
} sel;

static IMP orig_orderWindow, orig_makeKeyAndOrderFront, orig_orderFront, orig_orderFrontRegardless,
           orig_orderBack, orig_setIsVisible;

static void place_log(const char *what, long a, long b) {
    if (log_enabled) fprintf(stderr, "backstage-placement: pid %d %s %ld %ld\n", getpid(), what, a, b);
}

// The serial in the placement file, or 0 (off, missing, unreadable).
static uint32_t place_serial(void) {
    int fd = open(place_path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char buf[64];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    unsigned long value = 0;
    if (strncmp(buf, "serial ", 7) != 0) return 0;
    value = strtoul(buf + 7, NULL, 10);
    return value > 0 && value <= 0xFFFFFFFFul ? (uint32_t)value : 0;
}

static int is_backstage_display(CGDirectDisplayID id) {
    return rt.vendor(id) == BS_VENDOR && rt.model(id) == BS_MODEL;
}

static CGRect window_frame(id w) {
#if defined(__x86_64__)
    CGRect r;
    ((void (*)(CGRect *, id, SEL))rt.msgSendStret)(&r, w, sel.frame);
    return r;
#else
    return ((CGRect (*)(id, SEL))rt.msgSend)(w, sel.frame);
#endif
}

static int msg_bool(id w, SEL s) { return ((signed char (*)(id, SEL))rt.msgSend)(w, s) != 0; }
static id msg_id(id w, SEL s) { return ((id (*)(id, SEL))rt.msgSend)(w, s); }

static int rect_contains(CGRect outer, CGRect inner) {
    return inner.origin.x >= outer.origin.x && inner.origin.y >= outer.origin.y
        && inner.origin.x + inner.size.width <= outer.origin.x + outer.size.width
        && inner.origin.y + inner.size.height <= outer.origin.y + outer.size.height;
}

static double clamp_origin(double v, double lo, double length, double span) {
    if (length >= span) return lo;
    if (v < lo) return lo;
    if (v + length > lo + span) return lo + span - length;
    return v;
}

static void place_window(id w) {
    if (!w || !pthread_main_np()) return;
    if (msg_bool(w, sel.isVisible) || msg_id(w, sel.parentWindow) || msg_bool(w, sel.isSheet)) return;
    if (sel.sheetParent && msg_id(w, sel.sheetParent)) return;
    const char *cls = rt.className(w);
    if (cls && strstr(cls, "StatusBar")) return;
    uint32_t serial = place_serial();
    if (!serial) return;

    CGDirectDisplayID ids[32];
    uint32_t count = 0;
    if (rt.activeDisplays(32, ids, &count) != kCGErrorSuccess) return;
    CGRect target = { { 0, 0 }, { 0, 0 } };
    for (uint32_t i = 0; i < count; i++) {
        if (is_backstage_display(ids[i]) && rt.serial(ids[i]) == serial) { target = rt.bounds(ids[i]); break; }
    }
    if (target.size.width <= 0 || target.size.height <= 0) { place_log("no display for serial", serial, 0); return; }

    // AppKit's frames are measured up from the bottom of the primary display, CoreGraphics' down
    // from its top.
    double primaryHeight = rt.bounds(rt.mainDisplay()).size.height;
    CGRect f = window_frame(w);
    CGRect g = f;
    g.origin.y = primaryHeight - (f.origin.y + f.size.height);
    for (uint32_t i = 0; i < count; i++) {
        if (is_backstage_display(ids[i]) && rect_contains(rt.bounds(ids[i]), g)) return;
    }
    // The screen it would have appeared on: the one under its centre, else the main display.
    CGRect source = rt.bounds(rt.mainDisplay());
    CGDirectDisplayID under = 0;
    uint32_t found = 0;
    CGPoint centre = { g.origin.x + g.size.width / 2, g.origin.y + g.size.height / 2 };
    if (rt.displaysWithPoint(centre, 1, &under, &found) == kCGErrorSuccess && found == 1) source = rt.bounds(under);
    double x = clamp_origin(target.origin.x + (g.origin.x - source.origin.x), target.origin.x, g.size.width, target.size.width);
    double y = clamp_origin(target.origin.y + (g.origin.y - source.origin.y), target.origin.y, g.size.height, target.size.height);
    CGPoint origin = { x, primaryHeight - (y + g.size.height) };
    ((void (*)(id, SEL, CGPoint))rt.msgSend)(w, sel.setFrameOrigin, origin);
    place_log("placed window at", (long)x, (long)y);
}

static void hook_orderWindow(id self, SEL s, long mode, long relativeTo) {
    if (mode != 0) place_window(self);   // 0: NSWindowOut
    ((void (*)(id, SEL, long, long))orig_orderWindow)(self, s, mode, relativeTo);
}
static void hook_makeKeyAndOrderFront(id self, SEL s, id sender) {
    place_window(self);
    ((void (*)(id, SEL, id))orig_makeKeyAndOrderFront)(self, s, sender);
}
static void hook_orderFront(id self, SEL s, id sender) {
    place_window(self);
    ((void (*)(id, SEL, id))orig_orderFront)(self, s, sender);
}
static void hook_orderFrontRegardless(id self, SEL s) {
    place_window(self);
    ((void (*)(id, SEL))orig_orderFrontRegardless)(self, s);
}
static void hook_orderBack(id self, SEL s, id sender) {
    place_window(self);
    ((void (*)(id, SEL, id))orig_orderBack)(self, s, sender);
}
static void hook_setIsVisible(id self, SEL s, signed char visible) {
    if (visible) place_window(self);
    ((void (*)(id, SEL, signed char))orig_setIsVisible)(self, s, visible);
}

// The original is saved before the replacement goes in: another thread may call it at once.
static void swap_method(Class c, const char *name, IMP replacement, IMP *original) {
    Method m = rt.instanceMethod(c, rt.sel(name));
    if (!m) return;
    *original = rt.getImplementation(m);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    rt.setImplementation(m, replacement);
}

#define BS_SYM(field, name) (rt.field = (__typeof__(rt.field))dlsym(RTLD_DEFAULT, name))

// Installs the hooks once NSWindow exists. Called at load and after every dlopen (a test
// bundle brings AppKit in long after launch), never with dyld's or the runtime's locks held.
static void place_try_hook(void) {
    if (!place_path || __atomic_load_n(&place_hooked, __ATOMIC_ACQUIRE)) return;
    pthread_mutex_lock(&place_lock);
    // Looked up once: a failed dlsym would leave an error for the app's next dlerror().
    static int looked_up;
    if (!looked_up) { BS_SYM(lookUpClass, "objc_lookUpClass"); looked_up = 1; }
    if (place_hooked || !rt.lookUpClass) goto done;
    Class window = rt.lookUpClass("NSWindow");
    if (!window) goto done;
    if (!BS_SYM(instanceMethod, "class_getInstanceMethod") || !BS_SYM(setImplementation, "method_setImplementation")
        || !BS_SYM(getImplementation, "method_getImplementation")
        || !BS_SYM(sel, "sel_registerName") || !BS_SYM(className, "object_getClassName")
        || !(rt.msgSend = dlsym(RTLD_DEFAULT, "objc_msgSend"))
#if defined(__x86_64__)
        || !(rt.msgSendStret = dlsym(RTLD_DEFAULT, "objc_msgSend_stret"))
#endif
        || !BS_SYM(activeDisplays, "CGGetActiveDisplayList") || !BS_SYM(displaysWithPoint, "CGGetDisplaysWithPoint")
        || !BS_SYM(bounds, "CGDisplayBounds") || !BS_SYM(mainDisplay, "CGMainDisplayID")
        || !BS_SYM(vendor, "CGDisplayVendorNumber") || !BS_SYM(model, "CGDisplayModelNumber")
        || !BS_SYM(serial, "CGDisplaySerialNumber")) {
        place_log("runtime symbols missing", 0, 0);
        __atomic_store_n(&place_hooked, 1, __ATOMIC_RELEASE);   // don't retry on every dlopen
        goto done;
    }
    sel.frame = rt.sel("frame");
    sel.setFrameOrigin = rt.sel("setFrameOrigin:");
    sel.isVisible = rt.sel("isVisible");
    sel.parentWindow = rt.sel("parentWindow");
    sel.isSheet = rt.sel("isSheet");
    sel.sheetParent = rt.instanceMethod(window, rt.sel("sheetParent")) ? rt.sel("sheetParent") : NULL;
    swap_method(window, "orderWindow:relativeTo:", (IMP)hook_orderWindow, &orig_orderWindow);
    swap_method(window, "makeKeyAndOrderFront:", (IMP)hook_makeKeyAndOrderFront, &orig_makeKeyAndOrderFront);
    swap_method(window, "orderFront:", (IMP)hook_orderFront, &orig_orderFront);
    swap_method(window, "orderFrontRegardless", (IMP)hook_orderFrontRegardless, &orig_orderFrontRegardless);
    swap_method(window, "orderBack:", (IMP)hook_orderBack, &orig_orderBack);
    swap_method(window, "setIsVisible:", (IMP)hook_setIsVisible, &orig_setIsVisible);
    __atomic_store_n(&place_hooked, 1, __ATOMIC_RELEASE);
    place_log("hooks installed", 0, 0);
done:
    pthread_mutex_unlock(&place_lock);
}

// Every dlopen in the process comes through here (whether or not placement is on), so it must
// behave exactly like dlopen: dyld resolves @loader_path and @rpath against the image that called
// dlopen, which is the caller of this function, not this library. dlopen_from names that caller.
// After a failed dlopen nothing else runs, so the caller's dlerror() still describes it.
static void *bs_dlopen(const char *path, int mode) {
    void *caller = __builtin_return_address(0);
    static void *(*volatile dlopen_from_fn)(const char *, int, void *);
    static volatile int resolved;
    if (!resolved) {
        dlopen_from_fn = (void *(*)(const char *, int, void *))dlsym(RTLD_DEFAULT, "dlopen_from");
        resolved = 1;
    }
    void *handle = dlopen_from_fn ? dlopen_from_fn(path, mode, caller) : dlopen(path, mode);
    if (handle) place_try_hook();
    return handle;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *replacee; }
    bs_interpose_dlopen = { (const void *)bs_dlopen, (const void *)dlopen };

static void place_init(void) {
    const char *path = getenv("BACKSTAGE_PLACEMENT");
    if (!path || path[0] != '/' || strlen(path) >= 1024) return;
    place_path = strdup(path);
    place_try_hook();
}

__attribute__((constructor)) static void bs_inaudible_init(void) {
    log_enabled = getenv("BACKSTAGE_INAUDIBLE_LOG") != NULL;
    // Placement only: a launch with --audio must stay audible.
    if (getenv("BACKSTAGE_AUDIBLE")) { unsetenv("BACKSTAGE_INAUDIBLE_ACK"); place_init(); return; }
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
    // After the audio setup, which `launch` waits on.
    place_init();
}
