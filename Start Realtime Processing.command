#!/bin/bash
# Double-click to start the realtime processing worker on DEV3: a Matlab with
# no windows (matlab -batch) running MODprocess_deployment(<processed_root>,
# 'watch', true). It keeps going until stopped - by the monitor app's Stop
# button, or by writing {"command": "stop"} into
# <processed_root>/realtime/control.json. Closing this Terminal window also
# stops it.
#
# <processed_root> is read from acquisition/config.yml (processed_root:), the
# same folder Start New Deployment writes dev1_setup.yml into. Pass a folder
# as an argument to use a different one, and --force to start even if
# realtime/worker.lock says a worker is running (after a crash).
# From a Terminal:  "./Start Realtime Processing.command" [--force] [folder]
# If worker.lock names a worker that is still running, this one doesn't start:
# the window says "Worker did NOT start", shows that worker, and how to stop it.
SRC="$(cd "$(dirname "$(readlink "$0" || echo "$0")")" && pwd)"
[ -d "$SRC/processing" ] || SRC="$(cd "$(dirname "$0")" && pwd)"

FORCE=false
ROOT=""
for a in "$@"; do
    if [ "$a" = "--force" ]; then FORCE=true; else ROOT="$a"; fi
done
source "$SRC/util/launch_common.sh"
launch_style "REALTIME PROCESSING - DO NOT CLOSE (closing stops the worker)" 110 20 20
launch_find_root "$ROOT"
launch_find_matlab

echo "Realtime processing of $ROOT"
echo "Status: $ROOT/realtime/status.json   Log: $ROOT/realtime/cruise_log.txt"
echo "Stop it from the monitor app, or with {\"command\": \"stop\"} in $ROOT/realtime/control.json"
echo
# Paths are passed through the environment so no quoting can break the Matlab command
export MOD_FISH_PROCESSING_DIR="$SRC" MOD_PROCESSED_ROOT="$ROOT"
# exit code 3: refused to start because another worker holds worker.lock
"${RUN[@]}" "$MATLAB" -batch "addpath(genpath(getenv('MOD_FISH_PROCESSING_DIR'))); try, MODprocess_deployment(getenv('MOD_PROCESSED_ROOT'), 'watch', true, 'force', $FORCE); catch ME, if strcmp(ME.identifier, 'MODprocess_deployment:otherWorker'), exit(3); end, rethrow(ME); end"
STATUS=$?
echo
if [ $STATUS -eq 3 ]; then
    LOCK="$ROOT/realtime/worker.lock"
    PID="$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$LOCK" | head -1)"
    HOST="$(sed -n 's/.*"host": *"\([^"]*\)".*/\1/p' "$LOCK" | head -1)"
    STARTED="$(sed -n 's/.*"started_utc": *"\([^"]*\)".*/\1/p' "$LOCK" | head -1)"
    echo "=================================================================="
    echo "Worker did NOT start - nothing is processing from this window."
    echo "$LOCK says another worker is running:"
    echo "  PID $PID on $HOST, started $STARTED UTC"
    echo
    if [ "$HOST" != "$(hostname)" ]; then
        echo "That worker is on another Mac ($HOST): stop it there (the monitor's Stop button),"
        echo "then double-click this again."
    elif ! ps -p "$PID" -o command= | grep -q MODprocess_deployment; then
        echo "PID $PID is not a worker now (that worker is gone; the lock was left behind)."
        echo "Start with --force:"
        echo "  \"$SRC/Start Realtime Processing.command\" --force"
    else
        echo "It is still running (a worker runs as a windowless 'matlab -batch' - closing"
        echo "the MATLAB app doesn't stop it):"
        ps -p "$PID" -o pid,etime,command | cut -c1-150
        echo
        echo "To stop it:"
        echo "  1. Click Stop in the monitor (it finishes its current file first), or in a Terminal:"
        echo "       kill $PID"
        echo "  2. Check that it's gone - this prints nothing when no worker is running:"
        echo "       pgrep -fl MODprocess_deployment"
        echo "     Still there after a minute? Force it:  kill -9 $PID"
        echo "  3. Double-click \"Start Realtime Processing.command\" again."
    fi
    echo "=================================================================="
    read -n 1 -s -r -p "Press any key to close"
elif [ $STATUS -ne 0 ]; then
    read -n 1 -s -r -p "Worker stopped with an error (above). Press any key to close"
else
    read -n 1 -s -r -p "Worker stopped. Press any key to close"
fi
