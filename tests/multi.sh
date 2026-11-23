#!/bin/bash
# Two-agent end-to-end test: sessions A and B (BACKSTAGE_SESSION) each launch their own instance
# of the fixture and must stay out of each other's way. A watchdog asserts that nothing reaches the
# user's screens while this runs.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && swift build -c release)
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-multi.XXXX)"
export BACKSTAGE_HOME="$WORK/state"
unset BACKSTAGE_SESSION
WATCH=
SLEEPER=
cleanup() {
    local result=$?
    trap - EXIT
    wait 2>/dev/null
    if [[ -f "$BACKSTAGE_HOME/daemon.json" || -f "$BACKSTAGE_HOME/apps.json" ]]; then
        "$BS" stop --all >/dev/null 2>&1 || "$BS" stop >/dev/null 2>&1 || result=1
    fi
    if [[ -n "$SLEEPER" ]]; then kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; fi
    if [[ -n "$WATCH" ]]; then
        touch "$WORK/watch.stop"
        wait "$WATCH" || result=1
        cat "$WORK/watch.out"
    fi
    echo "artifacts: $WORK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$BS" status > "$WORK/status.json"
python3 - "$WORK/status.json" <<'PYTHON'
import json, sys
status = json.load(open(sys.argv[1]))
if not status["ok"]:
    sys.exit("\n".join(status["problems"]))
PYTHON
FAIL=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
a() { BACKSTAGE_SESSION=A "$BS" "$@"; }
b() { BACKSTAGE_SESSION=B "$BS" "$@"; }
jget() { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }
# Sorted PIDs (or sessions, with "session") of a `list` result.
pids() { python3 -c "import sys,json; print(sorted(a[sys.argv[1]] for a in json.load(sys.stdin)['apps']))" "${1:-pid}" 2>/dev/null; }
# Succeeds when the command exits 1 with a JSON error.
rejected() { local out code=0; out=$("$@" 2>&1) || code=$?; [[ $code == 1 ]] && echo "$out" | grep -q '"ok" : false'; }
field() { "$@" find --role textfield | jget "['elements'][0]['ref']"; }
value() { "$@" find --role textfield | jget "['elements'][0].get('value','')"; }
waitvalue() {
    local want=$1; shift
    for _ in $(seq 1 40); do [[ "$(value "$@")" == "$want" ]] && return 0; sleep 0.1; done; return 1
}
# A reaped-or-zombie process counts as gone (the legacy sleeper is our own child).
alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null) && [[ $st != Z* ]]; }
daemon_up() { [[ $("$BS" status | jget "['daemon'] is not None") == True ]]; }
# Prints "<red pixels> <green pixels>" for an image.
colors() { "$WORK/pixels" "$1"; }

echo "== build fixtures"
mkdir -p "$WORK/BackstageTestApp.app/Contents/MacOS"
swiftc -O TestApp.swift -o "$WORK/BackstageTestApp.app/Contents/MacOS/BackstageTestApp" || exit 1
cat > "$WORK/BackstageTestApp.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageTestApp</string><key>CFBundleIdentifier</key><string>dev.backstage.testapp.${WORK##*.}</string><key>CFBundleName</key><string>BackstageTestApp</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -O watch.swift -o "$WORK/watch" || exit 1
swiftc -O pixels.swift -o "$WORK/pixels" || exit 1
"$WORK/watch" "dev.backstage.testapp.${WORK##*.}" 600 "$WORK/watch.stop" > "$WORK/watch.out" 2>&1 &
WATCH=$!
sleep 0.3

echo "== each session launches its own instance"
PA=$(a launch "$WORK/BackstageTestApp.app" --env "TESTAPP_LOG=$WORK/a.log" --env TESTAPP_MARKER=alpha --env TESTAPP_PAD=red | jget "['pid']")
PB=$(b launch "$WORK/BackstageTestApp.app" --env "TESTAPP_LOG=$WORK/b.log" --env TESTAPP_MARKER=bravo --env TESTAPP_PAD=green | jget "['pid']")
[[ -n "$PA" && -n "$PB" && "$PA" != "$PB" ]] && pass "A launched $PA, B launched $PB" || { fail "launch"; exit 1; }

echo "== ordinary commands without a PID route to the session's own app"
[[ $(a windows | jget "['pid']") == "$PA" ]] && pass "A's default target is A's app" || fail "A's default target is not $PA"
[[ $(b windows | jget "['pid']") == "$PB" ]] && pass "B's default target is B's app" || fail "B's default target is not $PB"
[[ $(a windows --app BackstageTestApp | jget "['pid']") == "$PA" ]] && pass "--app resolves within A's session" || fail "--app crossed sessions"
FA=$(field a); FB=$(field b)
a set "$FA" "" >/dev/null; a focus "$FA" >/dev/null; a type "alpha text" >/dev/null
b set "$FB" "" >/dev/null; b focus "$FB" >/dev/null; b type "bravo text" >/dev/null
waitvalue "alpha text" a && pass "A typed into its own field" || fail "A's field holds '$(value a)'"
waitvalue "bravo text" b && pass "B typed into its own field" || fail "B's field holds '$(value b)'"
[[ $(a list | pids) == "[$PA]" ]] && pass "A lists only its app" || fail "A's list: $(a list | pids)"
[[ $(b list | pids) == "[$PB]" ]] && pass "B lists only its app" || fail "B's list: $(b list | pids)"
for _ in $(seq 1 20); do a logs 2>/dev/null | grep -q "fixture marker alpha" && break; sleep 0.1; done
a logs > "$WORK/a.logs"; b logs > "$WORK/b.logs"
grep -q "marker alpha" "$WORK/a.logs" && ! grep -q "marker bravo" "$WORK/a.logs" && pass "A's logs are A's app" || fail "A's logs: $(cat "$WORK/a.logs")"
grep -q "marker bravo" "$WORK/b.logs" && ! grep -q "marker alpha" "$WORK/b.logs" && pass "B's logs are B's app" || fail "B's logs: $(cat "$WORK/b.logs")"
SA=$(a screenshot | jget "['path']"); SB=$(b screenshot | jget "['path']")
if [[ -s "$SA" && -s "$SB" ]]; then
    read -r AR AG <<< "$(colors "$SA")"; read -r BR BG <<< "$(colors "$SB")"
    # A pad is ~49k pixels at 2x; the few hundred others are the window's own red/green title bar buttons.
    (( AR > 10000 && AG < 1000 )) && pass "A's screenshot shows only A's red pad ($AR red, $AG green)" || fail "A's screenshot: $AR red, $AG green"
    (( BG > 10000 && BR < 1000 )) && pass "B's screenshot shows only B's green pad ($BG green, $BR red)" || fail "B's screenshot: $BG green, $BR red"
    [[ "$(dirname "$SA")" != "$(dirname "$SB")" ]] && pass "screenshots go to per-session folders" || fail "both sessions share $(dirname "$SA")"
else
    fail "screenshots ($SA, $SB)"
fi

echo "== targeting the other session's app fails"
CROSS=1
rejected a windows --pid "$PB" && pass "A: windows --pid B" || { fail "A reached B's windows by PID"; CROSS=0; }
rejected a logs --pid "$PB" && pass "A: logs --pid B" || { fail "A read B's logs"; CROSS=0; }
rejected a screenshot --pid "$PB" -o "$WORK/cross.png" && pass "A: screenshot --pid B" || { fail "A captured B's app"; CROSS=0; }
rejected a type x --pid "$PB" && pass "A: type --pid B" || { fail "A typed into B's app"; CROSS=0; }
rejected a set "$FB" "hijacked" && pass "A: set with B's element ref" || { fail "A set B's field through a ref"; CROSS=0; }
rejected a focus "$FB" && pass "A: focus with B's element ref" || { fail "A focused B's element through a ref"; CROSS=0; }
waitvalue "bravo text" b && pass "B's field untouched by A" || fail "B's field changed to '$(value b)'"
rejected a screenshot --full -o "$WORK/full.png" && pass "A: screenshot --full rejected while B has windows" || fail "A captured the whole shared display"
if [[ $CROSS == 1 ]]; then
    # Only safe once the harmless checks above prove PIDs are session-scoped: on a build without
    # ownership, these would quit B's app or put it on the user's screen.
    rejected a quit --pid "$PB" && pass "A: quit --pid B" || fail "A quit B's app"
    rejected a show --pid "$PB" && pass "A: show --pid B" || fail "A handed B's app to the user"
    alive "$PB" && pass "B's app survived" || fail "B's app is gone"
else
    fail "skipped quit/show --pid B (ownership is not enforced)"
fi

echo "== the per-app lock keeps two clients' typing from interleaving"
b set "$FB" "" >/dev/null; b focus "$FB" >/dev/null
RUN_A=$(printf 'a%.0s' $(seq 1 80)); RUN_B=$(printf 'b%.0s' $(seq 1 80))
b type "$RUN_A" > "$WORK/t1.json" & T1=$!
b type "$RUN_B" > "$WORK/t2.json" & T2=$!
wait $T1; wait $T2
sleep 0.3
V=$(value b)
[[ "$V" =~ ^(a{80}b{80}|b{80}a{80})$ ]] && pass "concurrent typing arrived in whole runs" || fail "interleaved: '$V'"

echo "== stopping A while B is typing leaves B intact"
b set "$FB" "" >/dev/null; b focus "$FB" >/dev/null
LONG=$(printf '0123456789%.0s' $(seq 1 15))
b type "$LONG" > "$WORK/t3.json" & T3=$!
sleep 0.3
a stop > "$WORK/a-stop.json"; ASTOP=$?
wait $T3; TYPED=$?
[[ $ASTOP == 0 ]] && pass "A's stop succeeded" || fail "A's stop: $(cat "$WORK/a-stop.json")"
sleep 0.5
! alive "$PA" && pass "A's app quit" || fail "A's app still running"
alive "$PB" && pass "B's app still running" || fail "A's stop quit B's app"
[[ $TYPED == 0 ]] && waitvalue "$LONG" b && pass "B's typing completed intact" || fail "B's field holds '$(value b)'"
[[ $(b list | pids) == "[$PB]" ]] && pass "B still lists its app" || fail "B's app list changed"
daemon_up && pass "daemon kept running for B" || fail "daemon stopped while B had an app"
[[ $(a stop | jget "['ok']") == True ]] && pass "A's second stop is a no-op" || fail "A's second stop"
alive "$PB" && pass "B's app survived A's second stop" || fail "B's app gone after A's second stop"

echo "== records from before sessions belong to 'legacy'"
/bin/sleep 300 & SLEEPER=$!
cat > "$WORK/birth.c" <<'C'
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    struct proc_bsdinfo info;
    if (argc != 2 || proc_pidinfo(atoi(argv[1]), PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info)
        return 1;
    printf("%llu\n", info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec);
    return 0;
}
C
xcrun clang "$WORK/birth.c" -o "$WORK/birth"
BIRTH=$("$WORK/birth" "$SLEEPER")
python3 - "$BACKSTAGE_HOME/apps.json" "$SLEEPER" "$BIRTH" <<'PYTHON'
import json, sys, time
path, pid, birth = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
apps = json.load(open(path))
apps.append({"pid": pid, "name": "legacy-sleeper", "path": "/bin/sleep", "launchedAt": time.time(), "processStart": birth})
json.dump(apps, open(path + ".tmp", "w"))
PYTHON
mv "$BACKSTAGE_HOME/apps.json.tmp" "$BACKSTAGE_HOME/apps.json"
[[ $(b list | pids) == "[$PB]" ]] && pass "legacy app not in B's list" || fail "legacy app in B's list"
[[ $("$BS" list --all | pids session) == "['B', 'legacy']" ]] && pass "list --all shows B and legacy" || fail "list --all: $("$BS" list --all)"

echo "== B's stop quits its app; the daemon stays for the legacy app; stop --all ends everything"
b stop > "$WORK/b-stop.json" || fail "B's stop: $(cat "$WORK/b-stop.json")"
sleep 0.5
! alive "$PB" && pass "B's app quit" || fail "B's app still running"
alive "$SLEEPER" && pass "session stop left the legacy app alone" || fail "session stop quit the legacy app"
daemon_up && pass "daemon stays while a legacy app lives" || fail "daemon stopped with a legacy app running"
"$BS" stop --all > "$WORK/stop-all.json" && pass "stop --all" || fail "stop --all: $(cat "$WORK/stop-all.json")"
sleep 0.5
! alive "$SLEEPER" && pass "stop --all quit the legacy app" || fail "legacy app survived stop --all"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; SLEEPER=
! daemon_up && pass "stop --all stopped the daemon" || fail "daemon still running after stop --all"
[[ $("$BS" stop --all | jget "['ok']") == True ]] && pass "second stop --all is a no-op" || fail "second stop --all"

echo "== concurrent launches in two sessions; the last session's stop takes the daemon down"
a launch "$WORK/BackstageTestApp.app" --env "TESTAPP_LOG=$WORK/c.log" > "$WORK/c.json" & LA=$!
b launch "$WORK/BackstageTestApp.app" --env "TESTAPP_LOG=$WORK/d.log" > "$WORK/d.json" & LB=$!
wait $LA; wait $LB
PC=$(jget "['pid']" < "$WORK/c.json"); PD=$(jget "['pid']" < "$WORK/d.json")
[[ -n "$PC" && -n "$PD" && "$PC" != "$PD" ]] && pass "concurrent launches: A $PC, B $PD" || fail "concurrent launches: $(cat "$WORK/c.json" "$WORK/d.json")"
[[ $(a list | pids) == "[$PC]" && $(b list | pids) == "[$PD]" ]] && pass "each concurrent launch is in its own session" || fail "lists after concurrent launch: A $(a list | pids), B $(b list | pids)"
a stop >/dev/null
sleep 0.5
! alive "$PC" && alive "$PD" && daemon_up && pass "A's stop left B's app and the daemon" || fail "after A's stop: A alive=$(alive "$PC" && echo y), B alive=$(alive "$PD" && echo y)"
b stop >/dev/null
sleep 0.5
! alive "$PD" && ! daemon_up && pass "the last session's stop stopped the daemon" || fail "daemon or app left running"

touch "$WORK/watch.stop"
wait "$WATCH" || fail "watchdog detected interference"
WATCH=
cat "$WORK/watch.out"
grep -q PASS "$WORK/watch.out" && pass "non-interference watchdog" || fail "non-interference watchdog"
[ $FAIL = 0 ] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
