<#
.SYNOPSIS
  Install wsm-windows (wsmd) as a Scheduled Task that runs at logon with a
  1-minute watchdog. No admin required.

.DESCRIPTION
  Builds the Go binary, drops a config from the example if none exists, and
  registers a "wsmd" task that runs the daemon in your interactive session
  (required so it can move/focus windows). A repeating trigger relaunches it if
  it dies; MultipleInstances=IgnoreNew avoids duplicates.

  Safe to re-run to upgrade in place: it disables + stops any existing task and
  kills lingering daemon processes first, so the running .exe is unlocked before
  the rebuild and the 1-minute watchdog can't relaunch mid-install. Your config
  is left untouched (it is only written when none exists), and the task is
  re-registered fresh (re-enabled) at the end.

  The binary is built for the GUI subsystem (-H windowsgui) so it runs headless
  with no console window; because that discards stderr, the task passes -log so
  the daemon writes to <BinDir>\wsmd.log instead.

  Requires: Go 1.22+, PowerShell 7 (pwsh), and the VirtualDesktop module
  (Install-Module VirtualDesktop -Scope CurrentUser). Cursor must be installed.
#>
[CmdletBinding()]
param(
    [string]$BinDir = (Join-Path $env:LOCALAPPDATA 'wsm'),
    [string]$ConfigPath = (Join-Path $env:APPDATA 'wsm\config.jsonc'),
    [string]$TaskName = 'wsmd'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $BinDir 'wsm-windows.exe'
$logPath = Join-Path $BinDir 'wsmd.log'

# Stop any previous instance before rebuilding: the task holds an open handle to
# $bin, so `go build -o $bin` would fail with "file in use". Disable first so the
# 1-minute watchdog trigger can't relaunch the daemon while we build.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "==> Stopping + disabling existing task '$TaskName'"
    Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

# Kill lingering daemon processes (task-launched or manual) so the exe unlocks.
Get-Process -Name 'wsm-windows' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Wait (up to ~5s) for the OS to release the file handle before overwriting it.
if (Test-Path -LiteralPath $bin) {
    for ($i = 0; $i -lt 50; $i++) {
        try {
            $fh = [System.IO.File]::Open($bin, 'Open', 'ReadWrite', 'None')
            $fh.Close()
            break
        }
        catch { Start-Sleep -Milliseconds 100 }
    }
}

Write-Host "==> Building wsm-windows (headless / GUI subsystem)"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
Push-Location $repoRoot
try {
    # -H windowsgui: no console window when the task launches it at logon.
    & go build -ldflags '-H=windowsgui' -o $bin ./apps/wsm-windows
    if ($LASTEXITCODE -ne 0) { throw "go build failed ($LASTEXITCODE)" }
}
finally { Pop-Location }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "==> Writing example config to $ConfigPath (edit it to set a token!)"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ConfigPath) | Out-Null
    Copy-Item (Join-Path $repoRoot 'config\wsm.config.example.jsonc') $ConfigPath
}

Write-Host "==> Registering Scheduled Task '$TaskName'"
$me = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute $bin -Argument ('-config "{0}" -log "{1}"' -f $ConfigPath, $logPath)

$tLogon = New-ScheduledTaskTrigger -AtLogOn -User $me
$tWatch = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)

# Interactive + limited: wsmd moves/focuses windows, so it must run in your
# logged-on session. No time limit; skip a new run while one is already going.
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($tLogon, $tWatch) `
    -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "==> Done. Runs headless (no console window); logs to $logPath"
Write-Host "    Health check: Invoke-WebRequest http://127.0.0.1:39788/health -UseBasicParsing   # -> ok"
Write-Host "    Manage: Stop-/Disable-/Unregister-ScheduledTask -TaskName $TaskName"
