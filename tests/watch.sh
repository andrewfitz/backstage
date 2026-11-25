# Source from a GUI test after building the watchdog. Launch only after a valid sample.
start_watch() {
    "${3:-$WORK/watch}" "$1" "$2" "$WORK/watch.stop" "$WORK/watch.ready" > "$WORK/watch.out" 2>&1 &
    WATCH=$!
    local deadline=$((SECONDS + 10))
    until [[ -f "$WORK/watch.ready" ]]; do
        if (( SECONDS >= deadline )) || ! kill -0 "$WATCH" 2>/dev/null; then
            echo "watchdog did not become ready" >&2
            kill "$WATCH" 2>/dev/null || true
            return 1
        fi
        sleep 0.05
    done
}
