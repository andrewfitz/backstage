#!/bin/bash
# Stray windows (StrayWindows.swift): a window of an app backstage doesn't run, sitting on a
# backstage display (an app reopening where it last was), is returned by the daemon after
# BACKSTAGE_STRAY_GRACE without being activated; `recover --dry-run` lists it and `recover`
# returns it at once; managed apps' windows are never touched.
# Returned windows go to display 8 here (BACKSTAGE_TEST_STRAY_TARGET), never the user's screen:
# the stray fixture is opened hidden, moved onto display 7 while hidden, then unhidden there.
# A watchdog checks no fixture window ever reaches a user display or becomes frontmost.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build) || exit 1
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-strays.XXXX)" || exit 1
export BACKSTAGE_HOME="$WORK/state" BACKSTAGE_DISPLAY=7 BACKSTAGE_EXTRA_DISPLAYS=8 BACKSTAGE_SESSION=strays
export BACKSTAGE_STRAY_GRACE=5 BACKSTAGE_TEST_STRAY_TARGET=8 BACKSTAGE_WIDTH=1200 BACKSTAGE_HEIGHT=800
mkdir -p "$BACKSTAGE_HOME"
WATCH= SPID=
FAIL=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
APP="$WORK/BackstageStray.app"
cleanup() {
    local result=$?
    trap - EXIT
    [[ -n $SPID ]] && { "$WORK/sendhelper" terminate "$SPID" "$APP" || result=1; }
    if [[ -f "$BACKSTAGE_HOME/daemon.json" || -f "$BACKSTAGE_HOME/apps.json" ]]; then
        "$BS" stop --all > /dev/null 2>&1 || result=1
    fi
    if [[ -n $WATCH ]]; then touch "$WORK/watch.stop"; wait "$WATCH" || result=1; tail -5 "$WORK/watch.out"; fi
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" > /dev/null 2>&1 || true
    echo "artifacts: $WORK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
waitlog() { for _ in $(seq 1 "${3:-50}"); do grep -q "$1" "$2" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

echo "== build fixtures"
mkdir -p "$APP/Contents/MacOS"
swiftc -O TestApp.swift -o "$APP/Contents/MacOS/BackstageStray" || exit 1
BID="dev.backstage.straytest.${WORK##*.}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageStray</string><key>CFBundleIdentifier</key><string>$BID</string><key>CFBundleName</key><string>BackstageStray</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -O watch.swift -o "$WORK/watch" || exit 1
swiftc -O sendhelper.swift -o "$WORK/sendhelper" || exit 1
swiftc -O axmove.swift -o "$WORK/axmove" || exit 1
. ./watch.sh
start_watch "$BID" 180 || exit 1

echo "== managed apps on displays 7 and 8"
OUT7=$("$BS" launch "$APP" --env "TESTAPP_LOG=$WORK/m7.log")
P7=$(echo "$OUT7" | jq -r .pid)
OUT8=$("$BS" launch "$APP" --display new --env "TESTAPP_LOG=$WORK/m8.log" --env TESTAPP_PAD=green)
P8=$(echo "$OUT8" | jq -r .pid)
[[ $(echo "$OUT7" | jq -r .display) == 7 && $(echo "$OUT8" | jq -r .display) == 8 ]] && pass "managed apps on displays 7 and 8" \
    || fail "launches: $OUT7 $OUT8"
LOG="$BACKSTAGE_HOME/daemon.log"
bounds() { "$BS" status | jq -c --argjson n "$1" '.daemon as $d | $d.displays[] | select(.display == $n)
    | {x: .globalOrigin.x, y: .globalOrigin.y, width: $d.size.w, height: $d.size.h}'; }
D7=$(bounds 7)
D8=$(bounds 8)
[[ -n $D7 && -n $D8 ]] && pass "display 7 at $D7, display 8 at $D8" || { fail "display bounds: $("$BS" status | jq -c .daemon.displays)"; exit 1; }
# Is the window centre of pid $1 on the display with bounds $2?
centre_on() {
    "$WORK/axmove" --frames "$1" | head -1 | jq -R -e --argjson b "$2" 'split(" ") | map(tonumber) as [$x, $y, $w, $h]
        | ($x + $w / 2) >= $b.x and ($x + $w / 2) < $b.x + $b.width and ($y + $h / 2) >= $b.y and ($y + $h / 2) < $b.y + $b.height' > /dev/null
}
# Put the stray fixture's window onto display 7 (top-left at +$2,+$3).
onto7() {
    "$WORK/axmove" "$1" "$(echo "$D7" | jq ".x + $2")" "$(echo "$D7" | jq ".y + $3")" > /dev/null
}

echo "== an unmanaged app's window lands on display 7"
SPID=$("$WORK/sendhelper" launch "$APP" "TESTAPP_LOG=$WORK/stray.log" TESTAPP_PAD=red TESTAPP_POLICY=none)
waitlog launched "$WORK/stray.log" || fail "stray fixture didn't start"
sleep 0.5
onto7 "$SPID" 300 200
# Never unhide unless the window is on display 7: unhiding anywhere else shows it on the user's screen.
POS=$("$WORK/axmove" --position "$SPID")
if echo "$POS" | jq -R -e --argjson b "$D7" 'split(" ") | map(tonumber) as [$x, $y]
        | $x >= $b.x and $x < $b.x + $b.width - 100 and $y >= $b.y and $y < $b.y + $b.height - 100' > /dev/null; then
    pass "moved while hidden onto display 7 ($POS)"
else
    fail "the hidden fixture isn't on display 7 ($POS): not unhiding it"; exit 1
fi
"$WORK/sendhelper" unhide "$SPID"
for _ in $(seq 1 20); do centre_on "$SPID" "$D7" && break; sleep 0.05; done
centre_on "$SPID" "$D7" && pass "shown on display 7" || fail "not on display 7: $("$WORK/axmove" --frames "$SPID")"
R=$("$BS" recover --dry-run)
echo "$R" | jq -e --argjson p "$SPID" '[.stray[].pid] == [$p] and .stray[0].display == 7' > /dev/null \
    && pass "recover --dry-run lists only it (managed apps aren't strays)" || fail "dry run: $R"
centre_on "$SPID" "$D7" && pass "--dry-run moved nothing" || fail "--dry-run moved it"

echo "== the daemon returns it after the grace period, without activating it"
waitlog "returned stray window .* of pid $SPID " "$LOG" 100 && pass "daemon: $(grep "returned stray window .* of pid $SPID " "$LOG" | tail -1 | cut -d' ' -f2-)" \
    || { fail "the daemon didn't return it"; grep -i stray "$LOG" || true; }
sleep 0.2
centre_on "$SPID" "$D8" && pass "it's on the target display (8: the user's screen outside tests)" || fail "not returned: $("$WORK/axmove" --frames "$SPID")"
FIRST=$(grep -m1 "returned stray window .* of pid $SPID " "$LOG" | cut -d' ' -f1)
[[ -n $FIRST ]] && pass "returned at $FIRST"

echo "== managed apps stay put"
sleep 3
centre_on "$P7" "$D7" && pass "the managed app on display 7 wasn't touched" || fail "managed app 7 moved: $("$WORK/axmove" --frames "$P7")"
centre_on "$P8" "$D8" && pass "the managed app on display 8 wasn't touched" || fail "managed app 8 moved: $("$WORK/axmove" --frames "$P8")"
grep -q "stray window .* of pid \($P7\|$P8\) " "$LOG" && fail "a managed app was treated as a stray" || pass "no managed app treated as a stray"

echo "== recover returns one at once"
onto7 "$SPID" 100 100   # display 8 to display 7: never via the user's screen
for _ in $(seq 1 20); do centre_on "$SPID" "$D7" && break; sleep 0.05; done
R=$("$BS" recover)
echo "$R" | jq -e --argjson p "$SPID" '.ok and [.recovered[].pid] == [$p]' > /dev/null && pass "recover returned it" || fail "recover: $R"
centre_on "$SPID" "$D8" && pass "on the target display right away" || fail "after recover: $("$WORK/axmove" --frames "$SPID")"
R=$("$BS" recover)
echo "$R" | jq -e '.ok and .recovered == [] and .note == "no stray windows"' > /dev/null && pass "nothing left: $(echo "$R" | jq -r .note)" || fail "second recover: $R"

if (( FAIL )); then echo "FAILED"; exit 1; fi
echo "all stray-window checks passed"
