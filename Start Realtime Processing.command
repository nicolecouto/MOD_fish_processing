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
"${RUN[@]}" "$MATLAB" -batch "addpath(genpath(getenv('MOD_FISH_PROCESSING_DIR'))); MODprocess_deployment(getenv('MOD_PROCESSED_ROOT'), 'watch', true, 'force', $FORCE)"
echo
read -n 1 -s -r -p "Worker stopped. Press any key to close"
