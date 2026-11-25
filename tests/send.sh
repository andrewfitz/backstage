#!/bin/bash
# Send Front Window Backstage and Keep in Menu Bar, without touching the user's screen.
# - The hotkey: registered (daemon log, `status`), re-registered on a settings change without a
#   restart, and a combo another process holds is reported. Nothing is pressed or synthesized.
# - The send path, on a fixture this script opens hidden and in the background itself
#   (LaunchServices' launch-and-hide; it has a Dock tile, like any app you send). The daemon's
#   own path (child process, result, tooltip confirmation) runs through its test trigger
#   (BACKSTAGE_TEST_SEND_REQUESTS: a given pid instead of the frontmost app); refusals run
#   through `backstage __send-backstage --pid P`, the same function the daemon's child calls.
#   Checked: registered to the "user" owner, windows on the agent display, tap muted, focus left
#   alone (the fixture was never frontmost), and refusals (already managed, backstage itself, not
#   an app, a refused bundle ID). A watchdog checks the fixture never reaches a user display or
#   becomes frontmost. The focus handoff and the frontmost-app pick need a real frontmost app
#   and the hotkey a real key press, so they aren't exercised here.
# - Ownership: a session's plain `stop` leaves the sent app; another session reaches it with
#   --pid; `stop --all` quits it.
# - Keep in Menu Bar: the daemon's status item (read through accessibility, never pressed) is
#   shown with no apps and no count while it's on, hidden when it's off; the daemon doesn't
#   idle-exit while it's on, and does once it's turned off.
set -euo pipefail
# backstage's own tests use displays 7-8, never the ones agents use (docs/MULTI_DISPLAY_PLAN.md).
export BACKSTAGE_DISPLAY=${BACKSTAGE_DISPLAY:-7}
export BACKSTAGE_EXTRA_DISPLAYS=8   # Send Front Window To / Move to a new display take 8
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build)
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-send.XXXX)"
export BACKSTAGE_HOME="$WORK/state"
export BACKSTAGE_SESSION=send-test
export BACKSTAGE_TEST_HOOKS=1
export BACKSTAGE_IDLE_TIMEOUT=3
TAG="${WORK##*.}"
NAME="BackstageSend$TAG"
BID="dev.backstage.sendtest.$TAG"
RNAME="BackstageSendRefused$TAG"
RBID="dev.backstage.sendtest-refuse.$TAG"
# Test-only: one more bundle-ID prefix the send path refuses (it reads this in the hook process).
export BACKSTAGE_TEST_REFUSE=dev.backstage.sendtest-refuse
WATCH= HOLD= PID= RPID= SLEEPER= PID2=
cleanup() {
    local result=$?
    trap - EXIT
    [[ -n "$HOLD" ]] && { touch "$WORK/hold.stop"; wait "$HOLD" 2>/dev/null || true; }
    if [[ -n "$SLEEPER" && " $(jobs -pr | tr '\n' ' ') " == *" $SLEEPER "* ]]; then
        kill "$SLEEPER" 2>/dev/null || true
        wait "$SLEEPER" 2>/dev/null || true
    fi
    if [[ -f "$BACKSTAGE_HOME/daemon.json" || -f "$BACKSTAGE_HOME/apps.json" ]]; then "$BS" stop --all > /dev/null || result=1; fi
    if [[ -n "$PID" ]]; then "$WORK/sendhelper" terminate "$PID" "$WORK/$NAME.app" || result=1; fi
    if [[ -n "$RPID" ]]; then "$WORK/sendhelper" terminate "$RPID" "$WORK/$RNAME.app" || result=1; fi
    if [[ -n "$PID2" ]]; then "$WORK/sendhelper" terminate "$PID2" "$WORK/$NAME2.app" || result=1; fi
    if [[ -n "$WATCH" ]]; then
        touch "$WORK/watch.stop"
        wait "$WATCH" || result=1
        tail -5 "$WORK/watch.out"
    fi
    local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    for bundle in "$WORK/$NAME.app" "$WORK/$RNAME.app" "$WORK/${NAME2:-none}.app"; do
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
note() { echo "  note $*"; }
items() { "$WORK/sendhelper" items "$(jq -r .pid "$BACKSTAGE_HOME/daemon.json")"; }
# Wait (up to 4 s) for the daemon's status item count to be $1.
wait_items() { for _ in $(seq 1 40); do [[ $(items | jq '.items | length') == "$1" ]] && return 0; sleep 0.1; done; return 1; }
waitlog() { for _ in $(seq 1 50); do grep -q "$1" "$2" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

echo "== build fixtures"
NAME2="${NAME}Two"
for pair in "$NAME:$BID" "$RNAME:$RBID" "$NAME2:$BID.two"; do
    n=${pair%%:*} id=${pair#*:}
    mkdir -p "$WORK/$n.app/Contents/MacOS"
    swiftc -O TestApp.swift -o "$WORK/$n.app/Contents/MacOS/$n"
    cat > "$WORK/$n.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$n</string><key>CFBundleIdentifier</key><string>$id</string><key>CFBundleName</key><string>$n</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
done
swiftc -O sendhelper.swift -o "$WORK/sendhelper" || exit 1
swiftc -O watch.swift -o "$WORK/watch" || exit 1
swiftc -O audioprobe.swift -o "$WORK/audioprobe" || exit 1
# An output-only device for the fixture's silent tone (it makes the fixture a Core Audio client,
# so it gets a tap; a device with inputs would make macOS ask for the Microphone).
"$WORK/audioprobe" devices > "$WORK/devices.json"
DEV=$(jq -r '([.[] | select(.out > 0 and .in == 0 and .default)] + [.[] | select(.out > 0 and .in == 0)])[0].uid // empty' "$WORK/devices.json")

. ./watch.sh
start_watch "$BID" 120 || exit 1

echo "== a macOS keyboard shortcut is refused as the hotkey (checked before any daemon runs)"
# ⌘⇧3 (screenshot) is enabled on most Macs. With no daemon, nothing is registered either way.
if R=$("$BS" settings hotkey cmd+shift+3 2>&1); then
    note "⌘⇧3 isn't an enabled macOS shortcut here (or wasn't detected): $(echo "$R" | jq -c '{hotkey}')"
else
    echo "$R" | jq -e '.error | test("macOS keyboard shortcut")' > /dev/null && pass "⌘⇧3 refused: $(echo "$R" | jq -r .error)" || fail "⌘⇧3: $R"
fi

echo "== daemon with Keep in Menu Bar on and the hotkey set"
"$BS" settings keep-in-menu-bar on > /dev/null
"$BS" settings hotkey default | jq -e '.hotkey == "ctrl+opt+cmd+b" and .daemon == "not running"' > /dev/null \
    && pass "settings saved before the daemon starts" || fail "settings before start"
# The daemon runs without BACKSTAGE_TEST_HOOKS (its child passes the parent-is-daemon gate
# alone), with the test trigger that sends a given pid through its own path.
DPID=$(env -u BACKSTAGE_TEST_HOOKS BACKSTAGE_TEST_SEND_REQUESTS=1 "$BS" start | jq -r .pid)
LOG="$BACKSTAGE_HOME/daemon.log"
waitlog "hotkey: ⌃⌥⌘B registered for Send Front Window Backstage" "$LOG" && pass "hotkey ⌃⌥⌘B registered (daemon log)" \
    || { fail "hotkey not registered"; grep hotkey "$LOG" || true; }
"$BS" status | jq -e '.settings.hotkeyRegistered == true and .settings.keepInMenuBar == true' > /dev/null \
    && pass "status shows the hotkey registered and Keep in Menu Bar on" || fail "status settings: $("$BS" status | jq -c .settings)"
wait_items 1 && pass "status item shown with no apps running" || fail "status item not shown with Keep in Menu Bar: $(items)"
items | jq -e '.items[0] | (.title // "") | test("[0-9]") | not' > /dev/null \
    && pass "no count beside the icon with 0 apps" || fail "count shown with 0 apps: $(items)"
echo "== hotkey: re-registered on change, and a combo another app holds is reported"
"$BS" settings hotkey cmd+opt+f8 | jq -e '.hotkey == "opt+cmd+f8" and .hotkeyRegistered == true' > /dev/null \
    && pass "changed to ⌥⌘F8 without a restart" || fail "re-register: $("$BS" settings | jq -c .)"
# F9 with ⌃⌥⌘ (Carbon: controlKey|optionKey|cmdKey = 0x1900), held by another process.
"$WORK/sendhelper" hold 101 6400 "$WORK/hold.stop" > "$WORK/hold.out" &
HOLD=$!
waitlog "held\|failed" "$WORK/hold.out" || true
if grep -q held "$WORK/hold.out"; then
    R=$("$BS" settings hotkey ctrl+opt+cmd+f9)
    if echo "$R" | jq -e '.hotkeyRegistered == false and (.hotkeyError | test("already taken"))' > /dev/null; then
        pass "a combo another process holds is refused and reported"
        grep -q "hotkey: not registered: ⌃⌥⌘F9 is already taken" "$LOG" && pass "and logged" || fail "conflict not logged"
    else
        note "RegisterEventHotKey accepted ⌃⌥⌘F9 although another process holds it: $R"
    fi
else
    note "the helper couldn't hold ⌃⌥⌘F9: $(cat "$WORK/hold.out")"
fi
touch "$WORK/hold.stop"; wait "$HOLD" 2>/dev/null || true; HOLD=
"$BS" settings hotkey default | jq -e '.hotkeyRegistered == true' > /dev/null && pass "back to ⌃⌥⌘B" || fail "back to default"
# For the rest of the run, a combo nobody presses by accident: a ⌃⌥⌘B press would send the
# user's frontmost app to this test display.
"$BS" settings hotkey ctrl+opt+shift+cmd+f7 > /dev/null
sleep 4
kill -0 "$DPID" 2>/dev/null && pass "no idle exit while Keep in Menu Bar is on (idle timeout 3 s)" || fail "daemon idle-exited with Keep in Menu Bar on"

echo "== send a hidden fixture backstage through the daemon's path (what the hotkey and menu run)"
PID=$("$WORK/sendhelper" launch "$WORK/$NAME.app" "TESTAPP_LOG=$WORK/app.log" TESTAPP_POLICY=none \
    ${DEV:+TESTAPP_TONE=19000 TESTAPP_TONE_SILENT=1 "TESTAPP_TONE_DEVICE=$DEV"})
waitlog "launched" "$WORK/app.log" || fail "fixture didn't start"
sleep 0.5
# The daemon's test trigger: it sends this pid as if it were the frontmost app (child process,
# result, cue), instead of reading the frontmost app.
echo "$PID" > "$BACKSTAGE_HOME/send-request"
waitlog "send backstage: sent pid $PID " "$LOG" && pass "the daemon's child sent it: $(grep "send backstage: sent pid $PID " "$LOG" | sed 's/.*send backstage: //')" \
    || { fail "the daemon didn't send it"; grep "send backstage" "$LOG" || true; }
grep -q "send backstage (test): pid $PID " "$LOG" && pass "through sendFrontWindowBackstage" || fail "daemon path not logged"
grep "send backstage: sent pid $PID " "$LOG" | grep -q "focus unchanged" && pass "focus left alone (the fixture was never frontmost)" || fail "focus changed"
SIZE=$("$BS" status | jq -c .daemon.size)
OUT=$(BACKSTAGE_SESSION=send-other "$BS" windows --pid "$PID")
echo "$OUT" | jq -e --argjson s "$SIZE" '(.windows | length) > 0 and all(.windows[]; .frame.x >= 0 and .frame.y >= 0
        and .frame.x + .frame.w <= $s.w and .frame.y + .frame.h <= $s.h)' > /dev/null \
    && pass "its windows are on the agent display (and another session reaches it with --pid)" || fail "windows: $(echo "$OUT" | jq -c .windows) (display $SIZE)"
for _ in $(seq 1 20); do items | jq -e '.items[0].help // "" | test("Sent .* backstage")' > /dev/null && break; sleep 0.1; done
items | jq -e '.items[0].help // "" | test("Sent .* backstage")' > /dev/null \
    && pass "quiet confirmation in the tooltip: $(items | jq -r '.items[0].help' | tail -1)" || fail "no confirmation: $(items)"
"$BS" list --all | jq -e --argjson p "$PID" '.apps | map(select(.pid == $p and .session == "user" and .audio == "muted")) | length == 1' > /dev/null \
    && pass "list --all shows it under session \"user\"" || fail "list --all"
if [[ -n "$DEV" ]]; then
    TAP=
    for _ in $(seq 1 30); do TAP=$("$BS" list --all | jq -r --argjson p "$PID" '.apps[] | select(.pid == $p) | .tap // empty'); [[ "$TAP" == muted ]] && break; sleep 0.1; done
    [[ "$TAP" == muted ]] && pass "its audio tap is muted" || fail "tap: ${TAP:-none}"
else
    note "no output-only audio device: the tap check is skipped"
fi
"$BS" list | jq -e --argjson p "$PID" '.sentByUser[0].pid == $p and (.apps | length) == 0' > /dev/null \
    && pass "a session's own list names it under sentByUser only" || fail "list: $("$BS" list | jq -c .)"
for _ in $(seq 1 20); do items | jq -e '.items[0].title // "" | test("1")' > /dev/null && break; sleep 0.1; done
items | jq -e '.items | length == 1' > /dev/null && pass "status item shows: $(items | jq -c '.items[0] | {title, description}')" || fail "status item: $(items)"

echo "== displays: Send Front Window To, Move to, and an agent's move of a sent app"
PID2=$("$WORK/sendhelper" launch "$WORK/$NAME2.app" "TESTAPP_LOG=$WORK/app2.log" TESTAPP_POLICY=none)
waitlog "launched" "$WORK/app2.log" || fail "second fixture didn't start"
sleep 0.5
echo "$PID2 new" > "$BACKSTAGE_HOME/send-request"   # the menu's Send Front Window To > New Display
waitlog "send backstage: sent pid $PID2 " "$LOG" || fail "Send Front Window To didn't send it"
on_display() { "$BS" list --all | jq -r --argjson p "$1" '.apps[] | select(.pid == $p) | .display'; }
in_bounds() { BACKSTAGE_SESSION=send-other "$BS" windows --pid "$1" | jq -e --argjson s "$SIZE" '(.windows | length) > 0 and all(.windows[];
        .frame.x >= 0 and .frame.y >= 0 and .frame.x + .frame.w <= $s.w and .frame.y + .frame.h <= $s.h)' > /dev/null; }
[[ $(on_display "$PID2") == 8 ]] && in_bounds "$PID2" && pass "Send Front Window To > New Display put it on display 8" \
    || fail "send to new display: display $(on_display "$PID2"), $(BACKSTAGE_SESSION=send-other "$BS" windows --pid "$PID2" | jq -c .windows)"
"$BS" status | jq -e '.daemon.displays[] | select(.display == 8) | .reservedBy == "user"' > /dev/null \
    && pass "display 8 is kept for the user" || fail "display 8 reservation: $("$BS" status | jq -c .daemon.displays)"
echo "$PID 8" > "$BACKSTAGE_HOME/move-request"     # the menu's Move to > Display 8
for _ in $(seq 1 50); do [[ -f "$BACKSTAGE_HOME/move-result" ]] && break; sleep 0.1; done
[[ $(cat "$BACKSTAGE_HOME/move-result" 2>/dev/null) == ok && $(on_display "$PID") == 8 ]] && in_bounds "$PID" \
    && pass "Move to > Display 8 moved the first sent app there" || fail "menu move: $(cat "$BACKSTAGE_HOME/move-result" 2>/dev/null), display $(on_display "$PID")"
rm -f "$BACKSTAGE_HOME/move-result"
OUT=$(BACKSTAGE_SESSION=send-other "$BS" move --pid "$PID" --display 7 2>&1 || true)
[[ $(echo "$OUT" | jq -r .display) == 7 && $(on_display "$PID") == 7 ]] && in_bounds "$PID" \
    && pass "an agent moved a sent app back to display 7 with move --pid" || fail "agent move: $OUT"
OUT8=$(BACKSTAGE_SESSION=send-other "$BS" move --pid "$PID" --display 8 2>&1 || true)
echo "$OUT8" | jq -e '.ok == false and (.error | test("reserved"))' > /dev/null \
    && pass "but can't move it onto the user's own display 8: $(echo "$OUT8" | jq -r .error)" || fail "agent onto the user's display: $OUT8"
"$WORK/sendhelper" terminate "$PID2" "$WORK/$NAME2.app" && PID2= || fail "quit second fixture"

echo "== refusals"
refusal() { "$BS" __send-backstage --pid "$1" | jq -r '.refused // "NOT REFUSED"' || true; }
R=$(refusal "$PID"); [[ "$R" == *"already backstage"* ]] && pass "already managed: $R" || fail "already managed: $R"
R=$(refusal "$DPID"); [[ "$R" == *"backstage itself"* ]] && pass "the daemon: $R" || fail "the daemon: $R"
/bin/sleep 60 & SLEEPER=$!
R=$(refusal "$SLEEPER"); [[ "$R" == *"no app"* ]] && pass "not an app: $R" || fail "not an app: $R"
kill "$SLEEPER" 2>/dev/null || true; wait "$SLEEPER" 2>/dev/null || true; SLEEPER=
RPID=$("$WORK/sendhelper" launch "$WORK/$RNAME.app" "TESTAPP_LOG=$WORK/refused.log" TESTAPP_POLICY=none)
waitlog "launched" "$WORK/refused.log" || fail "refused fixture didn't start"
R=$(refusal "$RPID"); [[ "$R" == *"you need it on your screen"* ]] && pass "refused bundle ID: $R" || fail "refused bundle ID: $R"
"$BS" list --all | jq -e --argjson p "$RPID" '.apps | map(select(.pid == $p)) | length == 0' > /dev/null \
    && pass "the refused app wasn't registered" || fail "refused app registered"
"$WORK/sendhelper" terminate "$RPID" "$WORK/$RNAME.app" && RPID= || fail "quit refused fixture"
grep -q "send backstage: refused pid $DPID" "$LOG" && pass "refusals are logged" || fail "refusal not logged"

echo "== ownership"
BACKSTAGE_SESSION=send-other "$BS" windows --pid "$PID" | jq -e '.windows | length > 0' > /dev/null \
    && pass "another session reaches it with --pid" || fail "explicit --pid from another session"
BACKSTAGE_SESSION=send-other "$BS" windows > /dev/null 2>&1 && fail "it became a default target" || pass "it's no session's default target"
S=$("$BS" stop)
echo "$S" | jq -e '.quit == [] and (.daemon | test("user sent backstage"))' > /dev/null && kill -0 "$PID" \
    && pass "plain stop leaves it: $(echo "$S" | jq -r .daemon)" || fail "plain stop: $S"
"$BS" settings keep-in-menu-bar off > /dev/null
sleep 1
items | jq -e '.items | length == 1' > /dev/null && pass "with an app running the item stays when Keep is turned off" || fail "item hidden with an app running"
"$BS" stop --all | jq -e '.ok' > /dev/null && pass "stop --all" || fail "stop --all"
for _ in $(seq 1 30); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$PID" 2>/dev/null; then fail "stop --all left the sent app running"
else pass "stop --all quit the sent app"; PID=; fi

echo "== Keep in Menu Bar off: hidden with no apps, then idle exit"
DPID=$("$BS" start | jq -r .pid)
sleep 1
wait_items 0 && pass "no status item with no apps and Keep off" || fail "item shown with Keep off: $(items)"
"$BS" settings keep-in-menu-bar on > /dev/null
wait_items 1 && pass "turning Keep on shows it at once (no restart)" || fail "Keep on didn't show the item"
"$BS" settings keep-in-menu-bar off > /dev/null
wait_items 0 && pass "turning Keep off hides it" || fail "Keep off didn't hide the item"
for _ in $(seq 1 80); do kill -0 "$DPID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$DPID" 2>/dev/null && fail "daemon didn't idle-exit after Keep was turned off" || pass "idle exit resumed once Keep was off"

touch "$WORK/watch.stop"
wait "$WATCH" || fail "watchdog detected interference"
WATCH=
tail -5 "$WORK/watch.out"
grep -q PASS "$WORK/watch.out" && pass "non-interference watchdog" || fail "non-interference watchdog"
[ $FAIL = 0 ] && echo "ALL PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
