#!/bin/bash
# Audio (docs/AUDIO_PLAN.md, phase 1): muting, `audio`, `wait --sound`, two sessions, show,
# launch refusal, tap failure, doctor's self-test, the crash handler, and leak checks against what
# really reached a loopback: a loopback device that isn't the default output, and the default
# output itself when one of its inputs returns its output (with and without the tap's IO).
# Audio modes (Inaudible.swift): the fixture launched by default is inaudible, so an unmuted
# global tap and our own ScreenCaptureKit stream (what screen sharing and remote desktop get)
# read none of its probe, while the same launch with --audio is seen by both (the control); a
# hardened copy falls back to muted and `--inaudible` refuses it; unmeasured apps run no IO.
#
# Nothing here is audible: every probe is >= 18 kHz at -60 dBFS with 10 ms ramps, in bursts of
# at most 2 s, and the apps playing them are muted. Nothing raises a permission prompt: the
# fixture only plays to a device with input streams when its Microphone access is already
# decided, and the measuring helper only when the host's is granted (see audioprobe.swift).
set -uo pipefail
# backstage's own tests use displays 7-8, never the ones agents use (docs/MULTI_DISPLAY_PLAN.md).
export BACKSTAGE_DISPLAY=${BACKSTAGE_DISPLAY:-7}
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build) || exit 1
    BIN_DIR="$(cd "$ROOT" && swift build -c release --show-bin-path)" || exit 1
    BACKSTAGE_BIN="$BIN_DIR/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-audio.XXXX)" || exit 1
HOMES=()
FAIL=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
skip() { echo "  skip $*"; }
use_home() { export BACKSTAGE_HOME="$WORK/$1"; HOMES+=("$BACKSTAGE_HOME"); mkdir -p "$BACKSTAGE_HOME"; }
cleanup() {
    local result=$?
    trap - EXIT
    for h in ${HOMES[@]+"${HOMES[@]}"}; do
        if [[ -f "$h/daemon.json" || -f "$h/apps.json" ]]; then BACKSTAGE_HOME="$h" "$BS" stop --all > /dev/null 2>&1 || result=1; fi
    done
    [[ -n ${LISTENER:-} ]] && kill "$LISTENER" 2>/dev/null
    echo "artifacts: $WORK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- macOS 14.2 ---
if ! sw_vers -productVersion | awk -F. '{ exit !($1 > 14 || ($1 == 14 && $2 >= 2)) }'; then
    use_home old
    OUT=$("$BS" launch /System/Applications/Calculator.app 2>&1)
    echo "$OUT" | grep -q "14.2" && pass "launch refuses before macOS 14.2" || fail "launch should refuse before 14.2: $OUT"
    exit $FAIL
fi

echo "== build fixtures"
APP="$WORK/BackstageTestApp.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O TestApp.swift -o "$APP/Contents/MacOS/BackstageTestApp" || exit 1
# A stable bundle ID: a Microphone decision for the fixture (see --leak below) survives reruns.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageTestApp</string><key>CFBundleIdentifier</key><string>dev.backstage.testapp.audio</string><key>CFBundleName</key><string>BackstageTestApp</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -O audioprobe.swift -o "$WORK/audioprobe" || exit 1
PROBE="$WORK/audioprobe"
# Measures `audio record`'s WAVs without any of backstage's code (AVAudioFile + Goertzel).
swiftc -O wavcheck.swift -o "$WORK/wavcheck" || exit 1
WAVCHECK="$WORK/wavcheck"

# The device the fixture plays to: an output-only one (playing to a device with inputs would
# make macOS ask for the fixture's Microphone). The default output if it qualifies.
"$PROBE" devices > "$WORK/devices.json"
DEV=$(jq -r '([.[] | select(.out > 0 and .in == 0 and .default)] + [.[] | select(.out > 0 and .in == 0)])[0].uid // empty' "$WORK/devices.json")
MIC=$("$PROBE" mic)
echo "   fixture device: ${DEV:-none}; host Microphone: $MIC (3 = granted)"

launch() {  # extra --env args…; prints the pid. Measured (--audio) unless LAUNCH_AUDIO=default.
    local out flag=--audio
    [[ ${LAUNCH_AUDIO:-} == default ]] && flag=""
    out=$("$BS" launch "$APP" --env "TESTAPP_LOG=${FLOG:-$WORK/fixture-$BACKSTAGE_SESSION.log}" $flag "$@") || { echo "$out" >&2; return 1; }
    echo "$out" | jq -er '.pid | select(type == "number" and . > 0)'
}
audio() { "$BS" audio --pid "$1"; }
near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }'; }

# Ground truth on the default output itself, when it loops its output back to one of its own
# inputs (a UA Apollo returns outputs 1-2 on inputs 3-4, "MON L/R": what reaches the speakers).
# Found with an unmuted, inaudible probe; the input must read it at -60 dBFS within 3 dB. Read
# only with the host's Microphone already granted (no prompt). The other inputs carry live signal,
# so the leak checks count 18.5 kHz tone windows on that one input, not non-zero frames.
DEFOUT=$(jq -r '.[] | select(.default and .out > 0) | .uid' "$WORK/devices.json" | head -1)
DEFLOOP=""; DEFCH=""
if [[ $MIC == 3 && -n $DEFOUT ]] && jq -e --arg u "$DEFOUT" '.[] | select(.uid == $u) | .in > 0' "$WORK/devices.json" > /dev/null; then
    "$PROBE" listen --device "$DEFOUT" --hz 18500 --secs 1.2 > "$WORK/defloop.json" 2> /dev/null &
    L=$!; sleep 0.3
    "$PROBE" play --device "$DEFOUT" --hz 18500 --ms 300 > /dev/null; wait $L
    DEFCH=$(jq -r '[.channelToneDb | to_entries[] | select((.value + 60 | fabs) <= 3) | .key + 1][0] // empty' "$WORK/defloop.json")
    [[ -n $DEFCH ]] && DEFLOOP=$DEFOUT
fi
echo "   default output: ${DEFOUT:-none}; loops back on input: ${DEFCH:-none} ($(jq -c .channelToneDb "$WORK/defloop.json" 2>/dev/null || echo 'not measured'))"
# One pending launch (its BACKSTAGE_LAUNCH_ID: tapped on sight by the current daemon) playing two
# 300 ms bursts 1.6 s apart to the default output from its first line: the second after its
# tap's IO stopped (1 s after output stops), when IO runs at all. Pass: no tone at the loopback.
default_leak() {  # label
    local id p n playback_status=0 listen_status=0
    local listen_json="$WORK/defleak-$1.json" play_json="$WORK/defplay-$1.json"
    local listen_log="$WORK/defleak-$1.log" stop_file="$WORK/defleak-$1.stop"
    id=$(uuidgen); mkdir -p "$BACKSTAGE_HOME/launching" "$BACKSTAGE_HOME/logs"; touch "$BACKSTAGE_HOME/logs/$id.log"
    printf '{"id":"%s","session":"%s","cliPID":%d,"cliStart":0,"bundle":"%s","log":"%s","startedAt":%s}' \
        "$id" "${BACKSTAGE_SESSION:-audio-a}" $$ "$APP" "$BACKSTAGE_HOME/logs/$id.log" "$(date +%s)" > "$BACKSTAGE_HOME/launching/$id.json"
    "$PROBE" listen --device "$DEFLOOP" --channel "$DEFCH" --hz 18500 --secs 30 --stop-file "$stop_file" > "$listen_json" 2> "$listen_log" &
    LISTENER=$!
    for _ in $(seq 1 200); do
        grep -qx LISTENING "$listen_log" && break
        kill -0 "$LISTENER" 2>/dev/null || break
        sleep 0.05
    done
    if ! grep -qx LISTENING "$listen_log"; then
        kill "$LISTENER" 2>/dev/null
        wait "$LISTENER" 2>/dev/null
        LISTENER=
        rm -f "$BACKSTAGE_HOME/launching/$id.json" "$BACKSTAGE_HOME/logs/$id.log"
        fail "default output ($1): listener never received input samples: $(cat "$listen_log")"
        return
    fi
    BACKSTAGE_LAUNCH_ID=$id "$PROBE" play --device "$DEFLOOP" --hz 18500 --ms 300 --again-after-ms 1600 --hold-ms 200 > "$play_json" || playback_status=$?
    touch "$stop_file"
    wait "$LISTENER" || listen_status=$?
    LISTENER=
    rm -f "$BACKSTAGE_HOME/launching/$id.json" "$BACKSTAGE_HOME/logs/$id.log"
    if [[ $playback_status != 0 || $listen_status != 0 ]]; then
        fail "default output ($1): player exited $playback_status, listener exited $listen_status: $(cat "$listen_log")"
        return
    fi
    p=$(jq -r .pid "$play_json")
    n=$(jq -r .toneWindows "$listen_json")
    if ! jq -e -s '.[0].start < .[1].outputStart and .[0].end > .[1].outputEnd' "$listen_json" "$play_json" > /dev/null; then
        fail "default output ($1): inconclusive, the listener didn't cover both bursts: $(jq -c -s '{listen: [.[0].start, .[0].end], play: [.[1].outputStart, .[1].outputEnd]}' "$listen_json" "$play_json")"
    elif ! grep -q "muted pid $p " "$BACKSTAGE_HOME/daemon.log" 2> /dev/null; then
        fail "default output ($1): the player (pid $p) was never tapped"
    elif [[ $n == 0 ]]; then
        pass "default output ($1): nothing reached input $DEFCH of $DEFLOOP (best $(jq -r '(.toneDb * 10 | round) / 10' "$listen_json") dB at 18.5 kHz; IO: $(grep -c "IO on for pid $p " "$BACKSTAGE_HOME/daemon.log" 2> /dev/null) starts)"
    else
        fail "default output ($1): $n windows of the probe reached input $DEFCH of $DEFLOOP: $(cat "$listen_json")"
    fi
}

echo "== launch refuses when muting can't be set up"
use_home mutefail
export BACKSTAGE_SESSION=audio-a
BACKSTAGE_TEST_AUDIO=mute-fail "$BS" start > /dev/null
OUT=$("$BS" launch "$APP" --env "TESTAPP_LOG=$WORK/x.log" 2>&1); CODE=$?
[[ $CODE == 1 ]] && echo "$OUT" | jq -e '.ok == false and (.error | test("mute"))' > /dev/null \
    && pass "launch refused: $(echo "$OUT" | jq -r .error | cut -c1-90)…" || fail "launch should refuse: $OUT"
"$BS" status | jq -e '.audio.muting == "unavailable" and (.warnings | length > 0)' > /dev/null \
    && pass "status reports muting unavailable" || fail "status should report muting unavailable"
pgrep -f "$APP/Contents/MacOS" > /dev/null && fail "the refused app is running" || pass "nothing was started"
"$BS" stop --all > /dev/null

echo "== a tap failure after launch quits the app"
use_home tapfail
BACKSTAGE_TEST_AUDIO=tap-fail "$BS" start > /dev/null
OUT=$("$BS" launch "$APP" --env "TESTAPP_LOG=$WORK/tapfail.log" ${DEV:+--env TESTAPP_TONE=18500 --env TESTAPP_TONE_DEVICE=$DEV} 2>&1); CODE=$?
if [[ -z $DEV ]]; then skip "no output-only device"
elif [[ $CODE == 1 ]] && echo "$OUT" | jq -e '.error | test("couldn.t be muted")' > /dev/null; then
    pass "launch failed with the tap error: $(echo "$OUT" | jq -r .error | cut -c1-100)…"
else fail "launch should fail with the tap error: $OUT"; fi
for _ in $(seq 1 30); do pgrep -f "$APP/Contents/MacOS" > /dev/null || break; sleep 0.1; done
pgrep -f "$APP/Contents/MacOS" > /dev/null && fail "the app is still running" || pass "the app was quit"
[[ -z $DEV ]] || "$BS" list | jq -e '.audioFailures[0].tap == "failed"' > /dev/null && pass "list shows tap: failed" || fail "list should show the failure"
"$BS" stop --all > /dev/null

echo "== without System Audio Recording: launch still mutes, audio says why"
use_home nocapture
BACKSTAGE_TEST_AUDIO=no-capture "$BS" start > /dev/null
PID=$(launch ${DEV:+--env TESTAPP_TONE=18500 --env TESTAPP_TONE_DEVICE=$DEV}) && pass "launch works without the grant" || fail "launch without the grant"
OUT=$("$BS" audio --pid "$PID" 2>&1)
echo "$OUT" | jq -e '.ok == false and (.error | test("System Audio Recording"))' > /dev/null && pass "audio explains the missing grant" || fail "audio: $OUT"
OUT=$("$BS" wait --sound --pid "$PID" --timeout 1 2>&1)
echo "$OUT" | jq -e '.ok == false and (.error | test("System Audio Recording"))' > /dev/null && pass "wait --sound explains it too" || fail "wait --sound: $OUT"
OUT=$("$BS" audio record --pid "$PID" 2>&1)
echo "$OUT" | jq -e '.ok == false and (.error | test("System Audio Recording"))' > /dev/null && pass "audio record explains it too" || fail "audio record: $OUT"
[[ -z $DEV ]] || { [[ $(jq -r .tap "$BACKSTAGE_HOME/audio/$PID-"*.json) == muted ]] && pass "the app is muted all the same" || fail "app not muted"; }
# A helper joining later: macOS refuses to change a tap without the grant ('!hog'), so the tap
# is replaced by one covering both. This used to quit the app.
if [[ -n $DEV ]]; then
    CLOG="$WORK/child-parent.log"
    CP=$(FLOG="$CLOG" launch --env TESTAPP_TONE=18500 --env TESTAPP_TONE_DEVICE="$DEV" --env TESTAPP_CHILD_AFTER_MS=1000) || fail "launch the child fixture"
    CHILD=""
    for _ in $(seq 1 60); do CHILD=$(sed -n 's/^child=//p' "$CLOG" 2> /dev/null | head -1); [[ -n $CHILD ]] && grep -qw "includes pid $CHILD" "$BACKSTAGE_HOME/daemon.log" && break; sleep 0.1; done
    STATUS=$(cat "$BACKSTAGE_HOME/audio/$CP-"*.json 2> /dev/null)
    if [[ -n $CHILD ]] && echo "$STATUS" | jq -e --argjson c "$CHILD" '.tap == "muted" and (.processes | index($c))' > /dev/null \
        && grep -qw "replaced it with one that includes pid $CHILD" "$BACKSTAGE_HOME/daemon.log" && kill -0 "$CP" 2> /dev/null; then
        pass "a helper joining later is muted by a replacement tap; the app keeps running"
    else
        fail "helper join without the grant: child=${CHILD:-none} status=$STATUS log=$(grep -E "pid ${CHILD:-x}([^0-9]|$)|FAILED" "$BACKSTAGE_HOME/daemon.log" | tail -3)"
    fi
    "$BS" quit --pid "$CP" > /dev/null
fi
# Without --audio the commands refuse at once, before the permission check.
QP=$(LAUNCH_AUDIO=default launch) || fail "default launch"
"$BS" list | jq -e --argjson p "$QP" '.apps[] | select(.pid == $p) | .audio == "inaudible"' > /dev/null \
    && pass "the fixture (ad-hoc signed) launches inaudible by default" || fail "default launch mode: $("$BS" list | jq -c .apps)"
for cmd in "audio" "wait --sound --timeout 1" "audio record"; do
    OUT=$("$BS" $cmd --pid "$QP" 2>&1)
    echo "$OUT" | jq -e '.ok == false and (.error | test("launched inaudible.*relaunch with --audio"))' > /dev/null \
        && pass "$cmd refuses an inaudible launch: $(echo "$OUT" | jq -r .error | cut -c1-60)…" || fail "$cmd on an inaudible launch: $OUT"
done
"$BS" quit --pid "$QP" > /dev/null
[[ -n $DEFLOOP ]] && default_leak "no IO"
"$BS" doctor | jq -e '(.problems | join(" ")) | test("System Audio Recording")' > /dev/null && pass "doctor reports it" || fail "doctor should report it"
"$BS" stop --all > /dev/null

echo "== doctor's self-test"
use_home main
"$BS" start > /dev/null
DOC=$("$BS" doctor)
echo "$DOC" | jq -c '.audio'
HOST=$(echo "$DOC" | jq -r '.audio.host.name // empty')
[[ -n $HOST ]] && pass "daemon's responsible host: $HOST" || fail "doctor should name the daemon's host"
if ! echo "$DOC" | jq -e '.audio.selfTest.captured == true' > /dev/null; then
    skip "the self-test didn't capture its probe (System Audio Recording not granted to $HOST?): measuring tests skipped"
    exit $FAIL
fi
LEVEL=$(echo "$DOC" | jq -r .audio.selfTest.levelDb)
near "$LEVEL" -60 1.5 && pass "a muted tap of the daemon captured the -60 dBFS probe ($LEVEL dBFS)" || fail "self-test level $LEVEL"
if [[ -n $DEFLOOP ]]; then default_leak "IO on, then off, then on again"
else skip "default-output leak check: ${DEFOUT:-no default output} has no input that loops its output back (or the host's Microphone isn't granted)"; fi
if [[ -z $DEV ]]; then skip "no output-only audio device: tone tests need one"; exit $FAIL; fi

echo "== inaudible by default: what system-wide captures get (global tap, ScreenCaptureKit)"
# The fixture plays its probe from its first line, while an unmuted private global tap and our
# own SCStream of the main display with audio (excludesCurrentProcessAudio off: on, SCK also drops
# siblings under the same responsible host) listen. Default launch: inaudible, so both read none
# of it. --audio launch (the control): only muted, so both hear it, as screen sharing would.
CHZ=20250   # its own frequency: other audio runs use 18.5 kHz
capture_launch() {  # label [--audio]; writes $WORK/capture-<label>.json and launch-<label>.json
    local label=$1 flag=${2:-} c
    rm -f "$WORK/ready-$label"
    "$PROBE" capture --hz $CHZ --secs 3 --sck --ready "$WORK/ready-$label" > "$WORK/capture-$label.json" &
    c=$!
    for _ in $(seq 1 100); do [[ -e $WORK/ready-$label ]] && break; sleep 0.05; done
    "$BS" launch "$APP" --env "TESTAPP_LOG=$WORK/capture-$label.log" --env TESTAPP_TONE=$CHZ --env TESTAPP_TONE_DEVICE="$DEV" \
        --env TESTAPP_BARE=1 --timeout 1 $flag > "$WORK/launch-$label.json" 2>&1
    wait $c
}
seen() {  # capture json, source (tap|sck): "N windows, best D dB"
    jq -r --arg s "$2" '.[$s] | if .error then "not run (\(.error))" else "\(.toneWindows) windows, best \(.toneDb) dB, \(.nonzeroFrames) non-zero frames" end' "$1"
}
capture_launch inaudible
capture_launch control --audio
IP=$(jq -r .pid "$WORK/launch-inaudible.json"); CP=$(jq -r .pid "$WORK/launch-control.json")
jq -e '.audio == "inaudible" and .audioReason == null' "$WORK/launch-inaudible.json" > /dev/null \
    && pass "default launch: \"audio\": \"inaudible\"" || fail "default launch: $(cat "$WORK/launch-inaudible.json")"
jq -e '.audio == "metered" and (.audioReason | test("--audio"))' "$WORK/launch-control.json" > /dev/null \
    && pass "--audio launch: \"audio\": \"metered\"" || fail "--audio launch: $(cat "$WORK/launch-control.json")"
if ! grep -q "tone output started" "$WORK/capture-inaudible.log" || ! grep -q "tone output started" "$WORK/capture-control.log"; then
    fail "the fixture didn't play its probe: $(cat "$WORK/capture-inaudible.log" "$WORK/capture-control.log" | grep tone)"
fi
jq -e '.tap.toneWindows >= 3' "$WORK/capture-control.json" > /dev/null \
    && pass "control (--audio): the global tap hears the muted app: $(seen "$WORK/capture-control.json" tap)" \
    || fail "control: the global tap missed the --audio launch: $(seen "$WORK/capture-control.json" tap)"
jq -e '.tap.toneWindows == 0' "$WORK/capture-inaudible.json" > /dev/null \
    && pass "inaudible: the global tap reads none of it: $(seen "$WORK/capture-inaudible.json" tap)" \
    || fail "inaudible: the global tap heard it: $(seen "$WORK/capture-inaudible.json" tap)"
if jq -e '.sck.error' "$WORK/capture-control.json" > /dev/null; then
    skip "ScreenCaptureKit check: $(seen "$WORK/capture-control.json" sck)"
else
    jq -e '.sck.toneWindows >= 3' "$WORK/capture-control.json" > /dev/null \
        && pass "control (--audio): our SCStream hears the muted app: $(seen "$WORK/capture-control.json" sck)" \
        || fail "control: SCStream missed the --audio launch: $(seen "$WORK/capture-control.json" sck)"
    jq -e '.sck.toneWindows == 0 and .sck.buffers > 0' "$WORK/capture-inaudible.json" > /dev/null \
        && pass "inaudible: our SCStream reads none of it: $(seen "$WORK/capture-inaudible.json" sck)" \
        || fail "inaudible: SCStream heard it (or got no audio): $(jq -c .sck "$WORK/capture-inaudible.json")"
fi
[[ $(grep -c "IO on for pid $IP " "$BACKSTAGE_HOME/daemon.log") == 0 ]] && grep -q "muted pid $IP " "$BACKSTAGE_HOME/daemon.log" \
    && pass "the inaudible app's tap mutes it and never runs IO" || fail "inaudible app: tap or IO: $(grep "pid $IP " "$BACKSTAGE_HOME/daemon.log")"
"$BS" quit --pid "$IP" > /dev/null; "$BS" quit --pid "$CP" > /dev/null

echo "== a hardened app falls back to muted; --inaudible refuses it"
HARD="$WORK/HardenedTestApp.app"
cp -R "$APP" "$HARD" && codesign -f -s - --options runtime "$HARD" 2> /dev/null
OUT=$("$BS" launch "$HARD" --env "TESTAPP_LOG=$WORK/hardened.log" --env TESTAPP_TONE=18500 --env TESTAPP_TONE_DEVICE="$DEV" --env TESTAPP_BARE=1 --timeout 1)
HP=$(echo "$OUT" | jq -r .pid)
echo "$OUT" | jq -e '.audio == "muted" and (.audioReason | test("hardened runtime"))' > /dev/null \
    && pass "default launch: muted ($(echo "$OUT" | jq -r .audioReason | cut -c1-70)…)" || fail "hardened default launch: $OUT"
sleep 1.2
OUT=$("$BS" audio --pid "$HP" 2>&1)
echo "$OUT" | jq -e '.error | test("without --audio.*relaunch with --audio")' > /dev/null && pass "audio refuses it: launched without --audio" || fail "audio on a muted launch: $OUT"
grep -q "tone output started" "$WORK/hardened.log" && [[ $(grep -c "IO on for pid $HP " "$BACKSTAGE_HOME/daemon.log") == 0 ]] \
    && [[ ! -e $(ls "$BACKSTAGE_HOME/audio/$HP-"*.pcm 2> /dev/null | head -1) ]] \
    && pass "it plays, muted, but its tap runs no IO and publishes no ring" || fail "unmeasured app: IO or ring: $(grep "pid $HP " "$BACKSTAGE_HOME/daemon.log")"
"$BS" quit --pid "$HP" > /dev/null
OUT=$("$BS" launch "$HARD" --env "TESTAPP_LOG=$WORK/hardened2.log" --inaudible 2>&1); CODE=$?
[[ $CODE == 1 ]] && echo "$OUT" | jq -e '.error | test("inaudible: .*hardened runtime")' > /dev/null \
    && ! pgrep -f "$HARD/Contents/MacOS" > /dev/null && pass "--inaudible refuses it before starting anything" || fail "--inaudible on a hardened app: $OUT"
OUT=$(BACKSTAGE_INAUDIBLE_DYLIB= "$BS" launch "$APP" --env "TESTAPP_LOG=$WORK/nolib.log" --env TESTAPP_BARE=1 --timeout 0.5)
echo "$OUT" | jq -e '.audio == "muted" and (.audioReason | test("wasn.t found"))' > /dev/null \
    && pass "without the library: muted, and says so" || fail "missing library: $OUT"
"$BS" quit --pid "$(echo "$OUT" | jq -r .pid)" > /dev/null

echo "== a playing app: audio and wait --sound"
A=$(FLOG="$WORK/fixture-A.log" launch --env TESTAPP_TONE=18500 --env TESTAPP_TONE_DEVICE="$DEV") || fail "launch A"
W=$("$BS" wait --sound --pid "$A" --timeout 5) && pass "wait --sound: $(echo "$W" | jq -c .sound)" || fail "wait --sound: $W"
sleep 1.2
S=$(audio "$A")
echo "$S" | jq -e --argjson p "$A" '.tap == "muted" and (.processes | index($p)) != null and .ioRunning' > /dev/null && pass "tap muted, IO running" || fail "audio: $S"
HZ=$(echo "$S" | jq -r '.hz // 0'); PEAK=$(echo "$S" | jq -r '[.sounds[].peakDb] | max')
near "$HZ" 18500 30 && pass "hz $HZ" || fail "hz $HZ, expected 18500"
near "$PEAK" -60 1.5 && pass "peak $PEAK dBFS" || fail "peak $PEAK, expected -60"
MS=$(echo "$S" | jq -r '.sightToMuteMs[0]')
# The fixture plays from its first line: the mute must be in place before its first render.
MUTED=$(grep "muted pid $A " "$BACKSTAGE_HOME/daemon.log" | sed -E 's/.* at ([0-9.]+).*/\1/' | head -1)
RENDER=$(grep "tone first render at" "$WORK/fixture-A.log" | head -1 | awk '{print $NF}')
MARGIN=$(awk -v r="$RENDER" -v m="$MUTED" 'BEGIN { printf "%.1f", (r - m) * 1000 }')
awk -v x="$MARGIN" 'BEGIN { exit !(x > 0) }' && pass "muted $MS ms after sight, $MARGIN ms before the fixture's first render" \
    || fail "the mute landed $MARGIN ms after the fixture's first render (sight-to-mute $MS ms)"
SECS=$(echo "$S" | jq -r '[.sounds[] | select(.ongoing | not) | .seconds][0]')
near "$SECS" 0.3 0.03 && pass "a 300 ms burst measured $SECS s" || fail "300 ms burst measured $SECS s"
OUT=$("$BS" wait --sound --pid "$A" --min-db -20 --timeout 1.5 2>&1)
echo "$OUT" | jq -e '.error | test("below --min-db")' > /dev/null && pass "--min-db: $(echo "$OUT" | jq -r .error | sed 's/.*: //')" || fail "--min-db: $OUT"
G=$("$BS" wait --sound --gone --pid "$A" --timeout 3) && pass "wait --sound --gone: ended $(echo "$G" | jq -r .sound.seconds) s sound" || fail "--gone: $G"

echo "== two sessions, two frequencies"
B=$(BACKSTAGE_SESSION=audio-b launch --env TESTAPP_TONE=19500 --env TESTAPP_TONE_DEVICE="$DEV") || fail "launch B"
BACKSTAGE_SESSION=audio-b "$BS" wait --sound --pid "$B" --timeout 5 > /dev/null
sleep 1.2
HB=$(BACKSTAGE_SESSION=audio-b "$BS" audio --pid "$B" | jq -r '.hz // 0'); HA=$(audio "$A" | jq -r '.hz // 0')
near "$HB" 19500 30 && near "$HA" 18500 30 && pass "each session hears only its own app: $HA Hz and $HB Hz" || fail "A $HA Hz, B $HB Hz"
OUT=$("$BS" audio --pid "$B" 2>&1)
echo "$OUT" | jq -e '.error | test("another backstage session")' > /dev/null && pass "another session's app is refused" || fail "cross-session audio: $OUT"
OUT=$("$BS" audio record --pid "$B" -o "$WORK/not-mine.wav" 2>&1)
echo "$OUT" | jq -e '.error | test("another backstage session")' > /dev/null && [[ ! -e $WORK/not-mine.wav ]] \
    && pass "and so is recording it" || fail "cross-session audio record: $OUT"

echo "== short sounds: a 100 ms burst, found after it ended"
C=$(launch --env TESTAPP_TONE=18500 --env TESTAPP_TONE_DEVICE="$DEV" --env TESTAPP_TONE_PATTERN=none) || fail "launch C"
OUT=$("$BS" wait --sound --pid "$C" --timeout 1 2>&1)
echo "$OUT" | jq -e '.error | test("no audio output running")' > /dev/null && pass "quiet app: no audio output running" || fail "quiet app: $OUT"
OUT=$("$BS" audio record --pid "$C" 2>&1)
echo "$OUT" | jq -e '.ok == false and (.error | test("nothing to record"))' > /dev/null && pass "audio record before any sound: $(echo "$OUT" | jq -r .error | cut -c1-80)…" || fail "record before sound: $OUT"
T=$(audio "$C" | jq -r .time)
"$BS" menu --pid "$C" "Actions > Tone Burst" > /dev/null
sleep 1
W=$("$BS" wait --sound --pid "$C" --since "$T" --timeout 3) || fail "wait --since: $W"
SECS=$(echo "$W" | jq -r .sound.seconds); PEAK=$(echo "$W" | jq -r .sound.peakDb)
echo "$W" | jq -e '.sound.ongoing == false' > /dev/null && near "$SECS" 0.1 0.025 && near "$PEAK" -60 1.5 \
    && pass "100 ms burst: one sound of $SECS s at $PEAK dBFS, found after it ended (IO started on running output)" || fail "burst: $W"
NS=$(audio "$C" | jq '[.sounds[] | select(.start >= '"$T"')] | length')
[[ $NS == 1 ]] && pass "reported as one sound" || fail "$NS sounds for one burst"
# Recorded after it ended: the WAV ends where output last ran, and holds the burst at its time.
"$BS" wait --sound --gone --pid "$C" --timeout 3 > /dev/null
R=$("$BS" audio record --pid "$C" --seconds 3 -o "$WORK/burst.wav") || fail "record the burst: $R"
"$WAVCHECK" "$WORK/burst.wav" > "$WORK/burst.json"
NB=$(jq '.bursts | length' "$WORK/burst.json"); BSEC=$(jq -r '.bursts[0].seconds' "$WORK/burst.json"); BH=$(jq -r '.bursts[0].hz' "$WORK/burst.json")
AT=$(jq --argjson r "$R" --argjson w "$W" '(($r.start + .bursts[0].start - $w.sound.start) * 1000 | round)' "$WORK/burst.json")
[[ $NB == 1 ]] && near "$BSEC" 0.1 0.025 && near "$BH" 18500 2 && near "$AT" 0 20 \
    && pass "recorded after it ended: one $BSEC s burst at $BH Hz, $AT ms from where wait --sound put it" \
    || fail "recorded burst: $NB bursts, $BSEC s, $BH Hz, $AT ms off: $R $(cat "$WORK/burst.json")"

echo "== output running but silent"
D=$(launch --env TESTAPP_TONE=18500 --env TESTAPP_TONE_DEVICE="$DEV" --env TESTAPP_TONE_SILENT=1) || fail "launch D"
OUT=$("$BS" wait --sound --pid "$D" --timeout 1.5 2>&1)
echo "$OUT" | jq -e '.error | test("output running but silent")' > /dev/null && pass "silent output: $(echo "$OUT" | jq -r .error | sed 's/.*: //')" || fail "silent: $OUT"
"$BS" quit --pid "$D" > /dev/null

echo "== the published ring"
RING=$(jq -r .ring "$BACKSTAGE_HOME/audio/$A-"*.json)
[[ $(head -c 4 "$RING") == BSAR ]] && [[ $(stat -f %Lp "$RING") == 600 ]] && pass "ring $(basename "$RING"): BSAR header, mode 0600, $(stat -f %z "$RING") bytes" || fail "ring file"

echo "== audio record: the probe's WAV, checked outside backstage (phase 3 gate)"
# A plays 300 ms on / 700 ms off, so any 4 s holds about 1.2 s of tone whatever the phase.
R=$("$BS" audio record --pid "$A" --seconds 4) || fail "audio record: $R"
P=$(echo "$R" | jq -r .path); GAIN=$(echo "$R" | jq -r '.levelGainDb // 0')
[[ $P == "$BACKSTAGE_HOME/shots/"*/audio-*.wav && -s $P ]] && echo "$R" | jq -e '.ok and .channels == 2 and .format == "float32" and .seconds == 4' > /dev/null \
    && pass "without -o, into the session's screenshots folder: $(echo "$R" | jq -c '{seconds, sampleRate, channels, format}')" || fail "record result: $R"
RATE=$(echo "$R" | jq -r .sampleRate | cut -d. -f1)
afinfo "$P" > "$WORK/afinfo.txt"
DUR=$(awk '/estimated duration/ { print $3 }' "$WORK/afinfo.txt")
grep -q "2 ch, *$RATE Hz, Float32" "$WORK/afinfo.txt" && grep -q "source bit depth: F32" "$WORK/afinfo.txt" && near "$DUR" 4 0.0005 \
    && pass "afinfo: $(grep 'Data format' "$WORK/afinfo.txt" | sed 's/.*: *//'), $DUR s" || fail "afinfo: $(cat "$WORK/afinfo.txt")"
"$WAVCHECK" "$P" > "$WORK/record.json"
# Whole bursts only (not cut by the window's edges). The WAV is the tap as tapped: on a
# multichannel device it reads levelGainDb under `audio`'s compensated levels.
WHOLE=$(jq '[.bursts[] | select(.start > 0.05 and .start + .seconds < 3.95)]' "$WORK/record.json")
EXP=$(awk -v g="$GAIN" 'BEGIN { print -60 - g }')
CHECK=$(echo "$WHOLE" | jq -c --argjson e "$EXP" '{n: length, hz: [.[].hz], peak: [.[].peakDb], rms: [.[].rmsDb], seconds: [.[].seconds],
    ok: (length >= 3 and all(.[]; (.hz - 18500 | fabs) <= 2 and (.peakDb - $e | fabs) <= 0.5 and (.rmsDb - $e + 3.01 | fabs) <= 0.5 and (.seconds - 0.3 | fabs) <= 0.02))}')
TONE=$(jq -r .toneSeconds "$WORK/record.json")
echo "$CHECK" | jq -e .ok > /dev/null && near "$TONE" 1.2 0.1 \
    && pass "wavcheck: $(echo "$CHECK" | jq -c 'del(.ok)'), $TONE s of tone in 4 s" || fail "wavcheck: $CHECK; $(cat "$WORK/record.json")"
# The full 15 s while A plays: the writer laps the oldest frames during the read, so every read
# must still succeed (dropping at most the 0.1 s it may have overwritten).
HAVE=$("$BS" audio record --pid "$A" -o "$WORK/full.wav" | jq -r .seconds)
awk -v h="$HAVE" 'BEGIN { exit !(h < 14.85) }' && sleep "$(awk -v h="$HAVE" 'BEGIN { print 15.3 - h }')"
SECS=(); BAD=0
for i in $(seq 1 15); do
    OUT=$("$BS" audio record --pid "$A" -o "$WORK/full.wav") && SECS+=("$(echo "$OUT" | jq -r .seconds)") || { BAD=$((BAD + 1)); echo "    $OUT"; }
done
MIN=$(printf '%s\n' "${SECS[@]}" | sort -n | head -1); MAX=$(printf '%s\n' "${SECS[@]}" | sort -n | tail -1)
[[ $BAD == 0 ]] && near "$MIN" 14.9 0.1 && near "$MAX" 14.9 0.1 \
    && pass "15 reads of a full 15 s ring while it plays: all succeeded, $MIN-$MAX s" || fail "full reads: $BAD failed, $MIN-$MAX s"
N15=$("$WAVCHECK" "$WORK/full.wav" | jq '[.bursts[] | select((.hz - 18500 | fabs) <= 2)] | length')
[[ $N15 -ge 14 ]] && pass "the 15 s WAV holds $N15 bursts at 18500 Hz" || fail "the 15 s WAV holds $N15 bursts"
OUT=$("$BS" audio record --pid "$A" -o "$WORK/x.mp3" 2>&1)
echo "$OUT" | jq -e '.error | test("\\.wav")' > /dev/null && pass "a non-.wav path is refused" || fail "-o x.mp3: $OUT"

echo "== show unmutes (fixture quit at once)"
E=$(launch --env TESTAPP_TONE=18500 --env TESTAPP_TONE_DEVICE="$DEV" --env TESTAPP_TONE_PATTERN=100 --env TESTAPP_TONE_ONCE=1 --env TESTAPP_ACCESSORY=1) || fail "launch E"
"$BS" wait --sound --gone --pid "$E" --timeout 3 > /dev/null
EB=$(ls "$BACKSTAGE_HOME/audio/" | grep "^$E-.*json" | head -1)
OUT=$("$BS" show --pid "$E"); kill "$E" 2>/dev/null
echo "$OUT" | jq -e '.audio == "unmuted" and (.note | test("no longer muted"))' > /dev/null && pass "show says the app is unmuted" || fail "show: $OUT"
[[ ! -e "$BACKSTAGE_HOME/audio/$EB" ]] && pass "its tap is gone" || fail "tap still published after show"

echo "== leak checks against a loopback device"
LOOP=""
if [[ $MIC != 3 ]]; then skip "the host's Microphone access isn't granted: can't read a loopback without a prompt"
else
    for uid in $(jq -r '.[] | select(.in > 0 and .out > 0 and (.default | not)) | .uid' "$WORK/devices.json"); do
        "$PROBE" listen --device "$uid" --hz 18500 --secs 1.2 > "$WORK/loopcheck.json" &
        L=$!; sleep 0.3
        "$PROBE" play --device "$uid" --hz 18500 --ms 300 > /dev/null; wait $L
        near "$(jq -r .toneDb "$WORK/loopcheck.json")" -60 1.5 && { LOOP=$uid; break; }
    done
    [[ -z $LOOP ]] && skip "no loopback device that isn't the default output"
fi
if [[ -n $LOOP ]]; then
    echo "   loopback: $LOOP"
    listen() { "$PROBE" listen --device "$LOOP" --hz 18500 --secs "$1" > "$2" & LISTENER=$!; sleep 0.4; }
    # Negative control first: unmuted, the watchdog must hear the probe.
    listen 1.5 "$WORK/leak0.json"; "$PROBE" play --device "$LOOP" --hz 18500 --ms 50 > /dev/null; wait $LISTENER
    # 50 ms in a 100 ms detector window reads about 6 dB low; count the frames instead.
    [[ $(jq -r .nonzeroFrames "$WORK/leak0.json") -ge 2000 ]] && pass "watchdog hears an unmuted 50 ms probe ($(jq -r .nonzeroFrames "$WORK/leak0.json") frames)" \
        || fail "watchdog missed the control: $(cat "$WORK/leak0.json")"
    # On-sight muting of a pending launch (its BACKSTAGE_LAUNCH_ID), playing from its first line.
    # The player runs under this test's host (Microphone granted), so no prompt is possible.
    mkdir -p "$BACKSTAGE_HOME/launching" "$BACKSTAGE_HOME/logs"
    for i in 1 2 3; do
        ID=$(uuidgen); touch "$BACKSTAGE_HOME/logs/$ID.log"
        printf '{"id":"%s","session":"audio-a","cliPID":%d,"cliStart":0,"bundle":"%s","log":"%s","startedAt":%s}' \
            "$ID" $$ "$APP" "$BACKSTAGE_HOME/logs/$ID.log" "$(date +%s)" > "$BACKSTAGE_HOME/launching/$ID.json"
        listen 1.5 "$WORK/leak$i.json"
        BACKSTAGE_LAUNCH_ID=$ID "$PROBE" play --device "$LOOP" --hz 18500 --ms 300 --hold-ms 300 > "$WORK/play$i.json" || exit 1
        wait "$LISTENER" || exit 1
        LISTENER=
        rm -f "$BACKSTAGE_HOME/launching/$ID.json" "$BACKSTAGE_HOME/logs/$ID.log"
        P=$(jq -r .pid "$WORK/play$i.json")
        MS=$(grep "muted pid $P " "$BACKSTAGE_HOME/daemon.log" | sed -E 's/.* ([0-9.]+) ms after sight.*/\1/')
        GAP=$(jq -r '((.outputStart - .processStart) * 1000 | floor)' "$WORK/play$i.json")
        N=$(jq -r .nonzeroFrames "$WORK/leak$i.json")
        [[ -n $MS ]] || { fail "pending launch, run $i: no mute recorded for pid $P"; continue; }
        [[ $N == 0 ]] && pass "pending launch, run $i: 0 frames reached the loopback (sight-to-mute $MS ms; first HAL call to output start $GAP ms)" \
            || fail "pending launch, run $i: $N frames leaked (sight-to-mute $MS ms): $(cat "$WORK/leak$i.json")"
    done
    # The real thing: the fixture launched through backstage, playing to the loopback from its
    # first line. It refuses to (and skips) while its own Microphone access is undecided, since
    # macOS would ask for it in the fixture's name: see tests/audio-leak.sh --grant-fixture-mic.
    listen 2.5 "$WORK/leak-launch.json"
    LEAK_LOG="$WORK/fixture-loopback.log"
    LP=$(FLOG="$LEAK_LOG" launch --env TESTAPP_TONE=18500 --env TESTAPP_TONE_DEVICE="$LOOP" --env TESTAPP_TONE_PATTERN=500 --env TESTAPP_TONE_ONCE=1) || exit 1
    wait "$LISTENER" || exit 1
    LISTENER=
    if grep -q "tone skipped" "$LEAK_LOG"; then
        skip "fixture → loopback through launch: the fixture's Microphone access isn't decided (tests/audio-leak.sh --grant-fixture-mic, once)"
    elif ! grep -q "tone first render" "$LEAK_LOG"; then
        fail "fixture through launch: the fixture did not render the probe"
    else
        N=$(jq -r .nonzeroFrames "$WORK/leak-launch.json")
        MS=$(grep "muted pid $LP " "$BACKSTAGE_HOME/daemon.log" | sed -E 's/.* ([0-9.]+) ms after sight.*/\1/')
        [[ $N == 0 ]] && pass "fixture through launch: 0 frames reached the loopback (sight-to-mute $MS ms)" || fail "fixture through launch: $N frames leaked"
    fi
    "$BS" quit --pid "$LP" > /dev/null 2>&1
fi

echo "== stop: taps go with the apps"
"$BS" stop > /dev/null; BACKSTAGE_SESSION=audio-b "$BS" stop > /dev/null
for _ in $(seq 1 30); do [[ -f "$BACKSTAGE_HOME/daemon.json" ]] || break; sleep 0.2; done
LEFT=$(ls "$BACKSTAGE_HOME/audio" 2>/dev/null | grep -v '^daemon.json$' || true)
[[ -z $LEFT ]] && pass "no published audio files left" || fail "left: $LEFT"
DURING=$(grep -c "started output during" "$BACKSTAGE_HOME/daemon.log" || true)
[[ $DURING == 0 ]] && pass "no app started output while its tap was being set up" || fail "$DURING app(s) started output during tap setup"
SLOW=$(grep -c "slow tick" "$BACKSTAGE_HOME/daemon.log" || true)
[[ $SLOW == 0 ]] && pass "no slow ticks" || fail "$SLOW slow ticks in the daemon log"

echo "== crash handler: a crashing daemon kills its apps first (windowless fixture)"
use_home crash
"$BS" start > /dev/null
DP=$(jq -r .pid "$BACKSTAGE_HOME/daemon.json")
BARE=$(launch --env TESTAPP_BARE=1 --timeout 1) || exit 1
if ! [[ $DP =~ ^[1-9][0-9]*$ && $BARE =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$BARE" 2>/dev/null; then
    fail "crash control failed: expected a live windowless fixture (daemon $DP, fixture $BARE)"
    exit 1
fi
kill -SEGV "$DP" || { fail "could not signal daemon $DP"; exit 1; }
for _ in $(seq 1 30); do kill -0 "$BARE" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$BARE" 2>/dev/null; then
    fail "the app outlived the crashed daemon"
    kill -9 "$BARE" 2>/dev/null
else
    pass "SIGSEGV in the daemon killed its app"
fi
rm -f "$BACKSTAGE_HOME/daemon.json"

echo
[[ $FAIL == 0 ]] && echo "audio: all passed" || echo "audio: FAILURES"
exit $FAIL
