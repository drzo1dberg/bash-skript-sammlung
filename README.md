# bash-tools-and-scripts

My collection of personal Bash tools, plus practice and reference material from the Advanced Bash Scripting Guide. Maintained at `~/github-repos/drzo1dberg/bash-tools-and-scripts`, remote `drzo1dberg/bash-tools-and-scripts`.

The `tools` command from the dotfiles prints an overview of all personal tools on the PATH, the wrappers, and all functions.

## Layout

| Directory | Content |
|---|---|
| `bin/` | small standalone CLI tools, some symlinked into `~/.local/bin` |
| `mail-export/` | fetch the mail export and pull out links or addresses |
| `docs/` | longer-form documentation |
| `learning/` | practice and reference material, not production tooling |
| everything else | one directory per tool or helper, see below |

## Available on the PATH

These scripts are callable via symlink, without the full path:

| Command | Symlink | Purpose |
|---|---|---|
| `jiggle [interval] [pixels]` | `~/.local/bin/jiggle` -> `mousejiggle/jiggle.sh` | keeps Windows awake; nudges the mouse pointer slightly every few seconds; calls `jiggle.ps1` via `powershell.exe` |
| `zk-archive` | `~/.local/bin/zk-archive` -> `bin/zk-archive` | Zettelkasten archiver; moves old notes to `Zettelkasten/Archiv/YYYYKW##/`. Runs as a systemd user timer, Mondays 09:00, set up by the nvim config |
| `catdir [-e ext] [-x glob] [-p] [path]` | `~/.local/bin/catdir` -> `bin/catdir` | prints all files in a directory recursively as ONE scrollable stream (code via `bat`/`batcat`, markdown via `glow`); no pager -> scrollable in tmux copy-mode, `-p` forces `less`. `-e` filters by extension, `-x` excludes by glob (files or folders); shellcheck-clean |

`bin/` also holds `set-catppuccin-theme <flavour>`, which sets the Catppuccin flavour: `latte`, `frappe`, `macchiato`, or `mocha`. Not symlinked.

## Tool directories

| Script | Purpose |
|---|---|
| `mail-export/` | `download_mailexport_basicAuth`, `extractLinks_mailExport`, `getEmailsFromList.sh`: fetch the mail export and pull out links or addresses |
| `scanForTLS1.2orLess/`, `upgrade_storage_tls/` | scan TLS versions and raise storage endpoints |
| `api-user-export/` | user export via an API |
| `cherry-pick-folder-mover/` | move specific folders between Git repos |
| `gogo-golang-file-creator/gogo.sh` | create Go source files from a template |
| `spotlightdl-bash/` | download Windows Spotlight images |
| `mousejiggle/` | see `jiggle` above |
| `kv-edit-window/`, `kv-human-role/`, `kv-seed-appreg-secret/`, `sql-contained-users/` | Azure post-apply helpers (env-based, device-code login): temp Key Vault public window for one IP, grant/revoke a KV role by UPN, seed FE/BE app-registration client secrets into a KV, create contained SQL users for managed identities. shellcheck-clean |
| `mail-grant-exo-script/` | Exchange Online and Entra mail-permission helpers |

## Documentation

- `docs/wsl2-setup-ueberholung-2026-06.md` is the detailed guide to the WSL2/Debian overhaul from 2026-06-11: history, dotfiles, tools, WSL interop, nvim. The rationale behind the dotfile decisions lives here.

## Practice & reference

Everything under `learning/` is learning material, not production tooling. When cleaning up, don't confuse these with the real tools:

- `learning/advanced-bash-scripting-guide/`, `learning/bash-guide-for-beginners/`: cloned guides
- `learning/abs-exercises/`: exercises and examples from the ABS guide, among them `str-test`, `testing`, `startup-script-abs-guide`, `string-manipulation-exc10-1`, `artithmeticVsStringComparison`, `check-numbers-of-parameters-snippet.sh`, `testingForSymlinks`, the three `cleanup-*.sh` stages, `random-generator`, `rename-script`, `zmore`
