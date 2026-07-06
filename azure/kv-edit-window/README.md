# kv-edit-window

Öffnet ein zeitlich begrenztes Bearbeitungs-Fenster auf einem privaten Azure Key
Vault (`publicNetworkAccess=Disabled`) für **eine** Egress-IP und grantet dem
Setzer eine Data-Plane-Rolle. Für den Fall, dass jemand Secrets setzen muss, aber
nicht über den Private Endpoint an den KV kommt.

Zwei getrennte Dinge:
- **RBAC-Rolle** (Default `Key Vault Secrets Officer`) → persistent.
- **Netz-Fenster** (`publicNetworkAccess=Enabled` + IP-Whitelist) → temporär, wird
  per `trap` immer wieder auf `Disabled` geschlossen und verifiziert (public **und**
  ipRule).

## Nutzung

```bash
./kv-edit-window.sh prod                  # KV der Env prod
IP=1.2.3.4 ./kv-edit-window.sh prod       # andere Egress-IP
WINDOW_MINUTES=45 ./kv-edit-window.sh prod
GRANT_UPN="" ./kv-edit-window.sh prod     # nur Netz-Fenster, keine RBAC
```

Erstes Argument = Env (`test|acc|prod`), sourcet `cfg.<env>.env`. Fenster ist
offen solange das Skript läuft; `Strg-C` schließt sofort, sonst nach
`WINDOW_MINUTES` (Default 30). Login per Device-Code mit Tenant-Assertion.

## Konfiguration

`cfg.<env>.env` (aus `cfg.example.env` kopieren):

| Variable | Zweck |
|---|---|
| `CFG_TENANT_ID` | Ziel-Tenant |
| `CFG_ADMIN_IP` | Egress-IP, die freigeschaltet wird |
| `CFG_KV_EDIT_UPN` | wer die Rolle/den Zugriff bekommt |

Der KV-Name wird abgeleitet: `KV=kv-<WORKLOAD>-<env>-<INDEX>` (Defaults
`WORKLOAD=app`, `INDEX=001`), oder `KV` direkt setzen. `RESTORE_PUBLIC` (Default
`Disabled`) ist das feste Schließ-Ziel.

## Voraussetzungen

- `az` CLI, angemeldet (oder Device-Code beim Lauf)
- zum Vergeben der Rolle: `User Access Administrator`/`Owner` auf dem Scope
