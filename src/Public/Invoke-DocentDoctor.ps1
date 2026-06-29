Set-StrictMode -Version Latest

<#
.SYNOPSIS
Validate docent's environment and every configured source, printing a per-check
PASS / FAIL / SKIP report. Returns a summary object whose `.ok` is $false when
any check FAILED (the CLI turns that into a non-zero exit).

.DESCRIPTION
Self checks: the listener is bound, a token is configured, Cursor is running, and
the registry is writable. Per source:
  jira       -- GET /rest/api/2/myself with the Bearer token -> display name.
  github     -- `gh auth status` for the host + a trial open-PR search.
  remoteHost -- ssh (key-based) reachable, the reverse tunnel serves /health, and
                docent's hook is present in the remote ~/.cursor/hooks.json.

.EXAMPLE
docent doctor
#>
function Invoke-DocentDoctor {
    [CmdletBinding()]
    param(
        [string]$Config,
        [PSCustomObject]$ConfigObject
    )

    $cfg = if ($ConfigObject) { $ConfigObject } else { Get-DocentConfig -Config $Config }
    $checks = [System.Collections.Generic.List[object]]::new()

    Write-Host ''
    Write-Host 'docent doctor' -ForegroundColor Cyan
    if ($cfg._path) { Write-Host "  config: $($cfg._path)" -ForegroundColor DarkGray }
    else { Write-Host '  config: <defaults>' -ForegroundColor DarkGray }

    Write-Host ''
    Write-Host '  self' -ForegroundColor Cyan
    foreach ($c in (Test-DocentSelf -Config $cfg)) { Add-DocentCheck -Checks $checks -Check $c }

    Write-Host ''
    Write-Host '  sources' -ForegroundColor Cyan
    $sources = @(if ($cfg.PSObject.Properties.Name -contains 'sources') { $cfg.sources } else { @() })
    if ($sources.Count -eq 0) {
        Add-DocentCheck -Checks $checks -Check (New-DocentCheck -Name 'sources' -Status 'SKIP' -Detail 'no sources configured')
    }
    foreach ($src in $sources) {
        $type = if ($src.PSObject.Properties.Name -contains 'type') { [string]$src.type } else { '?' }
        switch ($type) {
            'jira' { Add-DocentCheck -Checks $checks -Check (Test-DocentJiraSource -Config $cfg -Source $src) }
            'github' { Add-DocentCheck -Checks $checks -Check (Test-DocentGithubSource -Config $cfg -Source $src) }
            'remoteHost' { foreach ($c in (Test-DocentRemoteHostSource -Config $cfg -Source $src)) { Add-DocentCheck -Checks $checks -Check $c } }
            default { Add-DocentCheck -Checks $checks -Check (New-DocentCheck -Name "source($type)" -Status 'SKIP' -Detail 'unknown source type') }
        }
    }

    $failed = @($checks | Where-Object { $_.status -eq 'FAIL' })
    $passed = @($checks | Where-Object { $_.status -eq 'PASS' })
    $skipped = @($checks | Where-Object { $_.status -eq 'SKIP' })

    Write-Host ''
    $summaryColor = if ($failed.Count -gt 0) { 'Red' } else { 'Green' }
    Write-Host "  $($passed.Count) passed, $($failed.Count) failed, $($skipped.Count) skipped" -ForegroundColor $summaryColor
    Write-Host ''

    return [PSCustomObject]@{
        ok      = ($failed.Count -eq 0)
        passed  = $passed.Count
        failed  = $failed.Count
        skipped = $skipped.Count
        checks  = @($checks)
    }
}

function New-DocentCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Status,
        [string]$Detail
    )
    [PSCustomObject]@{ name = $Name; status = $Status; detail = $Detail }
}

function Add-DocentCheck {
    param(
        [System.Collections.Generic.List[object]]$Checks,
        [Parameter(Mandatory)][PSCustomObject]$Check
    )
    $Checks.Add($Check)
    $color = switch ($Check.status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'SKIP' { 'DarkGray' } }
    Write-Host ("    [{0}] {1}  {2}" -f $Check.status.PadRight(4), $Check.name, $Check.detail) -ForegroundColor $color
}

# --- self ---
function Test-DocentSelf {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Config)
    $out = @()
    $port = if ($Config.port) { [int]$Config.port } else { 39787 }

    # listener bound
    $health = $null
    try { $health = (& curl.exe -fsS --max-time 3 "http://127.0.0.1:$port/health" 2>$null) } catch { }
    if ($health -match 'ok') { $out += New-DocentCheck -Name 'listener' -Status 'PASS' -Detail "http://127.0.0.1:$port/health -> ok" }
    else { $out += New-DocentCheck -Name 'listener' -Status 'FAIL' -Detail "no response on 127.0.0.1:$port (is 'docent serve' running?)" }

    # token configured
    $token = if ($env:DOCENT_TOKEN) { $env:DOCENT_TOKEN } elseif ($Config.token) { [string]$Config.token } else { $null }
    if ($token) { $out += New-DocentCheck -Name 'token' -Status 'PASS' -Detail 'shared-secret configured' }
    else { $out += New-DocentCheck -Name 'token' -Status 'SKIP' -Detail 'no token set (POST /open and /event are unauthenticated)' }

    # Cursor running
    $procName = if ($Config.processName) { [string]$Config.processName } else { 'Cursor' }
    $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) { $out += New-DocentCheck -Name 'cursor' -Status 'PASS' -Detail "$($procs.Count) '$procName' process(es)" }
    else { $out += New-DocentCheck -Name 'cursor' -Status 'SKIP' -Detail "no '$procName' process detected" }

    # registry writable
    try {
        $rp = Get-DocentRegistryPath -Config $Config
        $dir = Split-Path -Parent $rp
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $probe = Join-Path $dir ".docent-probe-$PID"
        Set-Content -LiteralPath $probe -Value 'ok' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -ErrorAction SilentlyContinue
        $out += New-DocentCheck -Name 'registry' -Status 'PASS' -Detail $rp
    }
    catch { $out += New-DocentCheck -Name 'registry' -Status 'FAIL' -Detail "not writable: $($_.Exception.Message)" }

    return $out
}

# --- jira ---
function Test-DocentJiraSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)]$Source
    )
    $sp = $Source.PSObject.Properties.Name
    $label = if ($sp -contains 'label') { [string]$Source.label } else { 'jira' }
    $name = "jira($label)"
    $baseUrl = if ($sp -contains 'baseUrl') { ([string]$Source.baseUrl).TrimEnd('/') } else { $null }
    if (-not $baseUrl) { return New-DocentCheck -Name $name -Status 'FAIL' -Detail 'missing baseUrl' }
    $tokenEnv = if ($sp -contains 'tokenEnv' -and $Source.tokenEnv) { [string]$Source.tokenEnv } else { 'DOCENT_JIRA_TOKEN' }
    $token = Get-DocentEnvToken -Name $tokenEnv
    if (-not $token) { return New-DocentCheck -Name $name -Status 'SKIP' -Detail "env '$tokenEnv' not set" }

    try {
        $out = & curl.exe -fsS --max-time 10 -H "Authorization: Bearer $token" "$baseUrl/rest/api/2/myself" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return New-DocentCheck -Name $name -Status 'FAIL' -Detail "$baseUrl unreachable or 401 (curl exit $LASTEXITCODE)" }
        $me = ($out -join "`n") | ConvertFrom-Json
        $who = if ($me.PSObject.Properties.Name -contains 'displayName') { $me.displayName } else { $me.name }
        return New-DocentCheck -Name $name -Status 'PASS' -Detail "authenticated as $who"
    }
    catch { return New-DocentCheck -Name $name -Status 'FAIL' -Detail $_.Exception.Message }
}

# --- github ---
function Test-DocentGithubSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)]$Source
    )
    $sp = $Source.PSObject.Properties.Name
    $label = if ($sp -contains 'label') { [string]$Source.label } else { 'github' }
    $name = "github($label)"
    $ghHost = if ($sp -contains 'host') { [string]$Source.host } else { $null }
    if (-not $ghHost) { return New-DocentCheck -Name $name -Status 'FAIL' -Detail 'missing host' }
    $gh = Get-DocentGhExe
    if (-not $gh) { return New-DocentCheck -Name $name -Status 'FAIL' -Detail "'gh' CLI not found on PATH" }

    try {
        $status = & $gh auth status --hostname $ghHost 2>&1
        if ($LASTEXITCODE -ne 0) { return New-DocentCheck -Name $name -Status 'FAIL' -Detail "gh not authenticated for $ghHost (gh auth login --hostname $ghHost)" }
        # Trial PR search to confirm search works against this host.
        $old = $env:GH_HOST; $env:GH_HOST = $ghHost
        try { & $gh search prs --author '@me' --state open --limit 1 --json number 2>$null | Out-Null; $searchCode = $LASTEXITCODE }
        finally { if ($null -eq $old) { Remove-Item Env:\GH_HOST -ErrorAction SilentlyContinue } else { $env:GH_HOST = $old } }
        if ($searchCode -ne 0) { return New-DocentCheck -Name $name -Status 'FAIL' -Detail "authenticated, but PR search failed (exit $searchCode)" }
        return New-DocentCheck -Name $name -Status 'PASS' -Detail "authenticated to $ghHost; PR search ok"
    }
    catch { return New-DocentCheck -Name $name -Status 'FAIL' -Detail $_.Exception.Message }
}

# --- remoteHost ---
function Test-DocentRemoteHostSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)]$Source
    )
    $sp = $Source.PSObject.Properties.Name
    $label = if ($sp -contains 'label') { [string]$Source.label } else { 'remoteHost' }
    $rhost = if ($sp -contains 'host') { [string]$Source.host } else { $null }
    $port = if ($Config.port) { [int]$Config.port } else { 39787 }
    $out = @()
    if (-not $rhost) { return @(New-DocentCheck -Name "remoteHost($label)" -Status 'FAIL' -Detail 'missing host') }

    # ssh reachable (key-based)
    $sshOk = $false
    try {
        $r = (& ssh -o BatchMode=yes -o ConnectTimeout=10 $rhost 'echo docent-ok' 2>&1)
        $code = $LASTEXITCODE
        $clean = @($r | Where-Object { $_ -notmatch 'remote port forwarding failed' })
        if ($code -eq 0 -and ($clean -join '') -match 'docent-ok') {
            $sshOk = $true
            $out += New-DocentCheck -Name "ssh($label)" -Status 'PASS' -Detail "$rhost reachable (key-based)"
        }
        else { $out += New-DocentCheck -Name "ssh($label)" -Status 'FAIL' -Detail "ssh $rhost failed: $($clean -join '; ')" }
    }
    catch { $out += New-DocentCheck -Name "ssh($label)" -Status 'FAIL' -Detail $_.Exception.Message }

    if (-not $sshOk) {
        $out += New-DocentCheck -Name "tunnel($label)" -Status 'SKIP' -Detail 'ssh unreachable'
        $out += New-DocentCheck -Name "hook($label)" -Status 'SKIP' -Detail 'ssh unreachable'
        return $out
    }

    # reverse tunnel: remote -> workstation docent /health
    try {
        $r = (& ssh -o BatchMode=yes -o ConnectTimeout=10 $rhost "curl -fsS --max-time 5 http://127.0.0.1:$port/health" 2>&1)
        $clean = @($r | Where-Object { $_ -notmatch 'remote port forwarding failed' })
        if (($clean -join '') -match 'ok') { $out += New-DocentCheck -Name "tunnel($label)" -Status 'PASS' -Detail "reverse path -> docent /health ok" }
        else { $out += New-DocentCheck -Name "tunnel($label)" -Status 'FAIL' -Detail "remote curl 127.0.0.1:$port/health failed (tunnel down?)" }
    }
    catch { $out += New-DocentCheck -Name "tunnel($label)" -Status 'FAIL' -Detail $_.Exception.Message }

    # docent hook present in remote hooks.json
    try {
        $r = (& ssh -o BatchMode=yes -o ConnectTimeout=10 $rhost 'grep -q docent-notify.sh "$HOME/.cursor/hooks.json" 2>/dev/null && echo present || echo absent' 2>&1)
        $clean = @($r | Where-Object { $_ -notmatch 'remote port forwarding failed' })
        if (($clean -join '') -match 'present') { $out += New-DocentCheck -Name "hook($label)" -Status 'PASS' -Detail 'docent hook present in ~/.cursor/hooks.json' }
        else { $out += New-DocentCheck -Name "hook($label)" -Status 'FAIL' -Detail "docent hook not installed (run: docent install-hooks -Host $rhost)" }
    }
    catch { $out += New-DocentCheck -Name "hook($label)" -Status 'FAIL' -Detail $_.Exception.Message }

    return $out
}
