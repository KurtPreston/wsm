Set-StrictMode -Version Latest

# Default config search order (first hit wins):
#   1. -Config <path> (handled by callers)
#   2. $env:DOCENT_CONFIG
#   3. ./docent.config.json(c) in the current directory
#   4. $HOME/.config/docent/config.json(c)
#
# Returns $null when no config file is found. docent serve runs fine on
# defaults alone, so a missing config is not an error.
function Get-DocentConfigPath {
    [CmdletBinding()]
    param([string]$Config)

    $candidates = @()
    if ($Config) { $candidates += $Config }
    if ($env:DOCENT_CONFIG) { $candidates += $env:DOCENT_CONFIG }
    $candidates += (Join-Path (Get-Location) 'docent.config.jsonc')
    $candidates += (Join-Path (Get-Location) 'docent.config.json')
    if ($HOME) {
        $candidates += (Join-Path $HOME '.config/docent/config.jsonc')
        $candidates += (Join-Path $HOME '.config/docent/config.json')
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }

    # An explicit -Config / $DOCENT_CONFIG that does not exist is a hard error;
    # otherwise a missing config simply means "use defaults".
    if ($Config) { throw "Config file not found: $Config" }
    if ($env:DOCENT_CONFIG) { throw "Config file not found (DOCENT_CONFIG): $($env:DOCENT_CONFIG)" }
    return $null
}

# Strip // line comments and /* */ block comments and trailing commas from a
# JSONC string, while preserving anything inside string literals (critical: our
# `uri` template contains `vscode-remote://...`, which must NOT be treated as a
# comment).
function Remove-DocentJsonComments {
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

function Get-DocentConfig {
    [CmdletBinding()]
    param([string]$Config)

    # Defaults. Nothing here is required for `docent serve`; the optional
    # pull-mode fields (host/resolve/list/...) are only validated by the
    # functions that actually use them.
    $defaults = @{
        port             = 39787
        token            = $null
        processName      = 'Cursor'
        cursorExe        = $null
        desktopName      = '{name}'
        uri              = 'vscode-remote://ssh-remote+{host}{path}'
        launchTimeoutSec = 25
        launchRetries    = 2
        launchDelaySec   = 2

        # Optional, pull-mode only.
        host             = $null
        project          = $null
        resolve          = $null
        list             = $null
        sshExe           = 'ssh'
        sshOptions       = @('-o', 'BatchMode=yes')
        remoteShell      = "bash -lc '{cmd}'"
    }

    $cfg = [ordered]@{}
    foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }

    $path = Get-DocentConfigPath -Config $Config
    if ($path) {
        Write-DocentDebug "Loading config: $path"
        $raw = Get-Content -LiteralPath $path -Raw
        $clean = Remove-DocentJsonComments -Text $raw
        try {
            $obj = $clean | ConvertFrom-Json
        }
        catch {
            throw "Failed to parse config '$path': $($_.Exception.Message)"
        }
        foreach ($p in $obj.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    }
    else {
        Write-DocentDebug "No config file found; using defaults."
    }

    $cfg['_path'] = $path
    return [PSCustomObject]$cfg
}

# Replace {key} tokens in a template from a context hashtable. Unknown tokens
# are left intact so partially-templated strings remain debuggable.
function Expand-DocentTemplate {
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

# Build the standard substitution context for a given ref/project (pull-mode).
function New-DocentContext {
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
