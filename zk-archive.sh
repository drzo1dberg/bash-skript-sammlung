#!/usr/bin/env bash
# ============================================================================
# zk-archive.sh
# Verschiebt alte Zettelkasten-Dateien in wochenweise Archiv-Ordner.
#
# Erwartetes Dateinamen-Format : MM-DD-YY.md   (z.B. 05-26-26.md)
# Archiv-Layout                : Archiv/YYYYKW## (z.B. Archiv/2026KW20)
# Gruppiert nach ISO-Woche (%G/%V) des Datums *im Dateinamen*, nicht mtime.
#
# Retention zaehlt in ISO-Kalenderwochen, nicht in Tagen:
#   RETENTION_WEEKS=2 => aktuelle Woche + 1 vorhergehende Woche bleiben.
#   Cutoff ist Montag 00:00 dieser aeltesten behaltenen Woche.
#   D.h. am Dienstag werden Montag der gleichen Woche NICHT mit wegsortiert.
#
# Default: Dry-Run. Mit --apply werden Dateien tatsaechlich bewegt.
#
# Usage:
#   zk-archive.sh              # dry-run (zeigt nur was passieren wuerde)
#   zk-archive.sh --apply      # fuehrt die Verschiebungen aus
#   ZK_DIR=/anderer/pfad zk-archive.sh --apply
# ============================================================================

set -euo pipefail

# ---- Magic numbers / konfigurierbar ----------------------------------------
ZK_DIR="${ZK_DIR:-$HOME/bf/Zettelkasten}"   # Quelle
ARCHIVE_SUBDIR="Archiv"                     # Unterordner unter ZK_DIR
RETENTION_WEEKS=2                           # Anzahl ISO-Wochen die bleiben
                                            #   1 = nur aktuelle Woche
                                            #   2 = aktuelle + letzte Woche
FILE_GLOB='??-??-??.md'                     # Filter: MM-DD-YY.md
DATE_REGEX='^([0-9]{2})-([0-9]{2})-([0-9]{2})\.md$'
CENTURY_PREFIX='20'                         # YY -> 20YY
# ----------------------------------------------------------------------------

apply=0
for arg in "${@:-}"; do
  case "$arg" in
    --apply)   apply=1 ;;
    --dry-run) apply=0 ;;
    -h|--help)
      sed -n '2,21p' "$0"
      exit 0
      ;;
    "") : ;;
    *)
      echo "Unbekannte Option: $arg" >&2
      exit 2
      ;;
  esac
done

[[ -d "$ZK_DIR" ]] || { echo "ZK_DIR existiert nicht: $ZK_DIR" >&2; exit 1; }
(( RETENTION_WEEKS >= 1 )) || { echo "RETENTION_WEEKS muss >= 1 sein" >&2; exit 1; }

# Cutoff = Montag 00:00 der aeltesten behaltenen ISO-Woche.
# Schritt 1: Montag der aktuellen Woche (dow: Mo=1..So=7)
dow=$(date +%u)
current_monday=$(date -d "$((dow - 1)) days ago" +%Y-%m-%d)
# Schritt 2: (RETENTION_WEEKS - 1) Wochen davor
weeks_back=$((RETENTION_WEEKS - 1))
cutoff_date=$(date -d "$current_monday -$weeks_back weeks" +%Y-%m-%d)
cutoff_epoch=$(date -d "$cutoff_date 00:00:00" +%s)
cutoff_year=$(date -d "$cutoff_date" +%G)
cutoff_week=$(date -d "$cutoff_date" +%V)
today_human=$(date +%Y-%m-%d)

mode_label="DRY-RUN"; (( apply )) && mode_label="APPLY"
echo "[$mode_label] Zettelkasten: $ZK_DIR"
echo "[$mode_label] Heute:        $today_human"
echo "[$mode_label] Cutoff:       $cutoff_date  (Mo ${cutoff_year}KW${cutoff_week}, behalte ${RETENTION_WEEKS} KW)"
echo

moved=0
kept=0
skipped=0

shopt -s nullglob
for f in "$ZK_DIR"/$FILE_GLOB; do
  bn=$(basename "$f")

  if [[ ! $bn =~ $DATE_REGEX ]]; then
    echo "skip (kein Datums-Match): $bn"
    skipped=$((skipped + 1))
    continue
  fi

  mm="${BASH_REMATCH[1]}"
  dd="${BASH_REMATCH[2]}"
  yy="${BASH_REMATCH[3]}"
  iso_date="${CENTURY_PREFIX}${yy}-${mm}-${dd}"

  if ! file_epoch=$(date -d "$iso_date 00:00:00" +%s 2>/dev/null); then
    echo "skip (ungueltiges Datum): $bn"
    skipped=$((skipped + 1))
    continue
  fi

  if (( file_epoch >= cutoff_epoch )); then
    kept=$((kept + 1))
    continue
  fi

  iso_year=$(date -d "$iso_date" +%G)
  iso_week=$(date -d "$iso_date" +%V)
  rel_dir="${ARCHIVE_SUBDIR}/${iso_year}KW${iso_week}"
  target_dir="$ZK_DIR/$rel_dir"
  target="$target_dir/$bn"

  if (( apply )); then
    mkdir -p "$target_dir"
    if mv -n -- "$f" "$target"; then
      echo "moved:      $bn -> $rel_dir/"
      moved=$((moved + 1))
    else
      echo "FEHLER beim Verschieben: $bn" >&2
      skipped=$((skipped + 1))
    fi
  else
    echo "would move: $bn -> $rel_dir/"
    moved=$((moved + 1))
  fi
done

echo
echo "Zusammenfassung: moved=$moved  kept=$kept  skipped=$skipped"
(( apply )) || echo "Hinweis: Dry-Run. Mit --apply tatsaechlich verschieben."
exit 0
