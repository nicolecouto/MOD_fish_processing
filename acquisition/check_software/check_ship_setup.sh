#!/bin/bash
# check_ship_setup.sh - read-only check that a ship computer (DEV1 or DEV3)
# is set up to run this repo: which branch and remotes the clone has, whether
# it is up to date with GitHub, that the acquisition/config.yml folders exist,
# that the MOD_fish_calibrations clone has every file processing needs, what
# is in the processed-data folder (cruise_meta_data.yml, RAW_full_cruise,
# spool_swap_log.csv, a leftover worker.lock), and that python3 with tkinter
# and matlab (and its architecture: an Intel MATLAB on Apple Silicon needs
# Rosetta) are found. Each line starts with OK, FIX (needs doing before a
# test) or note (worth knowing). Nothing is changed except git's view of
# GitHub (git fetch).
#
# Run it on each computer (DEV3 too: the realtime worker uses DEV3's Matlab):
#   bash acquisition/check_software/check_ship_setup.sh [path to the clone]
# The clone defaults to the one this script is in.
SW=/Volumes/DEV1_HD/Users/Shared/Software_current_cruise
R="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
ok()   { echo "  OK    $*"; }
bad()  { echo "  FIX   $*"; }
note() { echo "  note  $*"; }

echo "== Machine: $(hostname -s)   $(date '+%Y-%m-%d %H:%M')"
echo "== Clones in $SW"
for d in "$SW"/*/; do [ -d "$d/.git" ] && echo "  $(basename "$d"): $(git -C "$d" branch --show-current)"; done

echo "== MOD_fish_processing: $R"
if [ ! -d "$R/.git" ]; then bad "not a git clone - pass its path as the argument"; exit 1; fi
cd "$R" || exit 1
B=$(git branch --show-current)
[ "$B" = main-fork ] && ok "on branch main-fork" || bad "on branch '$B' - run: git switch main-fork"
git remote -v | grep -q 'nicolecouto/MOD_fish_processing.*(fetch)' && ok "remote 'fork' -> nicolecouto/MOD_fish_processing" || bad "no remote for your fork - see the setup steps"
git remote -v | grep -q 'modscripps/MOD_fish_processing.*(fetch)' && ok "remote -> modscripps/MOD_fish_processing" || note "no modscripps remote"
UP=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)
[ "$UP" = fork/main-fork ] && ok "main-fork tracks fork/main-fork" || bad "main-fork tracks '$UP' - run: git branch -u fork/main-fork"
git fetch -q --all 2>/dev/null || note "git fetch failed (no internet?) - ahead/behind below may be stale"
read BEH AHE <<<"$(git rev-list --left-right --count @{u}...HEAD 2>/dev/null)"
[ "${BEH:-1}" = 0 ] && ok "up to date with GitHub ($(git log -1 --format='%h %s'))" || bad "$BEH commit(s) behind GitHub - run: git pull"
[ "${AHE:-0}" = 0 ] || note "$AHE local commit(s) not on GitHub"
CH=$(git status --porcelain)
[ -z "$CH" ] && ok "no uncommitted changes" || { note "uncommitted changes:"; echo "$CH" | sed 's/^/          /'; }
[ -f acquisition/last_used.json ] && ok "acquisition/last_used.json present" || note "no acquisition/last_used.json - first Create Setup starts with empty probes and winch spool"

echo "== acquisition/config.yml"
val() { sed -n "s/^$1:[[:space:]]*//p" acquisition/config.yml | sed 's/[[:space:]]*#.*$//; s/^["'\'']//; s/["'\'']$//' | head -1; }
for k in setup_dir processed_root calibrations_root; do
    v=$(val $k); [ -d "$v" ] && ok "$k: $v" || bad "$k: '$v' does not exist"
done
P=$(val processed_root); C=$(val calibrations_root); S=$(val setup_dir)
[ -f "$S/Setup" ] && ok "current Setup: $(grep -m1 'CTD.survey' "$S/Setup")" || note "no Setup in setup_dir yet"
[ -x "$S/fctd_epsi" ] && ok "fctd_epsi found next to Setup" || note "fctd_epsi not found in setup_dir"

echo "== MOD_fish_calibrations: $C"
if [ -d "$C/.git" ]; then
    CB=$(git -C "$C" branch --show-current); [ "$CB" = main ] && ok "on branch main" || bad "on branch '$CB'"
    git -C "$C" fetch -q 2>/dev/null
    read CBEH CAHE <<<"$(git -C "$C" rev-list --left-right --count @{u}...HEAD 2>/dev/null)"
    [ "${CBEH:-1}" = 0 ] && ok "up to date ($(git -C "$C" log -1 --format='%h %s'))" || bad "behind GitHub - run: git -C \"$C\" pull"
elif [ -d "$C" ]; then bad "folder exists but is not a git clone - clone MOD_fish_calibrations there"
fi
[ -n "$(ls "$C"/SBE/*.CAL 2>/dev/null)" ] && ok "SBE/: $(ls "$C"/SBE/*.CAL | wc -l | tr -d ' ') .CAL files" || bad "no SBE/*.CAL"
[ -d "$C/SHEAR_PROBES" ] && ok "SHEAR_PROBES/: $(ls -d "$C"/SHEAR_PROBES/*/ 2>/dev/null | wc -l | tr -d ' ') probes" || bad "no SHEAR_PROBES/"
[ -d "$C/FPO7" ] && ok "FPO7/ present" || bad "no FPO7/"
[ -f "$C/SHEAR/cap1nFres200Meg_5KohmInput.mat" ] && ok "SHEAR/cap1nFres200Meg_5KohmInput.mat" || bad "missing SHEAR/cap1nFres200Meg_5KohmInput.mat (epsilon)"
[ -f "$C/FPO7/FPO7_benchnoise.mat" ] && ok "FPO7/FPO7_benchnoise.mat" || bad "missing FPO7/FPO7_benchnoise.mat (FP07 chi)"

echo "== Processed folder: $P"
[ -f "$P/cruise_meta_data.yml" ] && ok "cruise_meta_data.yml present" || bad "no cruise_meta_data.yml - copy $R/setup/cruise_meta_data_template.yml there and review it"
if [ -e "$P/RAW_full_cruise" ]; then
    ok "RAW_full_cruise: $(ls "$P/RAW_full_cruise" | wc -l | tr -d ' ') files$( [ -L "$P/RAW_full_cruise" ] && echo " (link to $(readlink "$P/RAW_full_cruise"))")"
else note "no RAW_full_cruise yet (the worker keeps looking for it)"; fi
[ -f "$P/realtime/worker.lock" ] && note "realtime/worker.lock exists: $(cat "$P/realtime/worker.lock")"
[ -f "$P/spool_swap_log.csv" ] && ok "spool_swap_log.csv, last row: $(tail -1 "$P/spool_swap_log.csv")" || note "no spool_swap_log.csv yet (first Create Setup writes it)"
[ -d "$P" ] && echo "  contents: $(ls "$P" | tr '\n' ' ')"

echo "== Tools"
python3 -c 'import tkinter' 2>/dev/null && ok "python3 with tkinter ($(python3 --version 2>&1))" || bad "python3 with tkinter not found (Start New Deployment needs it)"
M=$(command -v matlab || ls -d /Applications/MATLAB_R20*.app/bin/matlab 2>/dev/null | tail -1)
[ -n "$M" ] && ok "matlab: $M" || note "matlab not found (needed on DEV3 only)"
# Apple Silicon + an Intel-only MATLAB: works under Rosetta (Start Realtime
# Processing.command adds arch -x86_64), slower than a native MATLAB
APPLE=$(sysctl -n hw.optional.arm64 2>/dev/null)
for app in /Applications/MATLAB_R20*.app; do
    [ -d "$app/bin" ] || continue
    A=$(ls "$app/bin" | grep -E '^mac(a|i)64$' | tr '\n' ' ')
    note "$(basename "$app"): ${A:-no mac build}"
done
if [ -n "$M" ] && [ "$APPLE" = 1 ]; then
    MB="$(cd "$(dirname "$(readlink "$M" || echo "$M")")" && pwd)"
    if [ ! -d "$MB/maca64" ] && [ -d "$MB/maci64" ]; then
        if arch -x86_64 /usr/bin/true 2>/dev/null; then
            note "Apple Silicon Mac with an Intel MATLAB: runs under Rosetta (slower than a native R2023b+ MATLAB)"
        else
            bad "Intel MATLAB on Apple Silicon needs Rosetta - run: softwareupdate --install-rosetta --agree-to-license"
        fi
    fi
fi
