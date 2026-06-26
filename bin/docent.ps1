#!/usr/bin/env pwsh
<#
.SYNOPSIS
docent - cross-platform CLI dispatcher for the Docent module.

.DESCRIPTION
docent is a localhost-only webhook receiver that brings the right remote Cursor
workspace into focus on this machine. `serve` is the primary entrypoint; the
other commands drive the same open/focus logic by hand.

Usage:
  docent serve     [-Port <n>] [-Config <path>]
  docent open      -Host <h> -Path <p> [-Name <n>] [-Config <path>] [-NoSwitch]
  docent open-url  -Name <n> -Url <u> [-Config <path>]
  docent focus     [-Host <h>] [-Path <p>] [-Name <n>] [-Config <path>]
  docent close     [-Path <p>] [-Name <n>] [-Config <path>] [-RemoveDesktop]
  docent status    [-Config <path>]
  docent help

Webhook contract (POST /open):
  { "host": "<ssh host alias>", "path": "<remote absolute path>", "name": "<workspace name>" }

Environment:
  DOCENT_CONFIG     default config path
  DOCENT_LOG_LEVEL  debug | info | warn | error  (default: info)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('serve', 'open', 'open-url', 'focus', 'close', 'status', 'help')]
    [string]$Command,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '../src/Docent.psd1'
Import-Module $modulePath -Force -DisableNameChecking

# Split remaining args into positionals and -Name/value (or -Switch) options.
function ConvertTo-DocentParams {
    param([string[]]$InputArgs)
    # $Rest is $null (not an empty array) when no remaining args are supplied,
    # e.g. `docent status` / `docent serve`. StrictMode forbids .Count on $null.
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

$parsed = ConvertTo-DocentParams -InputArgs $Rest
$pos = $parsed.Positional
$named = $parsed.Named

switch ($Command) {
    'serve' {
        Start-DocentServer @named
    }
    'open' {
        Open-DocentWorkspace @named
    }
    'open-url' {
        Open-DocentUrl @named
    }
    'focus' {
        Focus-DocentWorkspace @named
    }
    'close' {
        Close-DocentWorkspace @named
    }
    'status' {
        Get-DocentStatus @named
    }
    'help' {
        Get-Help $PSCommandPath -Detailed
    }
}
