#!/bin/bash
# Run against a private state directory and a test-owned, windowless process.
set -eu
cd "$(dirname "$0")/.."
bin=${BACKSTAGE_BIN:-.build/release/backstage}
work=$(mktemp -d)
export BACKSTAGE_HOME="$work/state"
mkdir "$BACKSTAGE_HOME"
/bin/sleep 300 &
child=$!
cleanup() {
    if [[ -n "$child" ]]; then
        kill "$child" 2>/dev/null || :
        wait "$child" 2>/dev/null || :
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

reject 'pid' quit --pid xyz
reject 'pid' quit --pid 2147483648
reject 'pid' quit --pid
reject 'lines' logs --lines -1
reject 'scale' screenshot --scale nan
reject 'steps' drag 0 0 10 10 --steps 0
reject 'dy' scroll 0 0 --dy 2147483648
reject 'scale' screenshot --scale 0
reject 'timeout' wait --text ready --timeout inf
reject 'env' launch fixture --env MISSING_VALUE
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
    '{pid:$pid,displayID:1,x:0,y:0,width:1,height:1,startedAt:now,processStart:$birth}' > "$BACKSTAGE_HOME/daemon.json"
reject 'older version.*stop --all' windows
kill -0 "$child"
rm "$BACKSTAGE_HOME/daemon.json"

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
echo "CLI regression checks passed"
