Set-StrictMode -Version Latest

# Windows window manager: launch a remote Cursor window and reliably find its
# HWND, plus focus/close helpers keyed on the worktree folder name. macOS uses
# the osascript-based helpers in Backend.macos.ps1 instead.

# Locate Cursor.exe: explicit config wins, then the standard per-user install.
function Resolve-DocentCursorExe {
    [CmdletBinding()]
    param([PSCustomObject]$Config)

    if ($Config.cursorExe) {
        if (Test-Path -LiteralPath $Config.cursorExe) { return $Config.cursorExe }
        throw "Configured cursorExe not found: $($Config.cursorExe)"
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs/cursor/Cursor.exe'),
        (Join-Path $env:ProgramFiles 'Cursor/Cursor.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    $cmd = Get-Command cursor -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    throw "Could not locate Cursor.exe. Set 'cursorExe' in config."
}

# The basename of a (POSIX or Windows) path, used to match window titles.
function Get-DocentLeafName {
    param([Parameter(Mandatory)][string]$Path)
    return (($Path -replace '\\', '/').TrimEnd('/') -split '/')[-1]
}

# Cursor windows currently visible (filtered by process name).
function Get-DocentCursorWindows {
    [CmdletBinding()]
    param([PSCustomObject]$Config)

    $procName = if ($Config.processName) { $Config.processName } else { 'Cursor' }
    $procIds = @(Get-Process -Name $procName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    if ($procIds.Count -eq 0) { return @() }

    Get-DocentAllWindows | Where-Object { $procIds -contains $_.Pid }
}

# Decide whether a window title belongs to a given remote workspace. Matching is
# host-aware and anchored so that, e.g., leaf 'salsa-next' does NOT match the
# window for 'salsa-next-b'. Remote Cursor windows render as either
#   "<leaf> [SSH: <host>] - Cursor"            (no file open yet)
#   "<file> - <leaf> [SSH: <host>] - Cursor"   (a file is open)
# and, transiently right after launch (before the remote marker renders),
#   "<leaf> - Cursor".
function Test-DocentWorkspaceWindow {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$Title,
        [Parameter(Mandatory)][string]$LeafName,
        [string]$RemoteHost
    )
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }

    # Literal substring/equality matching (NOT -like): Cursor titles contain
    # '[' and ']' which are wildcard metacharacters under -like.
    if ($RemoteHost) {
        # "<leaf> [SSH: <host>]" anchored on the leaf (and its trailing space).
        # Handles both the bare and file-open remote titles.
        if ($Title.Contains("$LeafName [SSH: $RemoteHost]")) { return $true }
    }
    # Transient title right after launch, before the [SSH:]/file markers render.
    # Matched regardless of $RemoteHost so a freshly-launched remote window is
    # adopted in the brief window before its SSH marker appears.
    if ($Title -eq "$LeafName - Cursor") { return $true }

    # Local window (no remote requested): parse the title's workspace leaf so
    # file-open titles like "<file> - <leaf> - Cursor" (and Cursor's own
    # "<leaf> - <leaf> - Cursor") still match -- but only for non-SSH windows,
    # so a local focus never grabs a remote window that happens to share a leaf.
    if (-not $RemoteHost) {
        $parsed = ConvertFrom-DocentCursorTitle -Title $Title
        if ($parsed.Leaf -eq $LeafName -and [string]::IsNullOrEmpty($parsed.Host)) { return $true }
    }
    return $false
}

# Launch a remote Cursor window for $Uri and return its HWND once it appears.
# Mitigates the known `--folder-uri vscode-remote://` hang/no-op when Cursor is
# already running: non-blocking launch (Start-Process), poll for a NEW window
# whose title contains the folder leaf, and retry with a short delay.
function Open-DocentCursorWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$LeafName,
        [string]$RemoteHost
    )

    $exe = Resolve-DocentCursorExe -Config $Config
    Write-DocentDebug "Cursor.exe: $exe"

    # Idempotency / folder-uri no-op mitigation: when the workspace is ALREADY
    # open, `--new-window --folder-uri <same folder>` is a no-op (Cursor just
    # refocuses the existing window and no new window ever appears). Detect that
    # up front and adopt the existing window instead of waiting out a launch that
    # will never produce a new HWND.
    $existing = Find-DocentCursorWindow -Config $Config -LeafName $LeafName -RemoteHost $RemoteHost
    if ($existing) {
        Write-DocentInfo "Workspace '$LeafName' already open (hwnd $($existing.Hwnd)); adopting existing window."
        return $existing.Hwnd
    }

    $retries = [int]$Config.launchRetries
    $timeout = [int]$Config.launchTimeoutSec
    $delay = [int]$Config.launchDelaySec

    for ($attempt = 1; $attempt -le ($retries + 1); $attempt++) {
        $before = @(Get-DocentCursorWindows -Config $Config | Select-Object -ExpandProperty Hwnd)
        Write-DocentInfo "Launching Cursor (attempt $attempt) for '$LeafName'."
        Write-DocentDebug "$exe --new-window --folder-uri $Uri"

        Start-Process -FilePath $exe -ArgumentList @('--new-window', '--folder-uri', $Uri) | Out-Null

        $deadline = (Get-Date).AddSeconds($timeout)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $current = Get-DocentCursorWindows -Config $Config

            # Prefer a brand-new window whose title matches this workspace.
            $match = $current | Where-Object {
                ($before -notcontains $_.Hwnd) -and
                (Test-DocentWorkspaceWindow -Title $_.Title -LeafName $LeafName -RemoteHost $RemoteHost)
            } | Select-Object -First 1
            if ($match) {
                Write-DocentInfo "Matched window: '$($match.Title)' (hwnd $($match.Hwnd))."
                return $match.Hwnd
            }
        }

        # Fallback: any new window (title may not have rendered the folder yet).
        $current = Get-DocentCursorWindows -Config $Config
        $newAny = $current | Where-Object { $before -notcontains $_.Hwnd } | Select-Object -First 1
        if ($newAny) {
            Write-DocentWarn "No title match for '$LeafName'; using new window '$($newAny.Title)'."
            return $newAny.Hwnd
        }

        Write-DocentWarn "No new Cursor window after ${timeout}s (likely the folder-uri hang). Retrying in ${delay}s."
        Start-Sleep -Seconds $delay
    }

    throw "Failed to open a Cursor window for '$LeafName' after $($retries + 1) attempts."
}

# Find an existing Cursor window for a workspace (host-aware title match).
function Find-DocentCursorWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$LeafName,
        [string]$RemoteHost
    )
    Get-DocentCursorWindows -Config $Config |
        Where-Object { Test-DocentWorkspaceWindow -Title $_.Title -LeafName $LeafName -RemoteHost $RemoteHost } |
        Select-Object -First 1
}
