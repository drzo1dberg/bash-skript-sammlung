#!/usr/bin/env bash
#
# post-apply-create-sql-users.sh
# ------------------------------------------------------------------------------
# Legt die contained SQL-User fuer die Managed Identities an (Post-Apply-Schritt
# fuer Entra-only + private-only Azure SQL). Genau das, was beim ersten Deploy
# manuell gemacht wurde, hier reproduzierbar und idempotent.
#
# Env-Modus (empfohlen): erstes Argument ist die Env (test|acc|prod), analog zu
# den mail-* Launchern. Leitet RG/SQL-Server/Admin-Gruppe/MI-Namen ab,
# sourcet scripts/cfg.<env>.env und faehrt BEIDE DBs (appdb + appdb2),
# weil beide MIs auf beiden DBs contained user brauchen.
#
# Authentifizierung: Device-Code-Flow (immer), das sqlcmd nutzt danach
# ActiveDirectoryAzCli = dasselbe az-Token. Das Konto MUSS Mitglied der
# Admin-Gruppe sein (das Skript prueft das).
#
# Netzwerk: Solange das PE-Subnet kein symmetrisches Routing hat, erreicht KEIN
# In-VNet-Host den SQL-PE. Default oeffnet das Skript daher ein kurzes,
# auf die eigene Egress-IP beschraenktes Public-Fenster und dreht es per trap
# IMMER wieder auf den Ausgangszustand zu (mit Erfolgs-Verifikation). Ist der
# Routing-Fix live, mit OPEN_PUBLIC=false von einem In-VNet-Host laufen lassen.
#
# Verwendung:
#   ./post-apply-create-sql-users.sh prod                 # Env-Modus, beide DBs
#   ./post-apply-create-sql-users.sh acc                  # dito acc
#   DBS=appdb2 ./post-apply-create-sql-users.sh prod # nur eine DB
#   OPEN_PUBLIC=false ./post-apply-create-sql-users.sh prod  # aus dem VNet
#   ./post-apply-create-sql-users.sh                      # Legacy (test, DB=appdb)
#
# Ueberschreibbare ENV-Variablen siehe Konfigblock.
# ------------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] $*" >&2; }
die()  { echo "FEHLER: $*" >&2; exit 1; }

# --- Optionales erstes Argument <env> -----------------------------------------
# test|acc|prod: leitet die Standard-Namen ab und sourcet scripts/cfg.<env>.env
# (gleiche Konvention wie die mail-* Launcher). Ohne <env> = Legacy-Modus
# (Defaults test, per ENV-Var ueberschreibbar). Env ist gegen die Whitelist
# geprueft, daher unbedenklich in die generierte SQL interpoliert.
ENV_NAME=""
if [ $# -gt 0 ] && [[ "$1" =~ ^(test|acc|prod)$ ]]; then
  ENV_NAME="$1"; shift
  ENV_FILE="$SCRIPT_DIR/cfg.${ENV_NAME}.env"
  if [ -f "$ENV_FILE" ]; then
    log "Lade $ENV_FILE"
    set -a; # shellcheck source=/dev/null
    source "$ENV_FILE"; set +a
  fi
  suffix=""; [ "$ENV_NAME" != "test" ] && suffix="-$ENV_NAME"
  : "${RG:=rg-appdb-${ENV_NAME}-001}"
  : "${SQL_SERVER:=sql-appdb-${ENV_NAME}-001}"
  : "${ADMIN_GROUP:=grp-sql-appdb-admins${suffix}}"
elif [ $# -gt 0 ] && [[ "$1" != -* ]]; then
  die "Unbekannte Env '$1'. Erlaubt: test|acc|prod (oder ohne Argument = Legacy)."
fi

# --- Konfig (Env-Var > abgeleitet aus <env> > test-Default) -------------------
RG="${RG:-rg-appdb-test-001}"
SQL_SERVER="${SQL_SERVER:-sql-appdb-test-001}"
ADMIN_GROUP="${ADMIN_GROUP:-grp-sql-appdb-admins}"
OPEN_PUBLIC="${OPEN_PUBLIC:-true}"
FW_RULE="${FW_RULE:-tmp-postapply-create-users}"
FQDN="${SQL_SERVER}.database.windows.net"
TENANT_ID="${TENANT_ID:-${CFG_TENANT_ID:-00000000-0000-0000-0000-000000000000}}"

# Zustands-Flags fuer den unified Cleanup-trap (Temp-Datei + Fenster-Revert).
GEN_SQL=""; WINDOW_OPEN=0; DONE_CLEANUP=0; ORIG_PUBLIC=""

# Zu bearbeitende DBs: Env-Modus -> beide (beide MIs brauchen auf beiden DBs
# einen contained user: appdb = Chat-Storage/FE-MI, appdb2 = App-DB/BE-MI).
# Legacy -> die eine DB (Default appdb). Ueberschreibbar via DBS oder DB.
if [ -n "$ENV_NAME" ]; then
  DBS="${DBS:-appdb}"
else
  DBS="${DBS:-${DB:-appdb}}"
fi

# --- SQL-Datei: Env-Modus generiert sie aus den abgeleiteten MI-Namen ---------
SQL_FILE="${SQL_FILE:-$SCRIPT_DIR/create-sql-users.sql}"
if [ -n "$ENV_NAME" ] && [ "${SQL_FILE}" = "$SCRIPT_DIR/create-sql-users.sql" ]; then
  fe="id-${WORKLOAD}-fe-${ENV_NAME}-001"
  be="id-${WORKLOAD}-be-${ENV_NAME}-001"
  SQL_FILE="$(mktemp "/tmp/create-sql-users.${ENV_NAME}.XXXXXX.sql")"
  GEN_SQL="$SQL_FILE"
  cat > "$SQL_FILE" <<EOF
-- generiert von post-apply-create-sql-users.sh fuer env=${ENV_NAME}
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'${fe}')
    CREATE USER [${fe}] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [${fe}];
ALTER ROLE db_datawriter ADD MEMBER [${fe}];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'${be}')
    CREATE USER [${be}] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [${be}];
ALTER ROLE db_datawriter ADD MEMBER [${be}];
GO
SELECT dp.name AS [user], r.name AS [role]
FROM sys.database_role_members drm
JOIN sys.database_principals r  ON r.principal_id  = drm.role_principal_id
JOIN sys.database_principals dp ON dp.principal_id = drm.member_principal_id
WHERE dp.name IN (N'${fe}', N'${be}')
ORDER BY dp.name, r.name;
GO
EOF
  log "SQL generiert fuer $fe + $be -> $SQL_FILE"
fi

# --- Unified Cleanup: Fenster-Revert (falls geoeffnet) + Temp-Datei -----------
# EIN trap fuer alles, sonst wuerde ein zweiter trap auf EXIT den ersten
# ueberschreiben. Idempotent (DONE_CLEANUP). Signale reverten UND beenden sofort.
cleanup() {
  [ "$DONE_CLEANUP" = 1 ] && return; DONE_CLEANUP=1
  if [ "$WINDOW_OPEN" = 1 ]; then
    log "REVERT: Firewall-Regel $FW_RULE entfernen + publicNetworkAccess=$ORIG_PUBLIC"
    az sql server firewall-rule delete -g "$RG" -s "$SQL_SERVER" -n "$FW_RULE" >/dev/null 2>&1 || true
    az sql server update -g "$RG" -n "$SQL_SERVER" --set publicNetworkAccess="$ORIG_PUBLIC" -o none 2>/dev/null || true
    # Erfolg verifizieren: FW-Regel wirklich weg UND publicNetworkAccess zurueck.
    local still now
    still="$(az sql server firewall-rule show -g "$RG" -s "$SQL_SERVER" -n "$FW_RULE" --query name -o tsv 2>/dev/null || true)"
    now="$(az sql server show -g "$RG" -n "$SQL_SERVER" --query publicNetworkAccess -o tsv 2>/dev/null || echo '?')"
    if [ -n "$still" ] || [ "$now" != "$ORIG_PUBLIC" ]; then
      warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      warn "REVERT NICHT BESTAETIGT: FW-Regel='${still:-weg}', publicNetworkAccess=$now (soll $ORIG_PUBLIC)."
      warn "Die Operator-IP koennte auf prod-SQL offen bleiben. SOFORT manuell:"
      warn "  az sql server firewall-rule delete -g $RG -s $SQL_SERVER -n $FW_RULE"
      warn "  az sql server update -g $RG -n $SQL_SERVER --set publicNetworkAccess=$ORIG_PUBLIC"
      warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    else
      log "Revert bestaetigt (FW-Regel weg, publicNetworkAccess=$now)."
    fi
  fi
  if [ -n "$GEN_SQL" ]; then rm -f "$GEN_SQL" 2>/dev/null || true; fi
}
on_sig() { cleanup; exit 130; }
trap cleanup EXIT
trap on_sig INT TERM HUP

command -v az >/dev/null || die "az CLI nicht gefunden."
[ -f "$SQL_FILE" ] || die "SQL-Datei nicht gefunden: $SQL_FILE"

# Preflight: Env-Konsistenz zwischen Ziel-Server und SQL-Datei erzwingen. Faengt
# den Cross-Env-Unfall ab (prod-MI-Namen in der Datei, aber SQL_SERVER zeigt auf
# test, weil ein Teil-Override RG/SQL_SERVER vergessen hat) -> wuerde sonst still
# einen prod-MI als contained user in der test-DB anlegen. Env-Token aus dem
# Servernamen gegen die MI-Namen in der Datei.
srv_env="$(printf '%s\n' "$SQL_SERVER" | grep -oE '(test|acc|prod)-001' | grep -oE '(test|acc|prod)' | head -1 || true)"
file_env="$(grep -oE "id-${WORKLOAD}-(fe|be)-(test|acc|prod)-001" "$SQL_FILE" 2>/dev/null | grep -oE '(test|acc|prod)-001$' | grep -oE '(test|acc|prod)' | sort -u | paste -sd, - || true)"
if [ -n "$srv_env" ] && [ -n "$file_env" ] && [ "$file_env" != "$srv_env" ]; then
  die "Env-Mismatch: SQL_SERVER=$SQL_SERVER (env=$srv_env) passt NICHT zu den MI-Namen in $SQL_FILE (env=$file_env). Abbruch, sonst Cross-Env contained user. Nutze den Env-Modus: ./post-apply-create-sql-users.sh $srv_env"
elif [ -z "$srv_env" ] && [ -n "$file_env" ]; then
  warn "WARN: SQL_SERVER='$SQL_SERVER' hat kein <env>-001-Muster, Cross-Env-Preflight uebersprungen. SQL-Datei traegt env=$file_env. Sicherstellen, dass der Server dazu passt."
fi
log "Ziel: RG=$RG SQL=$SQL_SERVER ADMIN_GROUP=$ADMIN_GROUP DBs='$DBS'"

# Auth: IMMER Device-Code-Flow (kein Browser-Redirect, zuverlaessig in WSL/headless).
# RELOGIN=1 erzwingt neues Login (z.B. um als ein Mitglied von $ADMIN_GROUP reinzukommen).
if [ "${RELOGIN:-0}" = "1" ] || ! az account show >/dev/null 2>&1; then
  log "az-Login per Device-Code-Flow (Tenant $TENANT_ID) ..."
  az login --use-device-code --tenant "$TENANT_ID" -o none
fi

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

# --- sqlcmd-Lauf pro DB (ActiveDirectoryAzCli = aktuelles az-Token) -----------
run_sql() {  # $1=db
  "$SQLCMD" -S "$FQDN" -d "$1" --authentication-method ActiveDirectoryAzCli -l 20 -b -i "$SQL_FILE"
}
# Falls die FQDN auf die private/nicht-routbare PE-IP zeigt (Corporate-DNS) und
# wir den Public-Weg gehen: FQDN per rootless user-namespace auf den Public-
# Gateway pinnen (kein sudo noetig). getaddrinfo/go lesen /etc/hosts.
run_sql_pinned() {  # $1=pubip $2=db
  { cat /etc/hosts; echo "$1 $FQDN"; } > /tmp/postapply_hosts
  unshare --map-root-user --mount sh -c \
    "mount --bind /tmp/postapply_hosts /etc/hosts && '$SQLCMD' -S '$FQDN' -d '$2' --authentication-method ActiveDirectoryAzCli -l 20 -b -i '$SQL_FILE'"
}

# Wendet die SQL auf jede DB in $DBS an (mit Retry). Nutzt $PUBIP falls gesetzt.
apply_all_dbs() {
  local db a rc out ok
  for db in $DBS; do
    log "== DB $db =="
    ok=0
    for a in 1 2 3 4 5; do
      log "  SQL-Versuch $a ..."
      if [ -n "${PUBIP:-}" ] && command -v unshare >/dev/null; then
        out="$(run_sql_pinned "$PUBIP" "$db" 2>&1)" && rc=0 || rc=$?
      else
        out="$(run_sql "$db" 2>&1)" && rc=0 || rc=$?
      fi
      echo "$out"
      if [ "$rc" -eq 0 ]; then ok=1; break; fi
      log "  (rc=$rc, retry)"
    done
    [ "$ok" -eq 1 ] || die "SQL-Ausfuehrung fuer DB '$db' fehlgeschlagen (siehe oben). Public-Access wird durch den trap zurueckgesetzt."
    log "  DB $db OK."
  done
}

if [ "$OPEN_PUBLIC" != "true" ]; then
  log "OPEN_PUBLIC=false -> direkter Lauf (In-VNet-Erreichbarkeit des PE erwartet)."
  PUBIP=""
  apply_all_dbs
  log "Fertig."
  exit 0
fi

# --- Temp-Public-Fenster (Revert via unified cleanup-trap oben) ---------------
# Ausgangszustand von publicNetworkAccess lesen und beim Revert exakt
# wiederherstellen. NICHT hart auf Disabled setzen: test/acc/prod fahren die
# eigene SQL bewusst mit public_network_access_enabled=true (Zugriff via
# admin_ip_cidrs). Ein hartes Disabled wuerde die live-Env faelschlich privat
# drehen (Drift bis zum naechsten Apply, Admin-IPs abgeschnitten).
ORIG_PUBLIC="$(az sql server show -g "$RG" -n "$SQL_SERVER" --query publicNetworkAccess -o tsv 2>/dev/null || echo Enabled)"
[ -n "$ORIG_PUBLIC" ] || ORIG_PUBLIC="Enabled"
log "Ausgangs-publicNetworkAccess=$ORIG_PUBLIC (wird beim Revert wiederhergestellt)."

# AB HIER revertet der cleanup-trap das Fenster. Bewusst VOR der ersten Mutation
# gesetzt: bricht das FW-create ab oder kommt ein Signal zwischen Enable und
# create, muss der Revert trotzdem laufen (delete/update sind idempotent, || true).
WINDOW_OPEN=1

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

apply_all_dbs
log "SQL erfolgreich angewandt (DBs: $DBS)."
