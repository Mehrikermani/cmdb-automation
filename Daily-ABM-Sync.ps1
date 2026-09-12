param(
    [bool]$ForceFullSync = $false,
    [int]$TestLimit = 0    # 0 = all devices, set to 20 for testing
)

# ─────────────────────────────────────────────────────
# RUNBOOK: Daily-ABM-Sync
# Apple Business Manager → Jira Assets
# - New devices → IN STOCK
# - Existing devices → update ABM attributes only, never touch Asset Status
# - Filters devices purchased since 1 January 2024
# ─────────────────────────────────────────────────────

# 0. Auth
$IsRunbook = $null -ne $PSPrivateMetadata.JobId

if ($IsRunbook) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null
    Set-AzContext -SubscriptionId "514d4dd4-bf2a-421d-83d6-e06c1f04724a" | Out-Null
    Write-Host "✓ Authenticated via Managed Identity"
} else {
    try {
        $ctx = Get-AzContext
        if (-not $ctx -or -not $ctx.Account) { Connect-AzAccount }
        Set-AzContext -SubscriptionId "514d4dd4-bf2a-421d-83d6-e06c1f04724a" -ErrorAction Stop | Out-Null
    } catch {
        Connect-AzAccount
        Set-AzContext -SubscriptionId "514d4dd4-bf2a-421d-83d6-e06c1f04724a" | Out-Null
    }
    Write-Host "✓ Local Azure session ready"
}

# 1. Load credentials
Write-Host "Loading secrets from Key Vault..."
$KeyVaultName     = "kv-intune-assets-dev"
$AbmKeyId         = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "abm-key-id"          -AsPlainText
$AbmClientId      = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "abm-client-id"        -AsPlainText
$AbmPrivateKeyB64 = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "abm-private-key-b64"  -AsPlainText
$AbmPrivateKey    = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($AbmPrivateKeyB64))
$JiraEmail        = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "jira-email"            -AsPlainText
$JiraToken        = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "asset-jira-token"      -AsPlainText
$WorkspaceId      = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "jira-workspace-id"     -AsPlainText
Write-Host "✓ Secrets loaded"

# 2. Token functions
function ConvertTo-Base64Url([byte[]]$bytes) {
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-AbmToken($KeyId, $ClientId, $PrivateKeyPem) {
    Write-Host "  Building JWT..."
    $header  = @{ alg = "ES256"; kid = $KeyId; typ = "JWT" } | ConvertTo-Json -Compress
    $now     = [int][double]::Parse((Get-Date -UFormat %s))
    $exp     = $now + 86400 * 180
    $claims  = @{
        iss = $ClientId; iat = $now; exp = $exp
        aud = "https://account.apple.com/auth/oauth2/v2/token"
        sub = $ClientId; jti = [System.Guid]::NewGuid().ToString()
    } | ConvertTo-Json -Compress

    $headerB64 = ConvertTo-Base64Url([Text.Encoding]::UTF8.GetBytes($header))
    $claimsB64 = ConvertTo-Base64Url([Text.Encoding]::UTF8.GetBytes($claims))
    $unsigned  = "$headerB64.$claimsB64"

    $normalizedPem = $PrivateKeyPem -replace "`r`n", "`n" -replace "`r", "`n"
    $pemLines  = $normalizedPem -split "`n" | Where-Object { $_ -and $_ -notmatch "^-" }
    $keyBytes  = [Convert]::FromBase64String(($pemLines -join "").Trim())

    $ecdsa     = [System.Security.Cryptography.ECDsa]::Create()
    $bytesRead = 0; $imported = $false

    try { $ecdsa.ImportPkcs8PrivateKey($keyBytes, [ref]$bytesRead); $imported = $true } catch {}
    if (-not $imported) {
        try { $ecdsa.ImportECPrivateKey($keyBytes, [ref]$bytesRead); $imported = $true } catch {}
    }
    if (-not $imported) { throw "Failed to import private key" }

    Write-Host "  Signing JWT and exchanging for token..."
    $signature = $ecdsa.SignData([Text.Encoding]::UTF8.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256)
    $jwt       = "$unsigned.$(ConvertTo-Base64Url $signature)"
    $ecdsa.Dispose()

    $tokenResp = Invoke-RestMethod -Method Post `
        -Uri "https://account.apple.com/auth/oauth2/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body "grant_type=client_credentials&client_id=$ClientId&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=$jwt&scope=business.api"

    return $tokenResp.access_token
}

function Get-JiraHeaders($Email, $Token) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${Email}:${Token}"))
    return @{ Authorization = "Basic $b64"; Accept = "application/json"; "Content-Type" = "application/json" }
}

function Invoke-TokenRefreshIfNeeded($TokenTime, $KeyId, $ClientId, $PrivateKey, $JiraEmail, $JiraToken) {
    $age = (New-TimeSpan -Start $TokenTime -End (Get-Date)).TotalMinutes
    if ($age -gt 55) {
        Write-Host "  ♻ Refreshing tokens (age: $([math]::Round($age,1)) min)..."
        $script:AbmAccessToken = Get-AbmToken $KeyId $ClientId $PrivateKey
        $script:AbmHeaders     = @{ Authorization = "Bearer $script:AbmAccessToken" }
        $script:JiraHeaders    = Get-JiraHeaders $JiraEmail $JiraToken
        $script:TokenObtained  = Get-Date
        Write-Host "  ✓ Tokens refreshed"
    }
}

# 3. Initial authentication
Write-Host "Authenticating to ABM..."
$AbmAccessToken = Get-AbmToken $AbmKeyId $AbmClientId $AbmPrivateKey
$AbmHeaders     = @{ Authorization = "Bearer $AbmAccessToken" }
$TokenObtained  = Get-Date
Write-Host "✓ ABM authenticated"

$JiraHeaders = Get-JiraHeaders $JiraEmail $JiraToken
$AssetsBase  = "https://api.atlassian.com/jsm/assets/workspace/$WorkspaceId/v1"
Write-Host "✓ Jira headers built"

# 4. Reference maps
$ProductFamilyMap = @{
    "Mac"="56"; "iPhone"="16"; "iPad"="16"; "iPod"="16"
    "AppleTV"="15"; "AppleWatch"="15"; "HomePod"="15"; "AppleVision"="15"
}

$AssetStatusMap = @{
    "DISPOSED"="15"; "IN STOCK"="14"; "IN USE"="13"; "ORDERED"="12"
    "RETIRED"="11"; "MISSING"="10"; "IN TRANSIT"="9"; "PENDING RETURN"="83"
}

# 5. Attribute IDs
$DA = @{
    Name              = 131; SerialNumber      = 133
    Manufacturer      = 535; Platform          = 538
    DataSource        = 551; AssetStatus       = 145
    AbmAddedDate      = 761; AbmOrderNumber    = 762
    AbmOrderDate      = 763; AbmPurchaseSource = 765
    AbmDeviceModel    = 766; AbmProductType    = 767
    AbmUpdatedDate    = 768; AbmReleasedDate   = 903
}

# 6. Helpers
function Get-ObjectTypeId($ProductFamily) {
    if ($ProductFamilyMap.ContainsKey($ProductFamily)) { return $ProductFamilyMap[$ProductFamily] }
    return "15"
}

function Get-Platform($ProductFamily) {
    switch ($ProductFamily) {
        "Mac"    { return "macOS" }
        "iPhone" { return "iOS" }
        "iPad"   { return "iOS" }
        "iPod"   { return "iOS" }
        default  { return $ProductFamily }
    }
}

function Get-SafeDate($dateValue) {
    if (-not $dateValue) { return $null }
    try { return ([datetime]$dateValue).ToString("yyyy-MM-dd") } catch { return $null }
}

function Invoke-JsmAqlPage($Aql, $Page, $Base, $Headers) {
    $body = @{ qlQuery = $Aql; page = $Page; resultsPerPage = 25 } | ConvertTo-Json
    return Invoke-RestMethod -Method Post -Uri "$Base/object/aql" -Headers $Headers -Body $body
}

function Build-AbmDevicePayload($Device, $DA, $TypeId, $IsUpdate) {

    if ($IsUpdate) {
        # UPDATE: only ABM attributes — never touch Asset Status or Primary User
        $attrs = @()
        $addedDate    = Get-SafeDate $Device.addedToOrgDateTime
        $orderDate    = Get-SafeDate $Device.orderDateTime
        $updatedDate  = Get-SafeDate $Device.updatedDateTime
        $releasedDate = Get-SafeDate $Device.releasedFromOrgDateTime

        if ($addedDate)                 { $attrs += @{ objectTypeAttributeId = "$($DA.AbmAddedDate)";    objectAttributeValues = @(@{ value = $addedDate }) } }
        if ($Device.orderNumber)        { $attrs += @{ objectTypeAttributeId = "$($DA.AbmOrderNumber)";  objectAttributeValues = @(@{ value = "$($Device.orderNumber)" }) } }
        if ($orderDate)                 { $attrs += @{ objectTypeAttributeId = "$($DA.AbmOrderDate)";    objectAttributeValues = @(@{ value = $orderDate }) } }
        if ($Device.purchaseSourceType) { $attrs += @{ objectTypeAttributeId = "$($DA.AbmPurchaseSource)"; objectAttributeValues = @(@{ value = "$($Device.purchaseSourceType)" }) } }
        if ($Device.deviceModel)        { $attrs += @{ objectTypeAttributeId = "$($DA.AbmDeviceModel)";  objectAttributeValues = @(@{ value = "$($Device.deviceModel)" }) } }
        if ($Device.productType)        { $attrs += @{ objectTypeAttributeId = "$($DA.AbmProductType)";  objectAttributeValues = @(@{ value = "$($Device.productType)" }) } }
        if ($updatedDate)               { $attrs += @{ objectTypeAttributeId = "$($DA.AbmUpdatedDate)";  objectAttributeValues = @(@{ value = $updatedDate }) } }
        if ($releasedDate)              { $attrs += @{ objectTypeAttributeId = "$($DA.AbmReleasedDate)"; objectAttributeValues = @(@{ value = $releasedDate }) } }

        if ($attrs.Count -eq 0) { return $null }
        return @{ objectTypeId = $TypeId; attributes = $attrs } | ConvertTo-Json -Depth 10

    } else {
        # CREATE: full payload — Asset Status always IN STOCK
        $attrs = @(
            @{ objectTypeAttributeId = "$($DA.Name)";         objectAttributeValues = @(@{ value = "$($Device.serialNumber)" }) }
            @{ objectTypeAttributeId = "$($DA.SerialNumber)"; objectAttributeValues = @(@{ value = "$($Device.serialNumber)" }) }
            @{ objectTypeAttributeId = "$($DA.Manufacturer)"; objectAttributeValues = @(@{ value = "Apple" }) }
            @{ objectTypeAttributeId = "$($DA.Platform)";     objectAttributeValues = @(@{ value = (Get-Platform $Device.productFamily) }) }
            @{ objectTypeAttributeId = "$($DA.DataSource)";   objectAttributeValues = @(@{ value = "Apple Business Manager" }) }
            @{ objectTypeAttributeId = "$($DA.AssetStatus)";  objectAttributeValues = @(@{ value = "14" }) }  # IN STOCK always
        )
        $addedDate    = Get-SafeDate $Device.addedToOrgDateTime
        $orderDate    = Get-SafeDate $Device.orderDateTime
        $updatedDate  = Get-SafeDate $Device.updatedDateTime
        $releasedDate = Get-SafeDate $Device.releasedFromOrgDateTime

        if ($addedDate)                 { $attrs += @{ objectTypeAttributeId = "$($DA.AbmAddedDate)";    objectAttributeValues = @(@{ value = $addedDate }) } }
        if ($Device.orderNumber)        { $attrs += @{ objectTypeAttributeId = "$($DA.AbmOrderNumber)";  objectAttributeValues = @(@{ value = "$($Device.orderNumber)" }) } }
        if ($orderDate)                 { $attrs += @{ objectTypeAttributeId = "$($DA.AbmOrderDate)";    objectAttributeValues = @(@{ value = $orderDate }) } }
        if ($Device.purchaseSourceType) { $attrs += @{ objectTypeAttributeId = "$($DA.AbmPurchaseSource)"; objectAttributeValues = @(@{ value = "$($Device.purchaseSourceType)" }) } }
        if ($Device.deviceModel)        { $attrs += @{ objectTypeAttributeId = "$($DA.AbmDeviceModel)";  objectAttributeValues = @(@{ value = "$($Device.deviceModel)" }) } }
        if ($Device.productType)        { $attrs += @{ objectTypeAttributeId = "$($DA.AbmProductType)";  objectAttributeValues = @(@{ value = "$($Device.productType)" }) } }
        if ($updatedDate)               { $attrs += @{ objectTypeAttributeId = "$($DA.AbmUpdatedDate)";  objectAttributeValues = @(@{ value = $updatedDate }) } }
        if ($releasedDate)              { $attrs += @{ objectTypeAttributeId = "$($DA.AbmReleasedDate)"; objectAttributeValues = @(@{ value = $releasedDate }) } }

        return @{ objectTypeId = $TypeId; attributes = $attrs } | ConvertTo-Json -Depth 10
    }
}

# 7. Pre-cache JSM devices
Write-Host "`nPre-caching JSM devices..."
$JsmDeviceCache = @{}
$page = 1

do {
    $r = Invoke-JsmAqlPage "objectTypeId in (15, 56, 55, 16, 58, 59, 60)" $page $AssetsBase $JiraHeaders
    if ($page -eq 1) { Write-Host "  Total JSM devices: $($r.total)" }
    foreach ($obj in $r.values) {
        $snAttr = $obj.attributes | Where-Object { $_.objectTypeAttributeId -eq "133" }
        if ($snAttr -and $snAttr.objectAttributeValues.Count -gt 0) {
            $sn = $snAttr.objectAttributeValues[0].value
            if ($sn) { $JsmDeviceCache[$sn] = $obj }
        }
    }
    Write-Host "  Cached $($JsmDeviceCache.Count) / $($r.total)..."
    $page++
} while ($JsmDeviceCache.Count -lt $r.total)
Write-Host "✓ Devices cached: $($JsmDeviceCache.Count)"

# 8. Load last sync timestamp
$deltaVarName = "ABM-LastSyncTimestamp"
$lastSyncTime = $null

try {
    $deltaVar = Get-AzAutomationVariable `
        -AutomationAccountName "Intune-Automation" `
        -ResourceGroupName "Intune" `
        -Name $deltaVarName -ErrorAction Stop
    if ($deltaVar.Value) {
        $lastSyncTime = [datetime]::Parse($deltaVar.Value)
        Write-Host "✓ Last sync: $lastSyncTime — delta mode active"
    }
} catch {
    Write-Host "No previous sync timestamp — running full sync"
}

if ($ForceFullSync) {
    $lastSyncTime = $null
    Write-Host "⚠ ForceFullSync=true — full sync forced"
}

# 9. Fetch ABM devices
Write-Host "`nFetching devices from ABM..."
$AllDevices = @()
$nextUri    = "https://api-business.apple.com/v1/orgDevices"

do {
    Invoke-TokenRefreshIfNeeded $TokenObtained $AbmKeyId $AbmClientId $AbmPrivateKey $JiraEmail $JiraToken
    $maxRetries = 3; $retryCount = 0; $pageSuccess = $false

    while (-not $pageSuccess) {
        try {
            $response    = Invoke-RestMethod -Method Get -Uri $nextUri -Headers $AbmHeaders
            $AllDevices += $response.data
            $nextUri     = if ($response.links.next -and $response.links.next -ne "") { $response.links.next } else { $null }
            Write-Host "  Fetched $($AllDevices.Count) devices..."
            $pageSuccess = $true
        } catch {
            $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($statusCode -eq 429 -and $retryCount -lt $maxRetries) {
                $retryCount++
                Write-Host "  429 rate limit — waiting 60s (retry $retryCount/$maxRetries)..."
                Start-Sleep -Seconds 60
            } else {
                Write-Host "  ERROR fetching ABM: $($_.Exception.Message)"
                $nextUri = $null; $pageSuccess = $true
            }
        }
    }
} while ($nextUri)

Write-Host "✓ Total ABM devices fetched: $($AllDevices.Count)"

# Filter by purchase date — only devices since 1 January 2024
$cutoffDate   = [datetime]"2024-01-01"
$beforeFilter = $AllDevices.Count
$AllDevices   = $AllDevices | Where-Object {
    $_.attributes.orderDateTime -and ([datetime]$_.attributes.orderDateTime) -ge $cutoffDate
}
Write-Host "✓ Date filter: $($AllDevices.Count) devices since Jan 2024 (removed $($beforeFilter - $AllDevices.Count) older devices)"

# Test mode limit
if ($TestLimit -gt 0) {
    $AllDevices = $AllDevices | Select-Object -First $TestLimit
    Write-Host "⚠ TEST MODE — processing first $TestLimit devices only"
}

total = $AllDevices.Count
Write-Host "✓ Processing $total devices"

# 10. Main sync loop
$devCreated = 0; $devUpdated = 0; $devSkipped = 0; $devErrors = 0
$noSerial   = 0; $counter   = 0

foreach ($device in $AllDevices) {

    $counter++
    $pct   = [math]::Round($counter / [math]::Max($total, 1) * 100)
    $attrs = $device.attributes

    Invoke-TokenRefreshIfNeeded $TokenObtained $AbmKeyId $AbmClientId $AbmPrivateKey $JiraEmail $JiraToken

    if (-not $attrs.serialNumber) {
        Write-Host "[$counter/$total $pct%] SKIP — no serial number"
        $noSerial++
        continue
    }

    # Delta skip — unchanged since last sync
    if ($lastSyncTime -and $attrs.updatedDateTime) {
        try {
            if ([datetime]$attrs.updatedDateTime -lt $lastSyncTime) {
                Write-Host "[$counter/$total $pct%] SKIP (unchanged) — $($attrs.serialNumber)"
                $devSkipped++
                continue
            }
        } catch {}
    }

    # Check cache first
    $existingDevice = $JsmDeviceCache[$attrs.serialNumber]

    # Fallback AQL if not in cache
    if (-not $existingDevice) {
        Write-Host "[$counter/$total $pct%] Cache miss — querying JSM for $($attrs.serialNumber)..."
        $findBody = @{ qlQuery = "`"Serial Number`" = `"$($attrs.serialNumber)`""; page = 1; resultsPerPage = 1 } | ConvertTo-Json
        try {
            $found = Invoke-RestMethod -Method Post -Uri "$AssetsBase/object/aql" -Headers $JiraHeaders -Body $findBody
            if ($found.total -gt 0) {
                $existingDevice = $found.values[0]
                $JsmDeviceCache[$attrs.serialNumber] = $existingDevice
            }
        } catch {}
    }

    $ObjectTypeId = Get-ObjectTypeId $attrs.productFamily

    try {
        if ($existingDevice) {
            # EXISTS — update ABM attributes only, never touch Asset Status
            Write-Host "[$counter/$total $pct%] UPDATE — $($attrs.serialNumber) ($($attrs.deviceModel))"
            $body = Build-AbmDevicePayload $attrs $DA $ObjectTypeId $true
            if ($body) {
                Invoke-RestMethod -Method Put -Uri "$AssetsBase/object/$($existingDevice.id)" -Headers $JiraHeaders -Body $body | Out-Null
                Write-Host "  ✓ UPDATED — ABM attributes written"
                $devUpdated++
            } else {
                Write-Host "  SKIP — no ABM attributes to update"
                $devSkipped++
            }
        } else {
            # NEW — create with IN STOCK
            Write-Host "[$counter/$total $pct%] CREATE — $($attrs.serialNumber) ($($attrs.deviceModel)) → IN STOCK"
            $body   = Build-AbmDevicePayload $attrs $DA $ObjectTypeId $false
            $newDev = Invoke-RestMethod -Method Post -Uri "$AssetsBase/object/create" -Headers $JiraHeaders -Body $body
            $JsmDeviceCache[$attrs.serialNumber] = $newDev
            Write-Host "  ✓ CREATED — IN STOCK"
            $devCreated++
        }
    } catch {
        Write-Host "  ERROR — $($attrs.serialNumber): $($_.Exception.Message)"
        $devErrors++
    }

    Start-Sleep -Milliseconds 200
}

# 11. Save delta timestamp
$newTimestamp = (Get-Date).ToString("o")
try {
    Set-AzAutomationVariable `
        -AutomationAccountName "Intune-Automation" -ResourceGroupName "Intune" `
        -Name $deltaVarName -Value $newTimestamp -Encrypted $false -ErrorAction Stop
    Write-Host "✓ Timestamp saved — next run will use delta mode"
} catch {
    try {
        New-AzAutomationVariable `
            -AutomationAccountName "Intune-Automation" -ResourceGroupName "Intune" `
            -Name $deltaVarName -Value $newTimestamp -Encrypted $false
        Write-Host "✓ Timestamp created"
    } catch {
        Write-Host "WARN — could not save timestamp: $($_.Exception.Message)"
    }
}

# 12. Summary
$elapsed = [math]::Round((New-TimeSpan -Start $TokenObtained -End (Get-Date)).TotalMinutes, 1)
Write-Host "`n══ SUMMARY ══════════════════════════════════"
Write-Host "  Devices — Created: $devCreated  Updated: $devUpdated  Skipped: $devSkipped  Errors: $devErrors"
Write-Host "  No serial        : $noSerial"
Write-Host "  Total processed  : $counter / $total"
Write-Host "  Run time         : $elapsed minutes"
Write-Host "══════════════════════════════════════════════"
