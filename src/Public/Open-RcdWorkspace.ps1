Set-StrictMode -Version Latest

<#
.SYNOPSIS
Resolve a ref to a remote folder, ensure its named virtual desktop, launch a
remote Cursor window there, and place + switch to it.

.EXAMPLE
Open-RcdWorkspace -Ref my-feature
Open-RcdWorkspace -Ref my-feature -Project salsa -NoSwitch
#>
function Open-RcdWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Ref,
        [string]$Project,
        [string]$Config,
        [switch]$NoSwitch
    )

    $cfg = Get-RcdConfig -Config $Config
    $ctx = New-RcdContext -Config $cfg -Ref $Ref -Project $Project

    $path = Resolve-RcdPath -Config $cfg -Context $ctx
    $ctx['path'] = $path

    $uri = Expand-RcdTemplate -Template $cfg.uri -Context $ctx
    $deskName = Expand-RcdTemplate -Template $cfg.desktopName -Context $ctx
    $leaf = Get-RcdLeafName -Path $path

    $desktop = Get-RcdOrNewDesktop -Name $deskName
    $hwnd = Open-RcdCursorWindow -Config $cfg -Uri $uri -LeafName $leaf

    Move-RcdWindowToDesktop -Desktop $desktop -Hwnd $hwnd
    if (-not $NoSwitch) { Switch-RcdDesktop -Desktop $desktop }

    [PSCustomObject]@{
        Ref         = $Ref
        Project     = $ctx.project
        Path        = $path
        Uri         = $uri
        DesktopName = $deskName
        Hwnd        = $hwnd
    }
}
