<#
.SYNOPSIS
    wsm-windows PowerShell bridge: the single entry point the Go daemon
    (apps/wsm-windows) shells out to for every WindowManager operation.

.DESCRIPTION
    Dot-sources the helper files in this directory (Logging/Native/Desktop/
    Window) and dispatches on -Action. STDOUT is reserved for exactly one JSON
    object describing the result; all human-facing logs go to STDERR via the
    Write-Wsm* helpers.

.NOTES
    Exit codes:
      0  - success (JSON result on stdout)
      44 - "focus" found no matching window (maps to webserver.ErrWindowNotFound)
      1  - unexpected error ({"error": "..."} on stdout; details on stderr)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('list', 'open', 'focus')]
    [string]$Action,

    # Window/process matching, config-driven via the active IDEProfile.
    [string]$Process = 'Cursor',
    [string]$Exe,

    # open
    [string]$Uri,

    # open / focus
    [string]$Name,

    # focus
    [string]$Id,

    # open / focus: the SSH host a remote workspace was opened against.
    [string]$RemoteHost,

    # Folder-uri launch hang mitigations (see Open-WsmCursorWindow).
    [int]$LaunchRetries = 2,
    [int]$LaunchTimeoutSec = 25,
    [int]$LaunchDelaySec = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Logging.ps1')
. (Join-Path $PSScriptRoot 'Native.ps1')
. (Join-Path $PSScriptRoot 'Desktop.ps1')
. (Join-Path $PSScriptRoot 'Window.ps1')

$script:NotFoundExitCode = 44

$Config = [PSCustomObject]@{
    processName      = $Process
    cursorExe        = if ($Exe) { $Exe } else { $null }
    launchRetries    = $LaunchRetries
    launchTimeoutSec = $LaunchTimeoutSec
    launchDelaySec   = $LaunchDelaySec
}

# Writes exactly one compact JSON object to stdout.
function Write-WsmResult {
    param([Parameter(Mandatory)][hashtable]$Result)
    $Result | ConvertTo-Json -Compress -Depth 6
}

function Invoke-WsmList {
    $windows = @()
    foreach ($w in (Get-WsmCursorWindows -Config $Config)) {
        $parsed = ConvertFrom-WsmCursorTitle -Title $w.Title
        $entry = [ordered]@{
            id    = [string]$w.Hwnd
            title = $w.Title
            app   = $Config.processName
        }
        if ($parsed.Host) { $entry.host = $parsed.Host }
        $windows += $entry
    }
    Write-WsmResult @{ windows = @($windows) }
}

function Invoke-WsmOpen {
    if (-not $Uri) { throw "-Uri is required for -Action open" }
    if (-not $Name) { throw "-Name is required for -Action open" }

    $leaf = Get-WsmLeafName -Path $Name
    $desktop = Get-WsmOrNewDesktop -Name $Name
    $hwnd = Open-WsmCursorWindow -Config $Config -Uri $Uri -LeafName $leaf -RemoteHost $RemoteHost

    Move-WsmWindowToDesktop -Desktop $desktop -Hwnd $hwnd
    Switch-WsmDesktop -Desktop $desktop
    Set-WsmForegroundWindow -Hwnd $hwnd

    Write-WsmResult @{ ok = $true; action = 'opened'; name = $Name }
}

# Resolve the target window: an explicit -Id matches by HWND exactly;
# otherwise -Name is resolved to a leaf and matched host-aware, with a
# host-less retry (the "[SSH: host]" marker renders a beat after launch, so a
# freshly-opened remote window may not carry it yet).
function Resolve-WsmFocusTarget {
    if ($Id) {
        $hwnd = [IntPtr]([long]$Id)
        $win = Get-WsmCursorWindows -Config $Config | Where-Object { $_.Hwnd -eq $hwnd } | Select-Object -First 1
        if ($win) { return $win }
    }
    if (-not $Name) { return $null }

    $leaf = Get-WsmLeafName -Path $Name
    $win = Find-WsmCursorWindow -Config $Config -LeafName $leaf -RemoteHost $RemoteHost
    if (-not $win -and $RemoteHost) {
        Write-WsmDebug "No host-aware match for '$leaf' [SSH: $RemoteHost]; retrying host-less."
        $win = Find-WsmCursorWindow -Config $Config -LeafName $leaf
    }
    return $win
}

function Invoke-WsmFocus {
    if (-not $Name -and -not $Id) { throw "-Name or -Id is required for -Action focus" }
    $target = if ($Name) { $Name } else { $Id }

    $win = Resolve-WsmFocusTarget
    if (-not $win) {
        Write-WsmInfo "No matching window for '$target'."
        Write-WsmResult @{ notFound = $true }
        exit $script:NotFoundExitCode
    }

    # Prefer the desktop named after the workspace; fall back to wherever the
    # window itself already lives (e.g. it was opened outside wsm).
    $desktop = if ($Name) { Get-WsmDesktopByName -Name $Name } else { $null }
    if ($desktop) { Switch-WsmDesktop -Desktop $desktop }
    else { Switch-WsmDesktopForWindow -Hwnd $win.Hwnd }

    Set-WsmForegroundWindow -Hwnd $win.Hwnd
    Write-WsmResult @{ ok = $true; action = 'focused'; name = $target }
}

try {
    switch ($Action) {
        'list' { Invoke-WsmList }
        'open' { Invoke-WsmOpen }
        'focus' { Invoke-WsmFocus }
    }
}
catch {
    Write-WsmError $_.Exception.Message
    Write-WsmResult @{ error = $_.Exception.Message }
    exit 1
}
