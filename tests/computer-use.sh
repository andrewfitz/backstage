#!/bin/bash
# Check helper identity without creating any input events or using a running daemon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build)
    BIN_DIR="$(cd "$ROOT" && swift build -c release --show-bin-path)"
    BACKSTAGE_BIN="$BIN_DIR/backstage"
fi
WORK="$(mktemp -d /tmp/backstage-cu.XXXXXX)"
FIXTURE_PID=
cleanup() {
    if [[ -n "$FIXTURE_PID" ]]; then
        kill "$FIXTURE_PID" 2>/dev/null || true
        wait "$FIXTURE_PID" 2>/dev/null || true
    fi
    echo "artifacts: $WORK"
}
trap cleanup EXIT

"$BACKSTAGE_BIN" __guard-selftest
mkdir -p "$WORK/ClaudeFixture/Contents/Helpers" "$WORK/CodexFixture/Contents/MacOS"
CLAUDE_FIXTURE="$WORK/ClaudeFixture/Contents/Helpers/app-cu-helper"
CODEX_FIXTURE="$WORK/CodexFixture/Contents/MacOS/SkyComputerUseService"
# A minimal ad hoc-signed executable has no vendor identity and never posts input.
swiftc -o "$CLAUDE_FIXTURE" - <<'SWIFT'
import Darwin
print("ready")
fflush(stdout)
sleep(30)
SWIFT
codesign --force --sign - "$CLAUDE_FIXTURE"
cp "$CLAUDE_FIXTURE" "$CODEX_FIXTURE"

check_rejected() {
    local path=$1
    "$path" > "$WORK/fixture.log" &
    FIXTURE_PID=$!
    for _ in $(seq 1 40); do
        [[ -s "$WORK/fixture.log" ]] && break
        sleep 0.05
    done
    grep -q '^ready$' "$WORK/fixture.log"
    "$BACKSTAGE_BIN" __guard-selftest --pid "$FIXTURE_PID"
    kill "$FIXTURE_PID"
    wait "$FIXTURE_PID" 2>/dev/null || true
    FIXTURE_PID=
}
check_rejected "$CLAUDE_FIXTURE"
check_rejected "$CODEX_FIXTURE"

check_installed() {
    local path=$1 identifier=$2 team=$3
    [[ -x "$path" ]] || return 0
    codesign --verify --strict --test-requirement "=identifier \"$identifier\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team\"" "$path"
    echo "verified installed $identifier signature"
}
check_installed '/Applications/Claude.app/Contents/Helpers/app-cu-helper' app-cu-helper Q6L2SF6YDW
check_installed "$HOME/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService" com.openai.sky.CUAService 2DC432GLL2
check_installed '/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService' com.openai.sky.CUAService 2DC432GLL2
echo 'ALL PASSED'
