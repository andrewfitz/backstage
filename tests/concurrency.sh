#!/bin/bash
# Shared-display concurrency test (phase 3 of docs/MULTI_AGENT_PLAN.md). Sessions A and B
# (BACKSTAGE_SESSION) each run fixture instances on the one agent display:
#  - placement keeps new windows apart (two fit side by side here; the third wraps to a new row)
#  - with windows forced on top of each other, each session's screenshots hold all of its own
#    pixels and none of the other app's, including context menus, sheets and popovers
#  - clicks and typing reach the covered app, not the one on top
#  - gate: a slow launch plus a capture burst in A doesn't hold up B's typing and quitting.
#    B's latencies are printed next to an idle baseline.
# A watchdog asserts that nothing reaches the user's screens while this runs.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build) || exit 1
    BIN_DIR="$(cd "$ROOT" && swift build -c release --show-bin-path)" || exit 1
    BACKSTAGE_BIN="$BIN_DIR/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-concurrency.XXXX)" || exit 1
export BACKSTAGE_HOME="$WORK/state"
# A small display, so the third window has to wrap to a second row.
export BACKSTAGE_WIDTH=1000 BACKSTAGE_HEIGHT=900
unset BACKSTAGE_SESSION
WATCH=
BG=()
cleanup() {
    local result=$?
    trap - EXIT
    for p in ${BG[@]+"${BG[@]}"}; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    for p in ${BG[@]+"${BG[@]}"}; do wait "$p" 2>/dev/null; done
    if [[ -f "$BACKSTAGE_HOME/daemon.json" || -f "$BACKSTAGE_HOME/apps.json" ]]; then
        "$BS" stop --all >/dev/null 2>&1 || result=1
    fi
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
alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null) && [[ $st != Z* ]]; }
# value <a|b> [--pid P]: the fixture's text field value.
value() { local s=$1; shift; "$s" find --role textfield "$@" | jget "['elements'][0].get('value','')"; }
waitvalue() {
    local want=$1; shift
    for _ in $(seq 1 40); do [[ "$(value "$@")" == "$want" ]] && return 0; sleep 0.1; done; return 1
}
waitlog() { for _ in $(seq 1 ${3:-40}); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
# "x y w h" of the main fixture window (agent-display points) of `<session> --pid P`.
frame() {
    local s=$1; shift
    BACKSTAGE_SESSION=$s "$BS" windows "$@" | python3 -c "
import sys, json
w = next(w for w in json.load(sys.stdin)['windows'] if w['title'] == 'BackstageTestApp')
f = w['frame']; print(int(f['x']), int(f['y']), int(f['w']), int(f['h']))" 2>/dev/null
}
# Succeeds when two "x y w h" rects overlap.
overlap() { python3 -c "import sys; a, b = (list(map(float, s.split())) for s in sys.argv[1:3]); sys.exit(0 if a[0] < b[0]+b[2] and b[0] < a[0]+a[2] and a[1] < b[1]+b[3] and b[1] < a[1]+a[3] else 1)" "$1" "$2"; }
inside() { python3 -c "import sys; x, y = map(float, sys.argv[1:3]); f = list(map(float, sys.argv[3].split())); sys.exit(0 if f[0] <= x < f[0]+f[2] and f[1] <= y < f[1]+f[3] else 1)" "$1" "$2" "$3"; }
# Run a command, keep its stdout, and record "<label> <milliseconds>" in $WORK/times. A command
# still running after 60 s is killed and fails with status 124, so a hang fails the test.
timed() {
    local label=$1; shift
    python3 -c '
import subprocess, sys, time
t = time.monotonic()
try: code = subprocess.run(sys.argv[3:], timeout=60).returncode
except subprocess.TimeoutExpired: code = 124
with open(sys.argv[1], "a") as f: f.write("%s %.0f\n" % (sys.argv[2], (time.monotonic() - t) * 1000))
sys.exit(code)' "$WORK/times" "$label" "$@"
}
ms() { awk -v l="$1" '$1 == l { v = $2 } END { print v + 0 }' "$WORK/times"; }
# "<own> <foreign>" pad-colored pixel counts in a fresh screenshot of `<session> <pid>`:
# A's instances are red, B's green.
SHOTS=0
shot() {
    local out
    out=$(mktemp "$WORK/shot-$1-XXXX")
    if ! timed "shot-$1" env BACKSTAGE_SESSION="$1" "$BS" screenshot --pid "$2" -o "$out" >/dev/null; then echo "-1 -1"; return; fi
    local r g; read -r r g <<< "$("$WORK/pixels" "$out")"
    if [[ $1 == A ]]; then echo "$r $g"; else echo "$g $r"; fi
}
# check <label> <session> <pid> <baseline own> [<minimum own>]: the screenshot has all of the
# app's own pad pixels (within 2% of the baseline, or at least <minimum own> when a pad-colored
# menu, sheet or popover is open) and essentially none of the other app's. A pad is ~49k pixels
# and the swatches 12-30k; the few hundred allowed are title bar buttons. With a menu log
# and PID, return 2 if that menu closes before the capture can be checked.
check() {
    local label=$1 s=$2 pid=$3 base=$4 least=${5:-0} menu_log=${6:-} menu_pid=${7:-} own foreign ok=0 i tries=1
    # A menu, sheet or popover fades in after its window appears, so a capture taken right
    # away can miss part of it: give those up to ~1.5 s to finish drawing.
    (( least > 0 )) && tries=6
    for (( i = 0; i < tries; i++ )); do
        (( i > 0 )) && sleep 0.25
        if [[ -n "$menu_log" ]] && menuclosed "$menu_log" "$menu_pid"; then return 2; fi
        read -r own foreign <<< "$(shot "$s" "$pid")"
        if (( own < 0 || foreign < 0 || foreign >= 1000 )); then break; fi
        if [[ -n "$menu_log" ]] && menuclosed "$menu_log" "$menu_pid"; then return 2; fi
        if (( least == 0 )); then ok=$(( own * 100 >= base * 98 && own * 100 <= base * 102 ))
        else ok=$(( own >= least )); fi
        (( ok )) && break
    done
    if (( ok && foreign >= 0 && foreign < 1000 )); then
        pass "$label: $s's screenshot has its own pixels ($own, baseline $base) and no foreign ones ($foreign)"
    else
        fail "$label: $s's screenshot has $own own pixels (baseline $base, minimum $least) and $foreign foreign"
        return 1
    fi
}
# Which of two PIDs has the front window: prints the front PID.
front() { "$WORK/zorder" "$1" "$2" | awk '{ print $1 }'; }
# Wait until the PID's context menu is on screen ("pad right click" is logged before it opens).
waitmenu() { for _ in $(seq 1 30); do (( $("$WORK/zorder" --menus "$1") > 0 )) && return 0; sleep 0.1; done; return 1; }
# openmenu <a|b> <pid> <x> <y>: right-click the pad and wait for the menu window. A background
# context menu sometimes runs its tracking loop without ever showing a window (also with one app
# and no overlap; see docs/MULTI_AGENT_PLAN.md), so close it and try once more.
openmenu() {
    local s=$1 pid=$2 log="$WORK/$1.log" n attempt
    for attempt in 1 2; do
        MENU_CLOSED_BEFORE=$(grep -c "context menu closed" "$log")
        n=$(grep -c "pad right click" "$log")
        "$s" click "$3" "$4" --right --pid "$pid" >/dev/null
        for _ in $(seq 1 40); do (( $(grep -c "pad right click" "$log") > n )) && break; sleep 0.1; done
        (( $(grep -c "pad right click" "$log") > n )) || return 1
        waitmenu "$pid" && return 0
        echo "  note: $s's context menu didn't appear (attempt $attempt)"
        "$s" key esc --pid "$pid" >/dev/null; sleep 0.3
    done
    return 1
}

# A click elsewhere can dismiss AppKit's tracking menu during capture. Retry only when
# this opening has a new close event and its menu window is gone.
menuclosed() {
    local closed menus
    closed=$(grep -c "context menu closed" "$1")
    (( closed > MENU_CLOSED_BEFORE )) || return 1
    menus=$("$WORK/zorder" --menus "$2") || return 1
    [[ $menus == 0 ]]
}

checkmenu() {
    local owner=$1 pid=$2 base=$3 other=$4 other_pid=$5 other_base=$6
    local label=A log="$WORK/$owner.log" attempt result MENU_CLOSED_BEFORE
    [[ $owner == b ]] && label=B
    for attempt in 1 2; do
        if ! openmenu "$owner" "$pid" "$MX" "$MY"; then
            fail "$label's context menu didn't open"
            return 1
        fi
        sleep 0.2
        check "$label's context menu" "$label" "$pid" "$base" $((base + 5000)) "$log" "$pid"
        result=$?
        if [[ $result == 0 ]]; then
            check "${other} beside $label's menu" "$other" "$other_pid" "$other_base" 0 "$log" "$pid"
            result=$?
        fi
        if [[ $result == 2 ]]; then
            echo "  note: $label's context menu closed during capture (attempt $attempt)"
            continue
        fi
        if ! menuclosed "$log" "$pid"; then
            if "$owner" key esc --pid "$pid" >/dev/null; then
                for _ in $(seq 1 40); do menuclosed "$log" "$pid" && break; sleep 0.1; done
            fi
            menuclosed "$log" "$pid" && pass "esc closed $label's menu" || fail "$label's menu stayed open"
        fi
        return "$result"
    done
    fail "$label's context menu closed during both capture attempts"
    return 1
}

echo "== build fixtures"
mkdir -p "$WORK/BackstageTestApp.app/Contents/MacOS"
swiftc -O TestApp.swift -o "$WORK/BackstageTestApp.app/Contents/MacOS/BackstageTestApp" || exit 1
BUNDLE="dev.backstage.testapp.${WORK##*.}"
cat > "$WORK/BackstageTestApp.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageTestApp</string><key>CFBundleIdentifier</key><string>$BUNDLE</string><key>CFBundleName</key><string>BackstageTestApp</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
APP="$WORK/BackstageTestApp.app"
swiftc -O watch.swift -o "$WORK/watch" || exit 1
swiftc -O pixels.swift -o "$WORK/pixels" || exit 1
swiftc -O zorder.swift -o "$WORK/zorder" || exit 1
"$WORK/watch" "$BUNDLE" 600 "$WORK/watch.stop" > "$WORK/watch.out" 2>&1 &
WATCH=$!
sleep 0.3

echo "== placement: new windows go to the first free spot"
PA=$(a launch "$APP" --env "TESTAPP_LOG=$WORK/a.log" --env TESTAPP_PAD=red --env TESTAPP_OVERLAYS=1 --env "TESTAPP_SPOT=100,100 300,200" | jget "['pid']")
PB=$(b launch "$APP" --env "TESTAPP_LOG=$WORK/b.log" --env TESTAPP_PAD=green --env TESTAPP_OVERLAYS=1 --env "TESTAPP_SPOT=100,100 300,200" | jget "['pid']")
PC=$(BACKSTAGE_SESSION=C "$BS" launch "$APP" --env "TESTAPP_LOG=$WORK/c.log" | jget "['pid']")
[[ -n "$PA" && -n "$PB" && -n "$PC" ]] && pass "A launched $PA, B $PB, C $PC" || { fail "launch"; exit 1; }
FA=$(frame A --pid "$PA"); FB=$(frame B --pid "$PB"); FC=$(frame C --pid "$PC")
echo "  frames: A [$FA]  B [$FB]  C [$FC]  (display ${BACKSTAGE_WIDTH}x$BACKSTAGE_HEIGHT)"
python3 - "$BACKSTAGE_WIDTH" "$BACKSTAGE_HEIGHT" "$FA" "$FB" "$FC" <<'PYTHON' && pass "three windows on the display, none overlapping, the third on a second row" || fail "placement"
import sys
W, H = map(int, sys.argv[1:3]); a, b, c = (list(map(int, s.split())) for s in sys.argv[3:6])
def apart(p, q): return p[0] + p[2] <= q[0] or q[0] + q[2] <= p[0] or p[1] + p[3] <= q[1] or q[1] + q[3] <= p[1]
assert all(0 <= f[0] and 0 <= f[1] and f[0] + f[2] <= W and f[1] + f[3] <= H for f in (a, b, c)), "off the display"
assert apart(a, b) and apart(a, c) and apart(b, c), "overlap"
assert a[1] == b[1] and c[1] >= a[1] + a[3], "rows"
PYTHON
[[ $FAIL == 0 ]] || { echo "  windows on the agent display:"; "$WORK/zorder" --display "$("$BS" status | jget "['daemon']['displayID']")" | sed 's/^/    /'; }
BACKSTAGE_SESSION=C "$BS" quit --pid "$PC" >/dev/null && ! alive "$PC" && pass "C quit" || fail "C quit"

echo "== baseline screenshots, windows apart"
read -r BASE_A _ <<< "$(shot A "$PA")"; read -r BASE_B _ <<< "$(shot B "$PB")"
(( BASE_A > 40000 && BASE_B > 40000 )) && pass "baseline pads: A $BASE_A red, B $BASE_B green" || fail "baseline pads: A $BASE_A, B $BASE_B"
check "apart" A "$PA" "$BASE_A"; check "apart" B "$PB" "$BASE_B"
FIELD_A=$(a find --pid "$PA" --role textfield | jget "['elements'][0]['ref']")
FIELD_B=$(b find --pid "$PB" --role textfield | jget "['elements'][0]['ref']")
a set "$FIELD_A" "" --pid "$PA" >/dev/null; a focus "$FIELD_A" --pid "$PA" >/dev/null
b set "$FIELD_B" "" --pid "$PB" >/dev/null; b focus "$FIELD_B" --pid "$PB" >/dev/null

echo "== B's window exactly covers A's"
a menu "Actions > Move To Spot 1" --pid "$PA" >/dev/null
b menu "Actions > Move To Spot 1" --pid "$PB" >/dev/null
sleep 0.3
FA=$(frame A --pid "$PA"); FB=$(frame B --pid "$PB")
[[ "$FA" == "$FB" ]] && pass "same frame [$FA]" || fail "frames differ: A [$FA], B [$FB]"
[[ $(front "$PA" "$PB") == "$PB" ]] && pass "B is in front" || fail "front window: $(front "$PA" "$PB")"
check "A under B" A "$PA" "$BASE_A"; check "B over A" B "$PB" "$BASE_B"

# Pad points of A's window: a point for a left click, and one near the bottom-right for a menu.
read -r X Y W H <<< "$FA"
CX=$((X + 100)) CY=$((Y + H - 40)) MX=$((X + 380)) MY=$((Y + H - 30))
echo "== input reaches A while B covers it"
inside "$CX" "$CY" "$FB" && [[ $(front "$PA" "$PB") == "$PB" ]] && pass "($CX,$CY) is inside B's window, which is in front" || fail "click point not covered"
a click "$CX" "$CY" --pid "$PA" > "$WORK/click-a.json"
waitlog "$WORK/a.log" "pad click 1" && pass "coordinate click reached A's pad" || fail "A's pad got no click: $(cat "$WORK/click-a.json")"
! grep -q "pad click\|monitor type" "$WORK/b.log" && pass "B got no click" || fail "B received the click"
echo "  front after A's click: $(front "$PA" "$PB") (A=$PA, B=$PB)"
a menu "Actions > Move To Spot 1" --pid "$PA" >/dev/null; b menu "Actions > Move To Spot 1" --pid "$PB" >/dev/null
a type "under cover" --pid "$PA" >/dev/null
waitvalue "under cover" a --pid "$PA" && pass "typing reached A's field" || fail "A's field holds '$(value a --pid "$PA")'"
[[ -z "$(value b --pid "$PB")" ]] && pass "B's field is untouched" || fail "B's field holds '$(value b --pid "$PB")'"
[[ $(front "$PA" "$PB") == "$PB" ]] && pass "B still in front after A's typing" || fail "A came to the front while typing"

echo "== A's context menu, sheet and popover while B covers A"
# B at Spot 2 covers A's pad at the menu point and extends past the menu, sheet and popover,
# so any of A's pixels leaking into B's screenshot would be inside B's image.
b menu "Actions > Move To Spot 2" --pid "$PB" >/dev/null; sleep 0.2
FB=$(frame B --pid "$PB")
inside "$MX" "$MY" "$FB" && inside $((MX + 200)) $((MY + 90)) "$FB" && [[ $(front "$PA" "$PB") == "$PB" ]] \
    && pass "B [$FB] covers A's menu point and the menu's area" || fail "B [$FB] doesn't cover A's menu area"
checkmenu a "$PA" "$BASE_A" B "$PB" "$BASE_B"
! grep -q "right click" "$WORK/b.log" && pass "B got no right click" || fail "B received the right click"
sleep 0.3
# While A's context menu is open, A holds the keyboard focus; the daemon's input guard keeps the
# user's typing out of it (tests/focus.sh), so A's text can't change.
[[ "$(value a --pid "$PA")" == "under cover" ]] && pass "A's text unchanged around its context menu" \
    || fail "A's text changed around its context menu ('$(value a --pid "$PA")'): input from outside backstage reached it"
b menu "Actions > Move To Spot 2" --pid "$PB" >/dev/null; sleep 0.2
a menu "Actions > Show Sheet" --pid "$PA" >/dev/null
waitlog "$WORK/a.log" "sheet opened" && sleep 0.5
# macOS 27 shows the sheet as a panel over the window and dims the window, so only the sheet's
# 300x100 swatch is still pure red.
check "A's sheet" A "$PA" "$BASE_A" 25000; check "B over A's sheet" B "$PB" "$BASE_B"
a menu "Actions > Close Overlays" --pid "$PA" >/dev/null
waitlog "$WORK/a.log" "overlays closed"; sleep 0.5
a menu "Actions > Show Popover" --pid "$PA" >/dev/null
waitlog "$WORK/a.log" "popover opened" && sleep 0.5
check "A's popover" A "$PA" "$BASE_A" $((BASE_A + 5000)); check "B over A's popover" B "$PB" "$BASE_B"
a menu "Actions > Close Overlays" --pid "$PA" >/dev/null
waitlog "$WORK/a.log" "overlays closed" 40; sleep 0.5
check "A after overlays closed" A "$PA" "$BASE_A"

echo "== A's window covers B's: the same checks the other way round"
b menu "Actions > Move To Spot 1" --pid "$PB" >/dev/null
a menu "Actions > Move To Spot 1" --pid "$PA" >/dev/null; sleep 0.3
[[ "$(frame A --pid "$PA")" == "$(frame B --pid "$PB")" ]] && pass "same frame again" || fail "frames differ: A [$(frame A --pid "$PA")], B [$(frame B --pid "$PB")]"
[[ $(front "$PA" "$PB") == "$PA" ]] && pass "A is in front" || fail "front window: $(front "$PA" "$PB")"
check "A over B" A "$PA" "$BASE_A"; check "B under A" B "$PB" "$BASE_B"
b click "$CX" "$CY" --pid "$PB" > "$WORK/click-b.json"
waitlog "$WORK/b.log" "pad click 1" && pass "coordinate click reached B's pad" || fail "B's pad got no click: $(cat "$WORK/click-b.json")"
[[ $(grep -c "pad click" "$WORK/a.log") == 1 ]] && pass "A got no extra click" || fail "A received B's click"
a menu "Actions > Move To Spot 1" --pid "$PA" >/dev/null
A_BEFORE=$(value a --pid "$PA")
b type "also covered" --pid "$PB" >/dev/null
waitvalue "also covered" b --pid "$PB" && pass "typing reached B's field" || fail "B's field holds '$(value b --pid "$PB")'"
[[ "$(value a --pid "$PA")" == "$A_BEFORE" ]] && pass "A's field is untouched" || fail "A's field changed from '$A_BEFORE' to '$(value a --pid "$PA")'"
b menu "Actions > Move To Spot 1" --pid "$PB" >/dev/null
a menu "Actions > Move To Spot 2" --pid "$PA" >/dev/null; sleep 0.2
FA2=$(frame A --pid "$PA")
inside "$MX" "$MY" "$FA2" && inside $((MX + 200)) $((MY + 90)) "$FA2" && [[ $(front "$PA" "$PB") == "$PA" ]] \
    && pass "A [$FA2] covers B's menu point and the menu's area" || fail "A [$FA2] doesn't cover B's menu area"
checkmenu b "$PB" "$BASE_B" A "$PA" "$BASE_A"

echo "== partial overlap: B moves down and right, over part of A's pad"
a menu "Actions > Move To Spot 1" --pid "$PA" >/dev/null
b menu "Actions > Move To Spot 2" --pid "$PB" >/dev/null; sleep 0.3
FB=$(frame B --pid "$PB")
overlap "$FA" "$FB" && [[ "$FA" != "$FB" ]] && [[ $(front "$PA" "$PB") == "$PB" ]] && pass "B [$FB] partly covers A [$FA]" || fail "no partial overlap: A [$FA], B [$FB]"
check "A partly under B" A "$PA" "$BASE_A"; check "B partly over A" B "$PB" "$BASE_B"

echo "== gate: a slow launch and a capture burst in A don't hold up B"
TEXT="abcdefghijklmnopqrstuvwxyz0123456789ABCD"   # 40 characters
b focus "$FIELD_B" --pid "$PB" >/dev/null
for i in 1 2 3; do
    b set "$FIELD_B" "" --pid "$PB" >/dev/null
    timed idle-type-B env BACKSTAGE_SESSION=B "$BS" type "$TEXT" --pid "$PB" >/dev/null
    timed idle-shot-B env BACKSTAGE_SESSION=B "$BS" screenshot --pid "$PB" -o "$WORK/idle-b.png" >/dev/null
    timed idle-shot-A env BACKSTAGE_SESSION=A "$BS" screenshot --pid "$PA" -o "$WORK/idle-a.png" >/dev/null
done
waitvalue "$TEXT" b --pid "$PB" || fail "idle typing in B: '$(value b --pid "$PB")'"
b set "$FIELD_B" "" --pid "$PB" >/dev/null; b focus "$FIELD_B" --pid "$PB" >/dev/null
# A2 blocks its main thread for 8 s in applicationDidFinishLaunching, after LaunchServices has
# registered it: A's launch waits (unlocked) for its first window, and A2 doesn't answer AX.
SLOW=8
timed slow-launch-A env BACKSTAGE_SESSION=A "$BS" launch "$APP" --env "TESTAPP_LOG=$WORK/a2.log" --env TESTAPP_PAD=red \
    --env "TESTAPP_SLOW_LAUNCH=$SLOW" > "$WORK/a2.json" &
LAUNCH=$!; BG+=("$LAUNCH")
waitlog "$WORK/a2.log" "slow launch" 100 && pass "A2 is in its slow launch" || fail "A2 never started its slow launch"
# Two capture loops in A, for as long as the slow launch runs (at most 60 captures each).
for loop in 1 2; do
    ( for i in $(seq 1 60); do
          alive "$LAUNCH" || break
          timed burst-shot-A env BACKSTAGE_SESSION=A "$BS" screenshot --pid "$PA" -o "$WORK/burst-$loop.png" \
              > "$WORK/burst-$loop.json" 2>&1 || { echo "$(date +%T) $(tr -d '\n' < "$WORK/burst-$loop.json")" >> "$WORK/burst-errors"; }
      done ) &
    BG+=("$!")
done
BURST=("${BG[@]:1}")
sleep 0.5
timed load-type-B env BACKSTAGE_SESSION=B "$BS" type "$TEXT" --pid "$PB" >/dev/null; TYPED=$?
timed load-shot-B env BACKSTAGE_SESSION=B "$BS" screenshot --pid "$PB" -o "$WORK/load-b.png" >/dev/null; SHOT=$?
V=$(value b --pid "$PB")
timed load-quit-B env BACKSTAGE_SESSION=B "$BS" quit --pid "$PB" > "$WORK/b-quit.json"; QUIT=$?
STILL=0; alive "$LAUNCH" && alive "${BURST[0]}" && STILL=1
[[ $TYPED == 0 && "$V" == "$TEXT" ]] && pass "B typed its text during A's load" || fail "B's typing during A's load: '$V'"
[[ $SHOT == 0 ]] && pass "B captured during A's load" || fail "B's screenshot during A's load"
[[ $QUIT == 0 ]] && ! alive "$PB" && pass "B quit during A's load" || fail "B's quit: $(cat "$WORK/b-quit.json")"
[[ $STILL == 1 ]] && pass "B finished while A's slow launch and capture burst were still running" \
    || fail "A's launch or burst ended before B finished, so B wasn't measured under load"
# Under load, B's typing may take at most 1.5x its slowest idle run, plus 500 ms.
TYPE_LIMIT=$(awk '$1 == "idle-type-B" && $2 > m { m = $2 } END { print int(m * 1.5 + 500) }' "$WORK/times")
(( $(ms load-type-B) <= TYPE_LIMIT && $(ms load-quit-B) < 5000 )) \
    && pass "B's latencies under load: type $(ms load-type-B) ms (limit $TYPE_LIMIT), quit $(ms load-quit-B) ms" \
    || fail "B was slow under load: type $(ms load-type-B) ms (limit $TYPE_LIMIT), quit $(ms load-quit-B) ms"
wait "$LAUNCH"; LAUNCHED=$?
for p in "${BURST[@]}"; do wait "$p"; done
BG=()
PA2=$(jget "['pid']" < "$WORK/a2.json")
[[ $LAUNCHED == 0 && -n "$PA2" ]] && pass "A's slow launch finished ($PA2, $(ms slow-launch-A) ms)" || fail "slow launch: $(cat "$WORK/a2.json")"
FA2=$(frame A --pid "$PA2")
python3 - "$BACKSTAGE_WIDTH" "$BACKSTAGE_HEIGHT" "$FA2" "$FA" <<'PYTHON' && pass "A2 [$FA2] placed on the display clear of A1 [$FA]" || fail "A2's placement [$FA2] (A1 [$FA])"
import sys
W, H = map(int, sys.argv[1:3]); p, q = (list(map(int, s.split())) for s in sys.argv[3:5])
assert 0 <= p[0] and 0 <= p[1] and p[0] + p[2] <= W and p[1] + p[3] <= H
assert p[0] + p[2] <= q[0] or q[0] + q[2] <= p[0] or p[1] + p[3] <= q[1] or q[1] + q[3] <= p[1]
PYTHON
# A's own captures aren't part of the gate, but report any that failed.
[[ -s "$WORK/burst-errors" ]] && echo "  note: $(wc -l < "$WORK/burst-errors" | tr -d ' ') of A's burst captures failed:" && sed 's/^/    /' "$WORK/burst-errors"
grep "slow tick" "$BACKSTAGE_HOME/daemon.log" > "$WORK/slow-ticks.txt"
[[ ! -s "$WORK/slow-ticks.txt" ]] && pass "the daemon's guard loop never stalled" \
    || fail "the daemon's guard loop stalled: $(sort -k4 "$WORK/slow-ticks.txt" | tail -1) ($(wc -l < "$WORK/slow-ticks.txt" | tr -d ' ') times)"

echo "== latencies (ms; B's type is $(( ${#TEXT} )) characters)"
python3 - "$WORK/times" <<'PYTHON'
import collections, statistics, sys
times = collections.defaultdict(list)
for line in open(sys.argv[1]):
    label, value = line.split(); times[label].append(float(value))
for label in ["idle-type-B", "load-type-B", "idle-shot-B", "load-shot-B", "load-quit-B", "idle-shot-A", "burst-shot-A", "slow-launch-A"]:
    v = sorted(times.get(label, []))
    if v: print(f"  {label:14} n={len(v):<3} p50={statistics.median(v):6.0f}  p95={v[min(len(v) - 1, int(len(v) * 0.95))]:6.0f}  max={v[-1]:6.0f}")
PYTHON

echo "== stop"
a stop > "$WORK/a-stop.json" && pass "A's stop" || fail "A's stop: $(cat "$WORK/a-stop.json")"
sleep 0.5
! alive "$PA" && ! alive "$PA2" && pass "A's apps quit" || fail "A's apps still running"
touch "$WORK/watch.stop"
wait "$WATCH" || fail "watchdog detected interference"
WATCH=
cat "$WORK/watch.out"
grep -q PASS "$WORK/watch.out" && pass "non-interference watchdog" || fail "non-interference watchdog"
[ $FAIL = 0 ] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
