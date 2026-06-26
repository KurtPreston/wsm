Set-StrictMode -Version Latest

# Windows browser launcher: open a URL in a NEW Chromium browser window and
# reliably find its HWND so it can be moved onto a virtual desktop. Mirrors the
# Cursor flow in Window.ps1 but is generic over whichever browser is configured
# / auto-detected. macOS uses Open-DocentMacBrowser in Backend.macos.ps1 instead.

# Locate the browser executable: explicit config wins, then the standard
# per-user / system installs for Chrome, Edge, and Brave.
function Resolve-DocentBrowserExe {
    [CmdletBinding()]
    param([PSCustomObject]$Config)

    if ($Config.browserExe) {
        if (Test-Path -LiteralPath $Config.browserExe) { return $Config.browserExe }
        throw "Configured browserExe not found: $($Config.browserExe)"
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Google/Chrome/Application/chrome.exe'),
        (Join-Path ${env:ProgramFiles} 'Google/Chrome/Application/chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google/Chrome/Application/chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft/Edge/Application/msedge.exe'),
        (Join-Path ${env:ProgramFiles} 'Microsoft/Edge/Application/msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'BraveSoftware/Brave-Browser/Application/brave.exe'),
        (Join-Path ${env:ProgramFiles} 'BraveSoftware/Brave-Browser/Application/brave.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }

    throw "Could not locate a Chromium browser (Chrome/Edge/Brave). Set 'browserExe' in config."
}

# The process name (no extension) used to enumerate the browser's windows.
# Explicit config override wins; otherwise derive it from the exe filename.
function Get-DocentBrowserProcessName {
    [CmdletBinding()]
    param([PSCustomObject]$Config)

    if ($Config.browserProcessName) { return [string]$Config.browserProcessName }
    $exe = Resolve-DocentBrowserExe -Config $Config
    return [System.IO.Path]::GetFileNameWithoutExtension($exe)
}

# Browser windows currently visible (filtered by the browser process name).
function Get-DocentBrowserWindows {
    [CmdletBinding()]
    param([PSCustomObject]$Config)

    $procName = Get-DocentBrowserProcessName -Config $Config
    $procIds = @(Get-Process -Name $procName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    if ($procIds.Count -eq 0) { return @() }

    Get-DocentAllWindows | Where-Object { $procIds -contains $_.Pid }
}

# Launch a NEW browser window for $Url and return its HWND once it appears.
# Snapshots existing browser HWNDs first, then polls for a window that did not
# exist before -- Chromium reuses the same process for new windows, so we match
# on "new HWND" rather than process identity.
function Open-DocentBrowserWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Url
    )

    $exe = Resolve-DocentBrowserExe -Config $Config
    Write-DocentDebug "Browser exe: $exe"

    $timeout = [int]$Config.launchTimeoutSec

    $before = @(Get-DocentBrowserWindows -Config $Config | Select-Object -ExpandProperty Hwnd)
    Write-DocentInfo "Launching browser window for URL."
    Write-DocentDebug "$exe --new-window $Url"

    Start-Process -FilePath $exe -ArgumentList @('--new-window', $Url) | Out-Null

    $deadline = (Get-Date).AddSeconds($timeout)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $new = Get-DocentBrowserWindows -Config $Config |
            Where-Object { $before -notcontains $_.Hwnd } |
            Select-Object -First 1
        if ($new) {
            Write-DocentInfo "Matched new browser window '$($new.Title)' (hwnd $($new.Hwnd))."
            return $new.Hwnd
        }
    }

    Write-DocentWarn "No new browser window appeared within ${timeout}s for URL."
    return [IntPtr]::Zero
}

# Find an existing browser window already sitting on the named virtual desktop;
# $null if none. Used for focus-or-open so a repeat open reuses the desktop's
# browser window instead of stacking duplicates.
function Find-DocentBrowserWindowOnDesktop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$DeskName
    )
    Get-DocentBrowserWindows -Config $Config |
        Where-Object { (Get-DocentDesktopNameForWindow -Hwnd $_.Hwnd) -eq $DeskName } |
        Select-Object -First 1
}
