Set-StrictMode -Version Latest

<#
.SYNOPSIS
Close the Cursor window(s) on the ref's desktop, and optionally remove the
desktop itself.
#>
function Close-RcdWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Ref,
        [string]$Project,
        [string]$Config,
        [switch]$RemoveDesktop
    )

    $cfg = Get-RcdConfig -Config $Config
    $ctx = New-RcdContext -Config $cfg -Ref $Ref -Project $Project
    $deskName = Expand-RcdTemplate -Template $cfg.desktopName -Context $ctx

    $windows = Get-RcdCursorWindows -Config $cfg
    $onDesk = @($windows | Where-Object { (Get-RcdDesktopNameForWindow -Hwnd $_.Hwnd) -eq $deskName })

    if ($onDesk.Count -eq 0) {
        Write-RcdWarn "No Cursor windows found on desktop '$deskName'."
    }
    foreach ($w in $onDesk) {
        Write-RcdInfo "Closing '$($w.Title)' (hwnd $($w.Hwnd))."
        Close-RcdWindowHandle -Hwnd $w.Hwnd
    }

    if ($RemoveDesktop) {
        Start-Sleep -Milliseconds 500
        Remove-RcdDesktopByName -Name $deskName
    }
}
