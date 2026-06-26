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

    # Defaults. Nothing here is required for `docent serve`; it runs fine on
    # defaults alone.
    $defaults = @{
        port             = 39787
        token            = $null
        processName      = 'Cursor'
        cursorExe        = $null
        desktopName      = '{name}'
        uri              = 'vscode-remote://ssh-remote+{host}{path}'
        browserExe       = $null
        browserProcessName = $null
        links            = @()
        launchTimeoutSec = 25
        launchRetries    = 2
        launchDelaySec   = 2
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

# Derive companion URLs from a workspace name using the config's link policy.
# Each entry in $Config.links is { pattern, url, upper? }:
#   - pattern : a regex matched (case-insensitively) against $Name
#   - url     : a template where $1, $2, ... are replaced by the capture groups
#               of pattern (e.g. "https://jira.example.com/browse/$1")
#   - upper   : when true, capture groups are upper-cased before substitution
#               (e.g. branch leaf "salsa-12345" -> ticket "SALSA-12345")
# Returns the list of derived URLs (empty when 'links' is absent or nothing
# matches -> a total no-op for the caller).
function Resolve-DocentLinks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return @() }
    if (-not ($Config.PSObject.Properties.Name -contains 'links') -or -not $Config.links) { return @() }

    $urls = @()
    foreach ($link in $Config.links) {
        $props = $link.PSObject.Properties.Name
        if (($props -notcontains 'pattern') -or ($props -notcontains 'url')) { continue }
        $pattern = [string]$link.pattern
        $template = [string]$link.url
        if (-not $pattern -or -not $template) { continue }

        $m = [regex]::Match($Name, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) { continue }

        $upper = ($props -contains 'upper') -and $link.upper
        # Replace $0, $1, ... with the matched groups (highest index first so
        # $10 is not clobbered by $1).
        $url = $template
        for ($g = $m.Groups.Count - 1; $g -ge 0; $g--) {
            $val = $m.Groups[$g].Value
            if ($upper) { $val = $val.ToUpperInvariant() }
            $url = $url.Replace('$' + $g, $val)
        }
        $urls += $url
    }
    return $urls
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
