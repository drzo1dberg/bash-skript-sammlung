#!/usr/bin/env bash
# Launcher: ruft jiggle.ps1 von WSL aus via powershell.exe auf.
# Nutzung:
#   ./jiggle.sh                  # Standard (30s, 3px)
#   ./jiggle.sh 15 5             # Intervall 15s, 5px Versatz

set -e

INTERVAL="${1:-30}"
PIXELS="${2:-3}"

# readlink -f folgt Symlinks -> findet die echte Lage der .ps1
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
WIN_PATH="$(wslpath -w "$SCRIPT_DIR/jiggle.ps1")"

# pwsh (PowerShell 7+) bevorzugen, sonst Fallback auf altes powershell.exe
if command -v pwsh.exe >/dev/null 2>&1; then
    PS_EXE="pwsh.exe"
else
    PS_EXE="powershell.exe"
fi

echo "Starte Mouse Jiggle (Intervall ${INTERVAL}s, Versatz ${PIXELS}px) via $PS_EXE. Strg+C zum Beenden."
"$PS_EXE" -NoProfile -ExecutionPolicy Bypass -File "$WIN_PATH" -IntervalSeconds "$INTERVAL" -Pixels "$PIXELS"
