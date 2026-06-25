Set-StrictMode -Version Latest

<#
.SYNOPSIS
Switch to the ref's named virtual desktop (and foreground its window if found).
#>
function Focus-RcdWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Ref,
        [string]$Project,
        [string]$Config
    )

    $cfg = Get-RcdConfig -Config $Config
    $ctx = New-RcdContext -Config $cfg -Ref $Ref -Project $Project
    $deskName = Expand-RcdTemplate -Template $cfg.desktopName -Context $ctx

    $desktop = Get-RcdDesktopByName -Name $deskName
    if (-not $desktop) { throw "No virtual desktop named '$deskName'." }

    Switch-RcdDesktop -Desktop $desktop
    Write-RcdInfo "Switched to desktop '$deskName'."

    # Best-effort foreground of the matching window (by folder leaf in title).
    $windows = Get-RcdCursorWindows -Config $cfg
    $onDesk = $windows | Where-Object { (Get-RcdDesktopNameForWindow -Hwnd $_.Hwnd) -eq $deskName } | Select-Object -First 1
    if ($onDesk) {
        Set-RcdForegroundWindow -Hwnd $onDesk.Hwnd
        Write-RcdInfo "Foregrounded '$($onDesk.Title)'."
    }
    else {
        Write-RcdWarn "No Cursor window found on desktop '$deskName'."
    }
}

Set-Alias -Name Focus-Rcd -Value Focus-RcdWorkspace
