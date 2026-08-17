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

# pwsh (PowerShell 7+) bevorzugen, aber nur wenn es wirklich startet.
# Ohne installiertes PowerShell 7 liegt unter WindowsApps nur ein 2-Byte-Alias-Stub,
# den WSL nicht ausfuehren kann. Der Testaufruf sortiert diesen Fall aus.
if pwsh.exe -NoProfile -Command 'exit 0' >/dev/null 2>&1; then
    PS_EXE="pwsh.exe"
elif powershell.exe -NoProfile -Command 'exit 0' >/dev/null 2>&1; then
    PS_EXE="powershell.exe"
else
    echo "Fehler: Kein funktionierendes PowerShell erreichbar." >&2
    echo "Meist fehlt die WSL-Interop-Registrierung. Pruefen mit:" >&2
    echo "  ls /proc/sys/fs/binfmt_misc/WSLInterop" >&2
    echo "Wiederherstellen mit:" >&2
    echo "  sudo sh -c 'echo \":WSLInterop:M::MZ::/init:PF\" > /proc/sys/fs/binfmt_misc/register'" >&2
    exit 1
fi

echo "Starte Mouse Jiggle (Intervall ${INTERVAL}s, Versatz ${PIXELS}px) via $PS_EXE. Strg+C zum Beenden."
"$PS_EXE" -NoProfile -ExecutionPolicy Bypass -File "$WIN_PATH" -IntervalSeconds "$INTERVAL" -Pixels "$PIXELS"
