Set-StrictMode -Version Latest

<#
.SYNOPSIS
Start the docent webhook receiver: a localhost-only HTTP server that brings the
right remote Cursor workspace into focus on this machine.

.DESCRIPTION
Binds a System.Net.HttpListener to http://127.0.0.1:<port>/ (127.0.0.1 ONLY --
never a public interface). Routes:
  GET  /health  -> 200 "ok"
  POST /open    -> parse JSON {host, path, name}, run the open-or-focus handler,
                   return 200 + a small JSON result (4xx bad body, 5xx failure).

The dev box (running grove) POSTs to 127.0.0.1:<port>/open, reaching this
machine through a reverse SSH tunnel (RemoteForward). All logs go to stderr;
honor DOCENT_LOG_LEVEL.

.EXAMPLE
Start-DocentServer
Start-DocentServer -Port 39787
#>
function Start-DocentServer {
    [CmdletBinding()]
    param(
        [int]$Port,
        [string]$Config
    )

    $cfg = Get-DocentConfig -Config $Config
    $resolvedPort = if ($Port) { $Port } elseif ($cfg.port) { [int]$cfg.port } else { 39787 }
    $prefix = "http://127.0.0.1:$resolvedPort/"

    # Optional shared secret. $env:DOCENT_TOKEN wins over config 'token' so the
    # secret can stay out of the config file. When unset, POST /open is open to
    # anything that can reach the loopback port (incl. the reverse SSH tunnel).
    $token = if ($env:DOCENT_TOKEN) { $env:DOCENT_TOKEN } elseif ($cfg.token) { [string]$cfg.token } else { $null }

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)

    try {
        $listener.Start()
    }
    catch {
        throw "Failed to bind $prefix : $($_.Exception.Message)"
    }

    Write-DocentInfo "docent serving on $prefix (backend: $(Get-DocentBackendKind))"
    if ($cfg._path) { Write-DocentInfo "config: $($cfg._path)" } else { Write-DocentInfo "config: <defaults>" }
    if ($token) {
        Write-DocentInfo "auth: shared-secret token required for POST /open"
    }
    else {
        Write-DocentWarn "auth: no token set (DOCENT_TOKEN or config 'token'); POST /open is unauthenticated"
    }

    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            try {
                Invoke-DocentRequest -Context $context -Config $cfg -Token $token
            }
            catch {
                Write-DocentError "Unhandled request error: $($_.Exception.Message)"
                try { Send-DocentResponse -Context $context -StatusCode 500 -Object @{ ok = $false; error = $_.Exception.Message } } catch { }
            }
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
        Write-DocentInfo "docent stopped."
    }
}

# Route a single HttpListener request.
function Invoke-DocentRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [AllowNull()][AllowEmptyString()][string]$Token
    )

    $req = $Context.Request
    $method = $req.HttpMethod
    $path = $req.Url.AbsolutePath
    Write-DocentDebug "$method $path from $($req.RemoteEndPoint)"

    # /health stays unauthenticated so the tunnel can be probed for liveness.
    if ($method -eq 'GET' -and $path -eq '/health') {
        Send-DocentResponse -Context $Context -StatusCode 200 -Text 'ok'
        return
    }

    if ($method -eq 'POST' -and $path -eq '/open') {
        if (-not (Approve-DocentRequest -Request $req -Token $Token -Context $Context -Route "$method $path")) { return }

        $payload = Read-DocentJsonBody -Request $req -Context $Context
        if ($null -eq $payload) { return }

        $h = if ($payload.PSObject.Properties.Name -contains 'host') { [string]$payload.host } else { $null }
        $p = if ($payload.PSObject.Properties.Name -contains 'path') { [string]$payload.path } else { $null }
        $n = if ($payload.PSObject.Properties.Name -contains 'name') { [string]$payload.name } else { $null }

        if (-not $h -or -not $p) {
            Send-DocentResponse -Context $Context -StatusCode 400 -Object @{ ok = $false; error = 'body must include non-empty {host, path}' }
            return
        }

        try {
            $result = Open-DocentWorkspace -Host $h -Path $p -Name $n -ConfigObject $Config
            Send-DocentResponse -Context $Context -StatusCode 200 -Object @{
                ok     = $true
                action = $result.Action
                host   = $result.Host
                path   = $result.Path
                name   = $result.Name
                uri    = $result.Uri
            }
        }
        catch {
            Write-DocentError "open failed: $($_.Exception.Message)"
            Send-DocentResponse -Context $Context -StatusCode 500 -Object @{ ok = $false; error = $_.Exception.Message }
        }
        return
    }

    # POST /event -- a Cursor hook reports session activity (and, on session
    # start, the exact title-bar color). Token-authenticated like /open.
    if ($method -eq 'POST' -and $path -eq '/event') {
        if (-not (Approve-DocentRequest -Request $req -Token $Token -Context $Context -Route "$method $path")) { return }

        $payload = Read-DocentJsonBody -Request $req -Context $Context
        if ($null -eq $payload) { return }

        $props = $payload.PSObject.Properties.Name
        $name = if ($props -contains 'name') { [string]$payload.name } else { $null }
        $epath = if ($props -contains 'path') { [string]$payload.path } else { $null }
        $kind = if ($props -contains 'kind') { [string]$payload.kind } else { $null }
        $color = if ($props -contains 'color') { [string]$payload.color } else { $null }
        $convId = if ($props -contains 'conversationId') { [string]$payload.conversationId } else { $null }
        $ehost = if ($props -contains 'host') { [string]$payload.host } else { $null }

        if (-not $name -and $epath) { $name = Get-DocentLeafName -Path $epath }
        if (-not $name) {
            Send-DocentResponse -Context $Context -StatusCode 400 -Object @{ ok = $false; error = 'event must include name or path' }
            return
        }
        $validKinds = @('agent-stop', 'session-start', 'session-end', 'shell-done')
        if (-not $kind -or ($validKinds -notcontains $kind)) {
            Send-DocentResponse -Context $Context -StatusCode 400 -Object @{ ok = $false; error = "kind must be one of: $($validKinds -join ', ')" }
            return
        }

        try {
            Set-DocentSessionEvent -Config $Config -Name $name -Kind $kind -Host $ehost -Path $epath -Color $color -ConversationId $convId
            Send-DocentResponse -Context $Context -StatusCode 200 -Object @{ ok = $true; name = $name; kind = $kind }
        }
        catch {
            Write-DocentError "event failed: $($_.Exception.Message)"
            Send-DocentResponse -Context $Context -StatusCode 500 -Object @{ ok = $false; error = $_.Exception.Message }
        }
        return
    }

    # GET /sessions -- the grouped-by-ticket dashboard payload. Localhost-only,
    # like the dashboard it feeds; left unauthenticated so the browser can poll.
    if ($method -eq 'GET' -and $path -eq '/sessions') {
        try {
            $data = Get-DocentDashboard -Config $Config
            Send-DocentResponse -Context $Context -StatusCode 200 -Object $data
        }
        catch {
            Write-DocentError "sessions failed: $($_.Exception.Message)"
            Send-DocentResponse -Context $Context -StatusCode 500 -Object @{ ok = $false; error = $_.Exception.Message }
        }
        return
    }

    # POST /focus -- bring a session's window to the foreground by name.
    if ($method -eq 'POST' -and $path -eq '/focus') {
        $payload = Read-DocentJsonBody -Request $req -Context $Context
        if ($null -eq $payload) { return }
        $n = if ($payload.PSObject.Properties.Name -contains 'name') { [string]$payload.name } else { $null }
        $fhost = if ($payload.PSObject.Properties.Name -contains 'host') { [string]$payload.host } else { $null }
        if (-not $n) {
            Send-DocentResponse -Context $Context -StatusCode 400 -Object @{ ok = $false; error = 'body must include {name}' }
            return
        }
        try {
            $result = if ($fhost) { Focus-DocentWorkspace -Name $n -Host $fhost -ConfigObject $Config }
            else { Focus-DocentWorkspace -Name $n -ConfigObject $Config }
            if ($result.Action -eq 'none') {
                Send-DocentResponse -Context $Context -StatusCode 404 -Object @{ ok = $false; action = 'none'; name = $n }
            }
            else {
                Send-DocentResponse -Context $Context -StatusCode 200 -Object @{ ok = $true; action = $result.Action; name = $result.Name }
            }
        }
        catch {
            Write-DocentError "focus failed: $($_.Exception.Message)"
            Send-DocentResponse -Context $Context -StatusCode 500 -Object @{ ok = $false; error = $_.Exception.Message }
        }
        return
    }

    # GET / and /dashboard (+ static assets) -- serve the web dashboard.
    if ($method -eq 'GET') {
        $rel = if ($path -eq '/' -or $path -eq '/dashboard' -or $path -eq '/dashboard/') { 'index.html' } else { $path.TrimStart('/') }
        if (Send-DocentStaticFile -Context $Context -RelativePath $rel) { return }
    }

    Send-DocentResponse -Context $Context -StatusCode 404 -Object @{ ok = $false; error = 'not found' }
}

# Enforce the shared-secret token (when configured) for a request. Returns
# $true to proceed, or sends a 401 and returns $false.
function Approve-DocentRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [string]$Route
    )
    if (-not $Token) { return $true }
    $provided = Get-DocentBearerToken -Request $Request
    if (Test-DocentTokenMatch -Expected $Token -Provided $provided) { return $true }
    Write-DocentWarn "Rejected $Route from $($Request.RemoteEndPoint): bad or missing token"
    Send-DocentResponse -Context $Context -StatusCode 401 -Object @{ ok = $false; error = 'unauthorized' }
    return $false
}

# Read + parse a JSON request body. On bad JSON, sends a 400 and returns $null.
function Read-DocentJsonBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request,
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context
    )
    $body = Read-DocentRequestBody -Request $Request
    try { return ($body | ConvertFrom-Json) }
    catch {
        Write-DocentWarn "Bad JSON body: $($_.Exception.Message)"
        Send-DocentResponse -Context $Context -StatusCode 400 -Object @{ ok = $false; error = 'invalid JSON body' }
        return $null
    }
}

# Serve a file from the bundled web/ directory. Returns $true when served (any
# status), $false when the file is outside web/ or absent (so the caller 404s).
function Send-DocentStaticFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $webRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../web') -ErrorAction SilentlyContinue)
    if (-not $webRoot) { return $false }
    $webRoot = $webRoot.Path

    # Resolve and contain the request within web/ (block path traversal).
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $webRoot $RelativePath))
    $rootWithSep = [System.IO.Path]::GetFullPath($webRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not ($candidate + [System.IO.Path]::DirectorySeparatorChar).StartsWith($rootWithSep, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($rootWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $false }

    $bytes = [System.IO.File]::ReadAllBytes($candidate)
    $resp = $Context.Response
    $resp.ContentType = Get-DocentContentType -Path $candidate
    $resp.StatusCode = 200
    $resp.ContentLength64 = $bytes.Length
    try { $resp.OutputStream.Write($bytes, 0, $bytes.Length) }
    finally { $resp.OutputStream.Close() }
    return $true
}

# Minimal extension -> content-type map for the static dashboard assets.
function Get-DocentContentType {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { 'text/html; charset=utf-8' }
        '.htm' { 'text/html; charset=utf-8' }
        '.css' { 'text/css; charset=utf-8' }
        '.js' { 'text/javascript; charset=utf-8' }
        '.mjs' { 'text/javascript; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.svg' { 'image/svg+xml' }
        '.png' { 'image/png' }
        '.ico' { 'image/x-icon' }
        '.woff2' { 'font/woff2' }
        default { 'application/octet-stream' }
    }
}

# Extract the token from an `Authorization: Bearer <token>` header, or $null.
function Get-DocentBearerToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request)

    $header = $Request.Headers['Authorization']
    if (-not $header) { return $null }
    if ($header -match '^(?i:Bearer)\s+(.+)$') { return $Matches[1].Trim() }
    return $null
}

# Constant-time string comparison: avoids leaking the secret via response timing.
# Compares every byte regardless of where a mismatch occurs (length is also
# folded in so unequal lengths can never short-circuit).
function Test-DocentTokenMatch {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Expected,
        [AllowNull()][AllowEmptyString()][string]$Provided
    )

    if ([string]::IsNullOrEmpty($Expected) -or [string]::IsNullOrEmpty($Provided)) { return $false }

    $a = [System.Text.Encoding]::UTF8.GetBytes($Expected)
    $b = [System.Text.Encoding]::UTF8.GetBytes($Provided)
    $diff = $a.Length -bxor $b.Length
    $max = [Math]::Max($a.Length, $b.Length)
    for ($i = 0; $i -lt $max; $i++) {
        $x = if ($i -lt $a.Length) { $a[$i] } else { 0 }
        $y = if ($i -lt $b.Length) { $b[$i] } else { 0 }
        $diff = $diff -bor ($x -bxor $y)
    }
    return ($diff -eq 0)
}

# Read the full request body as a string using the request's content encoding.
function Read-DocentRequestBody {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request)

    if (-not $Request.HasEntityBody) { return '' }
    $encoding = if ($Request.ContentEncoding) { $Request.ContentEncoding } else { [System.Text.Encoding]::UTF8 }
    $reader = [System.IO.StreamReader]::new($Request.InputStream, $encoding)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}

# Write a response. Provide either -Text (text/plain) or -Object (JSON).
function Send-DocentResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][int]$StatusCode,
        [string]$Text,
        $Object
    )

    $resp = $Context.Response
    if ($PSBoundParameters.ContainsKey('Object')) {
        $payload = ($Object | ConvertTo-Json -Compress -Depth 6)
        $resp.ContentType = 'application/json'
    }
    else {
        $payload = $Text
        $resp.ContentType = 'text/plain'
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $resp.StatusCode = $StatusCode
    $resp.ContentLength64 = $bytes.Length
    try {
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $resp.OutputStream.Close()
    }
}
