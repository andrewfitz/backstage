#!/bin/bash
# Keyboard-focus regression test. An app tracking a menu takes the WindowServer's keyboard focus,
# even in the background, so while an agent app's context menu is open the user's typing is
# routed to that app. The daemon's input guard (Sources/backstage/InputGuard.swift) must keep
# every event backstage didn't send out of managed apps. Per cycle, with the fixture's text field
# focused:
#  - right-click the pad and wait for the menu window (the fixture now holds the keyboard focus)
#  - post an untagged key to the fixture (tests/untagged.swift: straight to its PID, never the HID
#    system), as input from someone else; close the menu with `key esc`; post another one
# Then: the field is still empty, the daemon dropped those events, backstage's own `type` still
# lands, and the watchdog (tests/watch.swift) saw no untagged input reach the fixture and no
# backstage input reach the user's app. Keys the user happens to type meanwhile are covered by the
# same checks: they are handed to the user's app (the watchdog reports how many).
# FOCUS_CYCLES sets the number of menu cycles (default 6).
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && swift build -c release)
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-focus.XXXX)"
export BACKSTAGE_HOME="$WORK/state"
unset BACKSTAGE_SESSION
WATCH=
cleanup() {
    local result=$?
    trap - EXIT
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

FAIL=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
jget() { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }
LOG="$WORK/fixture.log"
count() { grep -c "$1" "$LOG" 2>/dev/null; }
waitcount() { for _ in $(seq 1 40); do (( $(count "$1") >= $2 )) && return 0; sleep 0.1; done; return 1; }
value() { "$BS" find --pid "$PID" --role textfield | jget "['elements'][0].get('value','')"; }

echo "== build fixtures"
mkdir -p "$WORK/BackstageTestApp.app/Contents/MacOS"
swiftc -O TestApp.swift -o "$WORK/BackstageTestApp.app/Contents/MacOS/BackstageTestApp" || exit 1
BUNDLE="dev.backstage.testapp.${WORK##*.}"
cat > "$WORK/BackstageTestApp.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageTestApp</string><key>CFBundleIdentifier</key><string>$BUNDLE</string><key>CFBundleName</key><string>BackstageTestApp</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -O watch.swift -o "$WORK/watch" || exit 1
swiftc -O zorder.swift -o "$WORK/zorder" || exit 1
swiftc -O untagged.swift -o "$WORK/untagged" || exit 1
"$WORK/watch" "$BUNDLE" 300 "$WORK/watch.stop" > "$WORK/watch.out" 2>&1 &
WATCH=$!
sleep 0.3

echo "== launch"
PID=$("$BS" launch "$WORK/BackstageTestApp.app" --env "TESTAPP_LOG=$LOG" | jget "['pid']")
[[ -n "$PID" ]] && pass "launched pid $PID" || { fail "launch"; exit 1; }
grep -q "input guard up" "$BACKSTAGE_HOME/daemon.log" && pass "the daemon's input guard is up" || fail "no input guard in the daemon log"
FIELD=$("$BS" find --pid "$PID" --role textfield | jget "['elements'][0]['ref']")
"$BS" set "$FIELD" "" --pid "$PID" >/dev/null; "$BS" focus "$FIELD" --pid "$PID" >/dev/null
read -r X Y <<< "$("$BS" find --pid "$PID" --role window --text BackstageTestApp | python3 -c "import sys,json; f=json.load(sys.stdin)['elements'][0]['frame']; print(f['x']+100, f['y']+f['h']-40)")"

N=${FOCUS_CYCLES:-6}
echo "== $N context menu cycles, with input from outside backstage"
shown=0
for i in $(seq 1 "$N"); do
    "$BS" click "$X" "$Y" --right --pid "$PID" >/dev/null
    waitcount "pad right click" "$i" || { fail "cycle $i: right click didn't reach the pad"; break; }
    # The menu window (popup menu layer). It sometimes never appears, but tracking runs anyway.
    for _ in $(seq 1 20); do (( $("$WORK/zorder" --menus "$PID") > 0 )) && { shown=$((shown + 1)); break; }; sleep 0.1; done
    "$WORK/untagged" "$PID" x
    sleep 0.2
    "$BS" key esc --pid "$PID" >/dev/null
    waitcount "context menu closed" "$i" || { fail "cycle $i: esc didn't close the menu"; break; }
    "$WORK/untagged" "$PID" y
    sleep 0.2
done
echo "  menus shown: $shown of $N"
sleep 0.3
V=$(value)
[[ -z "$V" ]] && pass "no untagged key reached the fixture's field" || fail "untagged keys reached the fixture: field is '$V'"
"$BS" type "ok" --ref "$FIELD" --pid "$PID" >/dev/null
[[ "$(value)" == "ok" ]] && pass "backstage's own typing still lands" || fail "backstage's typing: field is '$(value)'"

echo "== stop"
"$BS" stop >/dev/null && pass "stop" || fail "stop"
grep "input guard:" "$BACKSTAGE_HOME/daemon.log" | tail -1 | sed 's/^/  /'
# The daemon logs the guard's totals as it exits.
DROPPED=$(grep "input guard:" "$BACKSTAGE_HOME/daemon.log" | tail -1 | sed -nE 's/.* ([0-9]+) dropped.*/\1/p')
(( ${DROPPED:-0} >= 4 * N )) && pass "the input guard dropped ${DROPPED} events (${N} cycles x 2 keys x down/up)" \
    || fail "the input guard dropped ${DROPPED:-0} events, expected at least $((4 * N)): $(grep "input guard" "$BACKSTAGE_HOME/daemon.log" | tail -1)"
touch "$WORK/watch.stop"
wait "$WATCH" || fail "watchdog detected interference"
WATCH=
cat "$WORK/watch.out"
grep -q PASS "$WORK/watch.out" && pass "non-interference watchdog" || fail "non-interference watchdog"
FOCUSED=$(sed -nE 's/.*keyboard focus at the test app ([0-9]+) time.*/\1/p' "$WORK/watch.out")
(( ${FOCUSED:-0} >= 1 )) && pass "the fixture held the keyboard focus during its menus (${FOCUSED} times): the scenario was reproduced" \
    || fail "the fixture never held the keyboard focus: the menus didn't reproduce the scenario"
[ $FAIL = 0 ] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
