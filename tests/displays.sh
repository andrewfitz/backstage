#!/bin/bash
# The eight fixed display identities (docs/MULTI_DISPLAY_PLAN.md, phase 1): homes reuse a slot
# instead of minting a new display identity, so ColorSync's list of registered displays doesn't
# grow from run to run. Uses displays 7 and 8 (and the lowest free shared one, 2-6, once).
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build) || exit 1
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage"
fi
BS="$BACKSTAGE_BIN"
WORK="$(mktemp -d /tmp/backstage-displays.XXXX)" || exit 1
FAIL=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
HOMES=()
home() { local h="$WORK/$1"; mkdir -p "$h"; chmod 700 "$h"; HOMES+=("$h"); }   # sets HOMES in this shell
cleanup() {
    local result=$?
    trap - EXIT
    for h in ${HOMES[@]+"${HOMES[@]}"}; do
        [[ -f "$h/daemon.json" ]] && BACKSTAGE_HOME="$h" "$BS" stop --all > /dev/null 2>&1
    done
    echo "artifacts: $WORK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

swiftc -O csdevices.swift -o "$WORK/csdevices" || exit 1
devices() { "$WORK/csdevices"; }
slot() { BACKSTAGE_HOME="$1" "$BS" status | jq -r '.daemon.display // empty'; }

home a; home b; home c; home d
A="$WORK/a"; B="$WORK/b"; C="$WORK/c"; D="$WORK/d"

cycle() {  # one round: two homes at once on 7 and 8, a busy request, a shared slot, restarts
    (BACKSTAGE_HOME="$A" BACKSTAGE_DISPLAY=7 "$BS" start > "$WORK/a.json" 2>&1) &
    (BACKSTAGE_HOME="$B" BACKSTAGE_DISPLAY=8 "$BS" start > "$WORK/b.json" 2>&1) &
    wait
    [[ $(slot "$A") == 7 && $(slot "$B") == 8 ]] && pass "two homes started at once got displays 7 and 8" \
        || fail "concurrent start: a=$(cat "$WORK/a.json") b=$(cat "$WORK/b.json")"

    local t0=$SECONDS out
    out=$(BACKSTAGE_HOME="$C" BACKSTAGE_DISPLAY=7 "$BS" start 2>&1)
    echo "$out" | jq -e '.ok == false and (.error | test("display 7 is in use"))' > /dev/null \
        && pass "a third home asking for 7 fails after $((SECONDS - t0)) s: $(echo "$out" | jq -r .error)" \
        || fail "busy display 7 should fail: $out"
    [[ -f "$C/daemon.json" ]] && BACKSTAGE_HOME="$C" "$BS" stop --all > /dev/null 2>&1

    out=$(BACKSTAGE_HOME="$D" BACKSTAGE_DISPLAY= "$BS" start 2>&1)
    local s; s=$(slot "$D")
    [[ $s =~ ^[2-6]$ ]] && pass "a home asking for no display got shared display $s" || fail "shared slot: $out (slot ${s:-none})"
    BACKSTAGE_HOME="$D" "$BS" stop --all > /dev/null

    # Right after a stop the old display may still be online for a moment: the restart waits.
    BACKSTAGE_HOME="$A" "$BS" stop --all > /dev/null
    out=$(BACKSTAGE_HOME="$A" BACKSTAGE_DISPLAY=7 "$BS" start 2>&1)
    [[ $(slot "$A") == 7 ]] && pass "display 7 is reused right after its daemon stopped" || fail "restart on 7: $out"
    BACKSTAGE_HOME="$A" "$BS" stop --all > /dev/null
    BACKSTAGE_HOME="$B" "$BS" stop --all > /dev/null
}

echo "== bad values"
OUT=$(BACKSTAGE_HOME="$C" BACKSTAGE_DISPLAY=9 "$BS" start 2>&1)
echo "$OUT" | jq -e '.ok == false and (.error | test("1 to 8"))' > /dev/null && pass "BACKSTAGE_DISPLAY=9 is refused" || fail "display 9: $OUT"

echo "== round 1"
cycle
AFTER1=$(devices)
echo "== round 2 (registered backstage displays after round 1: $AFTER1)"
cycle
AFTER2=$(devices)
[[ $AFTER2 == "$AFTER1" ]] && pass "ColorSync's backstage displays didn't grow in round 2 ($AFTER2)" \
    || fail "ColorSync's backstage displays grew from $AFTER1 to $AFTER2"

[[ $FAIL == 0 ]] && echo "displays: all passed"
exit $FAIL
