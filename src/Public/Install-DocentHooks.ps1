Set-StrictMode -Version Latest

<#
.SYNOPSIS
Install (or refresh) the docent Cursor hook on each `remoteHost` source's dev box
over SSH, so finished turns / shell commands / session starts report back to
docent through the reverse tunnel.

.DESCRIPTION
For every `remoteHost` source in the config (or just -Host when given), docent
SSHes out -- the SAME workstation->devbox direction that already creates the
reverse tunnel, key-based -- and idempotently:
  1. ensures ~/.cursor/hooks exists and copies hooks/docent-notify.sh there,
  2. drops a mode-600 ~/.cursor/docent-token (the shared secret the hook sends),
  3. MERGES the docent entries into ~/.cursor/hooks.json (stop / sessionStart /
     sessionEnd / afterShellExecution), preserving every other existing hook.

Re-runnable: existing docent entries are replaced (not duplicated) and unrelated
hooks are untouched. Runtime needs no SSH-out; this is setup only.

.EXAMPLE
docent install-hooks
docent install-hooks -Host desktop
#>
function Install-DocentHooks {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Alias('h')][string]$Host,
        [string]$Config,
        [PSCustomObject]$ConfigObject,
        # Override where on the remote the hooks.json lives (testing).
        [string]$RemoteHooksFile = '$HOME/.cursor/hooks.json'
    )

    $cfg = if ($ConfigObject) { $ConfigObject } else { Get-DocentConfig -Config $Config }

    $hookScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../hooks/docent-notify.sh') -ErrorAction SilentlyContinue)
    if (-not $hookScript) { throw "Cannot find hooks/docent-notify.sh next to the module." }
    $hookScript = $hookScript.Path

    $token = if ($env:DOCENT_TOKEN) { $env:DOCENT_TOKEN } elseif ($cfg.token) { [string]$cfg.token } else { $null }

    $targets = @()
    if ($Host) {
        $targets += [PSCustomObject]@{ host = $Host; label = $Host }
    }
    else {
        foreach ($s in (Get-DocentSources -Config $cfg -Type remoteHost)) {
            $sp = $s.PSObject.Properties.Name
            if ($sp -notcontains 'host' -or -not $s.host) { continue }
            $targets += [PSCustomObject]@{ host = [string]$s.host; label = if ($sp -contains 'label') { [string]$s.label } else { [string]$s.host } }
        }
    }
    if ($targets.Count -eq 0) { throw "No remoteHost sources configured (and no -Host given)." }

    $results = @()
    foreach ($t in $targets) {
        Write-DocentInfo "install-hooks: $($t.label) ($($t.host))"
        if (-not $PSCmdlet.ShouldProcess($t.host, 'install docent Cursor hook')) { continue }
        try {
            Install-DocentHookOnHost -RemoteHost $t.host -HookScriptPath $hookScript -Token $token -RemoteHooksFile $RemoteHooksFile
            $results += [PSCustomObject]@{ host = $t.host; ok = $true }
        }
        catch {
            Write-DocentError "install-hooks failed for $($t.host): $($_.Exception.Message)"
            $results += [PSCustomObject]@{ host = $t.host; ok = $false; error = $_.Exception.Message }
        }
    }
    return $results
}

# Run the per-host install: scp the script, drop the token, merge hooks.json.
function Install-DocentHookOnHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RemoteHost,
        [Parameter(Mandatory)][string]$HookScriptPath,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [string]$RemoteHooksFile = '$HOME/.cursor/hooks.json'
    )

    # 1. Ensure the hooks dir and copy the script (normalize CRLF, make executable).
    Invoke-DocentSsh -RemoteHost $RemoteHost -Command 'mkdir -p "$HOME/.cursor/hooks"'
    Copy-DocentScp -LocalPath $HookScriptPath -RemoteHost $RemoteHost -RemotePath '.cursor/hooks/docent-notify.sh'
    Invoke-DocentSsh -RemoteHost $RemoteHost -Command 'sed -i "s/\r$//" "$HOME/.cursor/hooks/docent-notify.sh"; chmod +x "$HOME/.cursor/hooks/docent-notify.sh"'

    # 2. Drop the shared-secret token (mode 600), piped via stdin so it never
    #    appears in a process argument list. Remove it when no token is set.
    if ($Token) {
        # `tr -d '\r\n'` strips the CR/LF that PowerShell appends when piping the
        # token over stdin. A stray CR in the token would otherwise ride along in
        # the hook's `Authorization: Bearer <token>` header and http.sys would
        # reject the request with a 400 before it ever reached docent.
        Invoke-DocentSsh -RemoteHost $RemoteHost -Command 'umask 077; tr -d "\r\n" > "$HOME/.cursor/docent-token"; chmod 600 "$HOME/.cursor/docent-token"' -StdinText $Token
        Write-DocentInfo "  token installed (mode 600)"
    }
    else {
        Invoke-DocentSsh -RemoteHost $RemoteHost -Command 'rm -f "$HOME/.cursor/docent-token"'
        Write-DocentWarn "  no token configured; removed any stale remote token"
    }

    # 3. Merge hooks.json idempotently. The remote script drops any prior
    #    docent-notify.sh entries, then re-adds the canonical four; all other
    #    hooks are preserved. Requires jq (already used by Cursor hooks).
    $merge = @"
set -e
f="$RemoteHooksFile"
mkdir -p "`$(dirname "`$f")"
[ -f "`$f" ] || echo '{"version":1,"hooks":{}}' > "`$f"
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found on remote" >&2; exit 3; }
tmp="`$(mktemp)"
jq '
  def addhook(ev; cmd):
    .hooks[ev] = (((.hooks[ev]) // []) | map(select((.command // "") | contains("docent-notify.sh") | not)) + [{command: cmd, timeout: 5}]);
  .version = (.version // 1)
  | .hooks = (.hooks // {})
  | addhook("stop"; "./hooks/docent-notify.sh agent-stop")
  | addhook("sessionStart"; "./hooks/docent-notify.sh session-start")
  | addhook("sessionEnd"; "./hooks/docent-notify.sh session-end")
  | addhook("afterShellExecution"; "./hooks/docent-notify.sh shell-done")
' "`$f" > "`$tmp" && mv "`$tmp" "`$f"
echo "OK hooks: `$(jq -c '.hooks | keys' "`$f")"
"@
    $out = Invoke-DocentSsh -RemoteHost $RemoteHost -Command $merge
    Write-DocentInfo "  $out"
}

# ssh wrapper: key-based, BatchMode, optional stdin. Throws on non-zero exit.
function Invoke-DocentSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RemoteHost,
        [Parameter(Mandatory)][string]$Command,
        [string]$StdinText
    )
    $sshArgs = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', $RemoteHost, $Command)
    if ($PSBoundParameters.ContainsKey('StdinText')) {
        $out = ($StdinText | & ssh @sshArgs 2>&1)
    }
    else {
        $out = (& ssh @sshArgs 2>&1)
    }
    $code = $LASTEXITCODE
    # The reverse-forward warning is benign noise when a tunnel already holds the port.
    $clean = @($out | Where-Object { $_ -notmatch 'remote port forwarding failed' })
    if ($code -ne 0) { throw "ssh $RemoteHost exit $code : $($clean -join '; ')" }
    return ($clean -join "`n").Trim()
}

# scp wrapper: copy a local file to a path relative to the remote home dir.
function Copy-DocentScp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$RemoteHost,
        [Parameter(Mandatory)][string]$RemotePath
    )
    $out = (& scp -o BatchMode=yes -o ConnectTimeout=10 $LocalPath "${RemoteHost}:${RemotePath}" 2>&1)
    $code = $LASTEXITCODE
    $clean = @($out | Where-Object { $_ -notmatch 'remote port forwarding failed' })
    if ($code -ne 0) { throw "scp to $RemoteHost exit $code : $($clean -join '; ')" }
}
