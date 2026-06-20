# bash-tools-and-scripts

My collection of personal Bash tools, plus practice and reference material from the Advanced Bash Scripting Guide. Maintained at `~/github-repos/drzo1dberg/bash-tools-and-scripts`, remote `drzo1dberg/bash-tools-and-scripts`.

The `tools` command from the dotfiles prints an overview of all personal tools on the PATH, the wrappers, and all functions.

## Available on the PATH

These scripts are callable via symlink, without the full path:

| Command | Symlink | Purpose |
|---|---|---|
| `jiggle [interval] [pixels]` | `/usr/local/bin/jiggle` -> `mousejiggle/jiggle.sh` | keeps Windows awake; nudges the mouse pointer slightly every few seconds; calls `jiggle.ps1` via `powershell.exe` |
| `zk-archive` | `~/.local/bin/zk-archive` -> `zk-archive.sh` | Zettelkasten archiver; moves old notes to `Zettelkasten/Archiv/YYYYKW##/`. Runs as a systemd user timer, Mondays 09:00, set up by the nvim config |
| `catdir [-e ext] [-x glob] [-p] [path]` | `~/.local/bin/catdir` -> `catdir` | prints all files in a directory recursively as ONE scrollable stream (code via `bat`/`batcat`, markdown via `glow`); no pager -> scrollable in tmux copy-mode, `-p` forces `less`. `-e` filters by extension, `-x` excludes by glob (files or folders); shellcheck-clean |

## Standalone scripts

| Script | Purpose |
|---|---|
| `download_mailexport_basicAuth`, `extractLinks_mailExport`, `getEmailsFromList.sh` | fetch the mail export and pull out links or addresses |
| `scanForTLS1.2orLess/`, `upgrade_storage_tls/` | scan TLS versions and raise storage endpoints |
| `api-user-export/` | user export via an API |
| `cherry-pick-folder-mover/` | move specific folders between Git repos |
| `gogo-golang-file-creator/gogo.sh` | create Go source files from a template |
| `spotlightdl-bash/` | download Windows Spotlight images |
| `set-catppuccin-theme <flavour>` | set the Catppuccin flavour: `latte`, `frappe`, `macchiato`, or `mocha` |
| `cleanup-simple.sh`, `cleanup-midlvl.sh`, `cleanup-pro.sh` | the same cleanup in three levels |
| `random-generator`, `rename-script`, `zmore` | small helpers: random value, batch rename, gzip piped through `more` |

## Documentation

- `wsl2-setup-ueberholung-2026-06.md` is the detailed guide to the WSL2/Debian overhaul from 2026-06-11: history, dotfiles, tools, WSL interop, nvim. The rationale behind the dotfile decisions lives here.

## Practice & reference

Not production tooling but learning material. When cleaning up, don't confuse these with the real tools:

- `advanced-bash-scripting-guide/`, `bash-guide-for-beginners/`: cloned guides
- ABS exercises: `str-test`, `testing`, `startup-script-abs-guide`, `string-manipulation-exc10-1`, `artithmeticVsStringComparison`, `check-numbers-of-parameters-snippet.sh`, `testingForSymlinks`
