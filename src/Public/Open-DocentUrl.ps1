Set-StrictMode -Version Latest

<#
.SYNOPSIS
Open a URL in a browser window on the virtual desktop named for a workspace.

.DESCRIPTION
The companion to Open-DocentWorkspace: places a browser window for $Url onto the
same named virtual desktop as a Cursor workspace. Primarily called as a side
effect of Open-DocentWorkspace (via the config link policy), but also usable
standalone from the CLI for testing.

Behavior:
  - if a browser window already exists on the named desktop, leaves it in place
    (focus-or-open: no duplicate window);
  - otherwise ensures the desktop exists, launches a new browser window, and
    moves it onto the desktop.

The window is PLACE-ONLY: it is moved onto the desktop but NOT brought to the
foreground, so the caller's Cursor window stays the focused window. macOS is
window-only (no Spaces): the URL just opens in a new browser window.

.EXAMPLE
Open-DocentUrl -Name my-feature -Url https://example.com/page
#>
function Open-DocentUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [string]$Config,
        [PSCustomObject]$ConfigObject
    )

    $cfg = if ($ConfigObject) { $ConfigObject } else { Get-DocentConfig -Config $Config }

    $tokens = @{ name = $Name; ref = $Name }
    $deskTemplate = if ($cfg.desktopName) { $cfg.desktopName } else { '{name}' }
    $deskName = Expand-DocentTemplate -Template $deskTemplate -Context $tokens

    Write-DocentInfo "open-url name=$deskName"
    Write-DocentDebug "url=$Url"

    # Focus-or-open: if the desktop already hosts a browser window, leave it.
    $existing = Find-DocentUrlWindowHandle -Config $cfg -DeskName $deskName
    if ($existing) {
        Write-DocentInfo "Browser window already on desktop '$deskName'; leaving in place."
        return [PSCustomObject]@{
            Action = 'present'
            Name   = $deskName
            Url    = $Url
            Hwnd   = $existing.Hwnd
        }
    }

    $target = Invoke-DocentEnsureWorkspaceTarget -Config $cfg -Name $deskName
    $handle = Invoke-DocentOpenUrlWindow -Config $cfg -Url $Url
    Invoke-DocentPlaceWindow -Config $cfg -Handle $handle -Name $deskName -Target $target

    [PSCustomObject]@{
        Action = 'opened'
        Name   = $deskName
        Url    = $Url
        Hwnd   = $handle.Hwnd
    }
}
