#!/usr/bin/env bash
#
# post-apply-create-sql-users.sh
# ------------------------------------------------------------------------------
# Legt die contained SQL-User fuer die Managed Identities an (Post-Apply-Schritt
# fuer Entra-only + private-only Azure SQL). Genau das, was beim ersten Deploy
# manuell gemacht wurde, hier reproduzierbar und idempotent.
#
# Authentifizierung: ActiveDirectoryAzCli -> nutzt dein aktuelles `az login`.
# Das Konto MUSS Mitglied von $ADMIN_GROUP sein (das Skript prueft das).
#
# Netzwerk: Solange das PE-Subnet kein symmetrisches Routing hat (siehe
# your private-endpoint routing runbook), erreicht KEIN
# In-VNet-Host den SQL-PE. Default oeffnet das Skript daher ein kurzes,
# auf die eigene Egress-IP beschraenktes Public-Fenster und dreht es per trap
# IMMER wieder zu. Ist der Routing-Fix live, mit OPEN_PUBLIC=false von einem
# In-VNet-Host laufen lassen (kein Public-Fenster).
#
# Verwendung:
#   ./post-apply-create-sql-users.sh                 # Temp-Public (Default)
#   OPEN_PUBLIC=false ./post-apply-create-sql-users.sh   # aus dem VNet, ohne Public
#
# Ueberschreibbare ENV-Variablen siehe Konfigblock.
# ------------------------------------------------------------------------------
set -euo pipefail

RG="${RG:-rg-app-001}"
SQL_SERVER="${SQL_SERVER:-sql-app-001}"
DB="${DB:-appdb}"
ADMIN_GROUP="${ADMIN_GROUP:-sql-admins-group}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="${SQL_FILE:-$SCRIPT_DIR/create-sql-users.sql}"
OPEN_PUBLIC="${OPEN_PUBLIC:-true}"
FW_RULE="${FW_RULE:-tmp-postapply-create-users}"
FQDN="${SQL_SERVER}.database.windows.net"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "FEHLER: $*" >&2; exit 1; }

command -v az >/dev/null || die "az CLI nicht gefunden."
[ -f "$SQL_FILE" ] || die "SQL-Datei nicht gefunden: $SQL_FILE"

# --- go-sqlcmd sicherstellen (einzelnes Binary, kein ODBC noetig) -------------
SQLCMD="$(command -v sqlcmd || true)"
if [ -z "$SQLCMD" ]; then
  log "go-sqlcmd nicht im PATH, lade nach /tmp ..."
  mkdir -p /tmp/sqlcmd-bin
  url="$(gh release view --repo microsoft/go-sqlcmd --json assets \
        --jq '.assets[]|select(.name|test("linux-amd64\\.tar\\.bz2$")).url' 2>/dev/null | head -1)"
  url="${url:-https://github.com/microsoft/go-sqlcmd/releases/latest/download/sqlcmd-linux-amd64.tar.bz2}"
  curl -fsSL -o /tmp/sqlcmd.tar.bz2 "$url"
  tar xjf /tmp/sqlcmd.tar.bz2 -C /tmp/sqlcmd-bin
  SQLCMD=/tmp/sqlcmd-bin/sqlcmd
fi
log "sqlcmd: $($SQLCMD --version 2>&1 | grep -i version | head -1)"

# --- Identitaet pruefen: bin ich Mitglied der Admin-Gruppe? -------------------
MY_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
if [ -n "$MY_OID" ]; then
  IS_MEMBER="$(az ad group member check --group "$ADMIN_GROUP" --member-id "$MY_OID" --query value -o tsv 2>/dev/null || echo false)"
  [ "$IS_MEMBER" = "true" ] || die "Aktuelles az-Konto ist NICHT in $ADMIN_GROUP. Entra-only-SQL weist es ab. (Konto wechseln oder in die Gruppe aufnehmen + in access.auto.tfvars festzurren.)"
  log "Identitaet OK: signed-in user ist Mitglied von $ADMIN_GROUP."
else
  log "WARN: signed-in-user nicht ermittelbar (evtl. SP-Login). Fahre fort."
fi

# --- sqlcmd-Lauf in Funktion (ActiveDirectoryAzCli = aktuelles az-Token) ------
run_sql() {
  "$SQLCMD" -S "$FQDN" -d "$DB" --authentication-method ActiveDirectoryAzCli -l 20 -b -i "$SQL_FILE"
}

# Falls die FQDN auf eine private/nicht-routbare IP zeigt (Corporate-DNS liefert
# den PE) und wir den Public-Weg gehen: FQDN per rootless user-namespace auf den
# Public-Gateway pinnen (kein sudo noetig). getaddrinfo/go lesen /etc/hosts.
run_sql_pinned() {
  local pubip="$1"
  { cat /etc/hosts; echo "$pubip $FQDN"; } > /tmp/postapply_hosts
  unshare --map-root-user --mount sh -c \
    "mount --bind /tmp/postapply_hosts /etc/hosts && '$SQLCMD' -S '$FQDN' -d '$DB' --authentication-method ActiveDirectoryAzCli -l 20 -b -i '$SQL_FILE'"
}

if [ "$OPEN_PUBLIC" != "true" ]; then
  log "OPEN_PUBLIC=false -> direkter Lauf (erwartet In-VNet-Erreichbarkeit des PE)."
  run_sql
  log "Fertig."
  exit 0
fi

# --- Temp-Public-Fenster mit garantiertem Revert ------------------------------
revert() {
  log "REVERT: Firewall-Regel entfernen + publicNetworkAccess=Disabled"
  az sql server firewall-rule delete -g "$RG" -s "$SQL_SERVER" -n "$FW_RULE" >/dev/null 2>&1 || true
  az sql server update -g "$RG" -n "$SQL_SERVER" --set publicNetworkAccess=Disabled --query publicNetworkAccess -o tsv 2>/dev/null || true
  local n; n="$(az sql server firewall-rule list -g "$RG" -s "$SQL_SERVER" --query 'length(@)' -o tsv 2>/dev/null || echo '?')"
  log "Revert fertig. Verbleibende Firewall-Regeln: $n"
}
trap revert EXIT

MYIP="$(curl -fsS --max-time 8 https://api.ipify.org || curl -fsS --max-time 8 https://ifconfig.me)"
[ -n "$MYIP" ] || die "Eigene Egress-IP nicht ermittelbar."
log "Eigene Egress-IP: $MYIP"

log "publicNetworkAccess=Enabled"
az sql server update -g "$RG" -n "$SQL_SERVER" --set publicNetworkAccess=Enabled --query publicNetworkAccess -o tsv
log "Firewall-Regel $FW_RULE nur fuer $MYIP"
az sql server firewall-rule create -g "$RG" -s "$SQL_SERVER" -n "$FW_RULE" \
  --start-ip-address "$MYIP" --end-ip-address "$MYIP" --query name -o tsv

# Public-Gateway-IP ueber oeffentlichen Resolver holen (umgeht Corporate-DNS).
PUBIP="$( (command -v dig >/dev/null && dig +short @1.1.1.1 "$FQDN" | grep -Eo '^[0-9.]+$' | tail -1) || true )"
log "Public-Gateway laut 1.1.1.1: ${PUBIP:-<unbekannt>}"

ok=0
for a in 1 2 3 4 5; do
  log "SQL-Versuch $a ..."
  if [ -n "$PUBIP" ] && command -v unshare >/dev/null; then
    out="$(run_sql_pinned "$PUBIP" 2>&1)" && rc=0 || rc=$?
  else
    out="$(run_sql 2>&1)" && rc=0 || rc=$?
  fi
  echo "$out"
  if [ "$rc" -eq 0 ]; then ok=1; break; fi
  log "(rc=$rc, retry)"
done
[ "$ok" -eq 1 ] || die "SQL-Ausfuehrung fehlgeschlagen (siehe Ausgabe oben). Public-Access wird durch den trap zurueckgesetzt."
log "SQL erfolgreich angewandt."
