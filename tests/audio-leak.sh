#!/bin/bash
# Leak suite for a dedicated Mac or test account (docs/AUDIO_PLAN.md, "Tests"). It plays probes
# to the DEFAULT output and listens to what reached it, so the default and system (alert)
# outputs must both be a loopback device (BlackHole or similar), and the account must be the
# active console session. It refuses to run anywhere else.
#
#   tests/audio-leak.sh --dedicated            the suite
#   tests/audio-leak.sh --grant-fixture-mic    one-time, on any Mac with a loopback: launch the
#                                              test fixture so macOS asks for its Microphone once
#                                              (answer either way); afterwards tests/audio.sh runs
#                                              its fixture-through-launch leak check too
#
# 1. Negative test first: an unmuted 50 ms probe must reach the watchdog, or the suite fails.
# 2. The fixture launched through backstage, playing to the default output from its first
#    line: 0 frames may reach it (3 runs). Launched with --audio: the tap's mute is what's under
#    test, and a default launch of the (ad-hoc signed) fixture is inaudible from inside.
# 3. Failure windows and audible sources, measured and recorded, not required to be silent:
#    kill -9 of the daemon, a coreaudiod restart (needs passwordless sudo), speech (`say`) and
#    an alert sound (`osascript -e beep`) from managed processes.
set -uo pipefail
# backstage's own tests use displays 7-8, never the ones agents use (docs/MULTI_DISPLAY_PLAN.md).
export BACKSTAGE_DISPLAY=${BACKSTAGE_DISPLAY:-7}
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
MODE=${1:-}
if [[ $MODE != --dedicated && $MODE != --grant-fixture-mic ]]; then
    echo "audio-leak.sh plays probes to the default output: run it only on a dedicated Mac or test account with a" >&2
    echo "loopback as the default and system output, as: tests/audio-leak.sh --dedicated" >&2
    exit 2
fi
if [[ $MODE == --dedicated && $(stat -f %u /dev/console) != "$(id -u)" ]]; then
    echo "refusing: the dedicated suite must run as the active console user" >&2
    exit 2
fi
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build) || exit 1
    BIN_DIR="$(cd "$ROOT" && swift build -c release --show-bin-path)" || exit 1
    BACKSTAGE_BIN="$BIN_DIR/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-audio-leak.XXXX)" || exit 1
export BACKSTAGE_HOME="$WORK/state" BACKSTAGE_SESSION=audio-leak
mkdir -p "$BACKSTAGE_HOME"
LISTENER=
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -n $LISTENER ]]; then kill "$LISTENER" 2>/dev/null; wait "$LISTENER" 2>/dev/null; fi
    if [[ -f $BACKSTAGE_HOME/daemon.json || -f $BACKSTAGE_HOME/apps.json ]]; then
        "$BS" stop --all > /dev/null 2>&1 || result=1
    fi
    echo "artifacts: $WORK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

APP="$WORK/BackstageTestApp.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O TestApp.swift -o "$APP/Contents/MacOS/BackstageTestApp" || exit 1
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageTestApp</string><key>CFBundleIdentifier</key><string>dev.backstage.testapp.audio</string><key>CFBundleName</key><string>BackstageTestApp</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -O audioprobe.swift -o "$WORK/audioprobe" || exit 1
PROBE="$WORK/audioprobe"
[[ $("$PROBE" mic) == 3 ]] || { echo "this host's Microphone access isn't granted: the watchdog can't read the loopback" >&2; exit 2; }
"$PROBE" devices > "$WORK/devices.json"

finish_listen() {
    local result=0
    wait "$LISTENER" || result=$?
    LISTENER=
    return "$result"
}
is_loopback() {  # uid
    "$PROBE" listen --device "$1" --hz 18500 --secs 1.2 > "$WORK/lb.json" 2> /dev/null &
    LISTENER=$!
    sleep 0.3
    local playResult=0
    "$PROBE" play --device "$1" --hz 18500 --ms 300 > /dev/null || playResult=$?
    finish_listen && [[ $playResult == 0 ]] && jq -e '.nonzeroFrames >= 10000' "$WORK/lb.json" >/dev/null
}

if [[ $MODE == --grant-fixture-mic ]]; then
    LOOP=$(jq -r '.[] | select(.in > 0 and .out > 0 and (.default | not)) | .uid' "$WORK/devices.json" | head -1)
    [[ -n $LOOP ]] && is_loopback "$LOOP" || { echo "no loopback device that isn't the default output" >&2; exit 2; }
    echo "Launching the test fixture (hidden, muted) to play to $LOOP: macOS will ask whether BackstageTestApp may use"
    echo "the Microphone. Either answer works: it only needs to be decided. The probe is inaudible either way."
    "$BS" launch "$APP" --audio --env "TESTAPP_LOG=$WORK/grant.log" --env TESTAPP_TONE=18500 --env "TESTAPP_TONE_DEVICE=$LOOP" \
        --env TESTAPP_TONE_PATTERN=300 --env TESTAPP_TONE_ONCE=1 --env TESTAPP_TONE_ALLOW_MIC_PROMPT=1 > /dev/null || exit 1
    echo "Press Return once you've answered."; read -r || exit 1
    "$BS" stop > /dev/null || exit 1
    exit 0
fi

DEF=$(jq -r '.[] | select(.default) | .uid' "$WORK/devices.json")
SYS=$(jq -r '.[] | select(.system) | .uid' "$WORK/devices.json")
if [[ -z $DEF || $DEF != "$SYS" ]] || ! is_loopback "$DEF"; then
    echo "refusing: the default output ($DEF) and the system output ($SYS) must be the same loopback device" >&2
    exit 2
fi
FAIL=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
measure() { echo "  measured: $*" | tee -a "$WORK/measured.txt"; }
listen() { "$PROBE" listen --device "$DEF" --hz "${3:-18500}" --secs "$1" > "$2" 2> /dev/null & LISTENER=$!; sleep 0.4; }

echo "== 1. negative test: an unmuted 50 ms probe reaches the watchdog"
listen 1.5 "$WORK/neg.json"
"$PROBE" play --device "$DEF" --hz 18500 --ms 50 > /dev/null && finish_listen || exit 1
jq -e '.nonzeroFrames >= 2000' "$WORK/neg.json" >/dev/null && pass "watchdog heard it" || { fail "the watchdog missed an unmuted probe: $(cat "$WORK/neg.json")"; exit 1; }

echo "== 2. the fixture through backstage, playing to the default output from its first line"
for i in 1 2 3; do
    listen 2.5 "$WORK/launch$i.json"
    PID=$("$BS" launch "$APP" --audio --env "TESTAPP_LOG=$WORK/f$i.log" --env TESTAPP_TONE=18500 --env TESTAPP_TONE_PATTERN=500 --env TESTAPP_TONE_ONCE=1 | jq -er '.pid | select(type == "number" and . > 0)') || exit 1
    finish_listen || exit 1
    grep -q "tone skipped" "$WORK/f$i.log" && { fail "the fixture skipped its tone (Microphone undecided): run --grant-fixture-mic first"; break; }
    grep -q "tone first render" "$WORK/f$i.log" || { fail "run $i: the fixture did not render the probe"; break; }
    N=$(jq -r .nonzeroFrames "$WORK/launch$i.json")
    MS=$(grep "muted pid $PID " "$BACKSTAGE_HOME/daemon.log" | sed -E 's/.* ([0-9.]+) ms after sight.*/\1/')
    [[ $N == 0 ]] && pass "run $i: 0 frames (sight-to-mute $MS ms)" || fail "run $i: $N frames leaked (sight-to-mute $MS ms)"
    "$BS" quit --pid "$PID" > /dev/null
done

echo "== 3. failure windows and audible sources (recorded, not required silent)"
PID=$("$BS" launch "$APP" --audio --env "TESTAPP_LOG=$WORK/k.log" --env TESTAPP_TONE=18500 --env TESTAPP_TONE_PATTERN=1000,0 | jq -er '.pid | select(type == "number" and . > 0)') || exit 1
listen 2 "$WORK/kill9.json"
DP=$(jq -er '.pid | select(type == "number" and . > 0)' "$BACKSTAGE_HOME/daemon.json") || exit 1
kill -9 "$DP" || exit 1
finish_listen || exit 1
kill "$PID" 2>/dev/null
measure "kill -9 of the daemon: $(jq -r .nonzeroFrames "$WORK/kill9.json") frames reached the output within 1.6 s (first at $(jq -r .firstNonzero "$WORK/kill9.json"))"
rm -f "$BACKSTAGE_HOME/daemon.json"
if sudo -n true 2>/dev/null; then
    PID=$("$BS" launch "$APP" --audio --env "TESTAPP_LOG=$WORK/r.log" --env TESTAPP_TONE=18500 --env TESTAPP_TONE_PATTERN=1000,0 | jq -er '.pid | select(type == "number" and . > 0)') || exit 1
    sleep 1
    listen 4 "$WORK/restart.json"
    sudo -n killall coreaudiod || exit 1
    finish_listen || exit 1
    measure "coreaudiod restart: $(jq -r .nonzeroFrames "$WORK/restart.json") frames reached the output in 3.6 s; daemon: $(grep -c "coreaudiod restarted" "$BACKSTAGE_HOME/daemon.log") restart(s) seen"
    "$BS" quit --pid "$PID" > /dev/null
else
    measure "coreaudiod restart: skipped (needs passwordless sudo)"
fi
listen 4 "$WORK/say.json" 1000
"$BS" launch /usr/bin/say --timeout 0 -- "backstage leak test" > /dev/null || exit 1
finish_listen || exit 1
measure "speech (say, launched through backstage): $(jq -r .nonzeroFrames "$WORK/say.json") non-zero frames reached the output"
listen 3 "$WORK/beep.json" 1000
"$BS" launch /usr/bin/osascript --timeout 0 -- -e beep > /dev/null || exit 1
finish_listen || exit 1
measure "alert sound (osascript beep, launched through backstage): $(jq -r .nonzeroFrames "$WORK/beep.json") non-zero frames (system sounds play from systemsoundserverd: expected audible)"
"$BS" stop > /dev/null || exit 1
echo
[[ $FAIL == 0 ]] && echo "audio-leak: passed (measurements in $WORK/measured.txt)" || echo "audio-leak: FAILURES"
exit $FAIL
