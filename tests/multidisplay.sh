#!/bin/bash
# Several displays per daemon (docs/MULTI_DISPLAY_PLAN.md, phase 2): `launch --display new`,
# reservations and their expiry, session affinity, coordinates on a second display, the window
# guard keeping each app on its own display, `move`, `crowded`, and an empty extra display going
# away. Runs on displays 7 (primary) and 8 (extra) only, with a small display so it crowds fast.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build) || exit 1
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-multidisplay.XXXX)" || exit 1
export BACKSTAGE_HOME="$WORK/state" BACKSTAGE_DISPLAY=7 BACKSTAGE_EXTRA_DISPLAYS=8
export BACKSTAGE_RESERVATION_SECONDS=40 BACKSTAGE_EXTRA_DISPLAY_GRACE=3 BACKSTAGE_WIDTH=900 BACKSTAGE_HEIGHT=600
mkdir -p "$BACKSTAGE_HOME"
WATCH=
FAIL=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -f "$BACKSTAGE_HOME/daemon.json" || -f "$BACKSTAGE_HOME/apps.json" ]]; then
        "$BS" stop --all > /dev/null 2>&1 || result=1
    fi
    if [[ -n $WATCH ]]; then touch "$WORK/watch.stop"; wait "$WATCH" || result=1; cat "$WORK/watch.out"; fi
    echo "artifacts: $WORK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "== build fixtures"
APP="$WORK/BackstageTestApp.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O TestApp.swift -o "$APP/Contents/MacOS/BackstageTestApp" || exit 1
BID="dev.backstage.testapp.${WORK##*.}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageTestApp</string><key>CFBundleIdentifier</key><string>$BID</string><key>CFBundleName</key><string>BackstageTestApp</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -O watch.swift -o "$WORK/watch" || exit 1
swiftc -O csdevices.swift -o "$WORK/csdevices" || exit 1
swiftc -O pixels.swift -o "$WORK/pixels" || exit 1
. ./watch.sh
start_watch "$BID" 300 || exit 1
DEVICES0=$("$WORK/csdevices")

as() { local who=$1; shift; BACKSTAGE_SESSION="$who" "$BS" "$@"; }
launch() {  # session, pad colour, extra args… ; prints the launch JSON
    local who=$1 pad=$2; shift 2
    as "$who" launch "$APP" --env "TESTAPP_LOG=$WORK/$who-$pad.log" --env "TESTAPP_PAD=$pad" "$@"
}
displays() { "$BS" status | jq -ec '.daemon | select(.pid != null) | ([.displays[]?.display] + [.display] | unique)'; }

echo "== menu layouts (synthetic: no displays created)"
R1=$("$BS" __menu-render --displays 1); R2=$("$BS" __menu-render --displays 2)
R3=$("$BS" __menu-render --displays 3 --page 1); R6=$("$BS" __menu-render --displays 6 --page 2)
echo "$R1" | jq -e '(.previews | length) == 1 and .pager == null' > /dev/null && pass "1 display: one picture, no pager" || fail "1: $R1"
echo "$R2" | jq -e '(.previews | length) == 2 and .pager == null and .width > 400 and all(.previews[]; .height <= 150 and .y == 6 and (.hidden | not))' > /dev/null \
    && pass "2 displays: two pictures side by side, no pager" || fail "2: $R2"
echo "$R3" | jq -e '.visible == [3] and .previews[1].hidden and .canBack and (.canForward | not) and .height == ('"$(echo "$R2" | jq .height)"' + 24)' > /dev/null \
    && pass "3 displays, page 2: display 3 alone, same height as page 1, back only" || fail "3: $R3"
echo "$R6" | jq -e '.visible == [5, 6] and .first == 5 and .last == 6 and .canBack and (.canForward | not)' > /dev/null \
    && pass "6 displays, page 3: displays 5-6" || fail "6: $R6"

echo "== one display: nothing changes"
OUT=$(launch A blue)
PA=$(echo "$OUT" | jq -r .pid)
[[ $(echo "$OUT" | jq -r .display) == 7 ]] && pass "A's app is on display 7 (the primary)" || fail "A's launch: $OUT"

echo "== a display of your own"
OUT=$(launch B green --display new)
PB=$(echo "$OUT" | jq -r .pid)
[[ $(echo "$OUT" | jq -r .display) == 8 ]] && pass "B's --display new got display 8" || fail "B's launch: $OUT"
"$BS" status | jq -e '.daemon.displays[] | select(.display == 8) | .reservedBy == "B"' > /dev/null \
    && pass "status shows display 8 reserved for B" || fail "status: $("$BS" status | jq -c .daemon.displays)"
as B list | jq -e --argjson p "$PB" '.apps[] | select(.pid == $p) | .display == 8' > /dev/null && pass "list shows B's app on 8" || fail "list: $(as B list | jq -c .apps)"

echo "== coordinates on display 8 are display 8's"
PADXY=$(as B find --pid "$PB" --role window --text BackstageTestApp | jq -r '.elements[0].frame | "\(.x + 100) \(.y + .h - 40)"')
as B click $PADXY --pid "$PB" > /dev/null
for _ in $(seq 1 40); do grep -q "pad click 1" "$WORK/B-green.log" 2>/dev/null && break; sleep 0.1; done
grep -q "pad click 1" "$WORK/B-green.log" && pass "a coordinate click at ($PADXY) on display 8 hit B's pad" || fail "click on display 8 missed"
SHOT=$(as B screenshot --pid "$PB" -o "$WORK/b-window.png")
if [[ -s "$WORK/b-window.png" ]] && read -r red green < <("$WORK/pixels" "$WORK/b-window.png") &&
   (( green > 20000 && red < 1000 )); then
    pass "B's screenshot shows B's green pad"
else
    fail "screenshot: $SHOT"
fi
FULL=$(as B screenshot --full)
echo "$FULL" | jq -e --argjson pid "$PB" '.display == 8 and .pids == [$pid] and .width == 900 and .height == 600' > /dev/null \
    && pass "screenshot --full picks B's only display" || fail "--full: $FULL"
FILL=$(as B window fill --pid "$PB")
echo "$FILL" | jq -e '.frame.x >= 0 and .frame.y >= 0 and .frame.x + .frame.w <= 900 and .frame.y + .frame.h <= 600' > /dev/null \
    && pass "window fill stays inside display 8" || fail "window fill: $FILL"

echo "== each app stays on its own display"
sleep 2
as B windows --pid "$PB" | jq -e '.windows[0].frame | .x >= 0 and .y >= 0 and .x < 900 and .y < 600' > /dev/null \
    && pass "the window guard left B's window on display 8" || fail "B's window moved: $(as B windows --pid "$PB" | jq -c .windows)"
as A windows --pid "$PA" | jq -e '.windows[0].frame | .x >= 0 and .y >= 0 and .x < 900 and .y < 600' > /dev/null \
    && pass "A's window is still on display 7" || fail "A's window: $(as A windows --pid "$PA" | jq -c .windows)"

echo "== session affinity and crowding"
OUT=$(launch B red)
PB2=$(echo "$OUT" | jq -r .pid)
[[ $(echo "$OUT" | jq -r .display) == 8 ]] && pass "B's next launch (no --display) joins B's display 8" || fail "affinity: $OUT"
[[ $(echo "$OUT" | jq -r '.crowded // false') == true ]] && pass "and says display 8 is crowded: $(echo "$OUT" | jq -r .warning | cut -c1-70)…" \
    || fail "crowded not reported: $OUT"

echo "== reservations"
OUT=$(launch C blue --display 8 2>&1)
echo "$OUT" | jq -e '.ok == false and (.error | test("reserved for another session"))' > /dev/null \
    && pass "C can't launch on B's reserved display: $(echo "$OUT" | jq -r .error)" || fail "C on 8: $OUT"
OUT=$(launch C blue)
PC=$(echo "$OUT" | jq -r .pid)
OUT=$(as C move --pid "$PC" --display 8 2>&1)
echo "$OUT" | jq -e '.ok == false and (.error | test("reserved"))' > /dev/null && pass "C can't move onto it either" || fail "C move: $OUT"
echo "   (waiting for the reservation to expire)"
UNTIL=$("$BS" status | jq -r '.daemon.displays[] | select(.display == 8) | .reservedUntil // empty')
if [[ -n $UNTIL ]]; then
    LEFT=$(python3 -c "import datetime,sys; t=datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')); print(max(0, int((t - datetime.datetime.now(datetime.timezone.utc)).total_seconds()) + 2))" "$UNTIL")
    sleep "$LEFT"
fi
OUT=$(as C move --pid "$PC" --display 8)
[[ $(echo "$OUT" | jq -r .display) == 8 ]] && pass "after it expired, C moved its app to display 8" || fail "C move after expiry: $OUT"
as C windows --pid "$PC" | jq -e '.windows[0].frame | .x >= 0 and .y >= 0 and .x < 900 and .y < 600' > /dev/null \
    && pass "C's window followed it to display 8" || fail "C's window: $(as C windows --pid "$PC" | jq -c .windows)"

echo "== an empty extra display goes away"
as B quit --pid "$PB" > /dev/null; as B quit --pid "$PB2" > /dev/null; as C move --pid "$PC" --display 7 > /dev/null
for _ in $(seq 1 30); do [[ $(displays) == '[7]' ]] && break; sleep 0.25; done
[[ $(displays) == '[7]' ]] && pass "display 8 was removed once nothing was on it" || fail "displays left: $(displays)"
DEVICES1=$("$WORK/csdevices")
[[ $DEVICES1 -le $((DEVICES0 + 1)) ]] && pass "ColorSync's backstage displays: $DEVICES0 before, $DEVICES1 after" \
    || fail "ColorSync's backstage displays grew from $DEVICES0 to $DEVICES1"

echo "== close-display"
OUT=$(launch B green --display new)
PB3=$(echo "$OUT" | jq -r .pid)
[[ $(echo "$OUT" | jq -r .display) == 8 ]] && pass "B has display 8 again" || fail "B's launch: $OUT"
OUT=$(as A close-display 8 2>&1)
echo "$OUT" | jq -e '.ok == false and (.error | test("reserved for another session"))' > /dev/null \
    && pass "A can't close B's display: $(echo "$OUT" | jq -r .error)" || fail "A closing 8: $OUT"
OUT=$(as A close-display 7 2>&1)
echo "$OUT" | jq -e '.ok == false and (.error | test("always stays"))' > /dev/null && pass "the first display can't be closed" || fail "closing 7: $OUT"
OUT=$(as A close-display 6 2>&1)
echo "$OUT" | jq -e '.ok == false and (.error | test("isn.t running"))' > /dev/null && pass "a display that isn't running: refused" || fail "closing 6: $OUT"
OUT=$(as B close-display 8)
echo "$OUT" | jq -e --argjson p "$PB3" '.ok and .closed and .moved == [$p] and .movedTo == 7' > /dev/null \
    && pass "B closed its display 8; its app moved to display 7" || fail "B closing 8: $OUT"
[[ $(displays) == '[7]' ]] && pass "display 8 is gone at once" || fail "displays left: $(displays)"
"$BS" list --all | jq -e --argjson p "$PB3" '.apps[] | select(.pid == $p) | .display == 7' > /dev/null \
    && pass "B's app still runs, on display 7" || fail "B's app after close: $("$BS" list --all | jq -c .apps)"
as B windows --pid "$PB3" | jq -e '(.windows | length) > 0 and all(.windows[]; .frame.x >= 0 and .frame.y >= 0 and .frame.x < 900 and .frame.y < 600)' > /dev/null \
    && pass "and its window is on display 7" || fail "B's window after close: $(as B windows --pid "$PB3" | jq -c .windows)"
OUT=$(launch C blue --display new)
[[ $(echo "$OUT" | jq -r .display) == 8 ]] || fail "C's launch: $OUT"
OUT=$(as A close-display 8 --force)
echo "$OUT" | jq -e '.ok and (.moved | length) == 1' > /dev/null && pass "--force closes another session's display (as the menu's ⓧ does)" || fail "--force: $OUT"
[[ $(displays) == '[7]' ]] || fail "displays after --force: $(displays)"
R=$("$BS" __menu-render --displays 3 --page 0)
echo "$R" | jq -e '[.previews[].closable] == [false, true]' > /dev/null && pass "menu: ⓧ on extra displays only" || fail "menu closable: $R"

echo "== a launch that ends by itself, and --display new again"
# A test runner that finishes before opening a window: the error says so, with its summary and
# log. Asking for a new display again gets the same empty one (this daemon may add only 8, so a
# second new display would be refused).
printf '#include <stdio.h>\nint main(void) { puts("Executed 3 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds"); return 0; }\n' > "$WORK/quick.c"
cc -o "$WORK/quick-runner" "$WORK/quick.c" || exit 1
OUT=$(as D launch "$WORK/quick-runner" --display new 2>&1)
echo "$OUT" | jq -e '.ok == false and .exited and (.error | test("exited by itself")) and (.testSummary | test("Executed 3 tests")) and (.log | length > 0)' > /dev/null \
    && pass "an app that ends by itself: $(echo "$OUT" | jq -r .error | cut -c1-110)…" || fail "quick runner: $OUT"
[[ $(displays) == '[7,8]' ]] || fail "displays after the quick runner: $(displays)"
OUT=$(as D launch "$WORK/quick-runner" --display new 2>&1)
echo "$OUT" | jq -e '.exited' > /dev/null && [[ $(displays) == '[7,8]' ]] \
    && pass "--display new again reuses the empty display 8" || fail "second --display new: $OUT; displays $(displays)"
grep -q "display 8 reused for session D" "$BACKSTAGE_HOME/daemon.log" && pass "the daemon logs the reuse" || fail "no reuse in the daemon log"
OUT=$(launch C blue --display new 2>&1)
echo "$OUT" | jq -e '.ok == false and (.error | test("no free display"))' > /dev/null \
    && pass "another session can't take D's reserved display" || fail "C's --display new: $OUT"
as D close-display 8 > /dev/null || fail "D closing 8"

echo "== bad values"
OUT=$(launch A blue --display 5 2>&1)
echo "$OUT" | jq -e '.ok == false and (.error | test("isn.t one this daemon runs"))' > /dev/null && pass "a display this daemon can't run is refused" || fail "display 5: $OUT"

"$BS" stop --all > /dev/null || fail "stop --all"
[[ $FAIL == 0 ]] && echo "multidisplay: all passed"
exit $FAIL
