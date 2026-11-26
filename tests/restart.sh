#!/bin/bash
# A daemon restart leaves the display alone (Sources/backstage/DisplayHost.swift): after
# `stop --all`, the display's host lingers BACKSTAGE_DISPLAY_LINGER seconds and the next daemon
# adopts it, so no display is removed or added and the user's monitor sees no change. A passive
# watcher counts display reconfigurations; a restart without linger shows it can see them.
# Uses display 7 only.
set -uo pipefail
export BACKSTAGE_DISPLAY=7
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build) || exit 1
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-restart.XXXX)" || exit 1
export BACKSTAGE_HOME="$WORK/state"
export BACKSTAGE_SESSION=restart-test
mkdir -p "$BACKSTAGE_HOME" && chmod 700 "$BACKSTAGE_HOME"
FAIL=0
W=
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
cleanup() {
    local result=$?
    trap - EXIT
    [[ -n "$W" ]] && { touch "$WORK/stop"; wait "$W" 2>/dev/null; }
    [[ -f "$BACKSTAGE_HOME/daemon.json" ]] && { "$BS" stop --all > /dev/null 2>&1 || result=1; }
    # Never leave display 7 held: end any host still running.
    for f in "$BACKSTAGE_HOME"/hosts/*.json; do
        [[ -f "$f" ]] || continue
        p=$(jq -r .pid "$f"); kill "$p" 2>/dev/null
    done
    echo "artifacts: $WORK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

swiftc -O reconfigwatch.swift -o "$WORK/reconfigwatch" || exit 1
APP="$WORK/BackstageTestApp.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O TestApp.swift -o "$APP/Contents/MacOS/BackstageTestApp" || exit 1
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageTestApp</string><key>CFBundleIdentifier</key><string>dev.backstage.restarttest.${WORK##*.}</string><key>CFBundleName</key><string>BackstageTestApp</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
launch_app() { "$BS" launch "$APP" --timeout 10 --env TESTAPP_POLICY=none --env "TESTAPP_LOG=$WORK/$1.log" | jq -r '.pid // empty'; }
did() { "$BS" status 2>/dev/null | jq -r '.daemon.displayID // empty'; }
online() { "$WORK/reconfigwatch" --online "$1"; }
hostpid() { jq -r .pid "$BACKSTAGE_HOME"/hosts/*.json 2>/dev/null | head -1; }
watch_start() {
    rm -f "$WORK/stop"
    "$WORK/reconfigwatch" --stop "$WORK/stop" --max 120 > "$WORK/$1.watch" 2>&1 &
    W=$!
    for _ in $(seq 1 50); do grep -qx watching "$WORK/$1.watch" && return 0; sleep 0.1; done
    fail "watcher didn't start"; return 1
}
watch_end() {   # sets N: the event count
    touch "$WORK/stop"; wait "$W"; W=
    N=$(( $(sed -n "s/^events=//p" "$WORK/$1.watch") + $(sed -n "s/^screenChanges=//p" "$WORK/$1.watch") ))   # either signal
}
gone() { for _ in $(seq 1 "$2"); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1; }

echo "== restart with the display lingering: nothing changes on the user's screens"
BACKSTAGE_DISPLAY_LINGER=10 "$BS" start > /dev/null || { fail "start"; exit 1; }
ID1=$(did); H1=$(hostpid)
P1=$(launch_app before)
[[ -n "$P1" ]] && pass "an app runs on display 7 before the restart (pid $P1)" || fail "launch before the restart"
sleep 1
watch_start linger || exit 1
BACKSTAGE_DISPLAY_LINGER=10 "$BS" stop --all > /dev/null && BACKSTAGE_DISPLAY_LINGER=10 "$BS" start > /dev/null || fail "restart"
sleep 1.5
watch_end linger
ID2=$(did)
[[ -n "$ID1" && "$ID1" == "$ID2" ]] && pass "same display ($ID1) after the restart" || fail "display changed: $ID1 -> $ID2"
[[ "$(hostpid)" == "$H1" ]] && pass "same display host (pid $H1)" || fail "host changed: $H1 -> $(hostpid)"
[[ "$N" -eq 0 ]] && pass "no display reconfiguration during the restart" || fail "$N reconfiguration(s): $(cat "$WORK/linger.watch")"
grep -q "adopted display 7" "$BACKSTAGE_HOME/daemon.log" && pass "the new daemon logged the adoption" || fail "no adoption logged"
"$BS" status | jq -e '.ok' > /dev/null && pass "status is ok after adopting" || fail "status: $("$BS" status)"
[[ -n "$P1" ]] && ! kill -0 "$P1" 2>/dev/null && pass "the stop quit the app before leaving the display" || fail "app $P1 survived the stop"
P2=$(launch_app after)
[[ -n "$P2" ]] && pass "launch works on the adopted display (pid $P2)" || fail "launch after adopting"
if [[ -n "$P2" ]]; then
    "$BS" screenshot --pid "$P2" -o "$WORK/adopted.png" > /dev/null && pass "screenshot works on the adopted display" || fail "screenshot after adopting"
    "$BS" windows --pid "$P2" | jq -e '.windows[0].frame | .x >= 0 and .y >= 0' > /dev/null && pass "its window is on the adopted display" \
        || fail "window: $("$BS" windows --pid "$P2" | jq -c .windows)"
    "$BS" quit --pid "$P2" > /dev/null
fi

echo "== a lingering display goes once its time is up"
# The daemon that adopted it set the linger it was started with: restart with 3 s.
BACKSTAGE_DISPLAY_LINGER=3 "$BS" stop --all > /dev/null && BACKSTAGE_DISPLAY_LINGER=3 "$BS" start > /dev/null || fail "restart"
ID=$(did); H=$(hostpid)
"$BS" stop --all > /dev/null
sleep 1
[[ $(online "$ID") == yes ]] && kill -0 "$H" 2>/dev/null && pass "still there 1 s after stop" || fail "display gone too early"
gone "$H" 60 && pass "the host exited after its 3 s" || fail "host pid $H still running"
[[ $(online "$ID") == no ]] && pass "display $ID is gone" || fail "display $ID still online"
compgen -G "$BACKSTAGE_HOME/hosts/*.json" > /dev/null && fail "host record left behind" || pass "host record removed"

echo "== a lingering display that doesn't fit is replaced; start doesn't fail"
BACKSTAGE_DISPLAY_LINGER=10 "$BS" start > /dev/null || fail "start"
H=$(hostpid)
BACKSTAGE_DISPLAY_LINGER=10 "$BS" stop --all > /dev/null
OUT=$(BACKSTAGE_DISPLAY_LINGER=10 BACKSTAGE_WIDTH=1280 BACKSTAGE_HEIGHT=800 "$BS" start 2>&1)
echo "$OUT" | jq -e '.ok' > /dev/null && pass "start with another size works" || fail "start: $OUT"
[[ "$(hostpid)" != "$H" ]] && ! kill -0 "$H" 2>/dev/null && pass "the old host was ended" || fail "old host $H still around"
grep -q "ending display host pid $H" "$BACKSTAGE_HOME/daemon.log" && pass "logged why" || fail "no log line for ending host $H"
"$BS" stop --all > /dev/null
sleep 11   # let the 1280x800 host's linger run out

echo "== control: a restart without linger reconfigures, and the watcher sees it"
BACKSTAGE_DISPLAY_LINGER=0 "$BS" start > /dev/null || fail "start"
ID1=$(did)
sleep 1
watch_start control || exit 1
BACKSTAGE_DISPLAY_LINGER=0 "$BS" stop --all > /dev/null && BACKSTAGE_DISPLAY_LINGER=0 "$BS" start > /dev/null || fail "restart"
sleep 1.5
watch_end control
[[ "$(did)" != "$ID1" ]] && pass "a new display" || fail "same display without linger"
[[ "${N:-0}" -ge 1 ]] && pass "the watcher counted $N reconfiguration(s)" || fail "watcher saw nothing: $(cat "$WORK/control.watch")"

echo "== the display host dying takes the daemon down"
DPID=$("$BS" status | jq -r .daemon.pid); H=$(hostpid)
kill -9 "$H"
gone "$DPID" 50 && pass "daemon exited after its display host died" || fail "daemon $DPID still running"
grep -q "display host (pid $H) exited" "$BACKSTAGE_HOME/daemon.log" && pass "logged it" || fail "not logged"

echo "== the daemon dying: a host with no linger goes with it"
BACKSTAGE_DISPLAY_LINGER=0 "$BS" start > /dev/null || fail "start"
DPID=$("$BS" status | jq -r .daemon.pid); H=$(hostpid); ID=$(did)
kill -9 "$DPID"
gone "$H" 30 && pass "host exited within 3 s of the daemon" || fail "host $H outlived its daemon"
sleep 0.5
[[ $(online "$ID") == no ]] && pass "display gone" || fail "display $ID still online"
rm -f "$BACKSTAGE_HOME/daemon.json"

[[ $FAIL == 0 ]] && echo "ALL PASSED" || echo "SOME CHECKS FAILED"
exit $FAIL
