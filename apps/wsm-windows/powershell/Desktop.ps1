Set-StrictMode -Version Latest

# Thin wrappers over the MScholtes VirtualDesktop module
# (https://github.com/MScholtes/PSVirtualDesktop). Desktops are addressed by
# NAME, not index, so they survive reshuffles when desktops are added/removed.
#
# wsm treats VirtualDesktop as a HARD requirement on Windows: Assert-
# WsmVirtualDesktop throws if it is missing rather than degrading silently, so
# a misconfigured box fails loudly at the first desktop operation instead of
# quietly never placing/switching windows.

function Assert-WsmVirtualDesktop {
    if (Get-Module -Name VirtualDesktop) { return }
    if (-not (Get-Module -ListAvailable -Name VirtualDesktop)) {
        throw "The 'VirtualDesktop' module is not installed. Run: Install-Module VirtualDesktop -Scope CurrentUser"
    }
    Import-Module VirtualDesktop -ErrorAction Stop -DisableNameChecking
    Write-WsmDebug "Imported VirtualDesktop module."
}

# Returns the desktop object for a given name, or $null if none exists.
function Get-WsmDesktopByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-WsmVirtualDesktop

    $count = Get-DesktopCount
    for ($i = 0; $i -lt $count; $i++) {
        $d = Get-Desktop -Index $i
        if ((Get-DesktopName -Desktop $d) -eq $Name) { return $d }
    }
    return $null
}

# Find-or-create a desktop with the given name. Returns the desktop object.
function Get-WsmOrNewDesktop {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-WsmVirtualDesktop

    $existing = Get-WsmDesktopByName -Name $Name
    if ($existing) {
        Write-WsmInfo "Reusing virtual desktop '$Name'."
        return $existing
    }

    Write-WsmInfo "Creating virtual desktop '$Name'."
    $d = New-Desktop
    Set-DesktopName -Desktop $d -Name $Name | Out-Null
    return $d
}

function Move-WsmWindowToDesktop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Desktop,
        [Parameter(Mandatory)][IntPtr]$Hwnd
    )
    Assert-WsmVirtualDesktop
    Move-Window -Desktop $Desktop -Hwnd $Hwnd | Out-Null
    Write-WsmDebug "Moved window $Hwnd to desktop."
}

function Switch-WsmDesktop {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Desktop)
    Assert-WsmVirtualDesktop
    Switch-Desktop -Desktop $Desktop | Out-Null
}

# Switch to the virtual desktop that currently hosts $Hwnd. Used as the focus
# fallback when no desktop is named after the workspace (e.g. the window was
# opened before wsm started managing it, or on another desktop entirely).
function Switch-WsmDesktopForWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    Assert-WsmVirtualDesktop
    try {
        $d = Get-DesktopFromWindow -Hwnd $Hwnd
        if ($d) { Switch-Desktop -Desktop $d | Out-Null }
    }
    catch {
        Write-WsmDebug "Switch-WsmDesktopForWindow failed for $Hwnd : $($_.Exception.Message)"
    }
}

# Returns the name of the desktop hosting a given window, or $null.
function Get-WsmDesktopNameForWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    Assert-WsmVirtualDesktop
    try {
        $d = Get-DesktopFromWindow -Hwnd $Hwnd
        if ($d) { return Get-DesktopName -Desktop $d }
    }
    catch {
        Write-WsmDebug "Get-DesktopFromWindow failed for $Hwnd : $($_.Exception.Message)"
    }
    return $null
}

function Remove-WsmDesktopByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Assert-WsmVirtualDesktop
    $d = Get-WsmDesktopByName -Name $Name
    if ($d) {
        Remove-Desktop -Desktop $d | Out-Null
        Write-WsmInfo "Removed virtual desktop '$Name'."
    }
}
