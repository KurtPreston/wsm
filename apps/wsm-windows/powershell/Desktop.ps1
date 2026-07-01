Set-StrictMode -Version Latest

# Thin wrappers over the MScholtes VirtualDesktop module
# (https://github.com/MScholtes/PSVirtualDesktop). Desktops are addressed by
# NAME, not index, so they survive reshuffles when desktops are added/removed.
# Windows backend only.

function Assert-DocentVirtualDesktop {
    if (Get-Module -Name VirtualDesktop) { return }
    if (-not (Get-Module -ListAvailable -Name VirtualDesktop)) {
        throw "The 'VirtualDesktop' module is not installed. Run: Install-Module VirtualDesktop -Scope CurrentUser"
    }
    Import-Module VirtualDesktop -ErrorAction Stop -DisableNameChecking
    Write-DocentDebug "Imported VirtualDesktop module."
}

# Returns the desktop object for a given name, or $null if none exists.
function Get-DocentDesktopByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-DocentVirtualDesktop

    $count = Get-DesktopCount
    for ($i = 0; $i -lt $count; $i++) {
        $d = Get-Desktop -Index $i
        if ((Get-DesktopName -Desktop $d) -eq $Name) { return $d }
    }
    return $null
}

# Find-or-create a desktop with the given name. Returns the desktop object.
function Get-DocentOrNewDesktop {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-DocentVirtualDesktop

    $existing = Get-DocentDesktopByName -Name $Name
    if ($existing) {
        Write-DocentInfo "Reusing virtual desktop '$Name'."
        return $existing
    }

    Write-DocentInfo "Creating virtual desktop '$Name'."
    $d = New-Desktop
    Set-DesktopName -Desktop $d -Name $Name | Out-Null
    return $d
}

function Move-DocentWindowToDesktop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Desktop,
        [Parameter(Mandatory)][IntPtr]$Hwnd
    )
    Assert-DocentVirtualDesktop
    Move-Window -Desktop $Desktop -Hwnd $Hwnd | Out-Null
    Write-DocentDebug "Moved window $Hwnd to desktop."
}

function Switch-DocentDesktop {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Desktop)
    Assert-DocentVirtualDesktop
    Switch-Desktop -Desktop $Desktop | Out-Null
}

# Returns the name of the desktop hosting a given window, or $null.
function Get-DocentDesktopNameForWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    Assert-DocentVirtualDesktop
    try {
        $d = Get-DesktopFromWindow -Hwnd $Hwnd
        if ($d) { return Get-DesktopName -Desktop $d }
    }
    catch {
        Write-DocentDebug "Get-DesktopFromWindow failed for $Hwnd : $($_.Exception.Message)"
    }
    return $null
}

function Remove-DocentDesktopByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-DocentVirtualDesktop
    $d = Get-DocentDesktopByName -Name $Name
    if ($d) {
        Remove-Desktop -Desktop $d | Out-Null
        Write-DocentInfo "Removed virtual desktop '$Name'."
    }
}
