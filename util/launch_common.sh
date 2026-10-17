#!/bin/bash
# launch_common.sh        Part of MOD_fish_processing
#
# Sourced (not run) by "Start Realtime Processing.command" and
# "Start Realtime Monitor.command", so both find the same folder and the same
# MATLAB the same way. Expects SRC (the repo folder) to be set. Sets:
#   ROOT   - the processed data folder: $1 if given, else processed_root in
#            acquisition/config.yml (the folder Start New Deployment writes into)
#   MATLAB - the matlab launcher: the one on the PATH, else the newest
#            /Applications/MATLAB_R20*.app
#   RUN    - array to put before "$MATLAB": (arch -x86_64) for an Intel MATLAB
#            (bin/maci64 only) on an Apple Silicon Mac, which runs under Rosetta
#            only when started that way - otherwise its launcher stops with
#            "No MATLAB bin directory for this machine architecture, ARCH =
#            maca64" (DEV3, 2026-10-17); empty otherwise
# On a problem it prints why, waits for a key and exits.
#
# Multiscale Ocean Dynamics (MOD) Group, Scripps Institution of Oceanography

launch_stop() {
    echo "$1"
    read -n 1 -s -r -p "Press any key to close"
    exit 1
}

launch_find_root() {
    ROOT="$1"
    if [ -z "$ROOT" ]; then
        ROOT="$(sed -n 's/^processed_root:[[:space:]]*//p' "$SRC/acquisition/config.yml" | sed 's/[[:space:]]*#.*$//' | head -1)"
        ROOT="${ROOT%\"}"; ROOT="${ROOT#\"}"; ROOT="${ROOT%\'}"; ROOT="${ROOT#\'}"   # drop surrounding quotes
    fi
    if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
        launch_stop "Processed data folder not found: '$ROOT' (processed_root in acquisition/config.yml)."
    fi
}

launch_find_matlab() {
    MATLAB="$(command -v matlab)"
    [ -z "$MATLAB" ] && MATLAB="$(ls -d /Applications/MATLAB_R20*.app/bin/matlab 2>/dev/null | tail -1)"
    [ -z "$MATLAB" ] && launch_stop "matlab not found - add it to the PATH or install it in /Applications."
    local mbin
    mbin="$(cd "$(dirname "$(readlink "$MATLAB" || echo "$MATLAB")")" && pwd)"
    RUN=()
    if [ "$(uname -m)" = arm64 ] && [ ! -d "$mbin/maca64" ]; then
        [ -d "$mbin/maci64" ] || launch_stop "$MATLAB has neither bin/maca64 nor bin/maci64 - not a MATLAB this Mac can run."
        arch -x86_64 /usr/bin/true 2>/dev/null || launch_stop "$MATLAB is the Intel build, and Rosetta isn't installed. Install it with:
  softwareupdate --install-rosetta --agree-to-license"
        RUN=(arch -x86_64)
        echo "MATLAB: $MATLAB (Intel build, run under Rosetta on this Apple Silicon Mac)"
    else
        echo "MATLAB: $MATLAB"
    fi
}
