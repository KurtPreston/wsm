Set-StrictMode -Version Latest

# All human-facing logs go to stderr so that stdout stays reserved for
# machine-readable results.

$script:DocentLogLevels = @{ debug = 0; info = 1; warn = 2; error = 3 }

function Get-DocentLogLevel {
    $envLevel = $env:DOCENT_LOG_LEVEL
    if ($envLevel -and $script:DocentLogLevels.ContainsKey($envLevel.ToLower())) {
        return $script:DocentLogLevels[$envLevel.ToLower()]
    }
    return $script:DocentLogLevels['info']
}

function Write-DocentLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('debug', 'info', 'warn', 'error')][string]$Level = 'info'
    )
    if ($script:DocentLogLevels[$Level] -lt (Get-DocentLogLevel)) { return }
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $tag = $Level.ToUpper().PadRight(5)
    [Console]::Error.WriteLine("[$stamp $tag] $Message")
}

function Write-DocentDebug { param([string]$Message) Write-DocentLog -Message $Message -Level debug }
function Write-DocentInfo  { param([string]$Message) Write-DocentLog -Message $Message -Level info }
function Write-DocentWarn  { param([string]$Message) Write-DocentLog -Message $Message -Level warn }
function Write-DocentError { param([string]$Message) Write-DocentLog -Message $Message -Level error }
