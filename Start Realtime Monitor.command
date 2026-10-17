#!/bin/bash
# Double-click to open the realtime monitor (MODvis_realtime_monitor) in its
# own MATLAB window - a second MATLAB next to the worker that Start Realtime
# Processing.command started. The monitor only reads the worker's files (and
# writes control.json for Pause/Stop), so opening or closing it never affects
# processing. This Terminal window can be closed once MATLAB has opened.
#
# The folder is processed_root in acquisition/config.yml, like the worker's;
# pass a folder as an argument to open a different one.
# From a Terminal:  "./Start Realtime Monitor.command" [folder]
SRC="$(cd "$(dirname "$(readlink "$0" || echo "$0")")" && pwd)"
[ -d "$SRC/processing" ] || SRC="$(cd "$(dirname "$0")" && pwd)"
source "$SRC/util/launch_common.sh"
launch_style "Realtime monitor (safe to close once MATLAB is open)" 15 45 100
launch_find_root "$1"
launch_find_matlab

mkdir -p "$ROOT/realtime"
OUT="$ROOT/realtime/monitor_console.txt"
echo "Realtime monitor of $ROOT"
echo "(MATLAB's own messages go to $OUT)"
# Paths are passed through the environment so no quoting can break the Matlab command;
# nohup + & so MATLAB keeps running when this window closes
export MOD_FISH_PROCESSING_DIR="$SRC" MOD_PROCESSED_ROOT="$ROOT"
nohup "${RUN[@]}" "$MATLAB" -desktop -r "addpath(genpath(getenv('MOD_FISH_PROCESSING_DIR'))); app = MODvis_realtime_monitor(getenv('MOD_PROCESSED_ROOT'));" > "$OUT" 2>&1 &
echo "MATLAB is starting (it can take a minute). You can close this window."
