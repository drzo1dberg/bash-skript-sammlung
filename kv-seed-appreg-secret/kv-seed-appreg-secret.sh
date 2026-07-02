#!/usr/bin/env bash
#
# kv-seed-appreg-secret.sh
# ------------------------------------------------------------------------------
# Erzeugt fuer die FE/BE-App-Registration einer Env ein NEUES Client-Secret
# (az ad app credential reset --append, KEIN Wipe bestehender Creds wie EasyAuth)
# und legt es als KV-Secret "<side>-azuread-client-secret" im Env-KV ab.
#
# Allgemein gehalten: die App-Reg-AppId wird per Display-Name aufgeloest
# (app-<workload>-<env>-<side>), es ist NICHTS hartkodiert. So funktioniert
# das Skript fuer test/acc/prod und andere Workloads gleich.
#
# WICHTIG: jeder Lauf erzeugt ein NEUES Secret (accumuliert per --append). Nur
# ausfuehren, wenn ein frisches Secret gewollt ist: Env-Neuanlage, Rotation oder
# nach einem App-Reg-Recreate (geaenderte AppId -> altes KV-Secret ist stale).
# Voraussetzung: Data-Plane-Rolle auf dem KV (siehe kv-human-role.sh).
#
# Usage:
#   ./kv-seed-appreg-secret.sh <env> [be|fe|both]
# Beispiele:
#   ./kv-seed-appreg-secret.sh prod both
#   ./kv-seed-appreg-secret.sh acc  fe
#
# Ueberschreibbar per ENV: WORKLOAD (appdb), INDEX (001), YEARS (2),
# KV (voller Name), RELOGIN=1.
# ------------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FEHLER: $*" >&2; exit 1; }

WORKLOAD="${WORKLOAD:-app}"
INDEX="${INDEX:-001}"
YEARS="${YEARS:-2}"

ENV_NAME="${1:-}"
SIDES_ARG="${2:-both}"
[[ "$ENV_NAME" =~ ^(test|acc|prod)$ ]] || die "Usage: $(basename "$0") <test|acc|prod> [be|fe|both]"
case "$SIDES_ARG" in
  be)   SIDES=(be) ;;
  fe)   SIDES=(fe) ;;
  both) SIDES=(be fe) ;;
  *)    die "2. Argument muss be|fe|both sein." ;;
esac

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
# wuerde sonst akzeptiert (TENANT_ID greift nur beim Neu-Login).
ACTIVE_TENANT="$(az account show --query tenantId -o tsv 2>/dev/null || true)"
[ "$ACTIVE_TENANT" = "$TENANT_ID" ] || die "Aktiver az-Tenant '$ACTIVE_TENANT' != erwartet '$TENANT_ID'. RELOGIN=1 setzen."

az keyvault show -n "$KV" --query id -o tsv >/dev/null 2>&1 \
  || die "KV '$KV' nicht gefunden oder kein Control-Plane-Zugriff."

# Secret-Wert NIE ueber argv (--value) an az geben, das waere ueber
# /proc/<pid>/cmdline lesbar. Stattdessen ueber eine 0600-Temp-Datei (--file).
umask 077
TMPF=""
cleanup() { if [ -n "$TMPF" ]; then rm -f "$TMPF" 2>/dev/null || true; fi; }
trap cleanup EXIT INT TERM HUP

for side in "${SIDES[@]}"; do
  reg="app-${WORKLOAD}-${ENV_NAME}-${side}"
  secret="${side}-azuread-client-secret"

  # App-Reg eindeutig aufloesen: fail-closed bei Namens-Kollision (z.B. Leiche
  # nach Recreate), sonst wuerde [0] willkuerlich eine erwischen.
  count="$(az ad app list --filter "displayName eq '$reg'" --query "length(@)" -o tsv 2>/dev/null || echo 0)"
  [ "$count" = "1" ] || die "App-Registration '$reg': $count Treffer (erwartet 1). Bei >1 die Duplikate aufraeumen."
  appid="$(az ad app list --filter "displayName eq '$reg'" --query "[0].appId" -o tsv)"
  [ -n "$appid" ] || die "AppId fuer '$reg' nicht ermittelbar."

  # Neues Secret (--append: bestehende Creds bleiben). password UND keyId holen,
  # damit wir bei einem KV-Write-Fehler das gerade erzeugte Credential zurueckrollen
  # (sonst haengt ein verwaistes, gueltiges Secret an der App-Reg).
  log "Reset Secret fuer $reg ($appid) ..."
  reset_tsv="$(az ad app credential reset --id "$appid" --append \
               --display-name "${ENV_NAME}-${side}-kv" --years "$YEARS" \
               --query "[password, keyId]" -o tsv)"
  pw="$(printf '%s' "$reset_tsv" | cut -f1)"
  kid="$(printf '%s' "$reset_tsv" | cut -f2)"
  reset_tsv=""
  if [ -z "$pw" ] || [ -z "$kid" ]; then die "credential reset lieferte kein password/keyId fuer $reg."; fi

  TMPF="$(mktemp)"
  printf '%s' "$pw" > "$TMPF"
  pw=""
  if az keyvault secret set --vault-name "$KV" --name "$secret" --file "$TMPF" -o none; then
    rm -f "$TMPF"; TMPF=""
    log "  KV-Secret '$secret' gesetzt (App $reg, gueltig ${YEARS}J)."
  else
    rm -f "$TMPF"; TMPF=""
    log "KV-secret-set fehlgeschlagen -> rolle frisches App-Credential (keyId $kid) zurueck ..."
    if ! az ad app credential delete --id "$appid" --key-id "$kid" -o none 2>/dev/null; then
      log "  WARN: Rollback von Credential $kid fehlgeschlagen -> manuell pruefen: az ad app credential list --id $appid"
    fi
    die "Abbruch fuer $reg: KV nicht geschrieben, kein verwaistes Credential hinterlassen."
  fi
done
log "Fertig. Danach KV-Ref-Refresh der Apps erzwingen (App-Setting re-apply), sonst alter Cache."
