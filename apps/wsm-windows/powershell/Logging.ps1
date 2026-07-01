Set-StrictMode -Version Latest

# All human-facing logs go to stderr so that stdout stays reserved for
# machine-readable results (wm.ps1 writes exactly one JSON object there).

$script:WsmLogLevels = @{ debug = 0; info = 1; warn = 2; error = 3 }

function Get-WsmLogLevel {
    $envLevel = $env:WSM_LOG_LEVEL
    if ($envLevel -and $script:WsmLogLevels.ContainsKey($envLevel.ToLower())) {
        return $script:WsmLogLevels[$envLevel.ToLower()]
    }
    return $script:WsmLogLevels['info']
}

function Write-WsmLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('debug', 'info', 'warn', 'error')][string]$Level = 'info'
    )
    if ($script:WsmLogLevels[$Level] -lt (Get-WsmLogLevel)) { return }
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $tag = $Level.ToUpper().PadRight(5)
    [Console]::Error.WriteLine("[$stamp $tag] $Message")
}

function Write-WsmDebug { param([string]$Message) Write-WsmLog -Message $Message -Level debug }
function Write-WsmInfo  { param([string]$Message) Write-WsmLog -Message $Message -Level info }
function Write-WsmWarn  { param([string]$Message) Write-WsmLog -Message $Message -Level warn }
function Write-WsmError { param([string]$Message) Write-WsmLog -Message $Message -Level error }
