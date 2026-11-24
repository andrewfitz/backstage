#!/bin/bash
# Two-agent end-to-end test: sessions A and B (BACKSTAGE_SESSION) each launch their own instance
# of the fixture and must stay out of each other's way. A watchdog asserts that nothing reaches the
# user's screens while this runs.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build) || exit 1
    BIN_DIR="$(cd "$ROOT" && swift build -c release --show-bin-path)" || exit 1
    BACKSTAGE_BIN="$BIN_DIR/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-multi.XXXX)" || exit 1
export BACKSTAGE_HOME="$WORK/state"
unset BACKSTAGE_SESSION
# A second BACKSTAGE_HOME, for two daemons side by side.
HOME2="$WORK/state2"
WATCH=
SLEEPER=
LC=
cleanup() {
    local result=$?
    trap - EXIT
    # The provisional launch CLI may be stopped. Reap it before stopping the daemon.
    if [[ -n "$LC" ]]; then kill -KILL "$LC" 2>/dev/null; wait "$LC" 2>/dev/null; fi
    if [[ -f "$BACKSTAGE_HOME/daemon.json" || -f "$BACKSTAGE_HOME/apps.json" ]]; then
        "$BS" stop --all >/dev/null 2>&1 || "$BS" stop >/dev/null 2>&1 || result=1
    fi
    if [[ -f "$HOME2/daemon.json" || -f "$HOME2/apps.json" ]]; then
        BACKSTAGE_HOME="$HOME2" "$BS" stop --all >/dev/null 2>&1 || result=1
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
python3 - "$WORK/status.json" <<'PYTHON' || exit 1
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
swiftc -O probe.swift -o "$WORK/probe" || exit 1
swiftc -O axmove.swift -o "$WORK/axmove" || exit 1
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
if a screenshot --full -o "$WORK/full.png" > "$WORK/full.json" && [[ -s "$WORK/full.png" ]]; then
    read -r FR FG <<< "$(colors "$WORK/full.png")"
    (( FR > 10000 && FG < 1000 )) && pass "A's --full shows A's app and none of B's ($FR red, $FG green)" || fail "A's --full: $FR red, $FG green"
else
    fail "A's screenshot --full: $(cat "$WORK/full.json")"
fi
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

echo "== a launch killed before registering its app leaves nothing behind"
# Freeze the CLI once its provisional record exists, let the app start, then kill the CLI: the
# daemon must quit the app nobody registered.
BACKSTAGE_SESSION=C "$BS" launch "$WORK/BackstageTestApp.app" --env "TESTAPP_LOG=$WORK/e.log" --env TESTAPP_MARKER=orphan \
    > "$WORK/e.json" 2>&1 & LC=$!
REC=
for _ in $(seq 1 1000); do
    REC=$(compgen -G "$BACKSTAGE_HOME/launching/*.json" | head -1)
    [[ -n "$REC" ]] && break
    sleep 0.01
done
kill -STOP "$LC" 2>/dev/null
if [[ -n "$REC" && -f "$REC" ]]; then
    ELOG=$(jget "['log']" < "$REC")
    for _ in $(seq 1 150); do grep -q "fixture marker orphan" "$ELOG" 2>/dev/null && break; sleep 0.1; done
    # The app has the log as stdout (so did `open`, briefly): pick the fixture's process.
    PE=$(for p in $(lsof -t "$ELOG" 2>/dev/null); do ps -o comm= -p "$p" | grep -q BackstageTestApp && echo "$p"; done | head -1)
    kill -KILL "$LC"; wait "$LC" 2>/dev/null; LC=
    [[ -n "$PE" ]] && pass "orphaned launch started pid $PE" || fail "orphaned launch's app never started"
    for _ in $(seq 1 300); do [[ ! -f "$REC" ]] && ! { [[ -n "$PE" ]] && alive "$PE"; } && break; sleep 0.1; done
    [[ -z "$PE" ]] || ! alive "$PE" && pass "the daemon quit the unregistered app" || fail "orphaned app $PE still running"
    [[ ! -f "$REC" ]] && pass "the provisional record is gone" || fail "provisional record left: $REC"
    [[ $(BACKSTAGE_SESSION=C "$BS" list | pids) == "[]" ]] && pass "the orphan is in no session" || fail "C lists $(BACKSTAGE_SESSION=C "$BS" list | pids)"
    alive "$PB" && daemon_up && pass "B's app and the daemon are unaffected" || fail "B's app or the daemon is gone"
else
    kill -KILL "$LC" 2>/dev/null; wait "$LC" 2>/dev/null; LC=
    fail "no provisional launch record appeared"
fi

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

echo "== two homes: two daemons at once, displays apart, each guarding its own windows"
h2() { BACKSTAGE_HOME="$HOME2" BACKSTAGE_SESSION=A "$BS" "$@"; }
# Succeeds once every display of the two homes meets every other display (the user's, each
# other's, any other backstage display) at most at a corner point.
layout_ok() {
    "$BS" status > "$WORK/h1-status.json" && h2 status > "$WORK/h2-status.json" && "$WORK/probe" displays > "$WORK/displays.json" || return 1
    python3 - "$WORK/h1-status.json" "$WORK/h2-status.json" "$WORK/displays.json" <<'PYTHON'
import json, sys
s1, s2, ds = (json.load(open(p)) for p in sys.argv[1:])
d1, d2 = s1["daemon"], s2["daemon"]
assert d1 and d2, "both daemons up"
assert d1["pid"] != d2["pid"] and d1["displayID"] != d2["displayID"], "each home has its own daemon and display"
rect = {d["id"]: (d["points"]["x"], d["points"]["y"], d["points"]["w"], d["points"]["h"]) for d in ds["displays"]}
def contact(a, b):
    dx = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]); dy = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    return "apart" if dx < 0 or dy < 0 else "overlap" if dx > 0 and dy > 0 else "corner" if dx == 0 and dy == 0 else "edge"
for mine in (d1["displayID"], d2["displayID"]):
    for other, r in rect.items():
        if other != mine:
            c = contact(rect[mine], r)
            assert c in ("apart", "corner"), f"display {mine} {rect[mine]} meets display {other} {r}: {c}"
print(f"home 1 display {rect[d1['displayID']]}, home 2 display {rect[d2['displayID']]}, all: {sorted(rect.values())}")
PYTHON
}
# Succeeds once every window of the PID lies inside its home's display (status JSON given).
own_windows() {
    "$WORK/axmove" --frames "$1" > "$WORK/frames.txt"
    python3 - "$2" "$WORK/frames.txt" <<'PYTHON'
import json, sys
d = json.load(open(sys.argv[1]))["daemon"]
x, y, w, h = d["globalOrigin"]["x"], d["globalOrigin"]["y"], d["size"]["w"], d["size"]["h"]
frames = [tuple(map(int, line.split())) for line in open(sys.argv[2]) if line.strip()]
assert frames and all(x <= f[0] and y <= f[1] and f[0] + f[2] <= x + w and f[1] + f[3] <= y + h for f in frames), frames
PYTHON
}
wait_own() { for _ in $(seq 1 40); do own_windows "$1" "$2" 2>/dev/null && return 0; sleep 0.1; done; own_windows "$1" "$2"; }
PH1=$(a launch "$WORK/BackstageTestApp.app" --env "TESTAPP_LOG=$WORK/h1.log" --env TESTAPP_PAD=red | jget "['pid']")
PH2=$(h2 launch "$WORK/BackstageTestApp.app" --env "TESTAPP_LOG=$WORK/h2.log" --env TESTAPP_PAD=green | jget "['pid']")
if [[ -n "$PH1" && -n "$PH2" ]]; then
    pass "home 1 launched $PH1, home 2 launched $PH2"
    OK=
    for _ in $(seq 1 20); do layout_ok > "$WORK/layout.txt" 2>&1 && { OK=1; break; }; sleep 0.2; done
    [[ -n $OK ]] && pass "displays apart: $(cat "$WORK/layout.txt")" || fail "display layout: $(tail -1 "$WORK/layout.txt")"
    wait_own "$PH1" "$WORK/h1-status.json" && pass "home 1's app is on home 1's display" || fail "home 1's windows: $(cat "$WORK/frames.txt")"
    wait_own "$PH2" "$WORK/h2-status.json" && pass "home 2's app is on home 2's display" || fail "home 2's windows: $(cat "$WORK/frames.txt")"
    # Put a window of each home's app on the other home's display (never on the user's screens):
    # its own daemon must take it back.
    read -r X1 Y1 <<< "$(jget "['daemon']['globalOrigin']['x'], d['daemon']['globalOrigin']['y']" < "$WORK/h1-status.json" | tr -d '(),')"
    read -r X2 Y2 <<< "$(jget "['daemon']['globalOrigin']['x'], d['daemon']['globalOrigin']['y']" < "$WORK/h2-status.json" | tr -d '(),')"
    "$WORK/axmove" "$PH2" $((X1 + 100)) $((Y1 + 100)) >/dev/null
    wait_own "$PH2" "$WORK/h2-status.json" && pass "home 2's daemon took its window back from home 1's display" || fail "home 2's windows: $(cat "$WORK/frames.txt")"
    "$WORK/axmove" "$PH1" $((X2 + 100)) $((Y2 + 100)) >/dev/null
    wait_own "$PH1" "$WORK/h1-status.json" && pass "home 1's daemon took its window back from home 2's display" || fail "home 1's windows: $(cat "$WORK/frames.txt")"
    [[ $(a list | pids) == "[$PH1]" && $(h2 list | pids) == "[$PH2]" ]] && pass "each home lists only its own app" || fail "lists: $(a list | pids) / $(h2 list | pids)"
    # One binary, two daemons: each home's screenshot shows its own app (red in 1, green in 2).
    if a screenshot -o "$WORK/h1.png" > "$WORK/h1-shot.json" && h2 screenshot -o "$WORK/h2.png" > "$WORK/h2-shot.json"; then
        read -r R1 G1 <<< "$(colors "$WORK/h1.png")"; read -r R2 G2 <<< "$(colors "$WORK/h2.png")"
        (( R1 > 10000 && G1 < 1000 && G2 > 10000 && R2 < 1000 )) && pass "each home's screenshot shows its own app" \
            || fail "screenshots: home 1 $R1 red $G1 green, home 2 $R2 red $G2 green"
    else
        fail "screenshots in two homes: $(cat "$WORK/h1-shot.json" "$WORK/h2-shot.json" 2>/dev/null)"
    fi
else
    fail "launch in two homes: '$PH1' '$PH2'"
fi
h2 stop >/dev/null; a stop >/dev/null
sleep 0.5
! alive "$PH1" && ! alive "$PH2" && ! daemon_up && [[ $(h2 status | jget "['daemon'] is None") == True ]] \
    && pass "both homes' stops quit their apps and daemons" || fail "a home's app or daemon is left"

touch "$WORK/watch.stop"
wait "$WATCH" || fail "watchdog detected interference"
WATCH=
cat "$WORK/watch.out"
grep -q PASS "$WORK/watch.out" && pass "non-interference watchdog" || fail "non-interference watchdog"
[ $FAIL = 0 ] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
