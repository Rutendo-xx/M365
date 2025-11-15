<#  
.SYNOPSIS
    Sync devices into a target Entra ID device group based on the users from a source user group.

.DESCRIPTION
    This script:
    • Connects to Microsoft Graph with device, directory, and group permissions  
    • Retrieves all users from a specified "Source User Group"  
    • Finds each user's Intune-managed devices  
    • Falls back to Azure AD registered devices if Intune records do not exist  
    • Adds each discovered device into a specified "Target Device Group"  
    • Skips devices already in the target group  

.NOTES
    Author: Rutendo Mazvi  
    Purpose: M365 Tenant Management  
#>

# ============================================
# =============== PARAMETERS =================
# ============================================

# Entra ID group containing the USERS whose devices you want to sync.
$SourceUserGroupId = "<ENTER-SOURCE-USER-GROUP-ID-HERE>"

# Entra ID group where DISCOVERED devices should be added.
$TargetDeviceGroupId = "<ENTER-TARGET-DEVICE-GROUP-ID-HERE>"

# ============================================
# =========== CONNECT TO MICROSOFT GRAPH =====
# ============================================

Connect-MgGraph -Scopes `
    "DeviceManagementManagedDevices.Read.All", `
    "Directory.Read.All", `
    "Group.ReadWrite.All", `
    "GroupMember.Read.All"

# ============================================
# ============= GET SOURCE USERS =============
# ============================================

Write-Host "Fetching users from Source User Group..." -ForegroundColor Cyan
$groupMembers = Get-MgGroupMember -GroupId $SourceUserGroupId -All
$userIds = $groupMembers | Select-Object -ExpandProperty Id

if (-not $userIds) {
    Write-Error "No users were found in the Source User Group."
    return
}

Write-Host "Found $($userIds.Count) user(s)." -ForegroundColor Green

# ============================================
# =========== INTUNE DEVICE LOOKUP ===========
# ============================================

Write-Host "Retrieving Intune managed devices..." -ForegroundColor Cyan
$intuneDevices = Get-MgDeviceManagementManagedDevice -All

# ============================================
# ========== PROCESS EACH USER ===============
# ============================================

foreach ($userId in $userIds) {

    Write-Host "`nProcessing user: $userId" -ForegroundColor Yellow
    $matchedDevices = @()

    # Primary match using Intune managed devices
    $matchedDevices += $intuneDevices | Where-Object { $_.UserId -eq $userId }

    # Fallback — Azure AD registered devices 
    if ($matchedDevices.Count -eq 0) {
        try {
            $registeredDevices = Get-MgUserRegisteredDevice -UserId $userId -All |
                Where-Object { $_.ODataType -eq "#microsoft.graph.device" }

            if ($registeredDevices) {
                Write-Host "Fallback found $($registeredDevices.Count) registered device(s)."
                $matchedDevices += $registeredDevices
            }
        }
        catch {
            Write-Warning "Could not load registered devices for user $userId"
        }
    }

    if ($matchedDevices.Count -eq 0) {
        Write-Host "No devices found for user $userId." -ForegroundColor DarkGray
        continue
    }

    # ============================================
    # ============ PROCESS MATCHED DEVICES =======
    # ============================================

    foreach ($device in $matchedDevices) {

        $deviceId = $device.AzureADDeviceId ?? $device.Id
        if (-not $deviceId) {
            Write-Warning "Device '$($device.DeviceName)' has no valid device object ID. Skipping."
            continue
        }

        # Lookup Entra device object
        try {
            $aadDevice = Get-MgDevice -Filter "deviceId eq '$deviceId'" -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not find AAD device object for device ID: $deviceId"
            continue
        }

        # Check membership
        $isMember = Get-MgGroupMember -GroupId $TargetDeviceGroupId -All |
            Where-Object { $_.Id -eq $aadDevice.Id }

        if ($isMember) {
            Write-Host "Device already in target group: $($device.DeviceName)" -ForegroundColor Gray
            continue
        }

        # Add to group
        try {
            $refUri = "https://graph.microsoft.com/v1.0/directoryObjects/$($aadDevice.Id)"
            New-MgGroupMemberByRef -GroupId $TargetDeviceGroupId -OdataId $refUri

            Write-Host "Added device: $($device.DeviceName)" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to add device: $_"
        }
    }
}
