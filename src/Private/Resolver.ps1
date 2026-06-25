Set-StrictMode -Version Latest

# Run a resolver/list command on the remote host over SSH. Returns stdout lines.
# stderr from the remote command is surfaced through our own stderr.
function Invoke-RcdSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$RemoteCommand
    )

    # Wrap the command in the configured login shell (so PATH and resolver
    # commands resolve in a non-interactive session), escaping single quotes for
    # safe embedding.
    $escaped = $RemoteCommand -replace "'", "'\''"
    $wrapped = Expand-RcdTemplate -Template $Config.remoteShell -Context @{ cmd = $escaped }

    $sshArgs = @()
    if ($Config.sshOptions) { $sshArgs += $Config.sshOptions }
    $sshArgs += $Config.host
    $sshArgs += $wrapped

    Write-RcdDebug "ssh $($sshArgs -join ' ')"

    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & $Config.sshExe @sshArgs 2>$errFile
        $code = $LASTEXITCODE
        $stderr = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        if ($stderr) {
            foreach ($line in ($stderr -split "`r?`n")) {
                if ($line.Trim()) { Write-RcdDebug "ssh stderr: $line" }
            }
        }
        if ($code -ne 0) {
            throw "SSH command failed (exit $code): $wrapped`n$stderr"
        }
        return @($stdout)
    }
    finally {
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    }
}

# Resolve a ref to its remote absolute folder path using the `resolve` template.
function Resolve-RcdPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $cmd = Expand-RcdTemplate -Template $Config.resolve -Context $Context
    Write-RcdInfo "Resolving '$($Context.ref)' via: $cmd"
    $out = Invoke-RcdSsh -Config $Config -RemoteCommand $cmd

    # The contract: stdout is the path. Take the last non-empty line defensively.
    $path = ($out | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 1)
    if (-not $path) { throw "Resolver returned no path for ref '$($Context.ref)'." }
    $path = $path.Trim()
    Write-RcdInfo "Resolved to: $path"
    return $path
}

# Enumerate refs via the `list` template. Returns objects with Ref + Path.
function Get-RcdRefList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][hashtable]$Context
    )
    if (-not $Config.list) { throw "Config has no 'list' template; cannot enumerate." }
    $cmd = Expand-RcdTemplate -Template $Config.list -Context $Context
    Write-RcdInfo "Listing refs via: $cmd"
    $out = Invoke-RcdSsh -Config $Config -RemoteCommand $cmd

    $result = foreach ($line in $out) {
        if (-not $line -or -not $line.Trim()) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -lt 2) {
            Write-RcdWarn "Skipping malformed list line (expected branch<TAB>path): $line"
            continue
        }
        [PSCustomObject]@{ Ref = $parts[0].Trim(); Path = $parts[1].Trim() }
    }
    return @($result)
}
