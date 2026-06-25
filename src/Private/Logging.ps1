Set-StrictMode -Version Latest

# All human-facing logs go to stderr so that stdout stays reserved for
# machine-readable results.

$script:RcdLogLevels = @{ debug = 0; info = 1; warn = 2; error = 3 }

function Get-RcdLogLevel {
    $envLevel = $env:RCD_LOG_LEVEL
    if ($envLevel -and $script:RcdLogLevels.ContainsKey($envLevel.ToLower())) {
        return $script:RcdLogLevels[$envLevel.ToLower()]
    }
    return $script:RcdLogLevels['info']
}

function Write-RcdLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('debug', 'info', 'warn', 'error')][string]$Level = 'info'
    )
    if ($script:RcdLogLevels[$Level] -lt (Get-RcdLogLevel)) { return }
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $tag = $Level.ToUpper().PadRight(5)
    [Console]::Error.WriteLine("[$stamp $tag] $Message")
}

function Write-RcdDebug { param([string]$Message) Write-RcdLog -Message $Message -Level debug }
function Write-RcdInfo  { param([string]$Message) Write-RcdLog -Message $Message -Level info }
function Write-RcdWarn  { param([string]$Message) Write-RcdLog -Message $Message -Level warn }
function Write-RcdError { param([string]$Message) Write-RcdLog -Message $Message -Level error }
