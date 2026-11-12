#!/usr/bin/env bash
# Records the booted simulator on request of a UI test (ViewerZoomUITests).
#
# A UI test runs inside the simulator and cannot launch `xcrun simctl`; this host
# script does it for the test through files dropped in /tmp/swimmich-video/:
#
#   <name>.start   -> starts `simctl io recordVideo` into <name>.mov, then creates
#                     <name>.recording once the recorder printed "Recording started"
#   <name>.stop    -> stops the recorder (SIGINT, so the file is finalized), waits
#                     for it to exit, then creates <name>.done
#
# Usage (leave it running in a terminal on the Mac that runs the simulator):
#
#   UITests/stubs/tools/sim_video_watcher.sh            # the booted simulator
#   SIM_UDID=<udid> UITests/stubs/tools/sim_video_watcher.sh
#
# Ctrl-C stops the watcher (and any recording still running). Written for the
# bash 3.2 of macOS: no associative arrays, one pid file per recording.
set -euo pipefail

DIR="${SWIMMICH_VIDEO_DIR:-/tmp/swimmich-video}"
SIM="${SIM_UDID:-booted}"
mkdir -p "$DIR"

cleanup() {
    for pidfile in "$DIR"/*.pid; do
        [ -e "$pidfile" ] || continue
        kill -INT "$(cat "$pidfile")" 2>/dev/null || true
        rm -f "$pidfile"
    done
}
trap cleanup EXIT INT TERM

start_recording() {
    local name="$1"
    local log="$DIR/$name.log"
    rm -f "$DIR/$name.mov" "$DIR/$name.recording" "$DIR/$name.done" "$log"
    xcrun simctl io "$SIM" recordVideo --codec=h264 --force "$DIR/$name.mov" 2>"$log" &
    local pid=$!
    echo "$pid" > "$DIR/$name.pid"
    # simctl prints "Recording started" on stderr once frames are being captured.
    for _ in $(seq 1 100); do
        if grep -q "Recording started" "$log" 2>/dev/null; then
            touch "$DIR/$name.recording"
            return
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    echo "sim_video_watcher: recorder '$name' never started (see $log)" >&2
}

stop_recording() {
    local name="$1"
    local pidfile="$DIR/$name.pid"
    if [ -e "$pidfile" ]; then
        local pid
        pid="$(cat "$pidfile")"
        kill -INT "$pid" 2>/dev/null || true
        # `wait` only knows this shell's children; poll for the exit instead.
        while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
        rm -f "$pidfile"
    fi
    touch "$DIR/$name.done"
}

echo "sim_video_watcher: watching $DIR for the simulator $SIM"
while true; do
    for start in "$DIR"/*.start; do
        [ -e "$start" ] || continue
        name="$(basename "$start" .start)"
        rm -f "$start"
        start_recording "$name"
    done
    for stop in "$DIR"/*.stop; do
        [ -e "$stop" ] || continue
        name="$(basename "$stop" .stop)"
        rm -f "$stop"
        stop_recording "$name"
    done
    sleep 0.1
done
