Set-StrictMode -Version Latest

<#
.SYNOPSIS
Bootstrap docent's dashboard configuration: detect the local environment (SSH
hosts, authenticated `gh` hosts, a JIRA token), scaffold a `sources` config, then
run `docent doctor` and report what still needs attention.

.DESCRIPTION
- No config yet  -> writes ./docent.config.jsonc pre-filled with detected sources.
- Config without `sources` -> prints a ready-to-paste `sources` block (the file
  is NOT modified, to preserve your comments/formatting).
- Config already has `sources` -> leaves it alone.
Finishes by running doctor so you immediately see which sources are wired up.

.EXAMPLE
docent init
#>
function Initialize-Docent {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Config,
        [PSCustomObject]$ConfigObject
    )

    Write-Host ''
    Write-Host 'docent init' -ForegroundColor Cyan

    # Detect environment.
    $sshHosts = @(Get-DocentDetectedSshHosts)
    $ghHosts = @(Get-DocentDetectedGhHosts)
    $jiraToken = Get-DocentEnvToken -Name 'DOCENT_JIRA_TOKEN'

    Write-Host ''
    Write-Host '  detected:' -ForegroundColor Cyan
    Write-Host ("    ssh hosts : {0}" -f $(if ($sshHosts.Count) { $sshHosts -join ', ' } else { '<none in ~/.ssh/config>' })) -ForegroundColor DarkGray
    Write-Host ("    gh hosts  : {0}" -f $(if ($ghHosts.Count) { $ghHosts -join ', ' } else { '<none authenticated>' })) -ForegroundColor DarkGray
    Write-Host ("    jira token: {0}" -f $(if ($jiraToken) { 'DOCENT_JIRA_TOKEN set' } else { '<DOCENT_JIRA_TOKEN not set>' })) -ForegroundColor DarkGray

    $scaffold = New-DocentSourcesScaffold -SshHosts $sshHosts -GhHosts $ghHosts -HasJiraToken:([bool]$jiraToken)

    # Decide what to do with the config file.
    $existingPath = $null
    try { $existingPath = Get-DocentConfigPath -Config $Config } catch { $existingPath = $null }

    Write-Host ''
    if (-not $existingPath) {
        $target = if ($Config) { $Config } else { Join-Path (Get-Location) 'docent.config.jsonc' }
        $content = New-DocentConfigScaffold -SourcesBlock $scaffold
        if ($PSCmdlet.ShouldProcess($target, 'write scaffolded docent config')) {
            Set-Content -LiteralPath $target -Value $content -Encoding utf8
            Write-Host "  created $target" -ForegroundColor Green
        }
        $cfgForDoctor = $target
    }
    else {
        Write-Host "  config: $existingPath" -ForegroundColor DarkGray
        $cfg = Get-DocentConfig -Config $existingPath
        $hasSources = ($cfg.PSObject.Properties.Name -contains 'sources') -and @($cfg.sources).Count -gt 0
        if ($hasSources) {
            Write-Host "  sources already configured ($(@($cfg.sources).Count) source(s)); leaving config untouched." -ForegroundColor Green
        }
        else {
            Write-Host '  config has no `sources`. Add this block (inside the top-level object):' -ForegroundColor Yellow
            Write-Host ''
            Write-Host $scaffold -ForegroundColor Gray
        }
        $cfgForDoctor = $existingPath
    }

    # Report gaps via doctor.
    Write-Host ''
    Write-Host '  running doctor...' -ForegroundColor Cyan
    $report = $null
    try { $report = Invoke-DocentDoctor -Config $cfgForDoctor }
    catch { Write-DocentWarn "doctor could not run: $($_.Exception.Message)" }

    if ($report) {
        $failed = @($report.checks | Where-Object { $_.status -eq 'FAIL' })
        if ($failed.Count -gt 0) {
            Write-Host '  next steps:' -ForegroundColor Yellow
            foreach ($f in $failed) { Write-Host "    - $($f.name): $($f.detail)" -ForegroundColor Yellow }
        }
        else {
            Write-Host '  all configured checks pass.' -ForegroundColor Green
        }
    }
    return $report
}

# Host aliases from ~/.ssh/config (excludes wildcard patterns).
function Get-DocentDetectedSshHosts {
    $cfg = if ($HOME) { Join-Path $HOME '.ssh/config' } else { $null }
    if (-not $cfg -or -not (Test-Path -LiteralPath $cfg)) { return @() }
    $hosts = @()
    foreach ($line in (Get-Content -LiteralPath $cfg)) {
        if ($line -match '^\s*Host\s+(.+)$') {
            foreach ($h in ($Matches[1] -split '\s+')) {
                if ($h -and $h -notmatch '[*?]') { $hosts += $h }
            }
        }
    }
    return ($hosts | Select-Object -Unique)
}

# Hosts that `gh` is authenticated to (parsed from `gh auth status`).
function Get-DocentDetectedGhHosts {
    $gh = Get-DocentGhExe
    if (-not $gh) { return @() }
    try {
        $out = & $gh auth status 2>&1
        $hosts = @()
        foreach ($line in $out) {
            if ($line -match 'Logged in to (\S+)') { $hosts += $Matches[1] }
        }
        return ($hosts | Select-Object -Unique)
    }
    catch { return @() }
}

# Build a JSONC `sources` block string from detected values, with helpful
# placeholders where a value could not be inferred.
function New-DocentSourcesScaffold {
    param(
        [string[]]$SshHosts,
        [string[]]$GhHosts,
        [bool]$HasJiraToken
    )

    $entries = @()

    $jiraBase = if ($GhHosts -and ($GhHosts -join ' ') -match '([\w.-]*drwholdings[\w.-]*)') { 'https://jira.drwholdings.com' } else { 'https://jira.example.com' }
    $jiraComment = if ($HasJiraToken) { '' } else { ' // TODO: set DOCENT_JIRA_TOKEN (a JIRA PAT) in your environment' }
    $entries += @"
    {
      "type": "jira",
      "label": "jira",
      "baseUrl": "$jiraBase",
      "jql": "assignee = currentUser() AND status = \"In Progress\"",
      "tokenEnv": "DOCENT_JIRA_TOKEN"$jiraComment
    }
"@

    $ghHost = if ($GhHosts -and $GhHosts.Count -gt 0) { $GhHosts[0] } else { 'github.com' }
    $ghComment = if ($GhHosts -and $GhHosts.Count -gt 0) { '' } else { ' // TODO: gh auth login --hostname <host>' }
    $entries += @"
    {
      "type": "github",
      "label": "github",
      "host": "$ghHost",
      "filter": "author"$ghComment
    }
"@

    if ($SshHosts -and $SshHosts.Count -gt 0) {
        foreach ($h in $SshHosts) {
            $entries += @"
    {
      "type": "remoteHost",
      "label": "$h",
      "host": "$h"
    }
"@
        }
    }
    else {
        $entries += @"
    {
      "type": "remoteHost",
      "label": "devbox",
      "host": "your-ssh-alias" // TODO: an alias from ~/.ssh/config
    }
"@
    }

    return "  `"sources`": [`n" + ($entries -join ",`n") + "`n  ]"
}

# Wrap a sources block in a minimal, fully-commented config file.
function New-DocentConfigScaffold {
    param([Parameter(Mandatory)][string]$SourcesBlock)

    return @"
// docent configuration (scaffolded by 'docent init').
// See docent.config.example.jsonc for every available option.
{
  // Shared secret required for POST /open and POST /event. Generate one and set
  // the same value as DOCENT_TOKEN in the environment, or leave commented for an
  // unauthenticated localhost-only setup.
  // "token": "<random-secret>",

  // Reverse-tunnel / listener port (must match your SSH RemoteForward).
  "port": 39787,

  // Turn a worktree/branch/PR name into a ticket key (first group, upper-cased).
  "ticketPattern": "^([a-z]+-\\d+)",

  // Seconds the JIRA/GitHub feeds are cached before GET /sessions refreshes them.
  "refreshSec": 60,

$SourcesBlock
}
"@
}
