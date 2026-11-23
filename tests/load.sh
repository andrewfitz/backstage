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
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
if [[ -z ${BACKSTAGE_BIN:-} ]]; then
    (cd "$ROOT" && swift build -c release) || exit 1
    BACKSTAGE_BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/backstage"
fi
BS="$BACKSTAGE_BIN"
BUNDLE_ID=dev.backstage.testapp.load
BUILD="${BACKSTAGE_LOAD_BUILD:-/tmp/backstage-load-build-$(id -u)}"

# Helpers are cached between runs and rebuilt when their source changes, so the build can happen
# before (and outside of) whatever serializes GUI runs on the machine.
build() {
    mkdir -p "$BUILD/BackstageTestApp.app/Contents/MacOS" || return 1
    local exe="$BUILD/BackstageTestApp.app/Contents/MacOS/BackstageTestApp"
    if [[ ! -x $exe || TestApp.swift -nt $exe ]]; then
        swiftc -O TestApp.swift -o "$exe" || return 1
    fi
    cat > "$BUILD/BackstageTestApp.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BackstageTestApp</string><key>CFBundleIdentifier</key><string>$BUNDLE_ID</string><key>CFBundleName</key><string>BackstageTestApp</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
    local tool
    for tool in watch pixels probe; do
        if [[ ! -x $BUILD/$tool || $tool.swift -nt $BUILD/$tool ]]; then
            swiftc -O "$tool.swift" -o "$BUILD/$tool" || return 1
        fi
    done
}
echo "== build helpers in $BUILD"
build || exit 1
for arg in "$@"; do [[ $arg == --build-only ]] && exit 0; done

WORK="$(mktemp -d /tmp/backstage-load.XXXX)"
export BACKSTAGE_HOME="$WORK/state"
# The menu bar item isn't under test, and its thumbnails would add captures if someone opened it.
export BACKSTAGE_MENUBAR="${BACKSTAGE_MENUBAR:-off}"
unset BACKSTAGE_SESSION
echo "BACKSTAGE_HOME=$BACKSTAGE_HOME"
echo "  (if this is interrupted: BACKSTAGE_HOME=$BACKSTAGE_HOME $BS stop --all)"
WATCH=
RUN=1
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -f "$BACKSTAGE_HOME/daemon.json" || -s "$BACKSTAGE_HOME/apps.json" ]]; then
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

"$BUILD/watch" "$BUNDLE_ID" 86400 "$WORK/watch.stop" > "$WORK/watch.out" 2>&1 &
WATCH=$!
sleep 0.3
python3 load.py run "$@" --bin "$BS" --work "$WORK" --app "$BUILD/BackstageTestApp.app" \
    --pixels "$BUILD/pixels" --probe "$BUILD/probe" --root "$ROOT"
RUN=$?
