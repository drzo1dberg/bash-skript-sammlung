#!/usr/bin/env bash
#
# kv-human-role.sh
# ------------------------------------------------------------------------------
# Grantet oder entzieht einer Person (per Mail/UPN) eine Data-Plane-Rolle auf dem
# Key Vault einer Env. Der Kern ist der "swap" von Mail zu Azure-Objekt-ID
# (az ad user show --id <upn> --query id) und die Rollenzuweisung am KV-Scope.
#
# Gedacht als Post-Apply-Helfer: das KV-TF-Modul gibt nur dem Apply-SP + den App-
# MIs Zugriff; menschlicher Secret-Zugriff (zum Seeden) ist bewusst out-of-band.
#
# Auth: immer Device-Code-Flow. Zum Vergeben brauchst du selbst User Access
# Administrator/Owner auf dem Scope (ggf. PIM aktivieren).
#
# Usage:
#   ./kv-human-role.sh <env> <grant|revoke> <upn> [rolle]
# Beispiele:
#   ./kv-human-role.sh prod grant  admin@example.com
#   ./kv-human-role.sh prod revoke admin@example.com
#   ./kv-human-role.sh prod grant  m@x.de "Key Vault Secrets Officer"
#
# Ueberschreibbar per ENV: WORKLOAD (appdb), INDEX (001), KV (voller Name),
# KV_ROLE (Default-Rolle), RELOGIN=1 (Login erzwingen).
# ------------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FEHLER: $*" >&2; exit 1; }

WORKLOAD="${WORKLOAD:-app}"
INDEX="${INDEX:-001}"

ENV_NAME="${1:-}"
ACTION="${2:-}"
UPN="${3:-}"
ROLE="${4:-${KV_ROLE:-Key Vault Administrator}}"

[[ "$ENV_NAME" =~ ^(test|acc|prod)$ ]] || die "Usage: $(basename "$0") <test|acc|prod> <grant|revoke> <upn> [rolle]"
[[ "$ACTION" =~ ^(grant|revoke)$ ]] || die "Aktion muss 'grant' oder 'revoke' sein."
[ -n "$UPN" ] || die "UPN/Mail fehlt (3. Argument)."

ENV_FILE="$SCRIPT_DIR/cfg.${ENV_NAME}.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

TENANT_ID="${TENANT_ID:-${CFG_TENANT_ID:-00000000-0000-0000-0000-000000000000}}"
KV="${KV:-kv-${WORKLOAD}-${ENV_NAME}-${INDEX}}"

command -v az >/dev/null || die "az CLI nicht gefunden."
if [ "${RELOGIN:-0}" = "1" ] || ! az account show >/dev/null 2>&1; then
  log "az-Login per Device-Code-Flow (Tenant $TENANT_ID) ..."
  az login --use-device-code --tenant "$TENANT_ID" -o none
fi

# Aktiven Tenant hart pruefen: eine bestehende Session zu einem falschen Tenant
# wuerde sonst akzeptiert (TENANT_ID greift nur beim Neu-Login), und ad-Lookups
# liefen gegen das falsche Directory.
ACTIVE_TENANT="$(az account show --query tenantId -o tsv 2>/dev/null || true)"
[ "$ACTIVE_TENANT" = "$TENANT_ID" ] || die "Aktiver az-Tenant '$ACTIVE_TENANT' != erwartet '$TENANT_ID'. RELOGIN=1 setzen."

# --- swap: Mail/UPN -> Azure-Objekt-ID ----------------------------------------
OID="$(az ad user show --id "$UPN" --query id -o tsv 2>/dev/null || true)"
[ -n "$OID" ] || die "UPN '$UPN' nicht auffindbar (Mail korrekt? Gast/externer Account?)."

KVID="$(az keyvault show -n "$KV" --query id -o tsv 2>/dev/null || true)"
[ -n "$KVID" ] || die "KV '$KV' nicht gefunden oder kein Control-Plane-Zugriff."

log "$ACTION: '$ROLE' fuer $UPN ($OID) auf $KV"

if [ "$ACTION" = "grant" ]; then
  have="$(az role assignment list --scope "$KVID" --assignee "$OID" \
          --query "[?roleDefinitionName=='$ROLE'] | length(@)" -o tsv 2>/dev/null || echo 0)"
  if [ "$have" != "0" ]; then
    log "Rolle bereits vorhanden, nichts zu tun."
  else
    az role assignment create --assignee-object-id "$OID" --assignee-principal-type User \
      --role "$ROLE" --scope "$KVID" -o none
    log "Grant gesetzt. (Denk ans spaetere revoke.)"
  fi
else
  az role assignment delete --assignee "$OID" --role "$ROLE" --scope "$KVID"
  log "Revoke ausgefuehrt (No matched assignments = war ohnehin nicht gesetzt)."
fi
