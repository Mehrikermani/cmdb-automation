# ─────────────────────────────────────────────────────
# RUNBOOK: Daily-Full-Sync
# Intune + Entra ID → Jira Assets
# Optimized: pre-caching + smart skip
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
        $setCtx = Set-AzContext -SubscriptionId "514d4dd4-bf2a-421d-83d6-e06c1f04724a" -ErrorAction Stop
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

# 2. Token functions
function Get-GraphToken($tenantId, $clientId, $clientSecret) {
    $body = @{
        client_id     = $clientId
        scope         = "https://graph.microsoft.com/.default"
        client_secret = $clientSecret
        grant_type    = "client_credentials"
    }
    $r = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Body $body
    return $r.access_token
}

function Get-JiraHeaders($email, $token) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${email}:${token}"))
    return @{
        Authorization  = "Basic $b64"
        Accept         = "application/json"
        "Content-Type" = "application/json"
    }
}

function Invoke-TokenRefreshIfNeeded($tokenTime, $tenantId, $clientId, $clientSecret, $email, $token) {
    $age = (New-TimeSpan -Start $tokenTime -End (Get-Date)).TotalMinutes
    if ($age -gt 50) {
        Write-Output "  ♻ Refreshing tokens (age: $([math]::Round($age,1)) min)..."
        $newToken             = Get-GraphToken $tenantId $clientId $clientSecret
        $script:GraphHeaders  = @{ Authorization = "Bearer $newToken" }
        $script:JiraHeaders   = Get-JiraHeaders $email $token
        $script:TokenObtained = Get-Date
        Write-Output "  ✓ Tokens refreshed"
    }
}

# 3. Initial authentication
$GraphToken    = Get-GraphToken $TenantId $ClientId $ClientSecret
$GraphHeaders  = @{ Authorization = "Bearer $GraphToken" }
$TokenObtained = Get-Date
Write-Output "✓ Graph authenticated"

$JiraHeaders = Get-JiraHeaders $JiraEmail $JiraToken
$AssetsBase  = "https://api.atlassian.com/jsm/assets/workspace/$WorkspaceId/v1"
Write-Output "✓ Jira headers built"

# 4. Reference maps
$LocationMap = @{
    "DEU"="405";"DE"="405";"FRA"="422";"ESP"="417";"GBR"="410"
    "NLD"="416";"IRL"="419";"ITA"="421";"POL"="411";"DNK"="418"
    "BGR"="407";"UKR"="420";"LTU"="424";"PRT"="1283"
    "BRA"="408";"BR"="408";"USA"="406";"CHL"="409"
    "ARG"="1267";"AUS"="1268";"AUT"="1269";"BEL"="1270";"BLR"="1271"
    "CAN"="1272";"COL"="1274";"FIN"="1275";"HRV"="1276";"IND"="1277"
    "ISR"="1278";"LUX"="1279";"MDA"="1280";"MEX"="1281";"PER"="1282"
    "CHE"="0";"SRB"="0"
    "Brasil"="408";"Brazil"="408";"Bulgaria"="407";"Chile"="409"
    "Poland"="411";"Portugal"="1283";"Spain"="417";"Peru"="1282"
    "Germany"="405";"France"="422";"Ireland"="419";"Italy"="421"
    "Denmark"="418";"Ukraine"="420";"Lithuania"="424";"Colombia"="1274"
    "India"="1277";"Canada"="1272";"Mexico"="1281";"Belgium"="1270"
    "Finland"="1275";"Croatia"="1276";"Moldova"="1280";"Israel"="1278"
}

$CityAliases = @{
    "Köln"="Cologne";"Koeln"="Cologne";"København"="Copenhagen"
    "São Paulo"="Sao Paulo";"Sao Paulo"="Sao Paulo"
    "São Jose dos Campos"="São Jose dos Campos"
    "Sao Jose dos Campos"="São Jose dos Campos"
    "Remote"="Remote";"remote"="Remote"
    "Home Office"="Remote";"home office"="Remote";"Anywhere"="Remote"
    "El Paso"="El-Paso";"El-Paso"="El-Paso"
    "N/A"=$null;"n/a"=$null;"-"=$null;"Vermont"=$null
}

$AssetStatusMap = @{
    "DISPOSED"="15";"IN STOCK"="14";"IN USE"="13";"ORDERED"="12"
    "RETIRED"="11";"MISSING"="10";"IN TRANSIT"="9";"PENDING RETURN"="83"
}

# 5. Attribute IDs
$DA = @{
    Name              = 131; SerialNumber      = 133
    IntuneDeviceId    = 534; Manufacturer      = 535
    Platform          = 538; OsVersion         = 146
    ComplianceStatus  = 536; PrimaryUser       = 586
    LastScanDate      = 141; EncryptionEnabled = 549
    Location          = 584; DataSource        = 551
    AssetStatus       = 145
}

$EA = @{
    Name          = 542; EntraObjectId = 543
    UPN           = 544; Department    = 545
    JobTitle      = 622; AccountStatus = 547
    Location      = 548; City          = 585
}

# 6. Helpers
function Get-ObjectTypeId($os) {
    if ($os -like "*Mac*")                        { return "56" }
    if ($os -like "*Windows*")                    { return "55" }
    if ($os -like "*iOS*" -or $os -like "*iPad*") { return "16" }
    return "15"
}

function Get-Platform($os) {
    if ($os -like "*Mac*")                        { return "macOS" }
    if ($os -like "*Windows*")                    { return "Windows" }
    if ($os -like "*iOS*" -or $os -like "*iPad*") { return "iOS" }
    return $os
}

function Get-DeviceStatus($existingDevice) {
    $status = @{
        HasPrimaryUser    = $false
        HasLocation       = $false
        HasOsVersion      = $false
        CurrentCompliance = $null
        CurrentOwnerId    = $null
    }
    foreach ($attr in $existingDevice.attributes) {
        switch ($attr.objectTypeAttributeId) {
            "586" {
                if ($attr.objectAttributeValues.Count -gt 0) {
                    $v = $attr.objectAttributeValues[0]
                    if ($v.referencedObject -and $v.referencedObject.id) {
                        $status.HasPrimaryUser = $true
                        $status.CurrentOwnerId = $v.referencedObject.id
                    }
                }
            }
            "584" {
                if ($attr.objectAttributeValues.Count -gt 0) {
                    $v = $attr.objectAttributeValues[0]
                    if ($v.referencedObject -and $v.referencedObject.id) {
                        $status.HasLocation = $true
                    }
                }
            }
            "146" {
                if ($attr.objectAttributeValues.Count -gt 0 -and $attr.objectAttributeValues[0].value) {
                    $status.HasOsVersion = $true
                }
            }
            "536" {
                if ($attr.objectAttributeValues.Count -gt 0 -and $attr.objectAttributeValues[0].value) {
                    $status.CurrentCompliance = $attr.objectAttributeValues[0].value
                }
            }
        }
    }
    return $status
}

function Invoke-JsmAqlPage($aql, $page, $base, $headers) {
    $body = @{ qlQuery = $aql; page = $page; resultsPerPage = 25 } | ConvertTo-Json
    return Invoke-RestMethod -Method Post -Uri "$base/object/aql" -Headers $headers -Body $body
}

function Build-DevicePayload($device, $da, $typeId, $locationId, $employeeId, $isUpdate, $assetStatus) {
    $attrs = @(
        @{ objectTypeAttributeId = "$($da.Name)";              objectAttributeValues = @(@{ value = "$($device.deviceName)" }) }
        @{ objectTypeAttributeId = "$($da.IntuneDeviceId)";    objectAttributeValues = @(@{ value = "$($device.id)" }) }
        @{ objectTypeAttributeId = "$($da.Platform)";          objectAttributeValues = @(@{ value = (Get-Platform $device.operatingSystem) }) }
        @{ objectTypeAttributeId = "$($da.OsVersion)";         objectAttributeValues = @(@{ value = "$($device.osVersion)" }) }
        @{ objectTypeAttributeId = "$($da.ComplianceStatus)";  objectAttributeValues = @(@{ value = "$($device.complianceState)" }) }
        @{ objectTypeAttributeId = "$($da.EncryptionEnabled)"; objectAttributeValues = @(@{ value = if ($device.isEncrypted) { "Yes" } else { "No" } }) }
        @{ objectTypeAttributeId = "$($da.DataSource)";        objectAttributeValues = @(@{ value = "Intune Auto" }) }
        @{ objectTypeAttributeId = "$($da.AssetStatus)";       objectAttributeValues = @(@{ value = $assetStatus }) }
    )
    if (-not $isUpdate) {
        $attrs += @{ objectTypeAttributeId = "$($da.SerialNumber)"; objectAttributeValues = @(@{ value = "$($device.serialNumber)" }) }
    }
    if ($device.manufacturer) {
        $attrs += @{ objectTypeAttributeId = "$($da.Manufacturer)"; objectAttributeValues = @(@{ value = "$($device.manufacturer)" }) }
    }
    if ($device.lastSyncDateTime) {
        $attrs += @{ objectTypeAttributeId = "$($da.LastScanDate)"; objectAttributeValues = @(@{ value = $device.lastSyncDateTime.ToString("yyyy-MM-dd") }) }
    }
    if ($locationId) {
        $attrs += @{ objectTypeAttributeId = "$($da.Location)"; objectAttributeValues = @(@{ value = "$locationId" }) }
    }
    if ($employeeId) {
        $attrs += @{ objectTypeAttributeId = "$($da.PrimaryUser)"; objectAttributeValues = @(@{ value = "$employeeId" }) }
    }
    return @{ objectTypeId = $typeId; attributes = $attrs } | ConvertTo-Json -Depth 10
}

function Build-EmployeePayload($user, $upn, $ea, $locationId, $cityId, $deptId, $roleId, $isUpdate) {
    $attrs = @(
        @{ objectTypeAttributeId = "$($ea.Name)";          objectAttributeValues = @(@{ value = "$($user.displayName)" }) }
        @{ objectTypeAttributeId = "$($ea.UPN)";           objectAttributeValues = @(@{ value = "$upn" }) }
        @{ objectTypeAttributeId = "$($ea.AccountStatus)"; objectAttributeValues = @(@{ value = if ($user.accountEnabled) { "Active" } else { "Disabled" } }) }
    )
    if ($user.id) {
        $attrs += @{ objectTypeAttributeId = "$($ea.EntraObjectId)"; objectAttributeValues = @(@{ value = "$($user.id)" }) }
    }
    if ($deptId) {
        $attrs += @{ objectTypeAttributeId = "$($ea.Department)"; objectAttributeValues = @(@{ value = "$deptId" }) }
    }
    if ($roleId) {
        $attrs += @{ objectTypeAttributeId = "$($ea.JobTitle)"; objectAttributeValues = @(@{ value = "$roleId" }) }
    }
    if ($locationId) {
        $attrs += @{ objectTypeAttributeId = "$($ea.Location)"; objectAttributeValues = @(@{ value = "$locationId" }) }
    }
    if ($cityId) {
        $attrs += @{ objectTypeAttributeId = "$($ea.City)"; objectAttributeValues = @(@{ value = "$cityId" }) }
    }
    return @{ objectTypeId = "141"; attributes = $attrs } | ConvertTo-Json -Depth 10
}

# 7. Pre-cache JSM objects
Write-Output "`nPre-caching JSM objects..."

$JsmDeviceCache = @{}
$page = 1
do {
    $r = Invoke-JsmAqlPage "objectTypeId in (15, 56, 55, 16, 58, 59, 60)" $page $AssetsBase $JiraHeaders
    if ($page -eq 1) { Write-Output "  Total JSM devices: $($r.total)" }
    foreach ($obj in $r.values) {
        $snAttr = $obj.attributes | Where-Object { $_.objectTypeAttributeId -eq "133" }
        if ($snAttr -and $snAttr.objectAttributeValues.Count -gt 0) {
            $sn = $snAttr.objectAttributeValues[0].value
            if ($sn) { $JsmDeviceCache[$sn] = $obj }
        }
    }
    Write-Output "  Cached $($JsmDeviceCache.Count) / $($r.total)..."
    $page++
} while ($JsmDeviceCache.Count -lt $r.total)
Write-Output "✓ Devices cached: $($JsmDeviceCache.Count)"

$JsmEmployeeCache = @{}
$page = 1
do {
    $r = Invoke-JsmAqlPage "objectTypeId = 141" $page $AssetsBase $JiraHeaders
    foreach ($obj in $r.values) {
        $upnAttr = $obj.attributes | Where-Object { $_.objectTypeAttributeId -eq "544" }
        if ($upnAttr -and $upnAttr.objectAttributeValues.Count -gt 0) {
            $upn = $upnAttr.objectAttributeValues[0].value
            if ($upn) { $JsmEmployeeCache[$upn] = $obj }
        }
    }
    $page++
} while ($JsmEmployeeCache.Count -lt $r.total)
Write-Output "✓ Employees cached: $($JsmEmployeeCache.Count)"

$DeptCache = @{}; $page = 1; $deptCount = 0
do {
    $r = Invoke-JsmAqlPage "objectTypeId = 102" $page $AssetsBase $JiraHeaders
    foreach ($obj in $r.values) { $DeptCache[$obj.name] = $obj.id; $deptCount++ }
    $page++
} while ($deptCount -lt $r.total)
Write-Output "✓ Departments cached: $($DeptCache.Count)"

$RoleCache = @{}; $page = 1; $roleCount = 0
do {
    $r = Invoke-JsmAqlPage "objectTypeId = 103" $page $AssetsBase $JiraHeaders
    foreach ($obj in $r.values) { $RoleCache[$obj.name] = $obj.id; $roleCount++ }
    $page++
} while ($roleCount -lt $r.total)
Write-Output "✓ Roles cached: $($RoleCache.Count)"

$CityCache = @{}; $page = 1; $cityCount = 0
do {
    $r = Invoke-JsmAqlPage "objectTypeId = 61" $page $AssetsBase $JiraHeaders
    foreach ($obj in $r.values) { $CityCache[$obj.name] = $obj.id; $cityCount++ }
    $page++
} while ($cityCount -lt $r.total)
Write-Output "✓ Cities cached: $($CityCache.Count)"

# 8. Fetch all devices from Intune
Write-Output "`nFetching all devices from Intune..."
$AllDevices = @()
$Fields  = "id,serialNumber,deviceName,operatingSystem,osVersion"
$Fields += ",manufacturer,complianceState,isEncrypted,userPrincipalName,lastSyncDateTime"
$url = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$top=999&`$select=$Fields"

while ($url) {
    Invoke-TokenRefreshIfNeeded $TokenObtained $TenantId $ClientId $ClientSecret $JiraEmail $JiraToken
    $r           = Invoke-RestMethod -Method Get -Uri $url -Headers $GraphHeaders
    $AllDevices += $r.value
    $url         = $r.'@odata.nextLink'
    Write-Output "  Fetched $($AllDevices.Count) devices..."
}

$total = $AllDevices.Count
Write-Output "✓ Total: $total devices`n"

# 9. Counters
$devCreated = 0; $devUpdated = 0; $devSkipped = 0; $devErrors  = 0
$empCreated = 0; $empUpdated = 0; $empErrors  = 0
$userFailed = 0; $noSerial   = 0; $counter    = 0

# 10. Main loop
foreach ($device in $AllDevices) {

    $counter++
    $pct = [math]::Round($counter / $total * 100)

    Invoke-TokenRefreshIfNeeded $TokenObtained $TenantId $ClientId $ClientSecret $JiraEmail $JiraToken

    if (-not $device.serialNumber) { $noSerial++; continue }

    $existingDevice = $JsmDeviceCache[$device.serialNumber]

    # Fetch user from Entra ID
    $locationId = $null; $cityId = $null; $deptId = $null
    $roleId     = $null; $user   = $null; $userFetchFailed = $false

    if ($device.userPrincipalName) {
        try {
            $user = Invoke-RestMethod `
                -Method Get `
                -Uri "https://graph.microsoft.com/v1.0/users/$($device.userPrincipalName)?`$select=id,displayName,department,jobTitle,country,city,accountEnabled" `
                -Headers $GraphHeaders

            $locationId = $LocationMap[$user.country]
            $cityLookup = if ($CityAliases.ContainsKey($user.city)) { $CityAliases[$user.city] } else { $user.city }
            $cityId     = if ($cityLookup) { $CityCache[$cityLookup] } else { $null }
            $deptId     = $DeptCache[$user.department]
            $roleId     = $RoleCache[$user.jobTitle]

            if (-not $locationId) { Write-Output "  WARN — no Location for: '$($user.country)'" }
            if (-not $cityId)     { Write-Output "  WARN — no City for: '$($user.city)'" }
        } catch {
            $errMsg = if ($_.ErrorDetails.Message) {
                try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $_.ErrorDetails.Message }
            } else { $_.Exception.Message }
            Write-Output "  WARN — user fetch failed '$($device.userPrincipalName)': $errMsg"
            $userFetchFailed = $true
            $userFailed++
        }
    }

    # Smart skip decision
    if ($existingDevice) {
        $jsm        = Get-DeviceStatus $existingDevice
        $shouldSkip = $false

        if (-not $device.userPrincipalName) {
            $shouldSkip = ($jsm.HasLocation -and $jsm.HasOsVersion -and $jsm.CurrentCompliance -eq $device.complianceState)
        } elseif ($userFetchFailed) {
            $shouldSkip = $false
        } elseif ($user -and -not $user.accountEnabled) {
            $shouldSkip = $false
            Write-Output "[$counter/$total $pct%] UPDATE — $($device.serialNumber) DISABLED USER"
        } else {
            $cachedEmp          = $JsmEmployeeCache[$device.userPrincipalName]
            $resolvedEmployeeId = if ($cachedEmp) { $cachedEmp.id } else { $null }
            $ownerCorrect       = ($jsm.HasPrimaryUser -and $jsm.CurrentOwnerId -eq $resolvedEmployeeId)
            $complianceOk       = ($jsm.CurrentCompliance -eq $device.complianceState)
            $shouldSkip         = ($ownerCorrect -and $jsm.HasLocation -and $jsm.HasOsVersion -and $complianceOk)

            if (-not $shouldSkip) {
                $reasons = @(
                    if (-not $ownerCorrect)     { "Owner" }
                    if (-not $jsm.HasLocation)  { "Location" }
                    if (-not $jsm.HasOsVersion) { "OsVersion" }
                    if (-not $complianceOk)     { "Compliance" }
                ) -join ', '
                Write-Output "[$counter/$total $pct%] UPDATE — $($device.serialNumber) ($reasons)"
            }
        }

        if ($shouldSkip) {
            Write-Output "[$counter/$total $pct%] SKIP — $($device.serialNumber)"
            $devSkipped++
            continue
        }
    } else {
        Write-Output "[$counter/$total $pct%] NEW — $($device.serialNumber)"
    }

    # Sync Employee
    $employeeId = $null
    if ($user) {
        $existingEmp = $JsmEmployeeCache[$device.userPrincipalName]

        if (-not $existingEmp) {
            $checkBody = @{ qlQuery = "objectTypeId = 141 AND `"UPN`" = `"$($device.userPrincipalName)`""; page = 1; resultsPerPage = 1 } | ConvertTo-Json
            try {
                $checkResult = Invoke-RestMethod -Method Post -Uri "$AssetsBase/object/aql" -Headers $JiraHeaders -Body $checkBody
                if ($checkResult.total -gt 0) {
                    $existingEmp = $checkResult.values[0]
                    $JsmEmployeeCache[$device.userPrincipalName] = $existingEmp
                }
            } catch {}
        }

        try {
            if ($existingEmp) {
                $empBody    = Build-EmployeePayload $user $device.userPrincipalName $EA $locationId $cityId $deptId $roleId $true
                Invoke-RestMethod -Method Put -Uri "$AssetsBase/object/$($existingEmp.id)" -Headers $JiraHeaders -Body $empBody | Out-Null
                $employeeId = $existingEmp.id
                $empUpdated++
            } else {
                $empBody    = Build-EmployeePayload $user $device.userPrincipalName $EA $locationId $cityId $deptId $roleId $false
                $newEmp     = Invoke-RestMethod -Method Post -Uri "$AssetsBase/object/create" -Headers $JiraHeaders -Body $empBody
                $employeeId = $newEmp.id
                $JsmEmployeeCache[$device.userPrincipalName] = $newEmp
                Write-Output "  ✓ EMPLOYEE CREATED — $($user.displayName)"
                $empCreated++
            }
        } catch {
            Write-Output "  EMPLOYEE ERROR — $($_.ErrorDetails.Message)"
            $empErrors++
        }
    }

    # Asset Status
    $assetStatus = if ($user -and -not $user.accountEnabled) {
        $AssetStatusMap["PENDING RETURN"]
    } elseif ($employeeId) {
        $AssetStatusMap["IN USE"]
    } else {
        $AssetStatusMap["IN STOCK"]
    }

    # Sync Device
    $ObjectTypeId = Get-ObjectTypeId $device.operatingSystem

    try {
        if ($existingDevice) {
            $body = Build-DevicePayload $device $DA $ObjectTypeId $locationId $employeeId $true $assetStatus
            Invoke-RestMethod -Method Put -Uri "$AssetsBase/object/$($existingDevice.id)" -Headers $JiraHeaders -Body $body | Out-Null
            Write-Output "  ✓ UPDATED"
            $devUpdated++
        } else {
            $body    = Build-DevicePayload $device $DA $ObjectTypeId $locationId $employeeId $false $assetStatus
            $newDev  = Invoke-RestMethod -Method Post -Uri "$AssetsBase/object/create" -Headers $JiraHeaders -Body $body
            $JsmDeviceCache[$device.serialNumber] = $newDev
            Write-Output "  ✓ CREATED"
            $devCreated++
        }
    } catch {
        Write-Output "  DEVICE ERROR — $($_.ErrorDetails.Message)"
        $devErrors++
    }

    Start-Sleep -Milliseconds 200
}

# 11. Summary
$elapsed = [math]::Round((New-TimeSpan -Start $TokenObtained -End (Get-Date)).TotalMinutes, 1)
Write-Output "`n══ SUMMARY ══════════════════════════════════"
Write-Output "  Devices   — Created: $devCreated  Updated: $devUpdated  Skipped: $devSkipped  Errors: $devErrors"
Write-Output "  Employees — Created: $empCreated  Updated: $empUpdated  Errors: $empErrors"
Write-Output "  User fetch failed  : $userFailed"
Write-Output "  No serial number   : $noSerial"
Write-Output "  Total processed    : $counter / $total"
Write-Output "  Run time           : $elapsed minutes"
