#!/bin/bash
# Load harness (multi-agent plan, phase 4). Not part of `make test`. See docs/LOAD_TESTING.md.
#
#   tests/load.sh <sessions> [workloads] [options]      e.g. tests/load.sh 2 all --duration 6
#   tests/load.sh --build-only                          compile the helpers, run nothing
#
# Workloads (comma list, default all): idle,input,capture,mixed,launch,cycles. Each session is a
# separate client process with its own BACKSTAGE_SESSION, driving its own copy of the fixture.
# More than 4 sessions needs --dedicated: run those on a separate macOS user account or a
# dedicated Mac, never on a desktop someone is using. The non-interference watchdog runs
# throughout; anything reaching the user's screens fails the run. Results (JSON + markdown) go
# to load-results/ (or --results DIR). Options: python3 tests/load.py --help.
set -uo pipefail
# backstage's own tests use displays 7-8, never the ones agents use (docs/MULTI_DISPLAY_PLAN.md).
export BACKSTAGE_DISPLAY=${BACKSTAGE_DISPLAY:-7}
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && make build) || exit 1
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage"
fi
BS="$BACKSTAGE_BIN"
BUILD="${BACKSTAGE_LOAD_BUILD:-/tmp/backstage-load-build-$(id -u)}"
mkdir -p -m 700 "$BUILD" || exit 1
if [[ ! -O "$BUILD" || -L "$BUILD" ]]; then
    echo "helper cache must be a directory owned by this user: $BUILD" >&2
    exit 1
fi
toolchain=$(swiftc --version 2>&1) || { echo "$toolchain" >&2; exit 1; }
sdk=$(xcrun --show-sdk-path) || exit 1

# A cache hit reads an immutable executable. Concurrent misses compile privately and
# publish a complete executable with an atomic rename on the same filesystem.
cached_helper() (
    local source=$1 name=$2 checksum key target stage
    checksum=$(shasum -a 256 "$source") || return 1
    key=$(printf '%s\n' "$checksum" "$toolchain" "$sdk" "${SDKROOT:-}" '-O' | shasum -a 256) || return 1
    target="$BUILD/$name-${key%% *}"
    if [[ ! -f "$target" || ! -x "$target" ]]; then
        stage=$(mktemp -d "$BUILD/.compile.XXXXXX") || return 1
        trap 'rm -f "$stage/$name"; rmdir "$stage"' EXIT
        swiftc -O "$source" -o "$stage/$name" || return 1
        local compiled_checksum
        compiled_checksum=$(shasum -a 256 "$source") || return 1
        if [[ "$compiled_checksum" != "$checksum" ]]; then
            echo "$source changed while compiling, rerun the load harness" >&2
            return 1
        fi
        mv -f "$stage/$name" "$target" || return 1
    fi
    printf '%s\n' "$target"
)
echo "== cache helpers in $BUILD"
FIXTURE_EXE=$(cached_helper TestApp.swift BackstageTestApp) || exit 1
WATCH_EXE=$(cached_helper watch.swift watch) || exit 1
PIXELS_EXE=$(cached_helper pixels.swift pixels) || exit 1
PROBE_EXE=$(cached_helper probe.swift probe) || exit 1
for arg in "$@"; do [[ $arg == --build-only ]] && exit 0; done

WORK="$(mktemp -d /tmp/backstage-load.XXXX)" || exit 1
BUNDLE_ID="dev.backstage.testapp.load.${WORK##*.}"
APP="$WORK/BackstageTestApp.app"
mkdir -p "$APP/Contents/MacOS" || exit 1
cp "$FIXTURE_EXE" "$APP/Contents/MacOS/BackstageTestApp" || exit 1
cat > "$APP/Contents/Info.plist" <<PLIST || exit 1
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageTestApp</string><key>CFBundleIdentifier</key><string>$BUNDLE_ID</string><key>CFBundleName</key><string>BackstageTestApp</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST

export BACKSTAGE_HOME="$WORK/state"
# The menu bar item isn't under test, and its thumbnails would add captures if someone opened it.
export BACKSTAGE_MENUBAR="${BACKSTAGE_MENUBAR:-off}"
unset BACKSTAGE_SESSION
echo "BACKSTAGE_HOME=$BACKSTAGE_HOME"
echo "  (if this is interrupted: BACKSTAGE_HOME=$BACKSTAGE_HOME $BS stop --all)"
WATCH=
RUN_PID=
RUN=1
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -n "$RUN_PID" ]]; then
        kill "$RUN_PID" 2>/dev/null || true
        wait "$RUN_PID" 2>/dev/null || true
        # The daemon detaches before publishing daemon.json. Give an interrupted
        # startup the same publication window as a normal start call.
        if [[ -f "$BACKSTAGE_HOME/daemon.log" && ! -f "$BACKSTAGE_HOME/daemon.json" ]]; then
            local deadline=$((SECONDS + 10))
            until [[ -f "$BACKSTAGE_HOME/daemon.json" ]] || (( SECONDS >= deadline )); do sleep 0.1; done
        fi
    fi
    if [[ -f "$BACKSTAGE_HOME/daemon.json" || -s "$BACKSTAGE_HOME/apps.json" || -d "$BACKSTAGE_HOME/launching" ]]; then
        "$BS" stop --all >/dev/null 2>&1 || result=1
    fi
    local watch_status=1
    if [[ -n "$WATCH" ]]; then
        touch "$WORK/watch.stop"
        wait "$WATCH"; watch_status=$?
        cat "$WORK/watch.out"
    fi
    if [[ -s "$WORK/results-path" ]]; then
        python3 load.py finalize "$(cat "$WORK/results-path")" "$WORK/watch.out" "$watch_status" || result=1
    fi
    [[ $RUN == 0 && $watch_status == 0 ]] || result=1
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

. ./watch.sh
start_watch "$BUNDLE_ID" 86400 "$WATCH_EXE" || exit 1
python3 load.py run "$@" --bin "$BS" --work "$WORK" --app "$APP" \
    --pixels "$PIXELS_EXE" --probe "$PROBE_EXE" --root "$ROOT" &
RUN_PID=$!
wait "$RUN_PID"
RUN=$?
RUN_PID=
