# Read or change the App-RBAC mailbox scope for app-mailer-be.
# No -NewMailbox given -> read-only, prints the current state.
# -NewMailbox <addr>   -> repoints the scope to that single mailbox.
# Changing the scope propagates to every role assignment that uses it.

param(
    # Entra tenant + EXO org to operate against, hard-pinned to one Entra
    # directory. EXO RBAC is TENANT-scoped, not subscription-scoped, so the tenant is
    # the lever here, not a subscription id. The the cloud subscription
    # <subscription-id> lives in exactly this tenant. TenantId guards
    # the live session below; Organization is the .onmicrosoft.com domain that the
    # -Organization parameter would need if this ever moves to app-only / MI auth.
    #
    # Praezedenz wie in Terraform: explizites -Param schlaegt mailrbac.env, mailrbac.env schlaegt
    # den Hardcoded-Default hier. Die $env:MAILRBAC_*-Werte kommen vom .sh-Launcher, der
    # mailrbac.env sourcet. Wird das .ps1 ohne Launcher direkt aufgerufen, greifen die Defaults.
    [string]$TenantId     = $(if ($env:MAILRBAC_TENANT_ID)    { $env:MAILRBAC_TENANT_ID }    else { "00000000-0000-0000-0000-000000000000" }),
    [string]$Organization = $(if ($env:MAILRBAC_ORGANIZATION) { $env:MAILRBAC_ORGANIZATION } else { "contoso.onmicrosoft.com" }),
    # App client ID, also accepted by Test-ServicePrincipalAuthorization and Get-ServicePrincipal
    [string]$AppId     = $(if ($env:MAILRBAC_APP_ID)     { $env:MAILRBAC_APP_ID }     else { "11111111-1111-1111-1111-111111111111" }),
    [string]$ScopeName = $(if ($env:MAILRBAC_SCOPE_NAME) { $env:MAILRBAC_SCOPE_NAME } else { "SingleMailbox-Scope" }),
    # Provide to switch the scope to a different single mailbox
    [string]$NewMailbox,
    # Preview the change without applying it
    [switch]$DryRun,
    # Default ist Device-Code, da die Skripte ueber WSL laufen und der Browser-Popup
    # dort unzuverlaessig ist. -Browser erzwingt den browserbasierten Login.
    [switch]$Browser
)

$ErrorActionPreference = "Stop"

$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
function Log {
    param([string]$Message, [string]$Color = "Gray")
    $ts = (Get-Date).ToString("HH:mm:ss")
    $el = $swTotal.Elapsed.ToString("mm\:ss")
    Write-Host "[$ts | +$el] $Message" -ForegroundColor $Color
}

# Module
if (-not (Get-Module ExchangeOnlineManagement)) {
    if (-not (Get-Module -ListAvailable ExchangeOnlineManagement)) {
        Log "Installing ExchangeOnlineManagement, one time and slow..." "Yellow"
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
    }
    Import-Module ExchangeOnlineManagement
}

# Connect, reuse session if present
if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    if ($Browser) {
        Log "Connecting to Exchange Online, sign-in opens on Windows..." "Yellow"
        Connect-ExchangeOnline -ShowBanner:$false
    } else {
        Log "Connecting via device code, no browser needed..." "Yellow"
        Connect-ExchangeOnline -Device -ShowBanner:$false
    }
} else {
    Log "Reusing existing EXO connection." "Green"
}

# Hard guard: EXO RBAC is tenant-scoped. Refuse to run if the live session is not the
# expected tenant, e.g. a stale reused session or a multi-tenant account.
$conn = Get-ConnectionInformation -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn.TenantId -ne $TenantId) {
    throw "Connected EXO tenant '$($conn.TenantId)' but expected '$TenantId' ($Organization). Run Disconnect-ExchangeOnline and reconnect with the expected admin account."
}
Log "Tenant verified: $TenantId" "Green"

# --- READ: always show the current state first ---
Log "Service principal pointer:" "Cyan"
Get-ServicePrincipal -Identity $AppId | Format-List DisplayName, AppId, ServiceId, ObjectId

Log "Management scope and its recipient filter:" "Cyan"
$scope = Get-ManagementScope -Identity $ScopeName
$scope | Format-List Name, RecipientFilter, RecipientRoot, Exclusive

Log "Effective RBAC assignments for this app:" "Cyan"
Test-ServicePrincipalAuthorization -Identity $AppId |
    Format-Table RoleName, GrantedPermissions, AllowedResourceScope, ScopeType

# --- CHANGE: only when -NewMailbox is provided ---
if ($NewMailbox) {
    # Safety: make sure the target mailbox actually exists
    $recipient = Get-Recipient -Identity $NewMailbox -ErrorAction SilentlyContinue
    if (-not $recipient) {
        throw "Recipient '$NewMailbox' not found. Aborting so the scope does not point at nothing."
    }

    $newFilter = "PrimarySmtpAddress -eq '$NewMailbox'"
    Log "Old filter: $($scope.RecipientFilter)" "Yellow"
    Log "New filter: $newFilter" "Yellow"

    if ($DryRun) {
        Log "DRY-RUN, no change applied. Re-run without -DryRun to switch the mailbox." "Yellow"
        return
    }

    Set-ManagementScope -Identity $ScopeName -RecipientRestrictionFilter $newFilter
    Log "Scope repointed to $NewMailbox. All role assignments using it follow automatically." "Green"

    # Re-read and verify against the new mailbox
    Log "New scope state:" "Cyan"
    Get-ManagementScope -Identity $ScopeName | Format-List Name, RecipientFilter
    Log "Verifying against $NewMailbox, InScope = True means allowed:" "Cyan"
    Test-ServicePrincipalAuthorization -Identity $AppId -Resource $NewMailbox |
        Format-Table RoleName, GrantedPermissions, AllowedResourceScope, InScope
}

Log "Done. Total runtime above." "Cyan"
