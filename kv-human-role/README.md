# kv-human-role

Grantet oder entzieht einer Person (per Mail/UPN) eine Data-Plane-Rolle auf einem
Azure Key Vault. Der Kern ist der Swap **Mail/UPN → Azure-Objekt-ID**
(`az ad user show --id <upn> --query id`) und die Rollenzuweisung am KV-Scope.

Nützlich, wenn der KV nur dem Deploy-Principal und App-Identitäten per Terraform
Zugriff gibt und menschlicher Secret-Zugriff bewusst out-of-band bleibt.

## Nutzung

```bash
./kv-human-role.sh prod grant  admin@example.com
./kv-human-role.sh prod revoke admin@example.com
./kv-human-role.sh prod grant  user@example.com "Key Vault Secrets Officer"
```

Erstes Argument = Env (`test|acc|prod`), sourcet `cfg.<env>.env`. Default-Rolle
`Key Vault Administrator`, als 4. Argument überschreibbar (`KV_ROLE` per ENV).
Grant ist idempotent, Revoke schluckt „nicht vorhanden". Device-Code-Login mit
Tenant-Assertion.

## Konfiguration

`cfg.<env>.env`: `CFG_TENANT_ID`. KV-Name abgeleitet
`KV=kv-<WORKLOAD>-<env>-<INDEX>` (Defaults `WORKLOAD=app`, `INDEX=001`), oder `KV`
direkt setzen. Zum Vergeben brauchst du `User Access Administrator`/`Owner` auf
dem Scope.
