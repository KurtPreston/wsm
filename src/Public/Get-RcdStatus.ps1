Set-StrictMode -Version Latest

<#
.SYNOPSIS
Show the current ref -> desktop -> window mapping.

.DESCRIPTION
Lists every virtual desktop alongside the Cursor windows currently placed on it.
With -Project (and a `list` template configured), also annotates which known refs
are open vs. closed.
#>
function Get-RcdStatus {
    [CmdletBinding()]
    param(
        [string]$Project,
        [string]$Config
    )

    $cfg = Get-RcdConfig -Config $Config
    Assert-RcdVirtualDesktop

    $windows = Get-RcdCursorWindows -Config $cfg
    $rows = foreach ($w in $windows) {
        [PSCustomObject]@{
            Desktop = (Get-RcdDesktopNameForWindow -Hwnd $w.Hwnd)
            Hwnd    = $w.Hwnd
            Title   = $w.Title
        }
    }

    [PSCustomObject]@{
        Config   = $cfg._path
        Host     = $cfg.host
        Desktops = @(Get-DesktopList | ForEach-Object { Get-DesktopName -Desktop (Get-Desktop -Index $_.Number) })
        Windows  = @($rows)
    }
}
