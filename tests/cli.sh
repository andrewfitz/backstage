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
reject 'managed' quit --force --pid "$child"
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
# A managed, windowless process can lack an AppKit application handle.
"$bin" quit --force --pid "$child" | jq -e '.ok == true' >/dev/null
wait "$child" 2>/dev/null || :
child=
echo "CLI regression checks passed"
