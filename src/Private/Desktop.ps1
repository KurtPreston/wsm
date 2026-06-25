Set-StrictMode -Version Latest

# Thin wrappers over the MScholtes VirtualDesktop module
# (https://github.com/MScholtes/PSVirtualDesktop). Desktops are addressed by
# NAME, not index, so they survive reshuffles when desktops are added/removed.

function Assert-RcdVirtualDesktop {
    if (Get-Module -Name VirtualDesktop) { return }
    if (-not (Get-Module -ListAvailable -Name VirtualDesktop)) {
        throw "The 'VirtualDesktop' module is not installed. Run: Install-Module VirtualDesktop -Scope CurrentUser"
    }
    Import-Module VirtualDesktop -ErrorAction Stop -DisableNameChecking
    Write-RcdDebug "Imported VirtualDesktop module."
}

# Returns the desktop object for a given name, or $null if none exists.
function Get-RcdDesktopByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-RcdVirtualDesktop

    $count = Get-DesktopCount
    for ($i = 0; $i -lt $count; $i++) {
        $d = Get-Desktop -Index $i
        if ((Get-DesktopName -Desktop $d) -eq $Name) { return $d }
    }
    return $null
}

# Find-or-create a desktop with the given name. Returns the desktop object.
function Get-RcdOrNewDesktop {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-RcdVirtualDesktop

    $existing = Get-RcdDesktopByName -Name $Name
    if ($existing) {
        Write-RcdInfo "Reusing virtual desktop '$Name'."
        return $existing
    }

    Write-RcdInfo "Creating virtual desktop '$Name'."
    $d = New-Desktop
    Set-DesktopName -Desktop $d -Name $Name | Out-Null
    return $d
}

function Move-RcdWindowToDesktop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Desktop,
        [Parameter(Mandatory)][IntPtr]$Hwnd
    )
    Assert-RcdVirtualDesktop
    Move-Window -Desktop $Desktop -Hwnd $Hwnd | Out-Null
    Write-RcdDebug "Moved window $Hwnd to desktop."
}

function Switch-RcdDesktop {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Desktop)
    Assert-RcdVirtualDesktop
    Switch-Desktop -Desktop $Desktop | Out-Null
}

# Returns the name of the desktop hosting a given window, or $null.
function Get-RcdDesktopNameForWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    Assert-RcdVirtualDesktop
    try {
        $d = Get-DesktopFromWindow -Hwnd $Hwnd
        if ($d) { return Get-DesktopName -Desktop $d }
    }
    catch {
        Write-RcdDebug "Get-DesktopFromWindow failed for $Hwnd : $($_.Exception.Message)"
    }
    return $null
}

function Remove-RcdDesktopByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-RcdVirtualDesktop
    $d = Get-RcdDesktopByName -Name $Name
    if ($d) {
        Remove-Desktop -Desktop $d | Out-Null
        Write-RcdInfo "Removed virtual desktop '$Name'."
    }
}
