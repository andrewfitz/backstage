#!/bin/bash
# Window placement from inside the app: the library `launch` injects puts every window an app
# shows onto its backstage display before the window is drawn, so none appears on the user's
# screen even briefly (the daemon's observer only moves windows after they appeared). Checks every
# AppKit route, AppKit linked at launch and loaded later by dlopen (as xctest loads a test bundle),
# --audio launches, `move` and close-display rewriting the target, "off" leaving windows alone,
# and a control without the library whose windows stay where the app put them.
# Every fixture window is fully transparent, so the fixture checks each window's frame itself,
# right after showing it: the daemon's observer doesn't act on transparent windows, so its log
# can't show anything here. Runs on displays 7 (primary) and 8 (extra).
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build) || exit 1
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-placement.XXXX)" || exit 1
export BACKSTAGE_HOME="$WORK/state" BACKSTAGE_DISPLAY=7 BACKSTAGE_EXTRA_DISPLAYS=8 BACKSTAGE_EXTRA_DISPLAY_GRACE=3
export BACKSTAGE_SESSION=placement-test
mkdir -p "$BACKSTAGE_HOME"
FAIL=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -f "$BACKSTAGE_HOME/daemon.json" || -f "$BACKSTAGE_HOME/apps.json" ]]; then
        "$BS" stop --all > /dev/null 2>&1 || result=1
    fi
    local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    for bundle in "$BACKSTAGE_HOME"/wrappers/*.app; do
        [[ -d "$bundle" ]] && "$lsregister" -u "$bundle" > /dev/null 2>&1 || true
    done
    echo "artifacts: $WORK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
jget() { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1"; }
serial() { echo $((0x42530000 + $1)); }

echo "== build fixtures"
swiftc -O -parse-as-library -emit-library placeprobe.swift -o "$WORK/libplaceprobe.dylib" || exit 1
mkdir -p "$WORK/linked"
cp placeprobe.swift "$WORK/linked/probe.swift"
printf 'import Foundation\nexit(runProbe())\n' > "$WORK/linked/main.swift"
swiftc -O "$WORK/linked/probe.swift" "$WORK/linked/main.swift" -o "$WORK/placeprobe" || exit 1
cat > "$WORK/host.c" <<'C'
// Brings AppKit in only through dlopen.
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc < 2) return 1;
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    int (*probe)(void) = (int (*)(void))dlsym(h, "bs_probe");
    return probe ? probe() : 3;
}
C
cc -o "$WORK/placehost" "$WORK/host.c" || exit 1
if otool -L "$WORK/placehost" | grep -q AppKit; then fail "the dlopen host links AppKit"; fi

echo "== dlopen behaves as without the library"
# The library reroutes every dlopen in the app (to install its hooks when AppKit arrives late):
# @loader_path and @rpath must still resolve against the caller, and dlerror() must survive.
LIB="$(dirname "$BS")/libbackstage-inaudible.dylib"
mkdir -p "$WORK/rp/a/sub"
echo 'int target_value(void) { return 42; }' > "$WORK/rp/target.c"
cat > "$WORK/rp/loader.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
int try_loads(void) {
    int ok = 0;
    ok += dlopen("@loader_path/sub/libtarget.dylib", RTLD_NOW) != NULL;
    ok += dlopen("@rpath/libtarget.dylib", RTLD_NOW) != NULL;
    const char *err = dlopen("/nonexistent/libnope.dylib", RTLD_NOW) ? NULL : dlerror();
    ok += err && strstr(err, "libnope") != NULL;
    printf("%d\n", ok);
    return ok;
}
C
echo 'int try_loads(void); int main(void) { return try_loads() == 3 ? 0 : 1; }' > "$WORK/rp/main.c"
cc -dynamiclib -o "$WORK/rp/a/sub/libtarget.dylib" -install_name @rpath/libtarget.dylib "$WORK/rp/target.c" \
    && cc -dynamiclib -o "$WORK/rp/a/libloader.dylib" -install_name @rpath/libloader.dylib -Wl,-rpath,@loader_path/sub "$WORK/rp/loader.c" \
    && cc -o "$WORK/rp/main" "$WORK/rp/main.c" -L "$WORK/rp/a" -lloader -Wl,-rpath,"$WORK/rp/a" || exit 1
"$WORK/rp/main" > /dev/null || fail "the dlopen fixture fails even without the library"
DYLD_INSERT_LIBRARIES="$LIB" BACKSTAGE_AUDIBLE=1 BACKSTAGE_PLACEMENT="$WORK/none" "$WORK/rp/main" > /dev/null \
    && pass "@loader_path, @rpath and dlerror() unchanged with the library" || fail "dlopen changed with the library injected"

"$BS" start > /dev/null || { echo "daemon didn't start"; exit 1; }

# launch <name> <args…>: sets PID, LOG, PLACE, AUDIO; waits for the probe's start-up report.
launch() {
    local name=$1; shift
    local out
    out=$("$BS" launch "$@" 2>&1)
    PID=$(jget '["pid"]' <<< "$out" 2>/dev/null) LOG=$(jget '["log"]' <<< "$out" 2>/dev/null) AUDIO=$(jget '["audio"]' <<< "$out" 2>/dev/null)
    if [[ -z $PID || -z $LOG ]]; then fail "$name: launch failed: $out"; return 1; fi
    PLACE="${LOG%.log}.place"
    for _ in $(seq 1 100); do grep -q '^failures: ' "$LOG" && break; sleep 0.1; done
}
# signal_window: has the probe open one more window and prints where it went ("backstage" or
# "elsewhere"), or "no reply". Waits for that window's own line.
signal_window() {
    local n
    n=$(( $(grep -c '^signal ' "$LOG") + 1 ))
    kill -USR1 "$PID"
    for _ in $(seq 1 100); do grep -q "^signal $n: " "$LOG" && break; sleep 0.1; done
    local line
    line=$(grep "^signal $n: " "$LOG")
    echo "${line:-no reply}" >> "$WORK/signals.txt"
    [[ -n $line ]] && awk '{print $3}' <<< "$line" || echo "no reply"
}
routes() {
    if grep -qx 'failures: 0' "$LOG"; then pass "$1: every route placed before showing ($(grep -c '^ok ' "$LOG") windows)"
    else fail "$1: $(grep -E '^FAIL|^failures' "$LOG" | tr '\n' ';')"; fi
}

echo "== AppKit linked"
launch linked "$WORK/placeprobe" --env BACKSTAGE_INAUDIBLE_LOG=1
routes linked
[[ $AUDIO == inaudible || $AUDIO == muted ]] && pass "audio $AUDIO" || fail "audio: $AUDIO"
[[ $(cat "$PLACE" 2>/dev/null) == "serial $(serial 7)" ]] && pass "placement file names display 7" || fail "placement file: $(cat "$PLACE" 2>&1)"
R=$(signal_window); [[ $R == backstage ]] && pass "a later window is placed" || fail "a later window: $R"
LINKED=$PID

echo "== AppKit loaded by dlopen"
launch dlopen "$WORK/placehost" -- "$WORK/libplaceprobe.dylib"
routes dlopen
R=$(signal_window); [[ $R == backstage ]] && pass "a later window is placed" || fail "a later window: $R"
DLOPEN=$PID

echo "== --audio"
launch audio "$WORK/placeprobe" --audio
routes "--audio"
[[ $AUDIO == metered ]] && pass "stays audible (metered)" || fail "audio: $AUDIO"
AUDIBLE=$PID

echo "== move and close-display"
OUT=$("$BS" move --pid "$LINKED" --display 8 2>&1)
[[ $(jget '["display"]' <<< "$OUT" 2>/dev/null) == 8 ]] || fail "move: $OUT"
PID=$LINKED
LOG=$("$BS" list | python3 -c "import sys,json; print([a['log'] for a in json.load(sys.stdin)['apps'] if a['pid']==$LINKED][0])")
PLACE="${LOG%.log}.place"
[[ $(cat "$PLACE") == "serial $(serial 8)" ]] && pass "move rewrites the placement file for display 8" || fail "after move: $(cat "$PLACE")"
R=$(signal_window); [[ $R == backstage ]] && pass "a new window after move is placed" || fail "a new window after move: $R"
OUT=$("$BS" close-display 8 --force 2>&1)
[[ $(cat "$PLACE") == "serial $(serial 7)" ]] && pass "close-display rewrites it for display 7" || fail "after close-display: $(cat "$PLACE") ($OUT)"

echo "== off (an app handed to the user)"
# The library logs each move (BACKSTAGE_INAUDIBLE_LOG): with "off" it must make none. (Where the
# window ends up is macOS's choice: it opens new windows where the app's others are, display 7 here.
# A real "off" follows `show`, which first moves them all to the user's screen.)
echo off > "$PLACE"
MOVES=$(grep -c 'backstage-placement: .* placed window' "$LOG")
R=$(signal_window)
[[ $R != "no reply" && $(grep -c 'backstage-placement: .* placed window' "$LOG") == "$MOVES" ]] \
    && pass "off: the library leaves a new window alone" || fail "off: the library still moved it ($R)"
echo "serial $(serial 7)" > "$PLACE"

echo "== control: without the library, the same windows are not placed"
export BACKSTAGE_INAUDIBLE_DYLIB=   # empty: no library
launch control "$WORK/placeprobe"
unset BACKSTAGE_INAUDIBLE_DYLIB
[[ -f $PLACE ]] && fail "a launch without the library wrote a placement file" || pass "no placement file"
N=$(sed -n 's/^failures: //p' "$LOG")
(( ${N:-0} >= 10 )) && pass "$N of the routes left their window where the app put it" || fail "control: failures: ${N:-none}"
R=$(signal_window); [[ $R == elsewhere ]] && pass "a later window stays where the app put it" || fail "control's later window: $R"

if (( FAIL )); then echo "placement: FAILED"; exit 1; fi
echo "placement: all passed"
