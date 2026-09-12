# ─────────────────────────────────────────────────────
# RUNBOOK: Retire-Devices
# Detects devices gone from Intune → sets RETIRED in JSM
# Runs daily at 3:00 AM via Azure Automation
# ─────────────────────────────────────────────────────

# 0. Auth
$IsRunbook = $null -ne $PSPrivateMetadata.JobId

if ($IsRunbook) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null
    Set-AzContext -SubscriptionId "514d4dd4-bf2a-421d-83d6-e06c1f04724a" | Out-Null
    Write-Output "✓ Authenticated via Managed Identity"
} else {
    try {
        $ctx = Get-AzContext
        if (-not $ctx -or -not $ctx.Account) { Connect-AzAccount }
        Set-AzContext -SubscriptionId "514d4dd4-bf2a-421d-83d6-e06c1f04724a" -ErrorAction Stop | Out-Null
    } catch {
        Connect-AzAccount
        Set-AzContext -SubscriptionId "514d4dd4-bf2a-421d-83d6-e06c1f04724a" | Out-Null
    }
    Write-Output "✓ Local Azure session ready"
}

# 1. Load credentials
$KeyVaultName = "kv-intune-assets-dev"
$TenantId     = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "graph-tenant-id"     -AsPlainText
$ClientId     = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "graph-client-id"     -AsPlainText
$ClientSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "graph-client-secret" -AsPlainText
$JiraEmail    = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "jira-email"           -AsPlainText
$JiraToken    = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "asset-jira-token"     -AsPlainText
$WorkspaceId  = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "jira-workspace-id"   -AsPlainText
Write-Output "✓ Secrets loaded"

# 2. Authentication
$TokenBody = @{
    client_id     = $ClientId
    scope         = "https://graph.microsoft.com/.default"
    client_secret = $ClientSecret
    grant_type    = "client_credentials"
}
$Token        = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $TokenBody
$GraphHeaders = @{ Authorization = "Bearer $($Token.access_token)" }

$b64         = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${JiraEmail}:${JiraToken}"))
$JiraHeaders = @{ Authorization = "Basic $b64"; Accept = "application/json"; "Content-Type" = "application/json" }
$AssetsBase  = "https://api.atlassian.com/jsm/assets/workspace/$WorkspaceId/v1"
Write-Output "✓ Authenticated to Graph and Jira"

# 3. Fetch all serial numbers currently in Intune
Write-Output "Fetching all devices from Intune..."
$IntuneSerials = @{}
$url = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$top=999&`$select=serialNumber"
while ($url) {
    $r = Invoke-RestMethod -Method Get -Uri $url -Headers $GraphHeaders
    foreach ($d in $r.value) {
        if ($d.serialNumber) { $IntuneSerials[$d.serialNumber] = $true }
    }
    $url = $r.'@odata.nextLink'
}
Write-Output "✓ $($IntuneSerials.Count) devices in Intune"

# 4. Fetch all IN USE devices from JSM
Write-Output "Fetching IN USE devices from JSM..."
$page = 1; $JsmDevices = @(); $total = $null

do {
    $body = @{
        qlQuery        = "objectTypeId in (15, 56, 55, 16, 58, 59, 60) AND `"Asset Status`" = `"IN USE`""
        page           = $page
        resultsPerPage = 25
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Method Post -Uri "$AssetsBase/object/aql" -Headers $JiraHeaders -Body $body
    if (-not $total) { $total = $r.total }
    $JsmDevices += $r.values
    $page++
} while ($JsmDevices.Count -lt $total)

Write-Output "✓ $($JsmDevices.Count) IN USE devices in JSM"

# 5. Find devices in JSM but not in Intune → retire them
$retired = 0; $errors = 0

foreach ($jsmDevice in $JsmDevices) {
    $snAttr = $jsmDevice.attributes | Where-Object { $_.objectTypeAttributeId -eq "133" }
    $sn     = if ($snAttr -and $snAttr.objectAttributeValues.Count -gt 0) { $snAttr.objectAttributeValues[0].value } else { $null }

    if (-not $sn) { continue }
    if ($IntuneSerials.ContainsKey($sn)) { continue }

    Write-Output "RETIRING — $sn ($($jsmDevice.name))"

    $body = @{
        attributes = @(
            @{ objectTypeAttributeId = "145"; objectAttributeValues = @(@{ value = "11" }) }
            @{ objectTypeAttributeId = "551"; objectAttributeValues = @(@{ value = "Retired — removed from Intune" }) }
        )
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Method Put -Uri "$AssetsBase/object/$($jsmDevice.id)" -Headers $JiraHeaders -Body $body | Out-Null
        Write-Output "  ✓ RETIRED"
        $retired++
    } catch {
        Write-Output "  ERROR — $($_.ErrorDetails.Message)"
        $errors++
    }
    Start-Sleep -Milliseconds 200
}

Write-Output "`n══ SUMMARY ══════════════════════════════════"
Write-Output "  Retired : $retired"
Write-Output "  Errors  : $errors"
