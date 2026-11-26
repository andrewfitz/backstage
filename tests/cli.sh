#!/bin/bash
# Run against a private state directory and a test-owned, windowless process.
set -eu
# backstage's own tests use displays 7-8, never the ones agents use (docs/MULTI_DISPLAY_PLAN.md).
export BACKSTAGE_DISPLAY=${BACKSTAGE_DISPLAY:-7}
cd "$(dirname "$0")/.."
bin=${BACKSTAGE_BIN:-.build/release/backstage}
work=$(mktemp -d)
export BACKSTAGE_HOME="$work/state"
export BACKSTAGE_SESSION=backstage-cli-test
unset BACKSTAGE_INAUDIBLE_DYLIB
mkdir "$BACKSTAGE_HOME"
/bin/sleep 300 &
child=$!
cleanup() {
    if [[ -n "$child" ]]; then
        # shellcheck disable=SC2086 # one PID, or several separated by spaces
        kill $child 2>/dev/null || :
        wait $child 2>/dev/null || :
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

reject() {
    local expected=$1 code=0
    shift
    "$bin" "$@" > "$work/result" || code=$?
    if [[ $code != 1 ]] || ! jq -e --arg pattern "$expected" \
        '.ok == false and (.error | test($pattern; "i"))' "$work/result" >/dev/null; then
        echo "Expected a JSON error matching '$expected' for $* (exit $code)" >&2
        cat "$work/result" >&2
        exit 1
    fi
}

reject 'parent daemon' __menu-thumbnail 1 0 640 360
reject 'thumbnail dimensions' __menu-thumbnail 1 0 641 360
reject 'pid' quit --pid xyz
reject 'pid' quit --pid 2147483648
reject 'pid' quit --pid
reject 'unknown command' invalid-command extra
reject 'needs a value' find --text -h
reject 'needs a value' screenshot --scale -o screenshot.png
reject 'lines' logs --lines -1
reject 'scale' screenshot --scale nan
reject 'steps' drag 0 0 10 10 --steps 0
reject 'steps.*1000' drag 0 0 10 10 --steps 1001
reject 'coordinates' click inf 5
reject 'coordinates' hover unparseable 0
reject 'coordinates' scroll 1e308 0 --scale 0.1
reject 'coordinates' drag 0 0 nan 10
reject 'dy' scroll 0 0 --dy 2147483648
reject 'scale' screenshot --scale 0
reject 'display number' screenshot --full --display new
reject 'display number' screenshot --full --display 9
reject 'nonempty' screenshot --out=
reject 'nonempty' click --ref=
reject 'window ref' tree --window w4294967296
reject 'window ref' window fill --window -1
reject 'timeout' wait --text ready --timeout inf
reject 'needs --text and/or --role' wait
reject 'env' launch fixture --env MISSING_VALUE
reject 'exclude each other' launch fixture --audio --inaudible
reject 'pid' stop --pid "$child"
reject 'selector' screenshot --full --pid "$child"
reject 'usage: backstage window' window
reject 'usage: backstage window' window maximize
reject 'arguments' window fill 10
reject 'arguments' window size 800
reject 'width and height' window size 800 0
reject 'width and height' window size 800 inf
reject 'not an option' window fill --scale 2
reject 'managed' window fill --pid "$child"
reject 'managed' quit --force --pid "$child"
reject "can't be combined" wait --sound --text ready
reject 'since' wait --sound --since nan
reject 'min-db' wait --sound --min-db inf
reject 'not an option' wait --sound --window 0
reject 'not an option' audio --window 0
reject 'arguments' audio extra
reject 'managed' audio --pid "$child"
reject 'arguments' audio record extra
reject 'not an option' audio --seconds 3
reject 'not an option' audio record --window 0
reject 'seconds' audio record --seconds 16
reject 'seconds' audio record --seconds 0
reject 'seconds' audio record --seconds nan
reject 'one output path' audio record -o a.wav --out b.wav
reject 'managed' audio record --pid "$child"
kill -0 "$child"

# Exercise a reused PID and a legacy record with no process identity.
for identity in '{"processStart":1}' '{}'; do
    jq -n --argjson pid "$child" --argjson identity "$identity" \
        '{pid:$pid,displayID:1,x:0,y:0,width:1,height:1,startedAt:now} + $identity' \
        > "$BACKSTAGE_HOME/daemon.json"
    "$bin" stop > "$work/result"
    jq -e '.ok == true' "$work/result" >/dev/null
    kill -0 "$child"
done

# Read the process's kernel birth time to create a valid managed record for logs.
cat > "$work/birth.c" <<'C'
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    struct proc_bsdinfo info;
    if (argc != 2 || proc_pidinfo(atoi(argv[1]), PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info)
        return 1;
    printf("%llu\n", info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec);
    return 0;
}
C
xcrun clang "$work/birth.c" -o "$work/birth"
birth=$("$work/birth" "$child")
jq -n --argjson pid "$child" --argjson birth "$birth" --arg log "$work/log" \
    '[{pid:$pid,name:"fixture",path:"/bin/sleep",launchedAt:now,stdout:$log,processStart:$birth}]' \
    > "$BACKSTAGE_HOME/apps.json"

check_tail() {
    tail -n "$1" "$work/log" > "$work/expected"
    "$bin" logs --pid "$child" --lines "$1" > "$work/actual"
    cmp "$work/expected" "$work/actual"
}
printf 'first\n\nlast\n' > "$work/log"
for n in 0 1 2 10; do check_tail "$n"; done
printf 'partial' >> "$work/log"
check_tail 2
# Cross several reverse-read blocks with empty lines and split UTF-8 sequences.
python3 - "$work/log" <<'PYTHON'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_bytes(("abc🚀" * 20000 + "\n\n" + "δ" * 70000).encode())
PYTHON
for n in 1 2 3; do check_tail "$n"; done
: > "$work/log"
check_tail 3

# A daemon from another backstage version (no protocol field) that still has apps is refused
# with a way out, and isn't touched. `windows` only reads state, so a bug here can't start a
# real daemon.
jq -n --argjson pid "$child" --argjson birth "$birth" \
    '{pid:$pid,displayID:1,x:0,y:0,width:1,height:1,startedAt:now,processStart:$birth,inputGuard:true}' > "$BACKSTAGE_HOME/daemon.json"
reject 'older version.*stop --all' windows
reject 'older version.*stop --all' press --pid "$child" w0
reject 'older version.*stop --all' quit --force --pid "$child"
reject 'older version.*stop --all' show --pid "$child"
reject 'older version.*stop --all' stop
kill -0 "$child"
jq '.protocol = 3 | .stopping = true' "$BACKSTAGE_HOME/daemon.json" > "$work/stopping"
mv "$work/stopping" "$BACKSTAGE_HOME/daemon.json"
reject 'shutting down' windows
reject 'shutting down' press --pid "$child" w0
kill -0 "$child"
rm "$BACKSTAGE_HOME/daemon.json"

# An input command must recheck its target after waiting on the app lock. Use the
# window command so the test can reach the lock without starting an input guard.
python3 - "$bin" "$BACKSTAGE_HOME" "$child" "$birth" <<'PYTHON'
import fcntl
import json
from pathlib import Path
import subprocess
import sys
import time

binary, home, pid, birth = sys.argv[1:]
registry = Path(home) / "apps.json"
lock = Path(home) / "locks" / f"app-{pid}-{birth}"
lock.parent.mkdir(exist_ok=True)
with lock.open("w") as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    proc = subprocess.Popen([binary, "window", "fill", "--pid", pid], stdout=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 10
        while True:
            opened = subprocess.run(["/usr/sbin/lsof", "-Fn", "-p", str(proc.pid)],
                                    capture_output=True, text=True)
            if "n" + str(lock.resolve()) in opened.stdout.splitlines():
                break
            if proc.poll() is not None or time.monotonic() >= deadline:
                raise AssertionError("window command did not wait on the app lock")
            time.sleep(0.025)
        saved = registry.with_suffix(".saved.json")
        replacement = registry.with_suffix(".replacement.json")
        saved.write_bytes(registry.read_bytes())
        replacement.write_text("[]")
        replacement.replace(registry)
        try:
            fcntl.flock(handle, fcntl.LOCK_UN)
            result = json.loads(proc.communicate(timeout=10)[0])
            assert proc.returncode == 1 and "no longer a live managed app" in result["error"], result
        finally:
            saved.replace(registry)
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.communicate()
PYTHON

# Session identity must agree with the byte-based keys used for app and session locks.
# A precomposed and a decomposed spelling must not address each other's apps.
mv "$BACKSTAGE_HOME/apps.json" "$work/legacy-apps.json"
owner=$'test-\xc3\xa9'
other=$'test-e\xcc\x81'
jq --arg owner "$owner" '.[0].session = $owner' "$work/legacy-apps.json" > "$BACKSTAGE_HOME/apps.json"
BACKSTAGE_SESSION="$other" reject 'another backstage session' logs --pid "$child"
BACKSTAGE_SESSION="$other" "$bin" list | jq -e '.apps == []' >/dev/null
BACKSTAGE_SESSION="$owner" "$bin" logs --pid "$child" --lines 0
mv "$work/legacy-apps.json" "$BACKSTAGE_HOME/apps.json"

# Session derivation. Results mustn't depend on the agent (if any) running this script, so
# agent variables are scrubbed, and fake agents are copies of a spawn-and-wait helper.
unset BACKSTAGE_SESSION
scrub=(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CODEX_THREAD_ID -u GROK_SESSION_ID)
cat > "$work/spawn.c" <<'C'
#include <spawn.h>
#include <string.h>
#include <sys/wait.h>
extern char **environ;
int main(int argc, char **argv) {
    int i = 1, status;
    pid_t pid;
    while (i < argc && strcmp(argv[i], "--")) i++;
    if (i + 1 >= argc || posix_spawnp(&pid, argv[i + 1], NULL, NULL, argv + i + 1, environ)) return 127;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
C
xcrun clang "$work/spawn.c" -o "$work/spawn"
mkdir -p "$work/agents" "$work/pkg/gemini"
for name in codex claude node; do cp "$work/spawn" "$work/agents/$name"; done
expect_session() {
    local pattern=$1
    shift
    "$@" > "$work/session"
    if ! jq -e --arg pattern "$pattern" '.session.id | test($pattern)' "$work/session" >/dev/null; then
        echo "Expected a session matching '$pattern' for $*" >&2
        cat "$work/session" >&2
        exit 1
    fi
}
# An agent's variable counts only if that agent set it rather than inheriting it.
expect_session '^codex:inner$' "${scrub[@]}" "$work/agents/codex" -- env CODEX_THREAD_ID=inner "$bin" status
expect_session '^codex:[0-9]+-[0-9]+$' "${scrub[@]}" CODEX_THREAD_ID=outer "$work/agents/codex" -- "$bin" status
expect_session '^claude:mine$' "${scrub[@]}" "$work/agents/claude" -- env CLAUDE_CODE_SESSION_ID=mine "$bin" status
expect_session '^claude:[0-9]+-[0-9]+$' "${scrub[@]}" CLAUDE_CODE_SESSION_ID=outer "$work/agents/claude" -- "$bin" status
# An outer agent's variable never reaches a nested agent of another kind.
expect_session '^codex:[0-9]+-[0-9]+$' "${scrub[@]}" CLAUDE_CODE_SESSION_ID=outer "$work/agents/codex" -- "$bin" status
# An agent run by an interpreter is recognised from its arguments, and the nearest agent wins.
expect_session '^gemini:[0-9]+-[0-9]+$' "${scrub[@]}" CLAUDE_CODE_SESSION_ID=outer \
    "$work/agents/claude" -- "$work/agents/node" "$work/pkg/gemini/cli.js" -- "$bin" status

# A caller whose parent has exited is reparented to launchd. That is never a session key: only
# a single agent variable is used as is; otherwise it's an error naming BACKSTAGE_SESSION.
detached() {
    rm -f "$work/detached"
    ( (sleep 0.3; exec "$@" > "$work/detached") & )
    for _ in $(seq 1 100); do
        jq -e . "$work/detached" >/dev/null 2>&1 && return
        sleep 0.1
    done
    echo "No output from detached $*" >&2
    exit 1
}
detached "${scrub[@]}" "$bin" list
jq -e '.ok == false and (.error | test("BACKSTAGE_SESSION"))' "$work/detached" >/dev/null
detached "${scrub[@]}" CODEX_THREAD_ID=lone "$bin" status
jq -e '.session.id == "codex:lone"' "$work/detached" >/dev/null
detached "${scrub[@]}" CODEX_THREAD_ID=one CLAUDE_CODE_SESSION_ID=two "$bin" list
jq -e '.ok == false and (.error | test("BACKSTAGE_SESSION"))' "$work/detached" >/dev/null

# No agent, in a terminal: the terminal session (a tab or tmux pane) is one session, another
# terminal is another. `script` gives a detached command a fresh terminal session.
in_terminal() {
    rm -f "$work/tty.$1."*
    ( (exec "${scrub[@]}" script -q /dev/null bash -c '"$1" status > "$2.1"; "$1" status > "$2.2"' _ "$bin" "$work/tty.$1" \
        < /dev/null > /dev/null 2>&1) & )
    for _ in $(seq 1 100); do
        jq -e . "$work/tty.$1.2" >/dev/null 2>&1 && return
        sleep 0.1
    done
    echo "No output from terminal session $1" >&2
    exit 1
}
in_terminal a
in_terminal b
jq -e '.session.from == "terminal session" and (.session.id | test("^tty:[0-9]+-[0-9]+$"))' "$work/tty.a.1" >/dev/null
[[ $(jq -r .session.id "$work/tty.a.1") == $(jq -r .session.id "$work/tty.a.2") ]]
[[ $(jq -r .session.id "$work/tty.a.1") != $(jq -r .session.id "$work/tty.b.1") ]]

# A managed, windowless process can lack an AppKit application handle.
"$bin" quit --force --pid "$child" | jq -e '.ok == true' >/dev/null
wait "$child" 2>/dev/null || :
child=
# The input guard's classifier (InputGuard.swift), on constructed events that are never posted.
"$bin" __guard-selftest | jq -e '.ok == true and .cases >= 12' >/dev/null

# Inaudible launches (Inaudible.swift): what launch would do about a target's sound, without
# launching anything. Dev builds are inaudible; hardened, SIP-protected and script targets muted.
printf 'int main(void) { return 0; }\n' > "$work/hello.c"
xcrun clang -o "$work/adhoc" "$work/hello.c"
cp "$work/adhoc" "$work/hardened"
codesign -f -s - --options runtime "$work/hardened" 2>/dev/null
printf '#!/bin/sh\nexit 0\n' > "$work/script.sh"
chmod +x "$work/script.sh"
"$bin" __inaudible-check "$work/adhoc" | jq -e '.eligible and .audio == "inaudible" and (.library | test("libbackstage-inaudible.dylib$"))' >/dev/null
"$bin" __inaudible-check --audio "$work/adhoc" | jq -e '.audio == "metered"' >/dev/null
"$bin" __inaudible-check "$work/hardened" | jq -e '(.eligible | not) and .audio == "muted" and (.detail | test("hardened runtime"))' >/dev/null
"$bin" __inaudible-check --inaudible "$work/hardened" | jq -e '.audio == null' >/dev/null
"$bin" __inaudible-check "$work/script.sh" | jq -e '(.eligible | not) and (.detail | test("script"))' >/dev/null
"$bin" __inaudible-check /bin/ls | jq -e '(.eligible | not) and (.detail | test("System Integrity Protection"))' >/dev/null
BACKSTAGE_INAUDIBLE_DYLIB= "$bin" __inaudible-check "$work/adhoc" | jq -e '.library == null and .audio == "muted"' >/dev/null
if xctest=$(xcrun -f xctest 2>/dev/null); then
    "$bin" __inaudible-check "$xctest" | jq -e '.eligible and .audio == "inaudible"' >/dev/null
fi
reject 'exclude each other' launch "$work/adhoc" --audio --inaudible
reject "can't launch hardened inaudible: .*hardened runtime" launch "$work/hardened" --inaudible
BACKSTAGE_INAUDIBLE_DYLIB= reject "can't launch adhoc inaudible: .*wasn't found" launch "$work/adhoc" --inaudible
reject 'not an option' audio --inaudible

# Apps the user sent backstage (owner "user"): any session reaches them with an explicit --pid
# or --app, none gets them as its default target, a session's plain `stop` leaves them, and
# `stop --all` quits them. Two windowless processes stand in for the apps.
/bin/sleep 300 &
sent=$!
/bin/sleep 300 &
own=$!
child="$sent $own"
: > "$work/sent.log"
jq -n --argjson sent "$sent" --argjson sb "$("$work/birth" "$sent")" --argjson own "$own" --argjson ob "$("$work/birth" "$own")" \
    --arg log "$work/sent.log" \
    '[{pid:$sent,name:"SentApp",path:"/bin/sleep",launchedAt:now,stdout:$log,processStart:$sb,session:"user",audio:"muted"},
      {pid:$own,name:"OwnApp",path:"/bin/sleep",launchedAt:now,stdout:$log,processStart:$ob,session:"owner-a",audio:"muted"}]' \
    > "$BACKSTAGE_HOME/apps.json"
BACKSTAGE_SESSION=user reject 'reserved for apps the user sent' list
for s in owner-a owner-b; do
    BACKSTAGE_SESSION=$s "$bin" logs --pid "$sent" --lines 1 > /dev/null
    BACKSTAGE_SESSION=$s "$bin" logs --app SentApp --lines 1 > /dev/null
    BACKSTAGE_SESSION=$s "$bin" list | jq -e --argjson sent "$sent" \
        '(.apps | map(.pid) | index($sent) | not) and .sentByUser[0].pid == $sent and (.note | test("--pid"))' >/dev/null
done
BACKSTAGE_SESSION=owner-b reject 'no managed apps in this session' logs
BACKSTAGE_SESSION=owner-b reject 'another backstage session' logs --pid "$own"
BACKSTAGE_SESSION=owner-a "$bin" list --all | jq -e --argjson sent "$sent" '.apps | map(select(.pid == $sent and .session == "user")) | length == 1' >/dev/null
BACKSTAGE_SESSION=owner-a "$bin" stop | jq -e --argjson own "$own" '.ok and .quit == [$own] and (.daemon | test("not running|user sent"))' >/dev/null
wait "$own" 2>/dev/null || :
kill -0 "$sent"
BACKSTAGE_SESSION=owner-b "$bin" stop | jq -e '.ok and .quit == []' >/dev/null
kill -0 "$sent"
"$bin" stop --all | jq -e --argjson sent "$sent" '.ok and .quit == [$sent]' >/dev/null
wait "$sent" 2>/dev/null || :
! kill -0 "$sent" 2>/dev/null
child=

# Send Front Window Backstage: what is never sent (the static rules), and the test hook's gate.
refused() { "$bin" __send-refusal "$@" | jq -e '.refused | type == "string"' >/dev/null; }
allowed() { "$bin" __send-refusal "$@" | jq -e '.refused == null' >/dev/null; }
refused --bundle-id com.apple.finder --name Finder --path /System/Library/CoreServices/Finder.app
refused --bundle-id com.apple.dock --name Dock
refused --name WindowServer --path /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
refused --bundle-id com.apple.Terminal --name Terminal --path /System/Applications/Utilities/Terminal.app
refused --bundle-id com.mitchellh.ghostty --name Ghostty
refused --bundle-id com.googlecode.iterm2 --name iTerm2
refused --bundle-id com.anthropic.claudefordesktop --name Claude
refused --bundle-id com.openai.codex --name ChatGPT
refused --bundle-id tv.parsec.www --name Parsec
refused --name herdr
allowed --bundle-id com.apple.TextEdit --name TextEdit --path /System/Applications/TextEdit.app
allowed --bundle-id com.apple.Safari --name Safari --path /Applications/Safari.app
allowed --bundle-id dev.example.thing --name Thing --path /Applications/Thing.app
BACKSTAGE_TEST_REFUSE=dev.example "$bin" __send-refusal --bundle-id dev.example.thing --name Thing | jq -e '.refused | type == "string"' >/dev/null
reject 'internal command' __send-backstage --pid 1
reject 'focus-to' __send-backstage --pid 1 --focus-to 0

# Settings: round trip through settings.json, validation, and `status`.
"$bin" settings | jq -e '.autoHide == true and .keepInMenuBar == false and .hotkey == "off" and (.hotkeyNote | test("off by default")) and .daemon == "not running"' >/dev/null
"$bin" settings auto-hide off | jq -e '.ok and .autoHide == false and .keepInMenuBar == true and (.note | test("backstage start"))' >/dev/null
jq -e '.keepInMenuBar == true' "$BACKSTAGE_HOME/settings.json" >/dev/null
"$bin" settings hotkey cmd+opt+b | jq -e '.hotkey == "opt+cmd+b" and .hotkeySymbols == "⌥⌘B" and .keepInMenuBar == true' >/dev/null
"$bin" settings hotkey Control+Option+Command+F5 | jq -e '.hotkey == "ctrl+opt+cmd+f5"' >/dev/null
"$bin" settings hotkey default | jq -e '.hotkey == "ctrl+opt+cmd+b" and .hotkeySymbols == "⌃⌥⌘B"' >/dev/null
reject 'at least two modifiers' settings hotkey ctrl+b
reject 'at least two modifiers' settings hotkey shift+opt+b
reject 'letter, a digit or F1' settings hotkey ctrl+opt+tab
reject 'letter, a digit or F1' settings hotkey ctrl+opt+f13
reject 'more than one key' settings hotkey ctrl+opt+a+b
reject 'no key' settings hotkey ctrl+opt
reject 'usage' settings auto-hide maybe
reject 'usage' settings keep-in-menu-bar maybe
reject 'usage' settings colour blue
"$bin" status | jq -e '.settings.keepInMenuBar == true and .settings.hotkey == "ctrl+opt+cmd+b"' >/dev/null
"$bin" settings hotkey off | jq -e '.hotkey == "off" and (.hotkeySymbols | not)' >/dev/null
"$bin" settings auto-hide on | jq -e '.autoHide == true and .keepInMenuBar == false' >/dev/null
jq -e '.keepInMenuBar == false and .hotkey == "off"' "$BACKSTAGE_HOME/settings.json" >/dev/null
# The older, opposite spelling still works.
"$bin" settings keep-in-menu-bar on | jq -e '.autoHide == false' >/dev/null
"$bin" settings keep-in-menu-bar off | jq -e '.autoHide == true' >/dev/null
echo "CLI regression checks passed"
