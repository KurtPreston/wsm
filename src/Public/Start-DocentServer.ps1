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

The dev box (running grove / `wt`) POSTs to 127.0.0.1:<port>/open, reaching this
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
        if ($Token) {
            $provided = Get-DocentBearerToken -Request $req
            if (-not (Test-DocentTokenMatch -Expected $Token -Provided $provided)) {
                Write-DocentWarn "Rejected $method $path from $($req.RemoteEndPoint): bad or missing token"
                Send-DocentResponse -Context $Context -StatusCode 401 -Object @{ ok = $false; error = 'unauthorized' }
                return
            }
        }

        $body = Read-DocentRequestBody -Request $req
        $payload = $null
        try {
            $payload = $body | ConvertFrom-Json
        }
        catch {
            Write-DocentWarn "Bad JSON body: $($_.Exception.Message)"
            Send-DocentResponse -Context $Context -StatusCode 400 -Object @{ ok = $false; error = 'invalid JSON body' }
            return
        }

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

    Send-DocentResponse -Context $Context -StatusCode 404 -Object @{ ok = $false; error = 'not found' }
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
