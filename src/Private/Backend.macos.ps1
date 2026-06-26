Set-StrictMode -Version Latest

# macOS backend: window-only control via the `cursor` CLI (or Cursor.app) for
# launching and `osascript` (System Events) for finding/raising windows. There
# are deliberately NO Spaces operations here -- docent on macOS only ensures the
# right Cursor window is foregrounded.
#
# This file is dot-sourced on every platform but its functions are only invoked
# when Get-DocentBackendKind returns 'macos'. Accessibility permission must be
# granted to whatever runs osascript (e.g. Terminal / the pwsh host).

# Escape a string for safe embedding inside an AppleScript double-quoted literal.
function Get-DocentAppleScriptString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return ($Value -replace '\\', '\\\\' -replace '"', '\"')
}

# Run an AppleScript snippet and return its trimmed stdout (empty string on
# failure). Errors are logged, never thrown, so the handler can fall back.
function Invoke-DocentOsascript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Script)

    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $out = & osascript -e $Script 2>$errFile
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            $err = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
            Write-DocentDebug "osascript exit $code : $err"
            return ''
        }
        if ($null -eq $out) { return '' }
        return ([string]($out -join "`n")).Trim()
    }
    finally {
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    }
}

# Launch a Cursor window for $Uri, then poll for and raise the matching window.
function Open-DocentMacWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Leaf
    )

    $cliPath = $null
    if ($Config.cursorExe) {
        $cliPath = $Config.cursorExe
    }
    else {
        $cmd = Get-Command cursor -ErrorAction SilentlyContinue
        if ($cmd) { $cliPath = $cmd.Source }
    }

    if ($cliPath) {
        Write-DocentInfo "Launching Cursor CLI for '$Leaf'."
        Write-DocentDebug "$cliPath --new-window --folder-uri $Uri"
        & $cliPath --new-window --folder-uri $Uri 2>$null | Out-Null
    }
    else {
        Write-DocentInfo "Launching Cursor.app for '$Leaf'."
        Write-DocentDebug "open -na Cursor --args --new-window --folder-uri $Uri"
        & open -na Cursor --args --new-window --folder-uri $Uri 2>$null | Out-Null
    }

    $timeout = [int]$Config.launchTimeoutSec
    $deadline = (Get-Date).AddSeconds($timeout)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Find-DocentMacWindow -Config $Config -Leaf $Leaf) {
            Set-DocentMacWindowFront -Config $Config -Leaf $Leaf
            return
        }
    }
    Write-DocentWarn "No Cursor window matching '$Leaf' appeared within ${timeout}s."
}

# Return the title of a Cursor window whose name contains $Leaf, or $null.
function Find-DocentMacWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Leaf
    )
    $proc = if ($Config.processName) { $Config.processName } else { 'Cursor' }
    $procEsc = Get-DocentAppleScriptString -Value $proc
    $leafEsc = Get-DocentAppleScriptString -Value $Leaf

    $script = @"
set theTitle to ""
tell application "System Events"
  repeat with p in (every process whose name is "$procEsc")
    repeat with w in (windows of p)
      if (name of w) contains "$leafEsc" then
        set theTitle to (name of w)
        exit repeat
      end if
    end repeat
    if theTitle is not "" then exit repeat
  end repeat
end tell
return theTitle
"@
    $title = Invoke-DocentOsascript -Script $script
    if ($title) { return $title }
    return $null
}

# Raise + frontmost the Cursor window whose name contains $Leaf.
function Set-DocentMacWindowFront {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Leaf
    )
    $proc = if ($Config.processName) { $Config.processName } else { 'Cursor' }
    $procEsc = Get-DocentAppleScriptString -Value $proc
    $leafEsc = Get-DocentAppleScriptString -Value $Leaf

    $script = @"
tell application "System Events"
  repeat with p in (every process whose name is "$procEsc")
    repeat with w in (windows of p)
      if (name of w) contains "$leafEsc" then
        perform action "AXRaise" of w
        set frontmost of p to true
        return "1"
      end if
    end repeat
  end repeat
end tell
return "0"
"@
    $result = Invoke-DocentOsascript -Script $script
    if ($result -eq '1') { Write-DocentInfo "Raised Cursor window for '$Leaf'." }
    else { Write-DocentWarn "Could not raise a Cursor window for '$Leaf'." }
}

# Open a URL in a browser (best-effort). macOS is window-only -- there are no
# Spaces operations here, so the URL simply opens in a new browser window with
# no desktop placement and no focus-matching. Uses the configured browserExe
# when set, otherwise the system default browser via `open <url>`.
function Open-DocentMacBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Url
    )

    if ($Config.browserExe) {
        Write-DocentInfo "Opening URL in '$($Config.browserExe)' (new window)."
        Write-DocentDebug "open -na $($Config.browserExe) --args --new-window $Url"
        & open -na $Config.browserExe --args --new-window $Url 2>$null | Out-Null
    }
    else {
        Write-DocentInfo "Opening URL in the default browser."
        Write-DocentDebug "open $Url"
        & open $Url 2>$null | Out-Null
    }
}

# All Cursor window titles (for status / close).
function Get-DocentMacWindowTitles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Config)
    $proc = if ($Config.processName) { $Config.processName } else { 'Cursor' }
    $procEsc = Get-DocentAppleScriptString -Value $proc

    $script = @"
set titles to {}
tell application "System Events"
  repeat with p in (every process whose name is "$procEsc")
    repeat with w in (windows of p)
      set end of titles to (name of w)
    end repeat
  end repeat
end tell
set AppleScript's text item delimiters to linefeed
return titles as text
"@
    $out = Invoke-DocentOsascript -Script $script
    if (-not $out) { return @() }
    return @($out -split "`n" | Where-Object { $_ -and $_.Trim() })
}

# Close the Cursor window whose name contains $Leaf (best effort).
function Close-DocentMacWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Leaf
    )
    $proc = if ($Config.processName) { $Config.processName } else { 'Cursor' }
    $procEsc = Get-DocentAppleScriptString -Value $proc
    $leafEsc = Get-DocentAppleScriptString -Value $Leaf

    $script = @"
tell application "System Events"
  repeat with p in (every process whose name is "$procEsc")
    repeat with w in (windows of p)
      if (name of w) contains "$leafEsc" then
        click (first button of w whose subrole is "AXCloseButton")
        return "1"
      end if
    end repeat
  end repeat
end tell
return "0"
"@
    $result = Invoke-DocentOsascript -Script $script
    if ($result -eq '1') { Write-DocentInfo "Closed Cursor window for '$Leaf'." }
    else { Write-DocentWarn "No Cursor window to close for '$Leaf'." }
}
