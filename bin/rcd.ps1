#!/usr/bin/env pwsh
<#
.SYNOPSIS
rcd - remote-cursor-desktops CLI dispatcher.

.DESCRIPTION
Thin wrapper around the RemoteCursorDesktops module.

Usage:
  rcd open      <ref> [-Project <p>] [-Config <path>] [-NoSwitch]
  rcd open-all  [-Project <p>] [-Config <path>] [-NoSwitch]
  rcd focus     <ref> [-Project <p>] [-Config <path>]
  rcd close     <ref> [-Project <p>] [-Config <path>] [-RemoveDesktop]
  rcd status    [-Project <p>] [-Config <path>]

Environment:
  RCD_CONFIG     default config path
  RCD_LOG_LEVEL  debug | info | warn | error  (default: info)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('open', 'open-all', 'focus', 'close', 'status', 'help')]
    [string]$Command,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '../src/RemoteCursorDesktops.psd1'
Import-Module $modulePath -Force -DisableNameChecking

# Split remaining args into positionals and -Name/value (or -Switch) options.
function ConvertTo-RcdParams {
    param([string[]]$InputArgs)
    # $Rest is $null (not an empty array) when no remaining args are supplied,
    # e.g. `rcd status` / `rcd open-all`. StrictMode forbids .Count on $null.
    if (-not $InputArgs) { $InputArgs = @() }
    $positional = @()
    $named = @{}
    $i = 0
    while ($i -lt $InputArgs.Count) {
        $a = $InputArgs[$i]
        if ($a -like '-*') {
            $name = $a.TrimStart('-')
            $next = if ($i + 1 -lt $InputArgs.Count) { $InputArgs[$i + 1] } else { $null }
            if ($null -ne $next -and $next -notlike '-*') {
                $named[$name] = $next
                $i += 2
            }
            else {
                $named[$name] = $true   # bare switch
                $i += 1
            }
        }
        else {
            $positional += $a
            $i += 1
        }
    }
    return @{ Positional = $positional; Named = $named }
}

$parsed = ConvertTo-RcdParams -InputArgs $Rest
$pos = $parsed.Positional
$named = $parsed.Named

switch ($Command) {
    'open' {
        if ($pos.Count -lt 1) { throw "Usage: rcd open <ref> [-Project p] [-Config path] [-NoSwitch]" }
        Open-RcdWorkspace -Ref $pos[0] @named
    }
    'open-all' {
        Open-RcdAll @named
    }
    'focus' {
        if ($pos.Count -lt 1) { throw "Usage: rcd focus <ref> [-Project p] [-Config path]" }
        Focus-RcdWorkspace -Ref $pos[0] @named
    }
    'close' {
        if ($pos.Count -lt 1) { throw "Usage: rcd close <ref> [-Project p] [-Config path] [-RemoveDesktop]" }
        Close-RcdWorkspace -Ref $pos[0] @named
    }
    'status' {
        Get-RcdStatus @named
    }
    'help' {
        Get-Help $PSCommandPath -Detailed
    }
}
