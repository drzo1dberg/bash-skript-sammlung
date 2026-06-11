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
3. In `lua/custom/plugins/init.lua` stand ein `rtp:prepend` auf `/home/<user>/.opam/...`, ein toter Pfad von einer fremden Maschine, opam existiert hier nicht. Zeile entfernt.
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

Terraform bekam zunächst ein eigenes Alias-Set, das später bewusst wieder verschwand. Die Begründung steht im Nachtrag weiter unten, der Abschnitt ist deshalb hier raus.

### Docker und kubectl

| Kommando | Bedeutung |
|---|---|
| `dctx` | Docker-Context-Toggle zwischen `default` und `desktop-linux`, mit Argument expliziter Wechsel |
| `k` | `kubectl`, mit Completion |

### tmux

| Kommando | Bedeutung |
|---|---|
| `t` | Hauptsession `main`, attacht falls vorhanden |
| `tn name` | neue Session oder attach, scheitert nicht mehr an Duplikaten |
| `tl`, `ta`, `tk` | list, attach, kill-session |
| `tsrc` | tmux-Config neu laden, war achtmal voll ausgetippt |
| `tconf` | Config editieren und direkt neu laden |

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
| `vl` | Zettelkasten-Tagesnotiz; `vl -1` öffnet die letzte existierende Notiz vor heute, `vl -2` die davor, siehe Nachtrag |
| `work`, `vault`, `findgit` | wie bisher |

## Änderungen je Datei

| Datei | Änderung |
|---|---|
| `~/.bash_aliases` | komplett neu strukturiert, alle Aliases oben beschrieben, `please` gefixt, `nvim-sync` zunächst gefixt und im Nachtrag ersatzlos entfernt |
| `~/.bashrc` | History-Block, `shopt -s globstar autocd cdspell dirspell histverify`, fzf-Bindings, kubectl-Completion, git-Completion für `gco` und `gsw`, `BROWSER`-Export. Die zunächst ergänzte `tf`-Completion ist mit den Terraform-Aliases wieder raus, siehe Nachtrag |
| `~/.gitconfig` | `push.autoSetupRemote`, `fetch.prune`, `merge.conflictstyle zdiff3`, `branch.sort -committerdate`, git-Aliases `st`, `br`, `lg`, im Nachtrag ein zweiter includeIf für den nvim-Checkout |
| `~/.tmux.conf` | `escape-time 10`, `renumber-windows on`, Splits und neue Fenster im aktuellen Pfad |
| `~/.profile` | doppelten PATH-Eintrag von pipx entfernt |
| `~/.local/bin/wsl-open` | neu, Browser- und Datei-Opener für WSL |
| `~/.config/nvim/` | vier Bugfixes, siehe oben |

Zur `.gitconfig`: `push.autoSetupRemote` passt exakt zur eigenen Regel, dass jeder lokale Branch gepusht wird. `git push` reicht ab jetzt auch beim ersten Push eines neuen Branches, das `-u origin branchname` entfällt. `fetch.prune` räumt remote gelöschte Branches automatisch aus der lokalen Sicht, was bei der Menge an Repos sonst Handarbeit ist. `zdiff3` zeigt in Konflikten zusätzlich den gemeinsamen Vorfahren, das macht Merge-Entscheidungen deutlich leichter.

Zu den shopt-Optionen: `autocd` wechselt in ein Verzeichnis, wenn man nur dessen Namen tippt. `cdspell` und `dirspell` korrigieren Tippfehler in Pfaden. `histverify` zeigt History-Expansionen wie `!!` erst an, bevor sie laufen, eine Absicherung bei sudo-nahen Kommandos. `globstar` aktiviert `**`-Globs, nützlich in Terraform-Modulstrukturen.

## Was bewusst nicht übernommen wurde

19 Kandidaten flogen raus. Die wichtigsten Begründungen, weil sie das Prinzip zeigen:

- Typo-Aliases wie `cls`, `rl` und `:q` zementieren Fehlgriffe, statt sie zu korrigieren. Die fzf-History-Suche löst das Problem an der Wurzel.
- Ein `cc`-Alias für Claude hätte den C-Compiler verschattet. Mit go, cargo und make auf dem System ist das ein realistisches Risiko. Die kollisionsfreien `clc` und `clr` kamen ins Set, wurden im Ausmisten danach aber auch wieder entfernt, siehe Nachtrag.
- `winhome`, `psh`, `wslstatus` und `wslrestart` haben kein einziges belegtes Muster in der History. Naheliegend ist kein Beleg.
- Ein generisches `azssh` für beliebige VMs klingt gut, aber belegt ist genau eine VM. Selbst der dafür gebaute `az-typo3` flog im Ausmisten wieder raus, der generische Wrapper war also doppelt unbegründet.
- Ein blindes `alias tfa='terraform apply tfplan'` hätte die Planfile-Fehler aus der History wiederholt, deshalb wurde es als Funktion mit Existenz-Check gebaut. Das komplette Terraform-Set ist inzwischen ganz gestrichen, siehe Nachtrag.

## Nachtrag vom selben Tag

Die größten offenen Punkte wurden noch am 11.06. erledigt. Der Ablauf und die Stolpersteine stehen hier, weil sie das heutige Layout erklären.

### Stray-Repo aufgelöst und der Sync nachgeholt

Der Befund zuerst: `~/github-repos/.git` war ein versehentlicher Clone von `nvim-config` auf oberster Ebene. Damit war die gesamte Repo-Sammlung Working-Tree eines einzigen Git-Repos. Ein unbedachtes `git add .` oder `git clean` auf dieser Ebene hätte alle Arbeits-Repos erfasst, und die `weekly commit`-Commits der letzten Monate liefen gegen dieses kaputte Layout ins Leere. Der Remote-Stand hing rund sieben Monate hinterher.

Das Stray-Repo wurde von Hand gelöscht. Danach holte `nvim-sync` den Rückstand in den korrekten Clone auf: ein Commit mit den vier nvim-Bugfixes aus der Überholung plus den Obsidian- und Lockfile-Änderungen aus dem Mai, die der alte Sync nie ins Repo gebracht hatte.

Der Push scheiterte zunächst an den Zugriffsrechten, und der Grund ist ein Merkposten für alle Privat-Repos: der Clone zeigte auf `git@github.com`, und dieser Host nutzt laut `~/.ssh/config` den Firmen-Key. Privat-Repos laufen über den SSH-Alias `github-private` mit dem privaten Key. Nach `git remote set-url origin git@github-private:drzo1dberg/nvim-config.git` lief der Push durch.

### nvim-Config als direkter Checkout

Nötig war das, weil das Kopier-Modell zwei Wahrheiten pflegt: die Live-Config und die Repo-Kopie. Sobald der Sync-Schritt vergessen wird, driften sie auseinander, und genau dieser Zustand war über Monate eingetreten. Der Umbau beseitigt die Ursache statt des Symptoms:

1. Das `.git` des Clones wurde nach `~/.config/nvim` verschoben. Der Status war sofort sauber, weil Live-Config und Repo nach dem Sync identisch waren.
2. Identitäts-Falle: die private Git-Identität hing am `includeIf` für `gitdir:~/github-repos/drzo1dberg/`. Am neuen Ort hätte git stillschweigend mit der Arbeits-Identität committet. Deshalb steht in der `~/.gitconfig` jetzt ein zweiter Block, `includeIf "gitdir:~/.config/nvim/"`. Der erste Commit lief verifiziert als `drzo1dberg`.
3. Die Kopie unter `~/github-repos/drzo1dberg/nvim-config` wurde gelöscht und `nvim-sync` ersatzlos aus `~/.bash_aliases` entfernt.

Der Workflow ist seitdem: in `~/.config/nvim` arbeiten, dort committen und pushen. `lazy-lock.json` wandert automatisch mit jedem Commit, ein vergessbarer Zwischenschritt existiert nicht mehr.

### Zwei Plugin-Fixes in nvim

`obsidian.nvim` zeigte auf das archivierte Upstream-Repo von epwalsh, das keine Fixes und keine Anpassungen an neue nvim-Versionen mehr bekommt. Die Spec zeigt jetzt auf den gepflegten Community-Fork `obsidian-nvim/obsidian.nvim`, frisch geklont als v3.9.0. Die gesamte Workspace-Konfiguration samt `note_path_func` und Frontmatter-Logik blieb unverändert und läuft auf dem Fork fehlerfrei.

Das Keymap `<leader>fp` rief `Telescope project`, aber das Plugin dahinter war nie installiert, die Taste warf nur einen Fehler. Jetzt liegt `telescope-project.nvim` als eigene Spec in `lua/custom/plugins/project.lua`, konfiguriert mit `base_dirs` auf beide Repo-Ordner. Damit zeigt die Taste denselben Projektbestand wie das Shell-Kommando `repo`.

Beide Fixes wurden headless verifiziert und sind als Commit `715461e` gepusht.

### Zettelkasten portabel für den Heim-PC

Der Obsidian-Vault hing fest am OneDrive-Mount der Firma und das `vl`-Alias fest an `~/bf`. Für den Umzug auf das Heim-Debian gibt es jetzt eine einzige Stellschraube: `~/.config/obsidian-vault`, eine Datei mit einer Zeile Pfad. Geschrieben wird sie vom install-Script im nvim-config-Repo:

```bash
~/.config/nvim/install.sh --obsidian-location ~/notizen
```

Das legt am Zielort auch die komplette Ordnerstruktur an, also `Zettelkasten`, `daily todos`, `Vorlagen` und `Architektur Decision Record`, damit `note_path_func` und die Daily Notes sofort funktionieren. Die Obsidian-Spec in nvim liest die Datei beim Start, die `.bashrc` exportiert sie als `OBSIDIAN_VAULT`, und `vl` wie `vault` greifen darauf zu. Fehlt die Datei, gilt der Work-Vault als Default, auf der Arbeitsmaschine ändert sich also nichts. Verifiziert über einen Negativ-Test: zeigt die Datei auf einen nicht existierenden Pfad, verweigert die Obsidian-Spec das Laden, der Override wird also nachweislich gelesen.

`vl` selbst wurde vom Alias zur Funktion. Ohne Argument öffnet es die Tagesnotiz wie bisher, `vl -1` die letzte existierende Notiz vor heute, `vl -2` die davor. Gezählt wird über vorhandene Dateien statt Kalendertage, am Montag liefert `vl -1` also den letzten Freitag oder Samstag. Weil die Dateinamen im US-Format `%m-%d-%y` über Jahresgrenzen lexikalisch falsch sortieren, übersetzt die Funktion jeden Namen in einen `YYYYMMDD`-Schlüssel und sortiert erst dann, getestet inklusive Jahreswechsel und Fehlerfällen.

Zwei Erweiterungen kamen direkt hinterher. Erstens kennt `vl` das Archiv: `zk-archive.sh` verschiebt alte Notizen in Wochenordner unter `Zettelkasten/Archiv/YYYYKW##/`, und sowohl die Rückwärtszählung als auch die Datumssuche laufen per `find` über diese Ordner mit. Ohne das wäre `vl -N` an der Retention-Grenze des Archivers stehen geblieben. Zweitens gibt es die direkte Datumssuche im deutschen Format: `vl -d 12.04.26` übersetzt Tag und Monat in den US-Dateinamen `04-12-26.md` und öffnet die Notiz, egal ob sie in der Wurzel oder in einem Archiv-Wochenordner liegt. Einstellige Tage und Monate sowie vierstellige Jahre wie `31.12.2025` werden normalisiert, ungültige Eingaben und nicht vorhandene Notizen geben eine klare Meldung. Alles im Sandbox-Zettelkasten mit Archiv-Struktur durchgetestet.

Der Archiver selbst läuft seitdem automatisch: montags 09:00 als systemd-User-Timer `zk-archive.timer` mit `Persistent=true`. Der Persistent-Punkt ist unter WSL entscheidend, klassisches cron feuert nur, wenn die Distro zur Minute des Jobs läuft, der systemd-Timer holt einen verpassten Montag beim nächsten Start nach. Eingerichtet wird das vom install-Script im nvim-config-Repo, das `zk-archive.sh` dafür nach `~/.local/bin/zk-archive` verlinkt. Auf Maschinen ohne systemd fällt es auf crontab zurück. `zk-archive.sh` liest den Vault jetzt ebenfalls aus `~/.config/obsidian-vault` statt fest aus `~/bf`, womit Archiver, nvim und die Shell-Aliases alle an derselben einen Stellschraube hängen.

## Nachtrag: Aliases nachträglich ausgemistet

Das Set wurde danach noch von Hand entschlackt und dabei zwei Kategorien entfernt, die zwar aus der History begründet waren, aber das falsche Signal trugen. Die Korrektur ist wichtig genug für diesen Eintrag, weil sie eine Schwäche der History-Mining-Methode offenlegt: Häufigkeit in der History ist ein verrauschtes Signal.

Raus sind das komplette Terraform-Set `tf`, `tff`, `tfv`, `tfi`, `tfp`, `tfc`, `tfa`, `tfd` samt der `tf`-Completion in der `.bashrc`, dazu `az-typo3`, die GitHub-Automatik `prs`, `prv`, `lpvar`, `tfrun` und die Claude-Kürzel `clc`, `clr`.

Die zwei Leitgründe:

- **Terraform ist zu mächtig für ein Alias.** `apply`, `destroy` und `plan` verändern echte Azure-Infrastruktur. Genau hier ist Tippreibung erwünscht, nicht abgekürzt. Ein Zweitaster wie `tfa` senkt die Schwelle für eine Operation, die bewusst und voll ausgeschrieben laufen soll. Die Häufigkeit in der History war real, aber der falsche Maßstab: oft getippt heißt nicht, dass es kürzer getippt gehört.
- **TYPO3 war ein History-Zufall.** Die `az ssh vm` und `ssh typo3-test` Zeilen kamen aus einer einzelnen Debugging-Phase und stehen nicht für die normale Arbeitsweise, die VM wird fast nie gebraucht. Das Mining hat einen einmaligen Ausschlag zu einem dauerhaften Shortcut verfestigt und damit ein falsches Incentive gesetzt. Konsequenterweise sind auch die ssh-config-Hosts `typo3-test` und `coremw-test` wieder raus, sie stammen aus derselben Phase. Die `~/.ssh/config` enthält jetzt nur noch die GitHub-Hosts.

Die übrigen Streichungen folgen demselben Gedanken: `lpvar` und `tfrun` sind seltene, folgenreiche Massenoperationen über mehrere Repos und gehören ausgeschrieben, `prs`, `prv`, `clc` und `clr` waren bequem, aber kein Muster, das die Abkürzung trägt. Was bleibt, ist das Set, das tägliche und harmlose Wege abkürzt: Navigation, git-Status und Commit, tmux, die WSL-Brücke und der Zettelkasten.

## Was noch offen ist

- `vl` nutzt das US-Datumsformat `%m-%d-%y`. ISO würde sauber sortieren, aber die Bestandsdateien im Zettelkasten heißen nach altem Schema und müssten mitmigriert werden, inklusive Prüfung auf Querverweise. Nur als bewusste Entscheidung umsetzen.
- gh war anfangs nur mit dem Arbeits-Account eingeloggt. Für PRs auf den privaten Repos fehlte der passende Login, `gh auth login` plus `gh auth switch` löst das.
- Im Home liegen die Artefakte `xcopy.exe` und `table.html`, beide vermutlich löschbar.

## Rollback

Der komplette Altstand von `.bashrc`, `.bash_aliases`, `.profile`, `.tmux.conf` und `.gitconfig` liegt unter `~/.dotfiles-backup-2026-06-11/`. Zurückrollen heißt: Datei zurückkopieren, `reload`. Die nvim-Änderungen sind seit dem Checkout-Umbau regulär über die Git-History von `~/.config/nvim` nachvollziehbar.
