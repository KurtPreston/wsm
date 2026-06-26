Set-StrictMode -Version Latest

<#
.SYNOPSIS
Open (or focus) a remote Cursor window for an explicit host/path/name. The
caller (a webhook from grove, or the CLI) already supplies the remote path.

.DESCRIPTION
Builds the remote folder URI from host + path, then:
  - if a Cursor window already exists for the path's leaf, focuses it;
  - otherwise ensures the workspace target (Windows: a virtual desktop named
    `name`; macOS: nothing), launches a new Cursor window, places it on the
    target, and (unless -NoSwitch) brings it to the foreground.

All OS-specific behavior lives behind the backend abstraction (Backend.ps1).

.EXAMPLE
Open-DocentWorkspace -Host ubuntu -Path /home/me/Code/salsa/my-feature -Name my-feature
#>
function Open-DocentWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Alias('h')][string]$Host,
        [Parameter(Mandatory)][string]$Path,
        [string]$Name,
        [string]$Config,
        [PSCustomObject]$ConfigObject,
        [switch]$NoSwitch
    )

    $cfg = if ($ConfigObject) { $ConfigObject } else { Get-DocentConfig -Config $Config }

    $leaf = Get-DocentLeafName -Path $Path
    $nameVal = if ($Name) { $Name } else { $leaf }
    $tokens = @{ host = $Host; path = $Path; name = $nameVal; ref = $nameVal }

    $deskTemplate = if ($cfg.desktopName) { $cfg.desktopName } else { '{name}' }
    $deskName = Expand-DocentTemplate -Template $deskTemplate -Context $tokens
    $uri = Expand-DocentTemplate -Template $cfg.uri -Context $tokens

    Write-DocentInfo "open host=$Host name=$deskName leaf=$leaf"
    Write-DocentDebug "uri=$uri"

    # Focus-vs-open: adopt an existing window for this workspace if present.
    $existing = Find-DocentWindowHandle -Config $cfg -Leaf $leaf -RemoteHost $Host
    if ($existing) {
        Write-DocentInfo "Existing window for '$leaf'; focusing."
        Invoke-DocentFocusWindow -Config $cfg -Handle $existing -Name $deskName
        Open-DocentWorkspaceLink -Config $cfg -Name $nameVal -DeskName $deskName -CursorHandle $existing -NoSwitch:$NoSwitch
        return [PSCustomObject]@{
            Action      = 'focused'
            Host        = $Host
            Path        = $Path
            Name        = $deskName
            Uri         = $uri
            Hwnd        = $existing.Hwnd
        }
    }

    $target = Invoke-DocentEnsureWorkspaceTarget -Config $cfg -Name $deskName
    $handle = Invoke-DocentOpenWindow -Config $cfg -Uri $uri -Leaf $leaf -RemoteHost $Host
    Invoke-DocentPlaceWindow -Config $cfg -Handle $handle -Name $deskName -Target $target
    if (-not $NoSwitch) { Invoke-DocentFocusWindow -Config $cfg -Handle $handle -Name $deskName }
    Open-DocentWorkspaceLink -Config $cfg -Name $nameVal -DeskName $deskName -CursorHandle $handle -NoSwitch:$NoSwitch

    [PSCustomObject]@{
        Action      = 'opened'
        Host        = $Host
        Path        = $Path
        Name        = $deskName
        Uri         = $uri
        Hwnd        = $handle.Hwnd
    }
}

# Open any companion links derived from the workspace name onto the same desktop
# (a no-op when no 'links' entry matches). Link windows are placed but not
# foregrounded; we then re-foreground the Cursor window so the editor stays
# frontmost. Failures are logged, never thrown -- a broken link must not fail the
# Cursor open.
function Open-DocentWorkspaceLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][string]$DeskName,
        [Parameter(Mandatory)]$CursorHandle,
        [switch]$NoSwitch
    )

    $links = @(Resolve-DocentLinks -Name $Name -Config $Config)
    if ($links.Count -eq 0) { return }

    foreach ($url in $links) {
        try { Open-DocentUrl -Name $Name -Url $url -ConfigObject $Config | Out-Null }
        catch { Write-DocentWarn "link open failed for $url : $($_.Exception.Message)" }
    }

    # Keep Cursor frontmost after the place-only browser windows landed.
    if (-not $NoSwitch) { Invoke-DocentFocusWindow -Config $Config -Handle $CursorHandle -Name $DeskName }
}
