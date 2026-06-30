# mail-grant-exo-script

Exchange-Online-RBAC, um eine App-Registration (Enterprise App) per
`Application Mail.Send` auf **genau ein Postfach** zu begrenzen, statt org-weite
Graph-`Mail.*`-Rechte zu vergeben. Kontextfreie Vorlage, echte Werte kommen aus
einer lokalen `mailrbac.<env>.env`.

## Aufbau

Drei `.sh`-Launcher rufen je ein gleichnamiges `.ps1` (Windows PowerShell via
WSL-Interop). Der Launcher erwartet als erstes Argument die Ziel-Env und sourcet
`mailrbac.<env>.env`, deren Werte als `$env:MAILRBAC_*` ans `.ps1` vererbt werden.
Praezedenz: explizites `-Param` > `mailrbac.<env>.env` > Hardcoded-Default im `.ps1`.

| Skript | Zweck |
|---|---|
| `mail-mantle-appreg` | EXO-Service-Principal-Pointer, Management-Scope auf ein Postfach, scoped Role-Assignment |
| `mail-revoke-entra-grants` | entzieht die org-weiten Graph-`Mail.*`-Application-Grants |
| `mail-scope-manage` | liest oder verbiegt (`-NewMailbox`) den Mailbox-Scope |

## Setup

```bash
cp mailrbac.example.env mailrbac.test.env   # dann echte Werte eintragen
./mail-mantle-appreg test
./mail-revoke-entra-grants test -DryRun
./mail-scope-manage test
```

Default-Login ist Device-Code (WSL-tauglich), `-Browser` erzwingt den
Browser-Login. Ein Tenant-Guard bricht ab, wenn die Live-Session nicht der in
`MAILRBAC_TENANT_ID` erwartete Tenant ist. `mailrbac.<env>.env` gehoert in
`.gitignore` und wird nie committed.

## Voraussetzungen

- WSL mit Zugriff auf `powershell.exe`/`pwsh.exe`
- PowerShell-Module `ExchangeOnlineManagement` und `Microsoft.Graph.Applications`
  (werden bei Bedarf automatisch installiert)
- ein Konto mit ausreichenden EXO-/Entra-Rechten im Ziel-Tenant
