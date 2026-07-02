#!/usr/bin/env bash
#
# kv-edit-window.sh
# ------------------------------------------------------------------------------
# Oeffnet ein zeitlich begrenztes Bearbeitungs-Fenster auf dem privaten Key Vault
# einer Env (publicNetworkAccess=Disabled) fuer EINE Egress-IP und stellt sicher,
# dass ein Principal (z.B. bernhard-adm) die Data-Plane-Rolle zum Secret-Setzen
# hat. Gedacht fuer den KV-Seed eines frischen Env (7 Secrets, siehe README/
# CLAUDE.md), wenn derjenige der die Secrets setzt nicht ueber den PE an den KV
# kommt.
#
# Erstes Argument = Env (test|acc|prod), analog zu den mail-* Launchern:
# sourcet scripts/cfg.<env>.env und leitet den KV-Namen ab. Default prod.
#
# Zwei Dinge, klar getrennt:
#   1) RBAC-Rolle (Default: Key Vault Secrets Officer) -> PERSISTENT, bleibt.
#      Die vier TF-Rollen geben nur dem Apply-SP + den beiden App-MIs Zugriff;
#      menschlicher Secret-Zugriff ist bewusst out-of-band.
#   2) Netz-Fenster (publicNetworkAccess=Enabled + IP-Whitelist) -> TEMPORAER,
#      wird per trap IMMER wieder auf den by-design privaten Zustand (Disabled)
#      geschlossen und der Erfolg des Reverts verifiziert.
#
# Verwendung (Michael oeffnet das Fenster, Bernhard setzt dann die Secrets):
#   ./kv-edit-window.sh prod                  # prod-KV, Bernhard IP+UPN (Defaults)
#   ./kv-edit-window.sh acc                   # acc-KV
#   IP=1.2.3.4 ./kv-edit-window.sh prod       # andere Egress-IP
#   WINDOW_MINUTES=45 ./kv-edit-window.sh prod
#   GRANT_UPN="" ./kv-edit-window.sh prod     # nur Netz-Fenster, keine RBAC
#
# Das Fenster ist offen solange das Skript laeuft. Strg-C schliesst sofort,
# sonst nach WINDOW_MINUTES automatisch. Das KV ist by design privat, daher wird
# IMMER auf Disabled geschlossen (RESTORE_PUBLIC ueberschreibbar).
# ------------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] $*" >&2; }
die()  { echo "FEHLER: $*" >&2; exit 1; }
command -v az >/dev/null || die "az CLI nicht gefunden."

# --- Env + Konfig -------------------------------------------------------------
ENV_NAME="${1:-prod}"
[[ "$ENV_NAME" =~ ^(test|acc|prod)$ ]] || die "Env '$ENV_NAME' ungueltig. Erlaubt: test|acc|prod."
ENV_FILE="$SCRIPT_DIR/cfg.${ENV_NAME}.env"
if [ -f "$ENV_FILE" ]; then
  log "Lade $ENV_FILE"
  set -a; # shellcheck source=/dev/null
  source "$ENV_FILE"; set +a
fi

TENANT_ID="${TENANT_ID:-${CFG_TENANT_ID:-00000000-0000-0000-0000-000000000000}}"
KV="${KV:-kv-appdb-${ENV_NAME}-001}"
IP="${IP:-${CFG_ADMIN_IP:-203.0.113.10}}"                 # Egress-IP des Setzers (Firewall-Whitelist)
GRANT_UPN="${GRANT_UPN:-${CFG_KV_EDIT_UPN:-admin@example.com}}"
GRANT_ROLE="${GRANT_ROLE:-Key Vault Secrets Officer}"
WINDOW_MINUTES="${WINDOW_MINUTES:-30}"
IP_BARE="${IP%%/*}"                                         # /32 ist implizit fuer Einzel-IP

# Restore-Ziel = by-design-Zustand des KV (privat). BEWUSST NICHT aus dem
# Live-Zustand gelesen: ein gecrashter oder paralleler Vorlauf koennte Enabled
# hinterlassen haben, dann wuerden wir faelschlich auf Enabled zurueckdrehen und
# das KV offen lassen. Das TF-Modul setzt public_network_access_enabled=false.
RESTORE_PUBLIC="${RESTORE_PUBLIC:-Disabled}"

# --- Auth: IMMER Device-Code-Flow (kein Browser-Redirect) ---------------------
if [ "${RELOGIN:-0}" = "1" ] || ! az account show >/dev/null 2>&1; then
  log "az-Login per Device-Code-Flow (Tenant $TENANT_ID) ..."
  az login --use-device-code --tenant "$TENANT_ID" -o none
fi

KVID="$(az keyvault show -n "$KV" --query id -o tsv 2>/dev/null)" \
  || die "KV $KV nicht gefunden oder kein Control-Plane-Zugriff (az login?)."
CUR_PUBLIC="$(az keyvault show -n "$KV" --query properties.publicNetworkAccess -o tsv 2>/dev/null || echo '?')"
log "KV: $KV  (aktuell publicNetworkAccess=$CUR_PUBLIC, schliesse am Ende auf $RESTORE_PUBLIC)"
if [ "$CUR_PUBLIC" = "Enabled" ]; then
  warn "WARNUNG: $KV ist bereits Enabled. Evtl. laeuft schon ein Fenster (anderer Lauf) oder ein"
  warn "         Vorlauf ist gecrasht. Dieser Lauf schliesst am Ende trotzdem auf $RESTORE_PUBLIC."
fi

# --- 1) RBAC sicherstellen (PERSISTENT, wird NICHT zurueckgesetzt) ------------
if [ -n "$GRANT_UPN" ]; then
  OID="$(az ad user show --id "$GRANT_UPN" --query id -o tsv 2>/dev/null)" \
    || die "UPN $GRANT_UPN nicht auffindbar."
  have="$(az role assignment list --scope "$KVID" --assignee "$OID" \
          --query "[?roleDefinitionName=='$GRANT_ROLE'] | length(@)" -o tsv 2>/dev/null || echo 0)"
  if [ "$have" = "0" ]; then
    log "RBAC: vergebe '$GRANT_ROLE' an $GRANT_UPN ($OID)"
    az role assignment create --assignee-object-id "$OID" --assignee-principal-type User \
      --role "$GRANT_ROLE" --scope "$KVID" -o none
  else
    log "RBAC: $GRANT_UPN hat '$GRANT_ROLE' bereits (bleibt bestehen)."
  fi
fi

# --- 2) Netz-Fenster oeffnen, garantierter + VERIFIZIERTER Revert -------------
REVERTED=0
revert() {
  [ "$REVERTED" = 1 ] && return; REVERTED=1
  echo ""
  log "REVERT: publicNetworkAccess -> $RESTORE_PUBLIC, IP-Regel $IP_BARE entfernen"
  az keyvault update -n "$KV" --public-network-access "$RESTORE_PUBLIC" -o none 2>/dev/null || true
  az keyvault network-rule remove -n "$KV" --ip-address "$IP_BARE" -o none 2>/dev/null || true
  # Erfolg verifizieren: BEIDES muss stimmen (public zurueck UND keine stale
  # ipRule). Das KV-TF-Modul managed publicNetworkAccess/network_acls NICHT ->
  # ein stiller Fehlschlag wird von keinem Apply geheilt, und eine stale IP waere
  # beim naechsten Enabled-Flip sofort scharf.
  local now iprule
  now="$(az keyvault show -n "$KV" --query properties.publicNetworkAccess -o tsv 2>/dev/null || echo UNBEKANNT)"
  iprule="$(az keyvault network-rule list -n "$KV" --query "ipRules[?starts_with(value, '$IP_BARE')] | length(@)" -o tsv 2>/dev/null || echo '?')"
  if [ "$now" != "$RESTORE_PUBLIC" ] || [ "$iprule" != "0" ]; then
    warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    warn "REVERT NICHT BESTAETIGT: $KV publicNetworkAccess=$now (soll $RESTORE_PUBLIC), stale ipRule($IP_BARE)=$iprule (soll 0)."
    warn "Das KV koennte OFFEN/exponiert bleiben. SOFORT manuell schliessen:"
    warn "  az keyvault update -n $KV --public-network-access $RESTORE_PUBLIC"
    warn "  az keyvault network-rule remove -n $KV --ip-address $IP_BARE"
    warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  else
    log "Fenster geschlossen (publicNetworkAccess=$now, keine stale ipRule). Data-Plane-RBAC von $GRANT_UPN bleibt."
  fi
}
# EXIT-trap fuer den normalen Ablauf; Signale reverten UND beenden SOFORT (sonst
# liefe die Warteschleife nach Strg-C weiter und loege '[offen]'). Doppel-Revert
# ist per REVERTED-Guard ausgeschlossen.
on_sig() { revert; exit 130; }
trap revert EXIT
trap on_sig INT TERM HUP

log "Oeffne Fenster: IP-Regel $IP_BARE + publicNetworkAccess=Enabled (defaultAction bleibt Deny)"
az keyvault network-rule add -n "$KV" --ip-address "$IP_BARE" -o none
az keyvault update -n "$KV" --public-network-access Enabled -o none

log "OFFEN. $GRANT_UPN kann jetzt von $IP_BARE aus Secrets setzen"
log "  -> Portal: KV '$KV' > Geheimnisse   ODER   az keyvault secret set --vault-name $KV --name <n> --value <v>"
log "Schliesst automatisch in $WINDOW_MINUTES min. Strg-C = sofort schliessen."

END=$(( $(date +%s) + WINDOW_MINUTES * 60 ))
while [ "$(date +%s)" -lt "$END" ]; do
  rem=$(( (END - $(date +%s) + 59) / 60 ))
  printf "\r[offen] noch ~%d min ...   " "$rem"
  sleep 15
done
log "Zeit abgelaufen."
