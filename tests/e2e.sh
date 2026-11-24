#!/bin/bash
# End-to-end test: drives a fixture app entirely through backstage while a watchdog asserts that
# nothing appears on the user's screens, the fixture stays in the background, and the cursor stays on a user display.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build)
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-e2e.XXXX)"
export BACKSTAGE_HOME="$WORK/state"
unset BACKSTAGE_SESSION
LOG="$WORK/fixture.log"
WATCH=
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -f "$BACKSTAGE_HOME/daemon.json" || -f "$BACKSTAGE_HOME/apps.json" ]]; then "$BS" stop --all || result=1; fi
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
python3 - "$WORK/status.json" <<'PYTHON'
import json, sys
status = json.load(open(sys.argv[1]))
if not status["ok"]:
    sys.exit("\n".join(status["problems"]))
PYTHON
FAIL=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
waitlog() { for i in $(seq 1 40); do grep -q "$1" "$LOG" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
count() { "$BS" find $A --role statictext --text "count:" | python3 -c "import sys,json; print(json.load(sys.stdin)['elements'][0]['value'].split(': ')[1])"; }
waitcount() { for i in $(seq 1 30); do [ "$(count)" = "$1" ] && return 0; sleep 0.1; done; return 1; }
jget() { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1"; }

echo "== build fixtures"
mkdir -p "$WORK/BackstageTestApp.app/Contents/MacOS"
swiftc -O TestApp.swift -o "$WORK/BackstageTestApp.app/Contents/MacOS/BackstageTestApp"
cat > "$WORK/BackstageTestApp.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageTestApp</string><key>CFBundleIdentifier</key><string>dev.backstage.testapp.${WORK##*.}</string><key>CFBundleName</key><string>BackstageTestApp</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
swiftc -O watch.swift -o "$WORK/watch"


"$WORK/watch" "dev.backstage.testapp.${WORK##*.}" 180 "$WORK/watch.stop" > "$WORK/watch.out" 2>&1 &
WATCH=$!
sleep 0.3

echo "== daemon startup"
# Started by bare name through PATH from a folder holding an unrelated `backstage` (a checkout):
# the daemon must be spawned from the running binary, not from ./backstage.
mkdir -p "$WORK/cwd/backstage"
D1=$(cd "$WORK/cwd" && PATH="$(dirname "$BS"):$PATH" "$(basename "$BS")" start | jget "['pid']")
D2=$("$BS" start | jget "['pid']")
[[ "$D1" == "$D2" ]] && pass "start reused daemon" || fail "daemon identity changed"

echo "== launch (rude app: self-activates + opens a popup window later)"
OUT=$("$BS" launch "$WORK/BackstageTestApp.app" --env TESTAPP_ACTIVATE=1 --env TESTAPP_POPUP=1 --env "TESTAPP_LOG=$LOG")
echo "$OUT"
PID=$(echo "$OUT" | jget "['pid']")
[ -n "$PID" ] && pass "launched pid $PID" || fail "launch"
A="--pid $PID"
LISTED=$("$BS" list | jget "['apps'][0]['pid']")
[[ "$LISTED" == "$PID" ]] && pass "list includes fixture" || fail "managed fixture missing"

echo "== screenshot"
S=$("$BS" screenshot $A -o "$WORK/s1.png"); echo "$S"
[ -s "$WORK/s1.png" ] && pass "screenshot written" || fail "screenshot"

echo "== tree / find"
"$BS" tree $A --window 0 
REF=$("$BS" find $A --role button --text Increment | jget "['elements'][0]['ref']")
FIELD=$("$BS" find $A --role textfield | jget "['elements'][0]['ref']")
[ -n "$REF" ] && pass "found Increment button at ref $REF" || fail "find button"

echo "== press x2 (AX)"
"$BS" press "$REF" $A >/dev/null; "$BS" press "$REF" $A >/dev/null
waitcount 2 && pass "AX press reached app" || fail "AX press"

echo "== click button by ref"
"$BS" click --ref "$REF" $A
waitcount 3 && pass "click by button ref" || fail "mouse click on button"

echo "== click custom view by coordinates (no AX element)"
PADXY=$("$BS" find $A --role window --text BackstageTestApp | python3 -c "import sys,json; f=json.load(sys.stdin)['elements'][0]['frame']; print(f['x']+100, f['y']+f['h']-40)")
"$BS" hover $PADXY $A >/dev/null
"$BS" click $PADXY $A
waitlog "pad click 1" && pass "coordinate click on custom view ($PADXY)" || fail "coordinate click on custom view"
"$BS" click $PADXY --double $A >/dev/null
waitlog "pad click .* count=2" && pass "double click" || fail "double click"
"$BS" scroll $PADXY --dy -40 $A >/dev/null
waitlog "pad scroll" && pass "scroll" || fail "scroll"
set -- $PADXY; X2=$(( $1 + 150 ))
"$BS" drag $1 $2 $X2 $2 $A >/dev/null
waitlog "pad drag steps=" && pass "drag ($(grep -o 'pad drag.*' "$LOG" | tail -1))" || fail "drag"
"$BS" click $PADXY --right $A >/dev/null
waitlog "pad right click" && pass "right click opened context menu" || fail "right click"
"$BS" screenshot $A -o "$WORK/menu.png" >/dev/null
"$BS" key esc $A >/dev/null
waitlog "context menu closed" && pass "esc closed context menu" || fail "esc closed context menu"
# A --scale 2 screenshot pixel is (2x, 2y) for point (x, y): the same click, given in 2x pixels.
CLICKS=$(grep -c "pad click" "$LOG")
"$BS" click $(( $1 * 2 )) $(( $2 * 2 )) --scale 2 $A >/dev/null
waitlog "pad click $(( CLICKS + 1 )) " \
    && [[ $(grep -o "pad click $(( CLICKS + 1 )) at [0-9,]*" "$LOG" | cut -d' ' -f5) == $(grep -o "pad click 1 at [0-9,]*" "$LOG" | cut -d' ' -f5) ]] \
    && pass "click --scale 2 at 2x pixels hit the same point" || fail "click --scale 2"

echo "== type + key"
"$BS" set "$FIELD" "hello" $A >/dev/null
"$BS" focus "$FIELD" $A >/dev/null
"$BS" key cmd+a $A >/dev/null
"$BS" type "typed in background" $A >/dev/null; waitlog "text=typed in background"
V=$("$BS" find $A --role textfield | jget "['elements'][0].get('value','')")
[ "$V" = "typed in background" ] && pass "type/key (value='$V')" || fail "type/key (value='$V')"

echo "== menu"
"$BS" menu "Actions > Increment" $A >/dev/null
waitcount 4 && pass "menu press" || fail "menu press"

echo "== raw mouse click on a standard button by coordinates"
BXY=$("$BS" find $A --role button --text Increment | python3 -c "import sys,json; f=json.load(sys.stdin)['elements'][0]['frame']; print(f['x']+f['w']//2, f['y']+f['h']//2)")
"$BS" click $BXY $A
waitcount 5 && pass "mouse click on NSButton ($BXY)" || fail "mouse click on NSButton"

"$BS" action "$REF" AXPress $A >/dev/null
waitcount 6 && pass "named accessibility action" || fail "AXPress action"

echo "== wait for popup window (opened by app after 2s, must be pulled onto agent display)"
"$BS" wait --text Popup --role window --timeout 8 $A >/dev/null && pass "popup appeared" || fail "popup wait"
sleep 0.5
"$BS" windows $A
"$BS" screenshot $A -o "$WORK/s2.png" >/dev/null && pass "screenshot 2"

echo "== screenshot formats and dimensions"
"$BS" status > "$WORK/live-status.json"
"$BS" windows $A > "$WORK/windows.json"
MAIN_REF=$(python3 - "$WORK/windows.json" <<'PYTHON'
import json, sys
print(next(w["ref"] for w in json.load(open(sys.argv[1]))["windows"] if w["title"] == "BackstageTestApp"))
PYTHON
)
"$BS" screenshot $A --window "$MAIN_REF" --scale 0.5 -o "$WORK/scaled.png" > "$WORK/scaled.json"
"$BS" screenshot $A --window "$MAIN_REF" -o "$WORK/window.jpg" > "$WORK/window.json"
"$BS" screenshot $A --window "$MAIN_REF" --scale 2 -o "$WORK/retina.png" > "$WORK/retina.json"
"$BS" screenshot --full -o "$WORK/full.png" > "$WORK/full.json"
python3 - "$WORK" <<'PYTHON'
import json, pathlib, re, subprocess, sys
work = pathlib.Path(sys.argv[1])
def record(name):
    return json.loads((work / (name + ".json")).read_text())
frame = next(w["frame"] for w in record("windows")["windows"] if w["title"] == "BackstageTestApp")
display = record("live-status")["daemon"]["size"]
# The agent display is Retina unless BACKSTAGE_SCALE=1: same points, twice the pixels.
daemon = record("live-status")["daemon"]
backing = int(__import__("os").environ.get("BACKSTAGE_SCALE", "2"))
assert daemon["scale"] == backing and daemon["pixels"] == {"w": display["w"] * backing, "h": display["h"] * backing}, daemon
# Its size in points is the main display's, unless BACKSTAGE_WIDTH/HEIGHT set one.
env = __import__("os").environ
assert daemon["sizeSource"] == ("env" if "BACKSTAGE_WIDTH" in env or "BACKSTAGE_HEIGHT" in env else "main display"), daemon
for name, extension, scale, bounds in [("scaled", "png", 0.5, frame), ("window", "jpg", 1, frame), ("retina", "png", 2, frame),
                                       ("full", "png", 1, display)]:
    path = work / (name + "." + extension)
    signature = b"\x89PNG\r\n\x1a\n" if extension == "png" else b"\xff\xd8\xff"
    with path.open("rb") as image:
        assert image.read(len(signature)) == signature, f"{path}: invalid {extension} signature"
    props = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)], text=True)
    dimensions = tuple(int(re.search(rf"pixel{axis}: (\d+)", props)[1]) for axis in ("Width", "Height"))
    expected = tuple(int(bounds[axis] * scale + 0.5) for axis in ("w", "h"))
    result = record(name)
    assert dimensions == expected == (result["width"], result["height"]), (path, dimensions, expected, result)
    assert result["scale"] == scale and pathlib.Path(result["path"]).samefile(path), result
PYTHON
pass "display is ${BACKSTAGE_SCALE:-2}x; scaled PNG, window JPEG, 2x PNG and full display PNG match expected dimensions"

echo "== window size / fill"
"$BS" window size 600 420 --window "$MAIN_REF" $A > "$WORK/wsize.json"
"$BS" window fill --window "$MAIN_REF" $A > "$WORK/wfill.json"
"$BS" screenshot $A --scale 2 -o "$WORK/filled.png" > "$WORK/filled.json"
python3 - "$WORK" <<'PYTHON'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
record = lambda name: json.loads((work / (name + ".json")).read_text())
display = record("live-status")["daemon"]["size"]
size, fill, shot = record("wsize"), record("wfill"), record("filled")
assert size["ok"] and "note" not in size and (size["frame"]["w"], size["frame"]["h"]) == (600, 420), size
f = fill["frame"]
# The whole display below its own menu bar.
assert fill["ok"] and "note" not in fill and f["x"] == 0 and 0 < f["y"] < 60 and f["w"] == display["w"] \
    and f["y"] + f["h"] == display["h"], fill
# A default screenshot runs from (0,0) to the window's bottom-right corner: the whole display.
assert (shot["width"], shot["height"]) == (display["w"] * 2, display["h"] * 2), shot
PYTHON
pass "window size 600x420, then fill: $(jq -c .frame "$WORK/wfill.json")"
if BACKSTAGE_SESSION=e2e-other "$BS" window fill $A > "$WORK/wforeign.json"; then fail "another session resized our window"
else grep -q "another backstage session" "$WORK/wforeign.json" && pass "window fill refuses another session's app" || fail "window fill (foreign)"; fi

echo "== logs"
"$BS" logs $A | grep -q "fixture stdout hello" && pass "logs captured app stdout" || fail "logs"

# backstage's one "you're active" event, plus the fixture's own activate(): macOS refuses that for
# a regular background app, but this one starts as a UIElement (no Dock tile), which may activate
# itself. Then the daemon must have handed focus straight back (the watchdog checks the rest).
N=$(grep -c "became active" "$LOG" || true)
if [ "$N" = 1 ]; then pass "app saw one activation"
elif [ "$N" = 2 ] && grep -q "managed app $PID took focus; handing focus back" "$BACKSTAGE_HOME/daemon.log"; then
    pass "app saw two activations: its own activate(), which the daemon handed back, and backstage's"
else fail "app saw $N activations (expected 1, or 2 with a focus hand-back)"; fi

echo "== quit"
[[ $("$BS" quit $A | jget "['ok']") == True ]]

echo "== bare executable in a quoted path"
BARE_DIR="$WORK/Fixture's directory"
BARE="$BARE_DIR/Bare fixture"
mkdir "$BARE_DIR"
cp "$WORK/BackstageTestApp.app/Contents/MacOS/BackstageTestApp" "$BARE"
BARE_OUT=$("$BS" launch "$BARE" --timeout 0 --env TESTAPP_BARE=1 --env "TESTAPP_LOG=$WORK/bare.log" -- "argument with a 'quote'") || { echo "$BARE_OUT" >&2; exit 1; }
echo "$BARE_OUT"
BARE_PID=$(echo "$BARE_OUT" | jget "['pid']")
grep -Fx "pid=$BARE_PID" "$WORK/bare.log"
grep -Fx "argument=argument with a 'quote'" "$WORK/bare.log"
# LaunchServices runs it directly (no exec'ing shim, which would give it a Dock tile), so it starts in /.
BARE_CWD=$(sed -n 's/^cwd=//p' "$WORK/bare.log")
[[ "$BARE_CWD" == / ]]
[[ $(echo "$BARE_OUT" | jget "['dock']") == hidden ]]
[[ $("$BS" quit --pid "$BARE_PID" | jget "['ok']") == True ]]
pass "bare executable ran in / with its exact argument, hidden from the Dock"

echo "== second instance: popup uses center() instead of fixed coordinates"
OUT2=$("$BS" launch "$WORK/BackstageTestApp.app" --env TESTAPP_POPUP=1 --env "TESTAPP_LOG=$LOG" --env TESTAPP_POPUP_CENTER=1)
P2=$(echo "$OUT2" | jget "['pid']")
"$BS" wait --text Popup --role window --timeout 8 --pid $P2 >/dev/null && pass "centered popup appeared" || fail "centered popup"

echo "== stop daemon while an app is still running (teardown must not spill onto the screen)"
[[ $("$BS" stop | jget "['ok']") == True ]]
sleep 1
kill -0 $P2 2>/dev/null && fail "app still running after stop" || pass "stop quit the managed app"
touch "$WORK/watch.stop"
wait "$WATCH" || fail "watchdog detected interference"
WATCH=
cat "$WORK/watch.out"
grep -q PASS "$WORK/watch.out" && pass "non-interference watchdog" || fail "non-interference watchdog"
[ $FAIL = 0 ] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
