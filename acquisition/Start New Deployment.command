#!/bin/bash
# Double-click to open the Start New Deployment window (writes fctd_epsi's
# Setup file). Copy or alias this file to the Desktop; it finds the scripts
# next to wherever the original lives.
SRC="$(cd "$(dirname "$(readlink "$0" || echo "$0")")" && pwd)"
[ -f "$SRC/start_new_deployment.py" ] || SRC="$(cd "$(dirname "$0")" && pwd)"
PY="$(command -v python3)"
if [ -z "$PY" ]; then
    echo "python3 not found - install it (e.g. Xcode command line tools or miniconda) and try again."
    read -n 1 -s -r -p "Press any key to close"; exit 1
fi
if ! "$PY" -c "import tkinter" 2>/dev/null; then
    echo "$PY has no tkinter - use a python3 that includes it (e.g. python.org or miniconda)."
    read -n 1 -s -r -p "Press any key to close"; exit 1
fi
cd "$SRC" && "$PY" start_new_deployment.py
