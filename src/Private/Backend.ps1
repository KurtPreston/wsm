Set-StrictMode -Version Latest

# OS-backend abstraction. docent selects a backend at runtime from the automatic
# $IsWindows / $IsMacOS variables (PowerShell 7+). The open-or-focus handler is
# written purely against the operations below; each operation dispatches to the
# Windows (Desktop.ps1 + Window.ps1 + Native.ps1) or macOS (Backend.macos.ps1)
# implementation.
#
# Operations:
#   Get-DocentBackendKind                          -> 'windows' | 'macos'
#   Invoke-DocentEnsureWorkspaceTarget(name)       -> target  (Windows: desktop; macOS: $null)
#   Invoke-DocentOpenWindow(uri, leaf, host)       -> handle  (launch Cursor, return a handle)
#   Find-DocentWindowHandle(leaf, host)            -> handle | $null
#   Invoke-DocentFocusWindow(handle, name)         (Windows: switch desktop + foreground; macOS: raise)
#   Invoke-DocentPlaceWindow(handle, name, target) (Windows: move window to desktop; macOS: no-op)
#
# A "handle" is a PSCustomObject: @{ Backend; Hwnd; Leaf; Title }. On macOS the
# window is addressed by its title leaf, so Hwnd is unused ([IntPtr]::Zero).

function Get-DocentBackendKind {
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    throw "Unsupported OS: docent supports Windows and macOS only."
}

function New-DocentHandle {
    param(
        [Parameter(Mandatory)][string]$Backend,
        [IntPtr]$Hwnd = [IntPtr]::Zero,
        [string]$Leaf,
        [string]$Title
    )
    [PSCustomObject]@{ Backend = $Backend; Hwnd = $Hwnd; Leaf = $Leaf; Title = $Title }
}

# Windows: find/create a virtual desktop named $Name and return it. macOS: no-op
# (window-only; no Spaces), returns $null.
function Invoke-DocentEnsureWorkspaceTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Name
    )
    switch (Get-DocentBackendKind) {
        'windows' { return Get-DocentOrNewDesktop -Name $Name }
        'macos' { return $null }
    }
}

# Launch a Cursor window for $Uri and return a handle once it appears.
function Invoke-DocentOpenWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Leaf,
        [string]$RemoteHost
    )
    switch (Get-DocentBackendKind) {
        'windows' {
            $hwnd = Open-DocentCursorWindow -Config $Config -Uri $Uri -LeafName $Leaf -RemoteHost $RemoteHost
            return New-DocentHandle -Backend 'windows' -Hwnd $hwnd -Leaf $Leaf
        }
        'macos' {
            Open-DocentMacWindow -Config $Config -Uri $Uri -Leaf $Leaf
            return New-DocentHandle -Backend 'macos' -Leaf $Leaf
        }
    }
}

# Launch a browser window for $Url and return a handle. Windows: a placeable
# HWND once it appears; macOS: best-effort open (window-only, Hwnd unused).
function Invoke-DocentOpenUrlWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Url
    )
    switch (Get-DocentBackendKind) {
        'windows' {
            $hwnd = Open-DocentBrowserWindow -Config $Config -Url $Url
            return New-DocentHandle -Backend 'windows' -Hwnd $hwnd
        }
        'macos' {
            Open-DocentMacBrowser -Config $Config -Url $Url
            return New-DocentHandle -Backend 'macos'
        }
    }
}

# Locate a browser window already on the named desktop; $null if none. macOS is
# window-only (no Spaces), so there is nothing to match -- always returns $null,
# which makes the URL opener always open a fresh window there.
function Find-DocentUrlWindowHandle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$DeskName
    )
    switch (Get-DocentBackendKind) {
        'windows' {
            $w = Find-DocentBrowserWindowOnDesktop -Config $Config -DeskName $DeskName
            if ($w) { return New-DocentHandle -Backend 'windows' -Hwnd $w.Hwnd -Title $w.Title }
            return $null
        }
        'macos' { return $null }
    }
}

# Locate an existing Cursor window for the workspace; $null if none.
function Find-DocentWindowHandle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Leaf,
        [string]$RemoteHost
    )
    switch (Get-DocentBackendKind) {
        'windows' {
            $w = Find-DocentCursorWindow -Config $Config -LeafName $Leaf -RemoteHost $RemoteHost
            if ($w) { return New-DocentHandle -Backend 'windows' -Hwnd $w.Hwnd -Leaf $Leaf -Title $w.Title }
            return $null
        }
        'macos' {
            $title = Find-DocentMacWindow -Config $Config -Leaf $Leaf
            if ($title) { return New-DocentHandle -Backend 'macos' -Leaf $Leaf -Title $title }
            return $null
        }
    }
}

# Bring the window to focus. Windows: switch to its named desktop, then
# foreground the HWND. macOS: raise/frontmost via osascript.
function Invoke-DocentFocusWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)]$Handle,
        [string]$Name
    )
    switch (Get-DocentBackendKind) {
        'windows' {
            if ($Name) {
                $desktop = Get-DocentDesktopByName -Name $Name
                if ($desktop) { Switch-DocentDesktop -Desktop $desktop }
            }
            if ($Handle -and $Handle.Hwnd -ne [IntPtr]::Zero) {
                Set-DocentForegroundWindow -Hwnd $Handle.Hwnd
            }
        }
        'macos' {
            Set-DocentMacWindowFront -Config $Config -Leaf $Handle.Leaf
        }
    }
}

# Place a freshly-opened window on its workspace target. Windows: move the HWND
# to the named virtual desktop (reusing $Target if supplied). macOS: no-op.
function Invoke-DocentPlaceWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)]$Handle,
        [string]$Name,
        $Target
    )
    switch (Get-DocentBackendKind) {
        'windows' {
            $desktop = if ($Target) { $Target } else { Get-DocentOrNewDesktop -Name $Name }
            if ($Handle.Hwnd -ne [IntPtr]::Zero) {
                Move-DocentWindowToDesktop -Desktop $desktop -Hwnd $Handle.Hwnd
            }
        }
        'macos' { }
    }
}
