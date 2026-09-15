# Meraki → Jira Assets CMDB Synchronization
# Portfolio-safe reference implementation.
#
# Purpose:
#   - Load Meraki and Jira Assets credentials from Azure Key Vault
#   - Fetch network devices and operational status from Meraki Dashboard
#   - Filter devices by product type and network
#   - Parse naming conventions into CMDB attributes
#   - Create missing Jira Assets objects
#   - Update existing objects by stable serial number
#   - Support dry-run/test limits before applying changes
#
# IMPORTANT:
#   Environment-specific IDs, names and credentials are intentionally replaced
#   with placeholders. Replace them only in the target environment.

$ErrorActionPreference = "Stop"

# -----------------------------
# CONFIGURATION
# -----------------------------
$KeyVaultName = "<key-vault-name>"

$SchemaId          = "<assets-schema-id>"
$SwitchObjectTypeId = "<switch-object-type-id>"

$ApplyChanges = $false
$TestLimit = 5
$ProductTypeFilter = "switch"

$NetworkId = "<meraki-network-id>"
$OfficeName = "<office-name>"

# Jira Assets attribute IDs are environment-specific.
$Attr = @{
    Name               = "<attribute-id-name>"
    SerialNumber       = "<attribute-id-serial>"
    Model              = "<attribute-id-model>"
    MacAddress         = "<attribute-id-mac>"
    LanIp              = "<attribute-id-lan-ip>"
    Firmware           = "<attribute-id-firmware>"
    NetworkId          = "<attribute-id-network-id>"
    ProductType        = "<attribute-id-product-type>"
    Source             = "<attribute-id-source>"
    LastSynced         = "<attribute-id-last-synced>"
    Floor              = "<attribute-id-floor>"
    PublicIp           = "<attribute-id-public-ip>"
    Office             = "<attribute-id-office>"
    Area               = "<attribute-id-area>"
    DeviceNumber       = "<attribute-id-device-number>"
    MerakiDashboardUrl = "<attribute-id-dashboard-url>"
    SwitchStatus       = "<attribute-id-switch-status>"
    LastReportedAt     = "<attribute-id-last-reported>"
    MerakiNetworkName  = "<attribute-id-network-name>"
}

# -----------------------------
# KEY VAULT / API AUTHENTICATION
# -----------------------------
$MerakiApiKey   = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "meraki-api-key" -AsPlainText).Trim()
$OrganizationId = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "meraki-organization-id" -AsPlainText).Trim()
$JiraEmail      = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "jira-email" -AsPlainText).Trim()
$JiraToken      = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "asset-jira-token" -AsPlainText).Trim()
$WorkspaceId    = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "jira-workspace-id" -AsPlainText).Trim()

$MerakiBaseUri = "https://api.meraki.com/api/v1"
$AssetsBase = "https://api.atlassian.com/jsm/assets/workspace/$WorkspaceId/v1"

$MerakiHeaders = @{
    "X-Cisco-Meraki-API-Key" = $MerakiApiKey
    Accept = "application/json"
    "Content-Type" = "application/json"
    "User-Agent" = "CMDB-Meraki-JSM-Sync/1.0"
}

$BasicAuth = [Convert]::ToBase64String(
    [System.Text.Encoding]::UTF8.GetBytes("$JiraEmail`:$JiraToken")
)

$JsmHeaders = @{
    Authorization = "Basic $BasicAuth"
    Accept = "application/json"
    "Content-Type" = "application/json"
}

# -----------------------------
# API HELPERS
# -----------------------------
function Invoke-MerakiGet {
    param([Parameter(Mandatory)][string]$Uri)
    try {
        Invoke-RestMethod -Method Get -Uri $Uri -Headers $MerakiHeaders
    }
    catch {
        Write-Error "Meraki API request failed: $($_.Exception.Message)"
        throw
    }
}

function Invoke-JsmPost {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][object]$Body)
    try {
        $jsonBody = $Body | ConvertTo-Json -Depth 40
        Invoke-RestMethod -Method Post -Uri $Uri -Headers $JsmHeaders -Body $jsonBody
    }
    catch {
        Write-Error "Jira Assets POST failed: $($_.Exception.Message)"
        throw
    }
}

function Invoke-JsmPut {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][object]$Body)
    try {
        $jsonBody = $Body | ConvertTo-Json -Depth 40
        Invoke-RestMethod -Method Put -Uri $Uri -Headers $JsmHeaders -Body $jsonBody
    }
    catch {
        Write-Error "Jira Assets PUT failed: $($_.Exception.Message)"
        throw
    }
}

function Add-AssetAttribute {
    param([Parameter(Mandatory)][string]$AttributeId, [AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return @{
        objectTypeAttributeId = $AttributeId
        objectAttributeValues = @(@{ value = [string]$Value })
    }
}

function Escape-AqlValue {
    param([Parameter(Mandatory)][string]$Value)
    $Value.Replace('\', '\\').Replace('"', '\"')
}

function Convert-MerakiStatusToJsmStatus {
    param([AllowNull()][string]$Status)
    if ([string]::IsNullOrWhiteSpace($Status)) { return "Unknown" }
    switch ($Status.ToLower()) {
        "online"   { "Online" }
        "offline"  { "Offline" }
        "alerting" { "Alerting" }
        "dormant"  { "Dormant" }
        default    { "Unknown" }
    }
}

function Find-JsmSwitchBySerial {
    param([Parameter(Mandatory)][string]$SerialNumber)
    $safeSerial = Escape-AqlValue $SerialNumber
    $aql = "objectTypeId = $SwitchObjectTypeId AND `"Serial Number`" = `"$safeSerial`""
    $result = Invoke-JsmPost -Uri "$AssetsBase/object/aql" -Body @{
        qlQuery = $aql
        page = 1
        resultsPerPage = 1
    }
    if ($result.values -and $result.values.Count -gt 0) { return $result.values[0] }
    if ($result.objectEntries -and $result.objectEntries.Count -gt 0) { return $result.objectEntries[0] }
    return $null
}

function Get-ObjectIdFromJsmObject {
    param([Parameter(Mandatory)][object]$Object)
    if ($Object.id) { return $Object.id }
    if ($Object.objectId) { return $Object.objectId }
    throw "Could not determine Jira Assets object ID."
}

function Parse-SwitchName {
    param([AllowNull()][string]$Name)
    $result = @{ Floor = $null; Area = $null; DeviceNumber = $null }
    if ([string]::IsNullOrWhiteSpace($Name)) { return $result }
    foreach ($part in ($Name -split "-")) {
        if ($part -match '^F\d{1,2}$') { $result.Floor = $part }
        elseif ($part -match '^(R\d{1,3}|IDF|MDF|RACK\d{1,3})$') { $result.Area = $part }
        elseif ($part -match '^(SW|ASW|CSW|DSW|MSW|ISW)\d{1,3}$') { $result.DeviceNumber = $part }
    }
    return $result
}

function New-SwitchPayload {
    param(
        [Parameter(Mandatory)][object]$Device,
        [AllowNull()][object]$Status,
        [Parameter(Mandatory)][string]$NetworkName,
        [Parameter(Mandatory)][string]$OfficeName
    )

    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $objectName = if ($Device.name) { $Device.name } else { "$($Device.model) - $($Device.serial)" }
    $parsed = Parse-SwitchName $objectName

    $statusValue = "Unknown"
    $publicIp = $null
    $lastReportedAt = $null

    if ($Status) {
        $statusValue = Convert-MerakiStatusToJsmStatus $Status.status
        $publicIp = $Status.publicIp
        if ($Status.lastReportedAt) {
            try { $lastReportedAt = ([datetime]$Status.lastReportedAt).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") } catch {}
        }
    }

    $attributes = @(
        (Add-AssetAttribute $Attr.Name $objectName)
        (Add-AssetAttribute $Attr.SerialNumber $Device.serial)
        (Add-AssetAttribute $Attr.Model $Device.model)
        (Add-AssetAttribute $Attr.MacAddress $Device.mac)
        (Add-AssetAttribute $Attr.LanIp $Device.lanIp)
        (Add-AssetAttribute $Attr.Firmware $Device.firmware)
        (Add-AssetAttribute $Attr.NetworkId $Device.networkId)
        (Add-AssetAttribute $Attr.ProductType $Device.productType)
        (Add-AssetAttribute $Attr.Source "Cisco Meraki")
        (Add-AssetAttribute $Attr.LastSynced $now)
        (Add-AssetAttribute $Attr.Office $OfficeName)
        (Add-AssetAttribute $Attr.Floor $parsed.Floor)
        (Add-AssetAttribute $Attr.Area $parsed.Area)
        (Add-AssetAttribute $Attr.DeviceNumber $parsed.DeviceNumber)
        (Add-AssetAttribute $Attr.MerakiNetworkName $NetworkName)
        (Add-AssetAttribute $Attr.MerakiDashboardUrl $Device.url)
        (Add-AssetAttribute $Attr.SwitchStatus $statusValue)
        (Add-AssetAttribute $Attr.PublicIp $publicIp)
        (Add-AssetAttribute $Attr.LastReportedAt $lastReportedAt)
    ) | Where-Object { $null -ne $_ }

    return @{ objectTypeId = $SwitchObjectTypeId; attributes = $attributes }
}

# -----------------------------
# MERAKI DISCOVERY
# -----------------------------
$networks = Invoke-MerakiGet "$MerakiBaseUri/organizations/$OrganizationId/networks"
$network = $networks | Where-Object { $_.id -eq $NetworkId } | Select-Object -First 1
$NetworkName = if ($network.name) { $network.name } else { $OfficeName }

$statuses = Invoke-MerakiGet "$MerakiBaseUri/organizations/$OrganizationId/devices/statuses"
$statusBySerial = @{}
foreach ($status in $statuses) { if ($status.serial) { $statusBySerial[$status.serial] = $status } }

$devices = Invoke-MerakiGet "$MerakiBaseUri/organizations/$OrganizationId/devices"
$selectedDevices = $devices | Where-Object {
    $_.productType -eq $ProductTypeFilter -and
    $_.networkId -eq $NetworkId -and
    -not [string]::IsNullOrWhiteSpace($_.serial)
}

if ($TestLimit -gt 0) { $selectedDevices = $selectedDevices | Select-Object -First $TestLimit }

# -----------------------------
# CREATE / UPDATE
# -----------------------------
$created = 0
$updated = 0
$wouldCreate = 0
$wouldUpdate = 0
$failed = 0

foreach ($device in $selectedDevices) {
    try {
        $status = if ($statusBySerial.ContainsKey($device.serial)) { $statusBySerial[$device.serial] } else { $null }
        $payload = New-SwitchPayload -Device $device -Status $status -NetworkName $NetworkName -OfficeName $OfficeName
        $existing = Find-JsmSwitchBySerial -SerialNumber $device.serial

        if ($existing) {
            if (-not $ApplyChanges) { $wouldUpdate++; continue }
            $objectId = Get-ObjectIdFromJsmObject $existing
            Invoke-JsmPut -Uri "$AssetsBase/object/$objectId" -Body $payload | Out-Null
            $updated++
        }
        else {
            if (-not $ApplyChanges) { $wouldCreate++; continue }
            Invoke-JsmPost -Uri "$AssetsBase/object/create" -Body $payload | Out-Null
            $created++
        }
    }
    catch {
        $failed++
        Write-Error "Failed to synchronize $($device.serial): $($_.Exception.Message)"
    }
}

[pscustomobject]@{
    selectedDevices = @($selectedDevices).Count
    created = $created
    updated = $updated
    wouldCreate = $wouldCreate
    wouldUpdate = $wouldUpdate
    failed = $failed
    applyChanges = $ApplyChanges
    network = $NetworkName
    productType = $ProductTypeFilter
}
