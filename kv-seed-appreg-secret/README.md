# kv-seed-appreg-secret

Erzeugt für die FE/BE-App-Registration einer Env ein **neues Client-Secret**
(`az ad app credential reset --append`, kein Wipe bestehender Credentials) und
legt es als KV-Secret `<side>-azuread-client-secret` ab. Die App-Reg-AppId wird
per Display-Name aufgelöst (`app-<workload>-<env>-<side>`), nichts hartkodiert.

## Nutzung

```bash
./kv-seed-appreg-secret.sh prod both     # be + fe
./kv-seed-appreg-secret.sh acc  fe        # nur fe
YEARS=1 ./kv-seed-appreg-secret.sh prod be
```

Erstes Argument = Env (`test|acc|prod`), sourcet `cfg.<env>.env`. Device-Code-Login
mit Tenant-Assertion. Voraussetzung: Data-Plane-Rolle auf dem KV (siehe
`../kv-human-role`).

## Wichtig

- **Jeder Lauf erzeugt ein neues Secret** (akkumuliert per `--append`). Nur bei
  Env-Neuanlage, Rotation oder App-Reg-Recreate laufen lassen.
- Härtung: Secret-Wert über `--file` (0600-Temp-Datei) statt `--value` (kein Leak
  über `/proc/<pid>/cmdline`); Credential-Rollback bei fehlgeschlagenem KV-Write;
  fail-closed bei App-Reg-Namenskollision.
- Danach den KV-Referenz-Cache der App auffrischen (App-Setting re-apply).

## Konfiguration

`cfg.<env>.env`: `CFG_TENANT_ID`. Abgeleitet: `KV=kv-<WORKLOAD>-<env>-<INDEX>`,
App-Reg `app-<WORKLOAD>-<env>-<side>` (Defaults `WORKLOAD=app`, `INDEX=001`,
`YEARS=2`), per ENV überschreibbar.
