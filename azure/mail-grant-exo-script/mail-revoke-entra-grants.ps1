# Revoke org-wide Microsoft Graph Mail.* application grants from a service principal.
# Collapses the Entra + RBAC union so only the scoped Exchange RBAC grant remains.
# Idempotent: re-running skips grants that are already gone.

param(
    # Entra tenant to operate against, hard-pinned to one Entra directory.
    # Graph and EXO RBAC are TENANT-scoped, not subscription-scoped, so the tenant
    # is the lever here, not a subscription id. The the cloud subscription
    # <subscription-id> lives in exactly this tenant. Pinning it
    # stops a stale token or a multi-tenant login from hitting the wrong directory.
    #
    # Praezedenz wie in Terraform: explizites -Param schlaegt mailrbac.env, mailrbac.env schlaegt
    # den Hardcoded-Default hier. Die $env:MAILRBAC_*-Werte kommen vom .sh-Launcher, der
    # mailrbac.env sourcet. Wird das .ps1 ohne Launcher direkt aufgerufen, greifen die Defaults.
    [string]$TenantId     = $(if ($env:MAILRBAC_TENANT_ID)   { $env:MAILRBAC_TENANT_ID }   else { "00000000-0000-0000-0000-000000000000" }),
    # Enterprise App service principal Object ID, NOT the app registration object id
    [string]$SpObjectId   = $(if ($env:MAILRBAC_SP_OBJECT_ID) { $env:MAILRBAC_SP_OBJECT_ID } else { "22222222-2222-2222-2222-222222222222" }),
    # Graph application permissions to revoke from this SP
    [string[]]$RolesToRevoke = $(if ($env:MAILRBAC_ROLES_TO_REVOKE) { $env:MAILRBAC_ROLES_TO_REVOKE -split '\s*,\s*' } else { @("Mail.Send", "Mail.ReadWrite", "Mail.ReadBasic.All", "Mail.Read") }),
    # Preview only, do not delete anything
    [switch]$DryRun,
    # Default ist Device-Code, da die Skripte ueber WSL laufen und der Browser-Popup
    # dort unzuverlaessig ist. -Browser erzwingt den browserbasierten Login.
    [switch]$Browser
)

$ErrorActionPreference = "Stop"

# Well-known appId of the Microsoft Graph resource service principal
$GRAPH_APP_ID = "00000003-0000-0000-c000-000000000000"

# Live logging with timestamp and cumulative elapsed time
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
function Log {
    param([string]$Message, [string]$Color = "Gray")
    $ts = (Get-Date).ToString("HH:mm:ss")
    $el = $swTotal.Elapsed.ToString("mm\:ss")
    Write-Host "[$ts | +$el] $Message" -ForegroundColor $Color
}

# 1. Module
Log "Checking Microsoft.Graph.Applications module..."
if (-not (Get-Module Microsoft.Graph.Applications)) {
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Applications)) {
        Log "Module not found, installing. One time and slow..." "Yellow"
        Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force
    }
    Import-Module Microsoft.Graph.Applications
}
Log "Module ready." "Green"

# 2. Connect. Reuse session if already connected, else sign in
$scopes = @("Application.Read.All", "AppRoleAssignment.ReadWrite.All")
if (-not (Get-MgContext)) {
    $connectParams = @{ Scopes = $scopes; TenantId = $TenantId; NoWelcome = $true }
    # Default ist Device-Code, da die Skripte ueber WSL laufen und der Browser-Popup
    # dort unzuverlaessig ist. -Browser erzwingt den browserbasierten Login.
    if ($Browser) {
        Log "Connecting to Microsoft Graph, sign-in opens on Windows..." "Yellow"
    } else {
        # Param name differs across module versions, pick whichever exists
        $cmd = Get-Command Connect-MgGraph
        if     ($cmd.Parameters.ContainsKey('UseDeviceCode'))          { $connectParams.UseDeviceCode = $true }
        elseif ($cmd.Parameters.ContainsKey('UseDeviceAuthentication')) { $connectParams.UseDeviceAuthentication = $true }
        Log "Connecting via device code, no browser needed..." "Yellow"
    }
    Connect-MgGraph @connectParams
} else {
    Log "Reusing existing Graph session." "Green"
}
Log "Connected." "Green"

# Hard guard: refuse to touch the wrong Entra tenant. Catches a reused session or a
# multi-tenant account whose default directory is not the expected one. Runs on both the
# fresh-connect and the reuse path, which is exactly where a stale session bites.
$ctxTenant = (Get-MgContext).TenantId
if ($ctxTenant -ne $TenantId) {
    throw "Connected to Entra tenant '$ctxTenant' but expected '$TenantId'. Run Disconnect-MgGraph and reconnect with the expected account."
}
Log "Tenant verified: $TenantId" "Green"

# 3. Resolve the Graph resource SP and the target app role IDs by name
Log "Resolving Microsoft Graph app roles..."
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$GRAPH_APP_ID'" | Select-Object -First 1
$targetRoles = $graphSp.AppRoles | Where-Object {
    $_.Value -in $RolesToRevoke -and $_.AllowedMemberTypes -contains "Application"
}
# Build id to name lookup for readable logging
$roleNameById = @{}
foreach ($r in $targetRoles) { $roleNameById[$r.Id] = $r.Value }
Log "Looking for grants: $($targetRoles.Value -join ', ')" "Cyan"

# 4. Find this SP's current grants that point at Microsoft Graph
$assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $SpObjectId -All
$toRevoke = $assignments | Where-Object {
    $_.ResourceId -eq $graphSp.Id -and $roleNameById.ContainsKey($_.AppRoleId)
}

if (-not $toRevoke) {
    Log "Nothing to do. No matching Mail.* grants found on this SP." "Green"
    return
}

# 5. Revoke, or just preview when -DryRun is set
foreach ($a in $toRevoke) {
    $name = $roleNameById[$a.AppRoleId]
    if ($DryRun) {
        Log "DRY-RUN would revoke '$name', assignment id $($a.Id)" "Yellow"
    } else {
        Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $SpObjectId -AppRoleAssignmentId $a.Id
        Log "Revoked '$name'" "Green"
    }
}

# 6. Show what remains so you can eyeball the result
Log "Remaining Graph grants on this SP after run:" "Cyan"
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $SpObjectId -All |
    Where-Object { $_.ResourceId -eq $graphSp.Id } |
    Select-Object @{ n = 'Permission'; e = { ($graphSp.AppRoles | Where-Object Id -eq $_.AppRoleId).Value } }, Id |
    Format-Table

Log "Done. Total runtime above." "Cyan"
