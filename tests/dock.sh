#!/bin/bash
# Dock test: apps `backstage launch` starts get no Dock tile (and no ⌘-Tab entry), sampled from the
# Dock's own accessibility tree for the whole time they run; an app that makes itself a regular app
# is reported; `--dock` opts out; and the restore `show` runs gives a hidden app its tile back.
# The restore is tested through `backstage __dock-restore`, which runs show's restore without
# moving the app's windows to the user's screen or activating it.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && swift build -c release)
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-dock.XXXX)"
export BACKSTAGE_HOME="$WORK/state"
TAG="${WORK##*.}"
NAME="BackstageDock$TAG"
BARE_NAME="BackstageDockBare$TAG"
WATCH=
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -n "$WATCH" ]]; then touch "$WORK/watch.stop"; wait "$WATCH" || true; fi
    if [[ -f "$BACKSTAGE_HOME/daemon.json" ]]; then "$BS" stop > /dev/null || result=1; fi
    # LaunchServices registered the fixture and the bare executable's wrapper: forget them.
    local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    for bundle in "$WORK/$NAME.app" "$BACKSTAGE_HOME"/wrappers/*.app; do
        [[ -d "$bundle" ]] && "$lsregister" -u "$bundle" > /dev/null 2>&1 || true
    done
    echo "artifacts: $WORK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
FAIL=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
jget() { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1"; }

echo "== build fixtures"
mkdir -p "$WORK/$NAME.app/Contents/MacOS" "$WORK/bare"
swiftc -O TestApp.swift -o "$WORK/$NAME.app/Contents/MacOS/$NAME"
cat > "$WORK/$NAME.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$NAME</string><key>CFBundleIdentifier</key><string>dev.backstage.docktest.$TAG</string><key>CFBundleName</key><string>$NAME</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
cp "$WORK/$NAME.app/Contents/MacOS/$NAME" "$WORK/bare/$BARE_NAME"
swiftc -O dockwatch.swift -o "$WORK/dockwatch"
APP="$WORK/$NAME.app"

"$WORK/dockwatch" watch "$NAME" "$BARE_NAME" --stop "$WORK/watch.stop" --max 300 > "$WORK/watch.out" 2>&1 &
WATCH=$!
for _ in $(seq 1 50); do grep -q watching "$WORK/watch.out" 2>/dev/null && break; sleep 0.1; done

echo "== launch: no Dock tile, ever"
OUT=$("$BS" launch "$APP" --env TESTAPP_POLICY=none --env "TESTAPP_LOG=$WORK/app.log")
PID=$(echo "$OUT" | jget "['pid']")
DOCK=$(echo "$OUT" | jget "['dock']")
[[ "$DOCK" == hidden ]] && pass "launch reports dock: hidden" || fail "launch reports dock: $DOCK"
TYPE=$("$WORK/dockwatch" type "$PID")
[[ "$TYPE" == UIElement ]] && pass "LaunchServices type is UIElement" || fail "LaunchServices type is $TYPE"
[[ $(echo "$OUT" | jget "['windows'][0]['title']") == BackstageTestApp ]] && pass "window placed on the agent display" || fail "no window"
REF=$("$BS" find --pid "$PID" --role button --text Increment | jget "['elements'][0]['ref']")
"$BS" press "$REF" --pid "$PID" > /dev/null && "$BS" click --ref "$REF" --pid "$PID" > /dev/null \
    && "$BS" screenshot --pid "$PID" -o "$WORK/hidden.png" > /dev/null && pass "find, press, click and screenshot work" || fail "driving the app"
"$BS" menu "Actions > Increment" --pid "$PID" > /dev/null && pass "menu works" || fail "menu"
sleep 1
[[ $("$WORK/dockwatch" type "$PID") == UIElement ]] && pass "still a UIElement after input" || fail "type changed after input"
"$BS" quit --pid "$PID" > /dev/null

echo "== bare executable: no Dock tile, starts in /"
OUT=$("$BS" launch "$WORK/bare/$BARE_NAME" --env TESTAPP_POLICY=none --env "TESTAPP_LOG=$WORK/bare.log" -- "an argument")
BPID=$(echo "$OUT" | jget "['pid']")
[[ $(echo "$OUT" | jget "['dock']") == hidden && $("$WORK/dockwatch" type "$BPID") == UIElement ]] \
    && pass "bare executable is hidden from the Dock" || fail "bare executable: $(echo "$OUT" | jget "['dock']") / $("$WORK/dockwatch" type "$BPID")"
[[ $(echo "$OUT" | jget "['windows'][0]['title']") == BackstageTestApp ]] \
    && pass "bare executable's window placed" || fail "bare executable has no window"
"$BS" quit --pid "$BPID" > /dev/null

touch "$WORK/watch.stop"; wait "$WATCH"; WATCH=
cat "$WORK/watch.out"
grep -q "^shows=0 " "$WORK/watch.out" && pass "no Dock tile appeared while the apps ran" || fail "a Dock tile appeared"

echo "== restore (what show does before activating)"
OUT=$("$BS" launch "$APP" --env TESTAPP_POLICY=none --env "TESTAPP_LOG=$WORK/app.log")
PID=$(echo "$OUT" | jget "['pid']")
R=$("$BS" __dock-restore --pid "$PID")
[[ $(echo "$R" | jget "['dock']") == restored && $(echo "$R" | jget "['type']") == Foreground ]] \
    && pass "restore: $(echo "$R" | jget "['dock']") ($(echo "$R" | jget "['type']"))" || fail "restore: $R"
for _ in $(seq 1 30); do [[ $("$WORK/dockwatch" has "$NAME") == yes ]] && break; sleep 0.1; done
[[ $("$WORK/dockwatch" has "$NAME") == yes ]] && pass "Dock tile appeared after restore" || fail "no Dock tile after restore"
"$BS" quit --pid "$PID" > /dev/null

echo "== self-promoting app is reported"
OUT=$("$BS" launch "$APP" --env "TESTAPP_LOG=$WORK/app.log")
PID=$(echo "$OUT" | jget "['pid']")
DOCK=$(echo "$OUT" | jget "['dock']")
[[ "$DOCK" == "visible (app made itself a regular app)" ]] && pass "launch reports: $DOCK" || fail "launch reports: $DOCK"
[[ $("$BS" __dock-restore --pid "$PID" | jget "['dock']") == visible ]] && pass "restore leaves it visible" || fail "restore of a regular app"
"$BS" quit --pid "$PID" > /dev/null

echo "== --dock opts out"
OUT=$("$BS" launch "$APP" --dock --env TESTAPP_POLICY=none --env "TESTAPP_LOG=$WORK/app.log")
PID=$(echo "$OUT" | jget "['pid']")
[[ $(echo "$OUT" | jget "['dock']") == "visible (--dock)" && $("$WORK/dockwatch" type "$PID") == Foreground ]] \
    && pass "--dock launches a regular app" || fail "--dock: $(echo "$OUT" | jget "['dock']") / $("$WORK/dockwatch" type "$PID")"
"$BS" quit --pid "$PID" > /dev/null

[[ $("$BS" stop | jget "['ok']") == True ]]
[ $FAIL = 0 ] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
