#!/bin/bash
# Launch identification when LaunchServices answers late or never (heavy load, WindowServer
# stalls): `launch` must still find and register the app by its launch token, and an app that
# only appears after `launch` gave up must end up registered to the session (or quit after a
# `stop`), never left running untracked. A watchdog asserts nothing reaches the user's screens.
set -uo pipefail
# backstage's own tests use displays 7-8, never the ones agents use (docs/MULTI_DISPLAY_PLAN.md).
export BACKSTAGE_DISPLAY=${BACKSTAGE_DISPLAY:-7}
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build) || exit 1
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage" || exit 1
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-launch.XXXX)" || exit 1
export BACKSTAGE_HOME="$WORK/state"
export BACKSTAGE_SESSION=launch-test
unset BACKSTAGE_TEST_LS BACKSTAGE_LAUNCH_DEADLINE
WATCH=
LATE=()
cleanup() {
    local result=$?
    trap - EXIT
    local p child
    # A fixture which already exited may have had its PID reused.
    for child in $(jobs -pr); do
        for p in ${LATE[@]+"${LATE[@]}"}; do
            [[ $child == "$p" ]] || continue
            kill "$p" 2>/dev/null
            wait "$p" 2>/dev/null
        done
    done
    if [[ -f "$BACKSTAGE_HOME/daemon.json" || -f "$BACKSTAGE_HOME/apps.json" ]]; then "$BS" stop --all >/dev/null 2>&1 || result=1; fi
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
jget() { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }
# Running, and not a zombie (the late processes are this shell's children until reaped).
alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null); [[ -n "$st" && "$st" != Z* ]]; }
listed() { "$BS" list | python3 -c "import sys,json; print(' '.join(str(a['pid']) for a in json.load(sys.stdin)['apps']))"; }
records() { compgen -G "$BACKSTAGE_HOME/launching/*.json" | wc -l | tr -d ' '; }
# The pid the session lists for a launch log, once the daemon has registered it (up to $2 s).
pid_for_log() {
    local log=$1 tries=$(( ${2:-15} * 10 )) p
    for _ in $(seq 1 "$tries"); do
        p=$("$BS" list | python3 -c "import sys,json; print(next((a['pid'] for a in json.load(sys.stdin)['apps'] if a.get('log') == sys.argv[1]), ''))" "$log")
        [[ -n "$p" ]] && { echo "$p"; return 0; }
        sleep 0.1
    done
    return 1
}
gone() { for _ in $(seq 1 50); do alive "$1" || return 0; sleep 0.1; done; return 1; }

echo "== build fixtures"
APP="$WORK/BackstageTestApp.app"
mkdir -p "$APP/Contents/MacOS" "$WORK/bin"
swiftc -O TestApp.swift -o "$APP/Contents/MacOS/BackstageTestApp" || exit 1
BID="dev.backstage.testapp.${WORK##*.}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageTestApp</string><key>CFBundleIdentifier</key><string>$BID</string><key>CFBundleName</key><string>BackstageTestApp</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
# The same fixture as a bare executable: launched through a wrapper .app, like `xctest`.
BARE="$WORK/bin/BackstageTestBare"
cp "$APP/Contents/MacOS/BackstageTestApp" "$BARE"
# A windowless process for the hand-written late launches below (the test starts it itself, so
# it must not open windows).
printf '%s\n' '#include <stdio.h>' '#include <unistd.h>' \
    'int main(void) { printf("late process up\n"); fflush(stdout); sleep(300); return 0; }' > "$WORK/late.c"
cc -O2 -o "$WORK/bin/late" "$WORK/late.c" || exit 1
swiftc -O watch.swift -o "$WORK/watch" || exit 1
"$WORK/watch" "$BID" 240 "$WORK/watch.stop" > "$WORK/watch.out" 2>&1 &
WATCH=$!
sleep 0.3
"$BS" start > /dev/null || { fail "daemon start"; exit 1; }

echo "== LaunchServices never answers: launch identifies the app by its token"
OUT=$(BACKSTAGE_TEST_LS=no-callback "$BS" launch "$APP" --timeout 5 --env "TESTAPP_LOG=$WORK/a.log")
P1=$(echo "$OUT" | jget "['pid']")
[[ -n "$P1" ]] && alive "$P1" && pass "launched pid $P1 without LaunchServices' answer" || fail "launch: $OUT"
echo "$OUT" | jget "['warning']" | grep -q "LaunchServices hadn't answered" && pass "warning says LaunchServices didn't answer" \
    || fail "no LaunchServices warning: $OUT"
[[ " $(listed) " == *" $P1 "* ]] && pass "list shows it" || fail "list: $(listed)"
[[ $(records) == 0 ]] && pass "no provisional record left" || fail "provisional record left behind"
"$BS" quit --pid "$P1" > /dev/null && gone "$P1" && pass "quit reached it" || fail "quit pid $P1"

echo "== same for a bare executable (wrapper .app), with --timeout 0"
OUT=$(BACKSTAGE_TEST_LS=no-callback "$BS" launch "$BARE" --timeout 0 --env "TESTAPP_LOG=$WORK/b.log")
P2=$(echo "$OUT" | jget "['pid']")
[[ -n "$P2" ]] && alive "$P2" && pass "launched bare pid $P2 without LaunchServices' answer" || fail "bare launch: $OUT"
[[ $(echo "$OUT" | jget "['audio']") == inaudible ]] && pass "still launched inaudible" || fail "audio: $(echo "$OUT" | jget "['audio']")"
[[ " $(listed) " == *" $P2 "* ]] && pass "list shows it" || fail "list: $(listed)"
"$BS" quit --pid "$P2" > /dev/null && gone "$P2" && pass "quit reached it" || fail "quit pid $P2"

# `launch` gives up (it's kept from seeing the process, as if it hadn't appeared yet): the daemon
# must register the app to the session once the CLI is gone.
for target in "$APP" "$BARE"; do
    kind=$([[ $target == "$APP" ]] && echo app || echo "bare executable")
    echo "== launch gives up on a $kind: the daemon registers it to the session"
    LOGF="$WORK/handover-${kind// /-}.log"
    BACKSTAGE_TEST_LS=no-callback,no-find BACKSTAGE_LAUNCH_DEADLINE=2 "$BS" launch "$target" --env "TESTAPP_LOG=$LOGF" > "$WORK/h.json" 2>&1
    RC=$?
    [[ $RC != 0 ]] && grep -q "registering it to this session" "$WORK/h.json" && pass "launch failed and said so" \
        || fail "launch (rc $RC): $(cat "$WORK/h.json")"
    APPLOG=$(python3 -c "import sys,re; m=re.search(r'Launch log: (\S+\.log)', open(sys.argv[1]).read()); print(m.group(1) if m else '')" "$WORK/h.json")
    P=$(pid_for_log "$APPLOG" 15)
    [[ -n "$P" ]] && alive "$P" && pass "the daemon registered pid $P to the session" || fail "no registered app for $APPLOG; list: $("$BS" list)"
    if [[ -n "$P" ]]; then
        [[ $("$BS" list | jget "['apps'][0]['session']") == launch-test ]] && pass "it belongs to this session" || fail "wrong session"
        grep -q "registered pid $P to session launch-test" "$BACKSTAGE_HOME/daemon.log" && pass "daemon logged the registration" || fail "no registration logged"
        [[ $(records) == 0 ]] && pass "provisional record dropped" || fail "provisional record left behind"
        for _ in $(seq 1 30); do grep -q "Window" "$LOGF" 2>/dev/null && break; sleep 0.1; done
        "$BS" screenshot --pid "$P" -o "$WORK/handover-${kind// /-}.png" > /dev/null 2>&1 && pass "screenshot works (windows on the agent display)" \
            || fail "screenshot of registered app"
        "$BS" quit --pid "$P" > /dev/null && gone "$P" && pass "quit reached it" || fail "quit pid $P"
    fi
done

# Hand-written handed-over records: a dead CLI, and a process that appears only after the
# CLI's old grace period (15 s after it died) would have dropped the record.
handover_record() {   # id startedAt-offset log
    local id=$1 started
    started=$(python3 -c "import time; print(time.time() - $2)")
    mkdir -p "$BACKSTAGE_HOME/launching" "$BACKSTAGE_HOME/logs"
    : > "$3"
    cat > "$BACKSTAGE_HOME/launching/$id.json.tmp" <<JSON
{"id": "$id", "session": "launch-test", "cliPID": $$, "cliStart": 1, "bundle": "$WORK/Late.app",
 "executable": "$WORK/bin/late", "log": "$3", "startedAt": $started, "audio": "muted", "handedOver": true}
JSON
    mv "$BACKSTAGE_HOME/launching/$id.json.tmp" "$BACKSTAGE_HOME/launching/$id.json"
}

echo "== a process that appears 17 s after its launch gave up is registered, not left untracked"
ID=$(uuidgen); LOGF="$BACKSTAGE_HOME/logs/$ID.log"
handover_record "$ID" 25 "$LOGF"
PENDING=$("$BS" list | jget "['pendingLaunches'][0]['launch']")
[[ "$PENDING" == "$ID" ]] && pass "list shows the pending launch" || fail "pendingLaunches: $("$BS" list)"
sleep 17
[[ -f "$BACKSTAGE_HOME/launching/$ID.json" ]] && pass "the daemon kept the record past the old grace period" || fail "record dropped early"
BACKSTAGE_LAUNCH_ID=$ID "$WORK/bin/late" > "$LOGF" 2>&1 &
PL=$!; LATE+=("$PL")
P=$(pid_for_log "$LOGF" 10)
[[ "$P" == "$PL" ]] && pass "the daemon registered the late process (pid $PL)" || fail "late process not registered (got '$P'); list: $("$BS" list)"
[[ $("$BS" list | jget "['pendingLaunches']") == "" ]] && pass "no pending launch left" || fail "pendingLaunches still listed"
"$BS" quit --pid "$PL" > /dev/null; gone "$PL" && pass "quit reached it" || fail "late pid $PL still running"

echo "== after the session's stop, a late process is quit instead"
ID=$(uuidgen); LOGF="$BACKSTAGE_HOME/logs/$ID.log"
handover_record "$ID" 1 "$LOGF"
"$BS" stop > "$WORK/stop.json"
[[ $(jget "['daemon']" < "$WORK/stop.json") == running* ]] && pass "stop kept the daemon for the pending launch" || fail "stop: $(cat "$WORK/stop.json")"
BACKSTAGE_LAUNCH_ID=$ID "$WORK/bin/late" > "$LOGF" 2>&1 &
PL=$!; LATE+=("$PL")
gone "$PL" && pass "the daemon quit it" || fail "late pid $PL still running after stop"
for _ in $(seq 1 30); do [[ -f "$BACKSTAGE_HOME/launching/$ID.json" ]] || break; sleep 0.1; done
[[ ! -f "$BACKSTAGE_HOME/launching/$ID.json" ]] && pass "record dropped" || fail "record left behind"
[[ -z "$(listed)" ]] && pass "nothing listed" || fail "list: $(listed)"

exit $FAIL
