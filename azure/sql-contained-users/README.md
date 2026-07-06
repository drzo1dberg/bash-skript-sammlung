# sql-contained-users

Post-Apply-Schritt für Entra-only + private-only Azure SQL: legt die **contained
SQL-User** für die FE/BE Managed Identities an (`CREATE USER ... FROM EXTERNAL
PROVIDER` + `db_datareader`/`db_datawriter`). Idempotent, überlebt jedes
`terraform apply`; Re-Run nur bei DB-Restore oder MI-Neuanlage.

## Nutzung

```bash
./post-apply-create-sql-users.sh prod                 # Env-Modus: leitet Namen ab, generiert SQL
DBS="appdb appdb2" ./post-apply-create-sql-users.sh prod  # mehrere DBs
OPEN_PUBLIC=false ./post-apply-create-sql-users.sh prod   # aus dem VNet, ohne Fenster
./post-apply-create-sql-users.sh                      # Legacy (Default-Env, SQL-Datei)
```

Erstes Argument = Env (`test|acc|prod`): leitet `RG`/`SQL_SERVER`/`ADMIN_GROUP`/
MI-Namen ab und **generiert die SQL**. Login per Device-Code, prüft die
Admin-Gruppen-Mitgliedschaft.

## Netzwerk

Erreicht kein In-VNet-Host den SQL Private Endpoint (asymmetrisches Routing),
öffnet der Default (`OPEN_PUBLIC=true`) ein kurzes, auf die eigene Egress-IP
beschränktes Public-Fenster und schließt es per `trap` wieder auf den
**ursprünglichen** `publicNetworkAccess` (nicht hart `Disabled`), inklusive
Verifikation dass die Temp-Firewall-Regel weg ist. Mit `OPEN_PUBLIC=false` von
einem In-VNet-Host ohne Fenster.

## Dateien / Konfiguration

| Datei | Zweck |
|---|---|
| `post-apply-create-sql-users.sh` | der Runner |
| `create-sql-users.sql` | Legacy-SQL für den Modus ohne `<env>` |
| `cfg.<env>.env` | `CFG_TENANT_ID` (Rest wird aus `<env>` abgeleitet) |

Abgeleitet: `RG=rg-<WORKLOAD>-<env>-<INDEX>`, `SQL_SERVER=sql-<WORKLOAD>-…`,
`ADMIN_GROUP=grp-sql-<WORKLOAD>-admins[-<env>]` (Defaults `WORKLOAD=app`,
`INDEX=001`). Ein Preflight-Guard bricht bei Env-Mismatch zwischen Servername und
MI-Namen ab.
