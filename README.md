# bash-tools-and-scripts

Meine Sammlung eigener Bash-Werkzeuge, dazu Übungs- und Referenzmaterial aus dem Advanced Bash Scripting Guide. Gepflegt unter `~/github-repos/drzo1dberg/bash-tools-and-scripts`, Remote `drzo1dberg/bash-tools-and-scripts`.

Überblick über alle eigenen Tools im PATH, die Wrapper und alle Funktionen gibt der Befehl `tools` aus den Dotfiles.

## Im PATH verfügbar

Diese Skripte sind per Symlink aufrufbar, ohne vollen Pfad:

| Aufruf | Symlink | Zweck |
|---|---|---|
| `jiggle [intervall] [pixel]` | `/usr/local/bin/jiggle` -> `mousejiggle/jiggle.sh` | hält Windows wach, bewegt den Mauszeiger alle paar Sekunden minimal, ruft `jiggle.ps1` über `powershell.exe` |
| `zk-archive` | `~/.local/bin/zk-archive` -> `zk-archive.sh` | Zettelkasten-Archiver, verschiebt alte Notizen nach `Zettelkasten/Archiv/YYYYKW##/`. Läuft als systemd-User-Timer, montags 09:00, eingerichtet von der nvim-config |

## Eigenständige Skripte

| Skript | Zweck |
|---|---|
| `download_mailexport_basicAuth`, `extractLinks_mailExport`, `getEmailsFromList.sh` | Mail-Export holen und Links bzw. Adressen herausziehen |
| `scanForTLS1.2orLess/`, `upgrade_storage_tls/` | TLS-Versionen scannen und Storage-Endpunkte anheben |
| `api-user-export/` | User-Export über eine API |
| `cherry-pick-folder-mover/` | Ordner gezielt zwischen Git-Repos übernehmen |
| `gogo-golang-file-creator/gogo.sh` | Go-Quelldateien aus einer Vorlage anlegen |
| `spotlightdl-bash/` | Windows-Spotlight-Bilder herunterladen |
| `set-catppuccin-theme <flavour>` | Catppuccin-Variante setzen, `latte`, `frappe`, `macchiato` oder `mocha` |
| `cleanup-simple.sh`, `cleanup-midlvl.sh`, `cleanup-pro.sh` | dasselbe Aufräumen in drei Ausbaustufen |
| `random-generator`, `rename-script`, `zmore` | kleine Helfer: Zufallswert, Stapel-Umbenennung, gzip mit `more` |

## Dokumentation

- `wsl2-setup-ueberholung-2026-06.md` ist der ausführliche Guide zur WSL2-Debian-Überholung vom 11.06.2026: History, Dotfiles, Tools, WSL-Interop, nvim. Die Begründungen hinter den Dotfile-Entscheidungen stehen hier.

## Übung und Referenz

Kein produktives Tooling, sondern Lernmaterial. Beim Aufräumen nicht mit den echten Tools verwechseln:

- `advanced-bash-scripting-guide/`, `bash-guide-for-beginners/`: geklonte Guides
- ABS-Übungen: `str-test`, `testing`, `startup-script-abs-guide`, `string-manipulation-exc10-1`, `artithmeticVsStringComparison`, `check-numbers-of-parameters-snippet.sh`, `testingForSymlinks`
