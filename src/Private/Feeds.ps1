Set-StrictMode -Version Latest

# Row builder for the session dashboard. Produces the grouped-by-ticket payload
# served by GET /sessions, from the union of:
#   1. live Cursor sessions (window enumeration, reconciled with the registry)
#   2. JIRA tickets   (per `jira` source)        -- see Get-DocentJiraTickets
#   3. open GitHub PRs (per `github` source)     -- see Get-DocentGitHubPRs
#
# JIRA/GitHub results are TTL-cached (config.refreshSec); live enumeration is
# always real-time. Each feed degrades independently: a failing source logs a
# warning and contributes nothing rather than failing the whole payload.

# ---------------------------------------------------------------------------
# Live Cursor sessions
# ---------------------------------------------------------------------------

# Parse a Cursor window title into its workspace leaf and (optional) SSH host.
# Remote titles render as:
#   "<leaf> [SSH: <host>] - Cursor"            (no file open)
#   "<file> - <leaf> [SSH: <host>] - Cursor"   (a file is open)
#   "<leaf> - Cursor"                          (transient / local)
# Returns @{ Leaf; Host } (Host $null when not a remote window).
function ConvertFrom-DocentCursorTitle {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Title)

    $result = @{ Leaf = $null; Host = $null }
    if ([string]::IsNullOrWhiteSpace($Title)) { return $result }

    $m = [regex]::Match($Title, '\[SSH:\s*(?<host>[^\]]+)\]')
    if ($m.Success) {
        $result.Host = $m.Groups['host'].Value.Trim()
        $pre = $Title.Substring(0, $m.Index).TrimEnd()
        # The leaf is the last " - "-delimited segment before the [SSH:] marker.
        $segs = $pre -split '\s+-\s+'
        $result.Leaf = $segs[-1].Trim()
        return $result
    }

    # Non-remote / transient: strip a trailing " - Cursor", take the last segment.
    $core = $Title
    if ($core.EndsWith(' - Cursor')) { $core = $core.Substring(0, $core.Length - ' - Cursor'.Length) }
    $segs = $core -split '\s+-\s+'
    $leaf = $segs[-1].Trim()
    if ($leaf -and $leaf -ne 'Cursor') { $result.Leaf = $leaf }
    return $result
}

# Enumerate live Cursor windows (cross-platform) as raw @{ Leaf; Host; Title; Hwnd }.
function Get-DocentLiveCursorWindows {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Config)

    $out = @()
    switch (Get-DocentBackendKind) {
        'windows' {
            foreach ($w in (Get-DocentCursorWindows -Config $Config)) {
                $parsed = ConvertFrom-DocentCursorTitle -Title $w.Title
                if (-not $parsed.Leaf) { continue }
                $out += [PSCustomObject]@{ Leaf = $parsed.Leaf; Host = $parsed.Host; Title = $w.Title; Hwnd = $w.Hwnd }
            }
        }
        'macos' {
            foreach ($t in (Get-DocentMacWindowTitles -Config $Config)) {
                $parsed = ConvertFrom-DocentCursorTitle -Title $t
                if (-not $parsed.Leaf) { continue }
                $out += [PSCustomObject]@{ Leaf = $parsed.Leaf; Host = $parsed.Host; Title = $t; Hwnd = [IntPtr]::Zero }
            }
        }
    }
    return $out
}

# Build the list of session rows: live windows enriched from the registry, plus
# registry records that are NOT live but still need follow-up (so a finished but
# unacknowledged session is never lost just because its window closed).
function Get-DocentSessionRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Config)

    $records = @{}
    foreach ($r in (Get-DocentRegistryRecords -Config $Config)) {
        if ($r -and ($r.PSObject.Properties.Name -contains 'name') -and $r.name) { $records[[string]$r.name] = $r }
    }

    $rows = @()
    $seen = @{}

    # Live windows first (dedupe by leaf/name). A live-enumeration failure must
    # not wipe the registry-derived follow-up rows below, so it is contained.
    $live = @()
    try { $live = @(Get-DocentLiveCursorWindows -Config $Config) }
    catch { Write-DocentWarn "live window enumeration failed: $($_.Exception.Message)" }
    foreach ($w in $live) {
        $name = $w.Leaf
        if ($seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        $rec = if ($records.ContainsKey($name)) { $records[$name] } else { $null }
        $rows += (New-DocentSessionRow -Config $Config -Name $name -Live $true -Host $w.Host -Title $w.Title -Record $rec)
    }

    # Non-live registry records that still need follow-up.
    foreach ($name in $records.Keys) {
        if ($seen.ContainsKey($name)) { continue }
        $rec = $records[$name]
        if (Test-DocentNeedsFollowup -Record $rec) {
            $rows += (New-DocentSessionRow -Config $Config -Name $name -Live $false -Host $null -Title $null -Record $rec)
        }
    }

    return $rows
}

# Assemble a single session row object (the shape consumed by the dashboard).
function New-DocentSessionRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Live,
        [AllowNull()][string]$Host,
        [AllowNull()][string]$Title,
        [AllowNull()]$Record
    )

    $p = if ($Record) { $Record.PSObject.Properties.Name } else { @() }
    $color = if ($Record -and ($p -contains 'color') -and $Record.color) { [string]$Record.color } else { Get-DocentColorForName -Name $Name }
    $fg = if ($Record -and ($p -contains 'fg') -and $Record.fg) { [string]$Record.fg } else { Get-DocentForegroundForHex -Hex $color }
    $colorSource = if ($Record -and ($p -contains 'colorSource') -and $Record.colorSource) { [string]$Record.colorSource } else { 'derived' }
    $ticket = if ($Record -and ($p -contains 'ticket') -and $Record.ticket) { [string]$Record.ticket } else { Resolve-DocentTicketKey -Name $Name -Config $Config }
    $hostVal = if ($Host) { $Host } elseif ($Record -and ($p -contains 'host')) { [string]$Record.host } else { $null }
    $pathVal = if ($Record -and ($p -contains 'path')) { [string]$Record.path } else { $null }

    $needsFollowup = if ($Record) { [bool](Test-DocentNeedsFollowup -Record $Record) } else { $false }
    $status = if ($needsFollowup) { 'needs-followup' } elseif ($Live) { 'idle' } else { 'idle' }

    $lastActivity = $null
    if ($Record) {
        foreach ($f in @('lastAgentStopAt', 'lastShellDoneAt', 'lastFocusedAt', 'lastOpenedAt', 'createdAt')) {
            if (($p -contains $f) -and $Record.$f) { $lastActivity = [string]$Record.$f; break }
        }
    }

    return [PSCustomObject]@{
        kind          = 'session'
        name          = $Name
        host          = $hostVal
        path          = $pathVal
        ticket        = $ticket
        color         = $color
        fg            = $fg
        colorSource   = $colorSource
        title         = $Title
        live          = $Live
        status        = $status
        needsFollowup = $needsFollowup
        lastActivity  = $lastActivity
    }
}

# ---------------------------------------------------------------------------
# Grouping
# ---------------------------------------------------------------------------

# Choose a stable, human-meaningful group key for an item lacking a ticket.
function Get-DocentFallbackGroupKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Item)
    $p = $Item.PSObject.Properties.Name
    if (($p -contains 'name') -and $Item.name) { return "session:$($Item.name)" }
    if (($p -contains 'prNumber') -and $Item.prNumber) { return "pr:$($Item.repo)#$($Item.prNumber)" }
    if (($p -contains 'path') -and $Item.path) { return "path:$($Item.path)" }
    return "item:$([guid]::NewGuid())"
}

# Merge session rows + JIRA tickets + PR rows into ticket groups. Each group:
#   { ticket, key, summary, jiraStatus, jiraUrl, color, fg, needsFollowup,
#     sessions[], prs[] }
# Items with no parseable ticket form single-child groups.
function Group-DocentItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [AllowNull()][object[]]$Sessions,
        [AllowNull()][object[]]$Tickets,
        [AllowNull()][object[]]$Prs
    )

    $groups = [ordered]@{}

    function Get-Group([string]$key) {
        if (-not $groups.Contains($key)) {
            $groups[$key] = [ordered]@{
                key           = $key
                ticket        = $null
                summary       = $null
                jiraStatus    = $null
                jiraUrl       = $null
                color         = $null
                fg            = $null
                needsFollowup = $false
                sessions      = @()
                prs           = @()
            }
        }
        return $groups[$key]
    }

    foreach ($s in @($Sessions)) {
        if (-not $s) { continue }
        $key = if ($s.ticket) { $s.ticket } else { Get-DocentFallbackGroupKey -Item $s }
        $g = Get-Group $key
        if ($s.ticket) { $g.ticket = $s.ticket }
        $g.sessions += $s
        if ($s.needsFollowup) { $g.needsFollowup = $true }
        # Adopt the first session color as the group tint when unset.
        if (-not $g.color -and $s.color) { $g.color = $s.color; $g.fg = $s.fg }
    }

    foreach ($t in @($Tickets)) {
        if (-not $t) { continue }
        $key = if ($t.ticket) { $t.ticket } else { continue }
        $g = Get-Group $key
        $g.ticket = $t.ticket
        $g.summary = $t.summary
        $g.jiraStatus = $t.status
        $g.jiraUrl = $t.url
    }

    foreach ($pr in @($Prs)) {
        if (-not $pr) { continue }
        $key = if ($pr.ticket) { $pr.ticket } else { Get-DocentFallbackGroupKey -Item $pr }
        $g = Get-Group $key
        if ($pr.ticket) { $g.ticket = $pr.ticket }
        $g.prs += $pr
    }

    # Finalize: derive group tint/ticket label, convert to objects.
    $result = @()
    foreach ($k in $groups.Keys) {
        $g = $groups[$k]
        if (-not $g.color) {
            $seed = if ($g.ticket) { $g.ticket } else { $k }
            $g.color = Get-DocentColorForName -Name $seed
            $g.fg = Get-DocentForegroundForHex -Hex $g.color
        }
        $result += [PSCustomObject]$g
    }

    # Sort: groups needing follow-up first, then those with live sessions, then
    # by ticket key for stability.
    return @($result | Sort-Object `
        @{ Expression = { -not $_.needsFollowup } }, `
        @{ Expression = { @($_.sessions | Where-Object { $_.live }).Count -eq 0 } }, `
        @{ Expression = { if ($_.ticket) { $_.ticket } else { $_.key } } })
}

# ---------------------------------------------------------------------------
# JIRA + GitHub feeds (TTL-cached). Implemented in the feeds step; defined here
# so the grouping/endpoint code can call them unconditionally.
# ---------------------------------------------------------------------------

$script:DocentFeedCache = @{}

# Return a cached value for $Key if younger than $TtlSec, else run $Producer,
# cache, and return it. $Producer returning $null is cached as an empty array.
function Get-DocentCachedFeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][int]$TtlSec,
        [Parameter(Mandatory)][scriptblock]$Producer
    )
    $now = Get-Date
    if ($script:DocentFeedCache.ContainsKey($Key)) {
        $entry = $script:DocentFeedCache[$Key]
        if (($now - $entry.At).TotalSeconds -lt $TtlSec) { return $entry.Value }
    }
    $value = & $Producer
    if ($null -eq $value) { $value = @() }
    $script:DocentFeedCache[$Key] = @{ At = $now; Value = $value }
    return $value
}

# Read a token from an env var, checking the process scope first and (on
# Windows) the User scope as a fallback so a token set with
# [Environment]::SetEnvironmentVariable(...,'User') is still picked up even when
# docent was launched without inheriting it.
function Get-DocentEnvToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if (-not $v -and $IsWindows) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    return $v
}

# Locate the `gh` CLI: PATH first, then the per-user portable install location.
function Get-DocentGhExe {
    $cmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($IsWindows) {
        $p = Join-Path $env:LOCALAPPDATA 'Programs/gh/bin/gh.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# JIRA feed: query each `jira` source's JQL and map issues to ticket rows. Auth
# is a Personal Access Token (Server/Data Center) sent as a Bearer header, read
# from the env var named by the source's `tokenEnv` (default DOCENT_JIRA_TOKEN).
function Get-DocentJiraTickets {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Config)

    $ttl = if ($Config.PSObject.Properties.Name -contains 'refreshSec' -and $Config.refreshSec) { [int]$Config.refreshSec } else { 60 }
    $rows = @()

    foreach ($src in (Get-DocentSources -Config $Config -Type jira)) {
        $sp = $src.PSObject.Properties.Name
        $baseUrl = if ($sp -contains 'baseUrl') { ([string]$src.baseUrl).TrimEnd('/') } else { $null }
        $jql = if ($sp -contains 'jql') { [string]$src.jql } else { 'assignee = currentUser() AND status = "In Progress"' }
        $tokenEnv = if ($sp -contains 'tokenEnv' -and $src.tokenEnv) { [string]$src.tokenEnv } else { 'DOCENT_JIRA_TOKEN' }
        $patternOverride = if ($sp -contains 'ticketPattern' -and $src.ticketPattern) { [string]$src.ticketPattern } else { $null }
        if (-not $baseUrl) { Write-DocentWarn "jira source missing baseUrl; skipping."; continue }

        $token = Get-DocentEnvToken -Name $tokenEnv
        if (-not $token) { Write-DocentWarn "jira source '$baseUrl': env var '$tokenEnv' not set; skipping."; continue }

        $cacheKey = "jira:$baseUrl|$jql"
        $issues = Get-DocentCachedFeed -Key $cacheKey -TtlSec $ttl -Producer {
            try {
                $args = @(
                    '-fsS', '-G',
                    '-H', "Authorization: Bearer $token",
                    "$baseUrl/rest/api/2/search",
                    '--data-urlencode', "jql=$jql",
                    '--data-urlencode', 'fields=summary,status',
                    '--data-urlencode', 'maxResults=50'
                )
                $out = & curl.exe @args 2>$null
                if ($LASTEXITCODE -ne 0 -or -not $out) { Write-DocentWarn "jira query failed ($baseUrl): curl exit $LASTEXITCODE"; return @() }
                $parsed = ($out -join "`n") | ConvertFrom-Json
                if ($parsed.PSObject.Properties.Name -contains 'issues') { return @($parsed.issues) }
                return @()
            }
            catch { Write-DocentWarn "jira query error ($baseUrl): $($_.Exception.Message)"; return @() }
        }

        foreach ($iss in $issues) {
            if (-not $iss) { continue }
            $key = [string]$iss.key
            $ticket = Resolve-DocentTicketKey -Name $key -Config $Config -PatternOverride $patternOverride
            if (-not $ticket) { $ticket = $key.ToUpperInvariant() }
            $summary = $null; $status = $null
            if ($iss.PSObject.Properties.Name -contains 'fields' -and $iss.fields) {
                $fp = $iss.fields.PSObject.Properties.Name
                if ($fp -contains 'summary') { $summary = [string]$iss.fields.summary }
                if (($fp -contains 'status') -and $iss.fields.status) { $status = [string]$iss.fields.status.name }
            }
            $rows += [PSCustomObject]@{
                kind   = 'ticket'
                ticket = $ticket
                summary = $summary
                status = $status
                url    = "$baseUrl/browse/$key"
                source = if ($sp -contains 'label') { [string]$src.label } else { $baseUrl }
            }
        }
    }
    return $rows
}

# GitHub feed: open PRs for each `github` source, via the `gh` CLI. `gh search`
# takes its host from GH_HOST (it has no --hostname flag), so we export it for
# the call. The ticket key is derived from the PR title (DRW titles lead with
# the ticket); a PR with no parseable ticket forms its own fallback group.
function Get-DocentGitHubPRs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Config)

    $ttl = if ($Config.PSObject.Properties.Name -contains 'refreshSec' -and $Config.refreshSec) { [int]$Config.refreshSec } else { 60 }
    $gh = Get-DocentGhExe
    $rows = @()

    foreach ($src in (Get-DocentSources -Config $Config -Type github)) {
        $sp = $src.PSObject.Properties.Name
        $ghHost = if ($sp -contains 'host') { [string]$src.host } else { $null }
        $filter = if ($sp -contains 'filter' -and $src.filter) { [string]$src.filter } else { 'author' }
        if ($filter -notin @('author', 'assignee', 'involves')) { $filter = 'author' }
        $patternOverride = if ($sp -contains 'ticketPattern' -and $src.ticketPattern) { [string]$src.ticketPattern } else { $null }
        if (-not $gh) { Write-DocentWarn "github source: 'gh' CLI not found; skipping."; continue }

        $cacheKey = "github:$ghHost|$filter"
        $prs = Get-DocentCachedFeed -Key $cacheKey -TtlSec $ttl -Producer {
            $oldHost = $env:GH_HOST
            if ($ghHost) { $env:GH_HOST = $ghHost }
            try {
                $out = & $gh search prs "--$filter" '@me' --state open --limit 50 --json number,title,url,repository,state,isDraft,createdAt,updatedAt 2>$null
                if ($LASTEXITCODE -ne 0 -or -not $out) { Write-DocentWarn "gh search prs failed (host=$ghHost): exit $LASTEXITCODE"; return @() }
                return @(($out -join "`n") | ConvertFrom-Json)
            }
            catch { Write-DocentWarn "gh search prs error (host=$ghHost): $($_.Exception.Message)"; return @() }
            finally {
                if ($null -eq $oldHost) { Remove-Item Env:\GH_HOST -ErrorAction SilentlyContinue } else { $env:GH_HOST = $oldHost }
            }
        }

        foreach ($pr in $prs) {
            if (-not $pr) { continue }
            $title = [string]$pr.title
            $ticket = Resolve-DocentTicketKey -Name $title -Config $Config -PatternOverride $patternOverride
            $repo = $null
            if ($pr.PSObject.Properties.Name -contains 'repository' -and $pr.repository) {
                $rp = $pr.repository.PSObject.Properties.Name
                $repo = if ($rp -contains 'nameWithOwner') { [string]$pr.repository.nameWithOwner } elseif ($rp -contains 'name') { [string]$pr.repository.name } else { $null }
            }
            $isDraft = ($pr.PSObject.Properties.Name -contains 'isDraft') -and $pr.isDraft
            $rows += [PSCustomObject]@{
                kind     = 'pr'
                ticket   = $ticket
                prNumber = [int]$pr.number
                title    = $title
                url      = [string]$pr.url
                repo     = $repo
                state    = [string]$pr.state
                draft    = [bool]$isDraft
                source   = if ($sp -contains 'label') { [string]$src.label } else { $host }
            }
        }
    }
    return $rows
}

# ---------------------------------------------------------------------------
# Top-level assembler consumed by GET /sessions.
# ---------------------------------------------------------------------------
function Get-DocentDashboard {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Config)

    $sessions = @()
    try { $sessions = @(Get-DocentSessionRows -Config $Config) }
    catch { Write-DocentWarn "session enumeration failed: $($_.Exception.Message)" }

    $tickets = @()
    try { $tickets = @(Get-DocentJiraTickets -Config $Config) }
    catch { Write-DocentWarn "jira feed failed: $($_.Exception.Message)" }

    $prs = @()
    try { $prs = @(Get-DocentGitHubPRs -Config $Config) }
    catch { Write-DocentWarn "github feed failed: $($_.Exception.Message)" }

    $groups = @(Group-DocentItems -Config $Config -Sessions $sessions -Tickets $tickets -Prs $prs)

    return [PSCustomObject]@{
        generatedAt  = (Get-Date).ToUniversalTime().ToString('o')
        backend      = (Get-DocentBackendKind)
        sessionCount = $sessions.Count
        groupCount   = $groups.Count
        groups       = $groups
    }
}
