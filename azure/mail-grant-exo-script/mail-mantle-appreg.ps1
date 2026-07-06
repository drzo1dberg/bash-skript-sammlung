# Scoped App-RBAC setup: restrict app-mailer-be to a single mailbox.
# Idempotent: re-running skips objects that already exist.

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
    [string]$TenantId      = $(if ($env:MAILRBAC_TENANT_ID)      { $env:MAILRBAC_TENANT_ID }      else { "00000000-0000-0000-0000-000000000000" }),
    [string]$Organization  = $(if ($env:MAILRBAC_ORGANIZATION)   { $env:MAILRBAC_ORGANIZATION }   else { "contoso.onmicrosoft.com" }),
    [string]$AppId         = $(if ($env:MAILRBAC_APP_ID)         { $env:MAILRBAC_APP_ID }         else { "11111111-1111-1111-1111-111111111111" }),  # Enterprise App "Application ID"
    [string]$SpObjectId    = $(if ($env:MAILRBAC_SP_OBJECT_ID)   { $env:MAILRBAC_SP_OBJECT_ID }   else { "22222222-2222-2222-2222-222222222222" }),  # Enterprise App "Object ID"
    [string]$AppName       = $(if ($env:MAILRBAC_APP_NAME)       { $env:MAILRBAC_APP_NAME }       else { "app-mailer-be" }),
    [string]$TargetMailbox = $(if ($env:MAILRBAC_TARGET_MAILBOX) { $env:MAILRBAC_TARGET_MAILBOX } else { "service-mailbox@contoso.com" }),
    [string]$ScopeName     = $(if ($env:MAILRBAC_SCOPE_NAME)     { $env:MAILRBAC_SCOPE_NAME }     else { "SingleMailbox-Scope" }),
    # Only the roles the app truly needs. Add "Application Mail.ReadWrite" if read access is required.
    [string[]]$Roles       = $(if ($env:MAILRBAC_ROLES)          { $env:MAILRBAC_ROLES -split '\s*,\s*' } else { @("Application Mail.Send") }),
    # Keep the EXO session open after the run, useful for fast iteration
	[switch]$Browser,
    [switch]$KeepConnection
)

$ErrorActionPreference = "Stop"

# Live logging: timestamp + cumulative elapsed so you can see where it stalls
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
function Log {
    param([string]$Message, [string]$Color = "Gray")
    $ts = (Get-Date).ToString("HH:mm:ss")
    $el = $swTotal.Elapsed.ToString("mm\:ss")
    Write-Host "[$ts | +$el] $Message" -ForegroundColor $Color
}

# Load module only if not already imported. Avoids slow path scans on re-runs
Log "Checking ExchangeOnlineManagement module..."
if (-not (Get-Module ExchangeOnlineManagement)) {
    if (-not (Get-Module -ListAvailable ExchangeOnlineManagement)) {
        Log "Module not found, installing (one-time, slow)..." "Yellow"
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
    }
    Log "Importing module (this can take a few seconds)..."
    Import-Module ExchangeOnlineManagement
}
Log "Module ready." "Green"

# Reuse an existing connection if present, otherwise connect
$conn = Get-ConnectionInformation -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $conn) {
    if ($Browser) {
        Log "Connecting to Exchange Online, sign-in opens on Windows..." "Yellow"
        Connect-ExchangeOnline -ShowBanner:$false
    } else {
        Log "Connecting via device code, no browser needed..." "Yellow"
        Connect-ExchangeOnline -Device -ShowBanner:$false
    }
    Log "Connected." "Green"
} else {
    Log "Reusing existing EXO connection: $($conn.UserPrincipalName)" "Green"
}

# Hard guard: EXO RBAC is tenant-scoped. Refuse to run if the live session is not the
# expected tenant, e.g. a stale reused session or a multi-tenant account. Re-read the
# connection because $conn is null right after a fresh connect above.
$conn = Get-ConnectionInformation -ErrorAction SilentlyContinue | Select-Object -First 1
if ($conn.TenantId -ne $TenantId) {
    throw "Connected EXO tenant '$($conn.TenantId)' but expected '$TenantId' ($Organization). Run Disconnect-ExchangeOnline and reconnect with the expected admin account."
}
Log "Tenant verified: $TenantId" "Green"

# 1. EXO pointer to the existing Entra service principal
Log "Step 1/4: service principal pointer..."
if (-not (Get-ServicePrincipal -Identity $AppId -ErrorAction SilentlyContinue)) {
    New-ServicePrincipal -AppId $AppId -ObjectId $SpObjectId -DisplayName $AppName | Out-Null
    Log "Created service principal pointer for $AppName" "Green"
} else {
    Log "Service principal already exists, skipping" "DarkGray"
}

# 2. Management scope limited to exactly one mailbox
Log "Step 2/4: management scope..."
if (-not (Get-ManagementScope -Identity $ScopeName -ErrorAction SilentlyContinue)) {
    New-ManagementScope -Name $ScopeName -RecipientRestrictionFilter "PrimarySmtpAddress -eq '$TargetMailbox'" | Out-Null
    Log "Created management scope $ScopeName for $TargetMailbox" "Green"
} else {
    Log "Management scope already exists, skipping" "DarkGray"
}

# 3. Scoped role assignment per role
# Split a comma-joined -Roles string, and make the assignment name app-specific
# so two different apps never collide on the same name.
$roleList = $Roles | ForEach-Object { $_ -split '\s*,\s*' } | Where-Object { $_ }
$appTag = $AppId.Substring(0, 8)
Log "Step 3/4: role assignments for: $($roleList -join ', ')"
foreach ($role in $roleList) {
    $assignmentName = "$role-$ScopeName-$appTag"
    if (-not (Get-ManagementRoleAssignment -Identity $assignmentName -ErrorAction SilentlyContinue)) {
        New-ManagementRoleAssignment -Name $assignmentName -App $AppId -Role $role -CustomResourceScope $ScopeName | Out-Null
        Log "Assigned '$role' scoped to $ScopeName as '$assignmentName'" "Green"
    } else {
        Log "Role assignment '$assignmentName' already exists, skipping" "DarkGray"
    }
}

# 4. Verify. InScope = True means access is allowed for that mailbox
Log "Step 4/4: verifying authorization against $TargetMailbox..."
Test-ServicePrincipalAuthorization -Identity $AppId -Resource $TargetMailbox | Format-Table

Log "Done. Total runtime above." "Cyan"

if ($KeepConnection) {
    Log "Keeping EXO session open (-KeepConnection set)." "Yellow"
} else {
    Disconnect-ExchangeOnline -Confirm:$false
    Log "Disconnected." "DarkGray"
}
