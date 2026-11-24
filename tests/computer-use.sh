#!/bin/bash
# Computer-use compatibility test for the daemon's input guard (Sources/backstage/InputGuard.swift).
# Computer-use agents' per-app background tools (the Claude desktop app's app_* tools, posted by
# Claude.app/Contents/Helpers/app-cu-helper; Codex computer use, Codex Computer Use.app's
# SkyComputerUseService) post input straight to an app's PID without backstage's tag. Checks:
#  - an untagged key from an ordinary process into a managed app is still dropped
#  - the same key from a process at a computer-use helper's path (tests/untagged.swift copied to
#    …/Contents/Helpers/app-cu-helper and …/Contents/MacOS/SkyComputerUseService) lands
#  - an untagged key into an app backstage doesn't manage (tests/keysink.swift: windowless, never
#    activates) arrives, and the guard doesn't count it
# All test input is posted to one PID from a private event source: nothing reaches the user's
# apps, and an event the guard wrongly keeps out is dropped, never handed to the user's app.
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
WORK="$(mktemp -d /tmp/backstage-cu.XXXX)" || exit 1
export BACKSTAGE_HOME="$WORK/state"
unset BACKSTAGE_SESSION
SINK=
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -f "$BACKSTAGE_HOME/daemon.json" || -f "$BACKSTAGE_HOME/apps.json" ]]; then
        "$BS" stop --all >/dev/null 2>&1 || result=1
    fi
    [[ -n "$SINK" ]] && kill "$SINK" 2>/dev/null
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
value() { "$BS" find --pid "$PID" --role textfield | jget "['elements'][0].get('value','')"; }
waitvalue() { for _ in $(seq 1 30); do [[ "$(value)" == "$1" ]] && return 0; sleep 0.1; done; return 1; }

echo "== build fixtures"
mkdir -p "$WORK/BackstageTestApp.app/Contents/MacOS"
swiftc -O TestApp.swift -o "$WORK/BackstageTestApp.app/Contents/MacOS/BackstageTestApp" || exit 1
BUNDLE="dev.backstage.testapp.${WORK##*.}"
cat > "$WORK/BackstageTestApp.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageTestApp</string><key>CFBundleIdentifier</key><string>$BUNDLE</string><key>CFBundleName</key><string>BackstageTestApp</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -O untagged.swift -o "$WORK/untagged" || exit 1
swiftc -O keysink.swift -o "$WORK/keysink" || exit 1
# The same poster at the computer-use helpers' paths (plain directories, not app bundles: nothing to register or open).
mkdir -p "$WORK/FakeClaude/Contents/Helpers" "$WORK/FakeCodex/Contents/MacOS"
CLAUDE_HELPER="$WORK/FakeClaude/Contents/Helpers/app-cu-helper"
CODEX_HELPER="$WORK/FakeCodex/Contents/MacOS/SkyComputerUseService"
cp "$WORK/untagged" "$CLAUDE_HELPER" && cp "$WORK/untagged" "$CODEX_HELPER" || exit 1

echo "== launch"
PID=$("$BS" launch "$WORK/BackstageTestApp.app" --env "TESTAPP_LOG=$WORK/fixture.log" | jget "['pid']")
[[ -n "$PID" ]] && pass "launched pid $PID" || { fail "launch"; exit 1; }
grep -q "input guard up" "$BACKSTAGE_HOME/daemon.log" && pass "the daemon's input guard is up" || fail "no input guard in the daemon log"
FIELD=$("$BS" find --pid "$PID" --role textfield | jget "['elements'][0]['ref']")
"$BS" set "$FIELD" "" --pid "$PID" >/dev/null; "$BS" focus "$FIELD" --pid "$PID" >/dev/null

echo "== untagged keys into the managed app"
"$WORK/untagged" "$PID" x
sleep 0.5
[[ -z "$(value)" ]] && pass "an ordinary process's untagged key was kept out" || fail "untagged key reached the managed app: field is '$(value)'"
"$CLAUDE_HELPER" "$PID" c
waitvalue c && pass "Claude computer-use helper's key landed" || fail "Claude helper's key: field is '$(value)', want 'c'"
"$CODEX_HELPER" "$PID" d
waitvalue cd && pass "Codex computer-use service's key landed" || fail "Codex helper's key: field is '$(value)', want 'cd'"
"$WORK/untagged" "$PID" y
sleep 0.5
[[ "$(value)" == "cd" ]] && pass "ordinary untagged keys are still kept out afterwards" || fail "field is '$(value)', want 'cd'"

echo "== untagged key into an app backstage doesn't manage"
"$WORK/keysink" "$WORK/sink.log" &
SINK=$!
for _ in $(seq 1 50); do grep -q ready "$WORK/sink.log" 2>/dev/null && break; sleep 0.1; done
grep -q ready "$WORK/sink.log" && pass "windowless key sink running (pid $SINK)" || fail "key sink didn't start"
"$WORK/untagged" "$SINK" k
for _ in $(seq 1 30); do grep -q "key k" "$WORK/sink.log" && break; sleep 0.1; done
grep -q "key k" "$WORK/sink.log" && pass "untagged key reached the unmanaged app" || fail "untagged key never reached the unmanaged app: $(cat "$WORK/sink.log")"

echo "== stop"
"$BS" stop >/dev/null && pass "stop" || fail "stop"
LINE=$(grep "input guard:" "$BACKSTAGE_HOME/daemon.log" | tail -1)
echo "  $LINE"
num() { printf '%s\n' "$LINE" | sed -nE "s/.* ([0-9]+) $1.*/\1/p"; }
# x and y from the ordinary poster (down + up each) and nothing else; c and d from the helpers.
[[ "$(num dropped)" == 4 ]] && pass "the guard dropped exactly the ordinary poster's 4 events (the unmanaged app's were untouched)" \
    || fail "dropped $(num dropped), want 4"
[[ "$(num 'redirected to')" == 0 ]] && pass "nothing was redirected to the user's app" || fail "redirected $(num 'redirected to'), want 0"
[[ "$(num 'from computer use')" == 4 ]] && pass "the guard let 4 computer-use events through" || fail "computer use let through: $(num 'from computer use'), want 4"
[ $FAIL = 0 ] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
