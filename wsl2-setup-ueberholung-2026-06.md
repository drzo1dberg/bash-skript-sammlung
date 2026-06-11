# WSL2 Setup Überholung, Juni 2026

Am 11.06.2026 wurde das komplette WSL2-Debian-Setup analysiert und überholt: Shell-History, Dotfiles, installierte Tools, WSL-Interop und die nvim-Konfiguration. Dieses Dokument hält fest, was gefunden wurde, was geändert wurde und warum. Der komplette Altstand liegt als Backup unter `~/.dotfiles-backup-2026-06-11/`.

Aktiviert wird alles mit `reload` oder einer neuen Shell.

## Wie analysiert wurde

Die Grundlage war keine Geschmacksfrage, sondern Daten. Die gesamte `~/.bash_history` wurde auf wiederkehrende Muster ausgewertet, jedes Dotfile gelesen, jedes relevante Tool auf Existenz geprüft. Daraus entstanden 53 Alias- und Verbesserungskandidaten. Jeder einzelne wurde danach auf dem Live-System gegengeprüft: Namenskollisionen mit Binaries und Builtins, Bash-Syntax, tatsächliches Verhalten. Die WSL-Clipboard-Funktionen wurden byte-genau getestet, inklusive Umlauten und CRLF-Zeilenenden. Ein zweiter Prüfschritt strich alles, was kein belegtes Muster in der Arbeitsweise hat. Übrig blieben 34 Vorschläge, 19 wurden begründet verworfen.

Das Leitprinzip: ein Alias muss ein echtes, belegtes Muster abkürzen. Alles andere wird ein Alias-Museum, das niemand pflegt und niemand benutzt.

## Gefundene Fehler und ihre Fixes

### vi landete im falschen Editor

Die History zeigt 15 Aufrufe von `vi`. Auf dem System zeigt `/usr/bin/vi` über das Debian-Alternatives-System auf `vim.tiny`, eine kastrierte vim-Variante ohne Plugins und ohne die eigene Konfiguration. Jeder dieser Aufrufe lief also am einzigen echten Editor nvim vorbei. Fix: `vi` und `vim` sind jetzt Aliases auf `nvim`.

### Das please-Alias war kaputt

Das alte `alias please='sudo $(fc -ln -1)'` sollte das letzte Kommando mit sudo wiederholen. Durch die ungeschützte Command-Substitution wurden Quotes zu literalen Zeichen und Pipes zu normalen Argumenten. sudo führte damit in etlichen Fällen ein anderes Kommando aus als gedacht. Fix: `please` ist jetzt eine Funktion, `sudo bash -c "$(fc -ln -1)"`. Quotes, Pipes und Redirects bleiben erhalten. Einschränkung: eigene Aliases stehen innerhalb von `bash -c` nicht zur Verfügung.

### Die History war auf Verlust konfiguriert

`HISTSIZE=1000` und `HISTFILESIZE=2000` sind für intensive Nutzung viel zu klein, die Datei stand kurz vor der Rotation. Schlimmer: ohne `history -a` nach jedem Kommando überschreiben sich parallele tmux-Panes gegenseitig die History, und genau dieses Setup läuft hier dauerhaft mit vielen Sessions. Die wertvollen Langbefehle, etwa `az role assignment` oder `claude --resume` mit UUID, wären als erste verschwunden. Fix: 100000 Einträge, Zeitstempel über `HISTTIMEFORMAT`, Deduplizierung über `erasedups`, sofortiges Schreiben über `PROMPT_COMMAND="history -a"`.

### fzf war installiert und nie aktiv

fzf lag auf dem System, aber die Key-Bindings unter `/usr/share/doc/fzf/examples/` wurden nirgends gesourct. Damit fehlten Ctrl-R für Fuzzy-History-Suche, Ctrl-T für Dateiauswahl und Alt-C für Verzeichniswechsel. Wie sehr das fehlte, zeigt die History selbst: neun Anläufe mit Vertippern wie `jigglE`, `jigglere` und `jiggl` plus eine find-Suche, nur um ein Script wiederzufinden, das Ctrl-R in zwei Sekunden geliefert hätte. Fix: beide Dateien werden jetzt gesourct, als Default-Finder läuft `fd`.

### gh konnte keinen Browser öffnen

`gh pr view --web` und alle anderen `--web`-Pfade waren funktionslos: kein `BROWSER` gesetzt, keine gh-Browser-Config, kein `wslview` installiert. Der xdg-open-Fallback scheitert unter WSL, weil er intern `explorer.exe` aufruft und dessen Exit-Code 1 als Fehler wertet. Fix: ein kleines Script `~/.local/bin/wsl-open` öffnet URLs, Dateien und Verzeichnisse über `rundll32.exe url.dll,FileProtocolHandler`. Das liefert saubere Exit-Codes, getestet für Dateien, Verzeichnisse und URLs. In der `.bashrc` ist es als `BROWSER` exportiert.

### tmux bremste nvim aus

Ohne gesetztes `escape-time` wartet tmux 500 Millisekunden nach jedem ESC, ob noch eine Escape-Sequenz folgt. Für einen vim-Nutzer heißt das: jeder Wechsel vom Insert- in den Normal-Mode fühlt sich träge an, in jedem Pane, den ganzen Tag. Fix: `escape-time 10`. Dazu `renumber-windows on` gegen Lücken in der Fensternummerierung, und Splits sowie neue Fenster starten jetzt im aktuellen Pfad statt im Home-Verzeichnis.

### tn scheiterte an existierenden Sessions

`tn` war das meistgenutzte tmux-Kommando der History, schlug aber mit `duplicate session` fehl, sobald der Name schon existierte. Fix: `tn` ist jetzt eine Funktion mit `tmux new-session -A`, die bei existierender Session attacht. Damit ist `tn name` das einzige nötige Einstiegskommando.

### Vier Bugs in der nvim-Konfiguration

1. `after/ftplugin/markdown.lua` rief `vim.diagnostic.enable(false)` ohne Filter auf. Das schaltet Diagnostics global für die ganze Session ab. Sobald die erste Markdown-Datei offen war, verschwanden LSP-Diagnostics in allen Buffern, auch in Lua, YAML und Go. Fix: `vim.diagnostic.enable(false, { bufnr = 0 })`, wirkt nur noch auf den Markdown-Buffer.
2. Das Harpoon-Menü auf `<leader>hh` konnte sich nie öffnen. harpoon2 verlangt die Liste als Argument von `toggle_quick_menu`, ohne Argument schließt es nur. Fix: die Liste wird jetzt übergeben.
3. In `lua/custom/plugins/init.lua` stand ein `rtp:prepend` auf `/home/user/.opam/...`, ein toter Pfad von einer fremden Maschine. Der Home-User hier heißt `nunesjacobs`, opam existiert nicht. Zeile entfernt.
4. Das which-key-Label für `<leader>h` behauptete `Git Hunk`, real liegt dort Harpoon. Label korrigiert.

Geprüft und für gesund befunden: das System-Clipboard in nvim. `xclip` läuft über WSLg, yank landet im Windows-Clipboard und zurück, in beide Richtungen real getestet. Kein Eingriff nötig.

### Doppelter PATH-Eintrag

Die `.profile` hängte `~/.local/bin` doppelt an den PATH, einmal über den Debian-Standardblock und einmal über eine von pipx generierte Zeile. Die pipx-Zeile ist entfernt.

## Das neue Alias-Set

Alles liegt in `~/.bash_aliases`, thematisch gruppiert. Am Dateianfang steht ein `unalias`-Guard, damit `reload` in laufenden Shells sicher ist. Ohne ihn bricht das Sourcen ab, wenn ein alter Alias gleichen Namens beim Parsen einer Funktionsdefinition expandiert.

### Editor

| Kommando | Bedeutung |
|---|---|
| `v` | nvim, wie bisher |
| `vi`, `vim` | nvim, statt versehentlich vim.tiny |
| `bat` | batcat, Debian nennt das Binary so |

### Git

Das Kurz-Set folgt der tatsächlichen Nutzung: `git status` war mit 20 von 66 git-Aufrufen das häufigste Subkommando.

| Kommando | Bedeutung |
|---|---|
| `gs` | `git status` |
| `ga` | `git add`, gezielt mit Argumenten |
| `gaa` | `git add .` |
| `gc` | `git commit`, öffnet nvim für die Message |
| `gcm fix typo` | Commit mit Message direkt aus den Argumenten |
| `gp` | `git push` |
| `gl` | Graph-Log, letzte 15 Einträge |
| `gd` | `git diff` |
| `gco`, `gsw` | checkout und switch, beide mit Branch-Completion |

Dazu zwei Funktionen, die die eigene Branch-Disziplin als je ein Kommando umsetzen:

`gpu` pusht den aktuellen Branch mit `-u origin` und ruft direkt `gh pr create --fill` auf. Existiert der PR schon, öffnet er sich im Browser. Auf `main` oder `master` verweigert die Funktion den Dienst, damit die Regel Feature-Branch-zuerst hält.

`gclean` stellt den Default-Endzustand her: auf den Default-Branch wechseln, `pull --ff-only`, `fetch --prune`, dann alle gemergten Branches lokal und remote löschen. Der Default-Branch wird aus `origin/HEAD` ermittelt statt hart kodiert, gelöscht wird mit `-d` statt `-D` als Sicherheitsnetz.

### Terraform

Die History zeigt 41 terraform-Aufrufe, immer im selben Zyklus: fmt, validate, plan, apply, destroy.

| Kommando | Bedeutung |
|---|---|
| `tf` | `terraform`, mit funktionierender Completion |
| `tff` | `terraform fmt -recursive`, erfasst auch Module in Unterverzeichnissen |
| `tfv` | `terraform validate` |
| `tfi` | `terraform init` |
| `tfp` | `terraform plan -out tfplan` |
| `tfc` | der ganze Pre-Apply-Zyklus: fmt, validate, plan, bricht bei Fehlern früh ab |
| `tfa` | apply nur gegen ein vorhandenes `tfplan`, räumt es nach Erfolg weg |
| `tfd` | `terraform destroy` |

`tfa` ist bewusst eine Funktion statt eines blinden `terraform apply tfplan`. Fehlt die Plan-Datei, gibt es eine klare Meldung statt eines Fehlers. Nach erfolgreichem Apply wird `tfplan` gelöscht, damit nie ein veralteter Plan liegen bleibt. Genau diese Planfile-Verwirrung ist in der History mehrfach dokumentiert.

Die Completion für `tf` brauchte eine eigene Zeile in der `.bashrc`, weil die terraform-Completion über `complete -C` am Kommandonamen hängt: `complete -C /usr/bin/terraform tf`.

### Azure, Docker, GitHub CLI

| Kommando | Bedeutung |
|---|---|
| `az-typo3` | das vollständige `az ssh vm` auf die TYPO3-Test-VM, der längste wiederkehrende Einzeiler der History |
| `dctx` | Docker-Context-Toggle zwischen `default` und `desktop-linux`, mit Argument expliziter Wechsel |
| `prs` | `gh pr status`, eigene PRs und Review-Anfragen auf einen Blick |
| `prv` | `gh pr view --web`, funktioniert jetzt dank `wsl-open` |
| `lpvar NAME WERT` | setzt eine GitHub-Variable in allen vier Landingpage-Repos, ersetzt eine fünfmal getippte for-Schleife |
| `tfrun repo [apply\|destroy]` | startet den Terraform-Workflow eines Repos remote über `gh workflow run` |
| `k` | `kubectl`, mit Completion |

### tmux und Claude

| Kommando | Bedeutung |
|---|---|
| `t` | Hauptsession `main`, attacht falls vorhanden |
| `tn name` | neue Session oder attach, scheitert nicht mehr an Duplikaten |
| `tl`, `ta`, `tk` | list, attach, kill-session |
| `tsrc` | tmux-Config neu laden, war achtmal voll ausgetippt |
| `tconf` | Config editieren und direkt neu laden |
| `clc` | `claude --continue` |
| `clr` | `claude --resume`, ohne Argument mit Session-Picker |

### WSL-Brücke zu Windows

Die Namen folgen macOS, weil das die etablierte Muscle-Memory für genau diese Gesten ist.

| Kommando | Bedeutung |
|---|---|
| `pbcopy` | stdin oder Dateien ins Windows-Clipboard, etwa `git diff \| pbcopy` |
| `pbpaste` | Windows-Clipboard nach stdout, CRLF wird gestrippt |
| `open` | Datei, Verzeichnis oder URL mit Windows öffnen, ohne Argument das aktuelle Verzeichnis |
| `cpath` | Windows-Pfad eines Verzeichnisses oder einer Datei ins Clipboard, für Explorer-Adressleiste und Dialoge |
| `pubkey name` | Public Key anzeigen und gleichzeitig ins Clipboard legen |
| `dl` | Sprung in den Windows-Downloads-Ordner |

Zwei Details aus den Tests, die diese Funktionen robuster machen als die naheliegenden Einzeiler: `Get-Clipboard` liefert CRLF-Zeilenenden und hängt über `Write-Output` ein zusätzliches Newline an, deshalb läuft `pbpaste` über `[Console]::Out.Write` plus sed. Und `explorer.exe` liefert grundsätzlich Exit-Code 1, deshalb nutzt `open` den `rundll32`-Weg.

`pubkey` hat übrigens einen dokumentierten Vorgänger-Unfall: in der History liegt ein `cat key.pub > xcopy.exe`, das statt zu kopieren eine Datei namens `xcopy.exe` im Home erzeugt hat. Die liegt da immer noch und kann weg.

### Navigation und Sonstiges

| Kommando | Bedeutung |
|---|---|
| `repo` | Fuzzy-Sprung in eines der rund 20 Projekt-Repos, über fd und fzf |
| `mkcd` | Verzeichnis anlegen und hineinwechseln |
| `psg name` | Prozesssuche ohne das grep-Echo |
| `week` | öffnet die Obsidian-Wochennotiz über `nvim +ObsidianThisWeek` |
| `vl` | Zettelkasten-Tagesnotiz, unverändert |
| `work`, `vault`, `findgit` | wie bisher |

Statt eines ssh-Alias gibt es jetzt Host-Einträge in `~/.ssh/config`: `ssh typo3-test` und `ssh coremw-test`. Das ist dem Alias überlegen, weil es auch für `scp` und `sftp` gilt und die IP nur an einer Stelle steht.

## Änderungen je Datei

| Datei | Änderung |
|---|---|
| `~/.bash_aliases` | komplett neu strukturiert, alle Aliases oben beschrieben, `please` und `nvim-sync` gefixt |
| `~/.bashrc` | History-Block, `shopt -s globstar autocd cdspell dirspell histverify`, fzf-Bindings, kubectl-Completion, git-Completion für `gco` und `gsw`, tf-Completion, `BROWSER`-Export |
| `~/.gitconfig` | `push.autoSetupRemote`, `fetch.prune`, `merge.conflictstyle zdiff3`, `branch.sort -committerdate`, git-Aliases `st`, `br`, `lg` |
| `~/.tmux.conf` | `escape-time 10`, `renumber-windows on`, Splits und neue Fenster im aktuellen Pfad |
| `~/.profile` | doppelten PATH-Eintrag von pipx entfernt |
| `~/.ssh/config` | Host-Einträge `typo3-test` und `coremw-test` |
| `~/.local/bin/wsl-open` | neu, Browser- und Datei-Opener für WSL |
| `~/.config/nvim/` | vier Bugfixes, siehe oben |

Zur `.gitconfig`: `push.autoSetupRemote` passt exakt zur eigenen Regel, dass jeder lokale Branch gepusht wird. `git push` reicht ab jetzt auch beim ersten Push eines neuen Branches, das `-u origin branchname` entfällt. `fetch.prune` räumt remote gelöschte Branches automatisch aus der lokalen Sicht, was bei der Menge an Repos sonst Handarbeit ist. `zdiff3` zeigt in Konflikten zusätzlich den gemeinsamen Vorfahren, das macht Merge-Entscheidungen deutlich leichter.

Zu den shopt-Optionen: `autocd` wechselt in ein Verzeichnis, wenn man nur dessen Namen tippt. `cdspell` und `dirspell` korrigieren Tippfehler in Pfaden. `histverify` zeigt History-Expansionen wie `!!` erst an, bevor sie laufen, eine Absicherung bei sudo-nahen Kommandos. `globstar` aktiviert `**`-Globs, nützlich in Terraform-Modulstrukturen.

## Was bewusst nicht übernommen wurde

19 Kandidaten flogen raus. Die wichtigsten Begründungen, weil sie das Prinzip zeigen:

- Typo-Aliases wie `cls`, `rl` und `:q` zementieren Fehlgriffe, statt sie zu korrigieren. Die fzf-History-Suche löst das Problem an der Wurzel.
- Ein `cc`-Alias für Claude hätte den C-Compiler verschattet. Mit go, cargo und make auf dem System ist das ein realistisches Risiko. Stattdessen `clc` und `clr`.
- `winhome`, `psh`, `wslstatus` und `wslrestart` haben kein einziges belegtes Muster in der History. Naheliegend ist kein Beleg.
- Ein generisches `azssh` für beliebige VMs klingt gut, aber belegt ist genau eine VM, und dafür ist `az-typo3` der kürzere und schnellere Treffer. Der nötige `az vm list`-Lookup hätte zudem Sekunden gekostet.
- Ein blindes `alias tfa='terraform apply tfplan'` hätte exakt die Planfile-Fehler wiederholt, die in der History dokumentiert sind. Die Funktionsvariante mit Existenz-Check ist die bessere Antwort.

## Offene Entscheidungen

### Das Stray-Repo in github-repos, wichtigster offener Punkt

`~/github-repos/.git` ist ein versehentlicher Clone von `nvim-config` auf oberster Ebene. Damit ist die gesamte Repo-Sammlung Working-Tree eines Git-Repos. Ein unbedachtes `git add .` oder `git clean` auf dieser Ebene würde alle Arbeits-Repos erfassen. Die `weekly commit`-Commits der letzten Monate liefen gegen dieses kaputte Layout, der Remote-Stand ist entsprechend veraltet. Der korrekte Clone liegt unter `~/github-repos/drzo1dberg/nvim-config`, und das neue `nvim-sync` zielt bereits dorthin. Aufräumen:

```bash
command rm -rf ~/github-repos/.git ~/github-repos/nvim-config
nvim-sync   # spiegelt die Live-Config in den korrekten Clone
# danach im Clone committen und pushen
```

### nvim-Config direkt als Checkout führen

Der sauberste Endzustand wäre, `~/.config/nvim` selbst zum Git-Checkout des Repos zu machen. Dann gibt es genau eine Wahrheit, `lazy-lock.json` wandert automatisch mit jedem Commit, und der Sync-Schritt, der vergessen werden kann, existiert nicht mehr. Das `nvim-sync` wäre damit Geschichte. Umsetzung erst nach dem Aufräumen des Stray-Repos.

### Kleinere Punkte

- `vl` nutzt das US-Datumsformat `%m-%d-%y`. ISO würde sauber sortieren, aber die Bestandsdateien im Zettelkasten heißen nach altem Schema und müssten mitmigriert werden. Nur als bewusste Entscheidung umsetzen.
- Das nvim-Keymap `<leader>fp` ruft `Telescope project`, aber das Plugin `telescope-project.nvim` ist nicht installiert. Entweder Plugin ergänzen oder Keymap streichen.
- `obsidian.nvim` zeigt auf das archivierte Upstream-Repo von epwalsh. Der gepflegte Community-Fork ist `obsidian-nvim/obsidian.nvim`. Läuft aktuell, bekommt aber keine Fixes mehr.
- Im Home liegen die Artefakte `xcopy.exe` und `table.html`, beide vermutlich löschbar.

## Rollback

Der komplette Altstand von `.bashrc`, `.bash_aliases`, `.profile`, `.tmux.conf` und `.gitconfig` liegt unter `~/.dotfiles-backup-2026-06-11/`. Zurückrollen heißt: Datei zurückkopieren, `reload`. Die nvim-Änderungen sind über das nvim-config-Repo nachvollziehbar, sobald der aktuelle Stand committet ist.
