Set-StrictMode -Version Latest

# Default config search order (first hit wins):
#   1. -Config <path> (handled by callers)
#   2. $env:RCD_CONFIG
#   3. ./rcd.config.json(c) in the current directory
#   4. $HOME/.config/rcd/config.json(c)
function Get-RcdConfigPath {
    [CmdletBinding()]
    param([string]$Config)

    $candidates = @()
    if ($Config) { $candidates += $Config }
    if ($env:RCD_CONFIG) { $candidates += $env:RCD_CONFIG }
    $candidates += (Join-Path (Get-Location) 'rcd.config.jsonc')
    $candidates += (Join-Path (Get-Location) 'rcd.config.json')
    if ($HOME) {
        $candidates += (Join-Path $HOME '.config/rcd/config.jsonc')
        $candidates += (Join-Path $HOME '.config/rcd/config.json')
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    throw "No config file found. Looked in: $($candidates -join ', ')"
}

# Strip // line comments and /* */ block comments and trailing commas from a
# JSONC string, while preserving anything inside string literals (critical: our
# `uri` template contains `vscode-remote://...`, which must NOT be treated as a
# comment).
function Remove-RcdJsonComments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)

    $sb = [System.Text.StringBuilder]::new()
    $inString = $false
    $escaped = $false
    $i = 0
    $n = $Text.Length

    while ($i -lt $n) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $n) { $Text[$i + 1] } else { [char]0 }

        if ($inString) {
            [void]$sb.Append($ch)
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            $i++
            continue
        }

        if ($ch -eq '"') { $inString = $true; [void]$sb.Append($ch); $i++; continue }

        if ($ch -eq '/' -and $next -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($ch -eq '/' -and $next -eq '*') {
            $i += 2
            while ($i + 1 -lt $n -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
            $i += 2
            continue
        }

        [void]$sb.Append($ch)
        $i++
    }

    # Remove trailing commas before } or ].
    return [regex]::Replace($sb.ToString(), ',(\s*[}\]])', '$1')
}

function Get-RcdConfig {
    [CmdletBinding()]
    param([string]$Config)

    $path = Get-RcdConfigPath -Config $Config
    Write-RcdDebug "Loading config: $path"
    $raw = Get-Content -LiteralPath $path -Raw
    $clean = Remove-RcdJsonComments -Text $raw

    try {
        $obj = $clean | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse config '$path': $($_.Exception.Message)"
    }

    # Defaults.
    $defaults = @{
        host             = $null
        project          = $null
        resolve          = $null
        list             = $null
        uri              = 'vscode-remote://ssh-remote+{host}{path}'
        desktopName      = '{ref}'
        cursorExe        = $null
        processName      = 'Cursor'
        sshExe           = 'ssh'
        sshOptions       = @('-o', 'BatchMode=yes')
        remoteShell      = "bash -lc '{cmd}'"
        launchTimeoutSec = 25
        launchRetries    = 2
        launchDelaySec   = 2
    }

    $cfg = [ordered]@{}
    foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }
    foreach ($p in $obj.PSObject.Properties) { $cfg[$p.Name] = $p.Value }

    if (-not $cfg.host) { throw "Config '$path' is missing required field 'host'." }
    if (-not $cfg.resolve) { throw "Config '$path' is missing required field 'resolve'." }

    $cfg['_path'] = $path
    return [PSCustomObject]$cfg
}

# Replace {key} tokens in a template from a context hashtable. Unknown tokens
# are left intact so partially-templated strings remain debuggable.
function Expand-RcdTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Template,
        [Parameter(Mandatory)][hashtable]$Context
    )
    return [regex]::Replace($Template, '\{(\w+)\}', {
            param($m)
            $key = $m.Groups[1].Value
            if ($Context.ContainsKey($key) -and $null -ne $Context[$key]) {
                return [string]$Context[$key]
            }
            return $m.Value
        })
}

# Build the standard substitution context for a given ref/project.
function New-RcdContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        # Empty is valid: `open-all` builds a listing context whose `list`
        # template does not reference {ref}.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Ref,
        [string]$Project,
        [string]$Path
    )
    $proj = if ($Project) { $Project } else { $Config.project }
    return @{
        host    = $Config.host
        project = $proj
        ref     = $Ref
        path    = $Path
    }
}
