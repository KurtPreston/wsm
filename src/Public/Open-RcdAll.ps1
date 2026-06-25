Set-StrictMode -Version Latest

<#
.SYNOPSIS
Enumerate all refs via the `list` template and open one desktop + window each.

.DESCRIPTION
Windows are launched sequentially (each waits for its HWND before the next) to
keep the new-window detection unambiguous. The final desktop is left focused
unless -NoSwitch is given.
#>
function Open-RcdAll {
    [CmdletBinding()]
    param(
        [string]$Project,
        [string]$Config,
        [switch]$NoSwitch
    )

    $cfg = Get-RcdConfig -Config $Config
    $ctx = New-RcdContext -Config $cfg -Ref '' -Project $Project
    $refs = Get-RcdRefList -Config $cfg -Context $ctx

    if ($refs.Count -eq 0) {
        Write-RcdWarn "No refs returned by list template."
        return
    }
    Write-RcdInfo "Opening $($refs.Count) workspace(s)."

    $results = foreach ($r in $refs) {
        try {
            # We already have the path from the list, but resolving per-ref keeps
            # the codepath identical and tolerates list/resolve drift.
            Open-RcdWorkspace -Ref $r.Ref -Project $Project -Config $cfg._path -NoSwitch
        }
        catch {
            Write-RcdError "Failed to open '$($r.Ref)': $($_.Exception.Message)"
            [PSCustomObject]@{ Ref = $r.Ref; Path = $r.Path; Error = $_.Exception.Message }
        }
    }

    if (-not $NoSwitch -and $results) {
        $last = $results | Where-Object { $_.PSObject.Properties.Name -contains 'DesktopName' } | Select-Object -Last 1
        if ($last) {
            $d = Get-RcdDesktopByName -Name $last.DesktopName
            if ($d) { Switch-RcdDesktop -Desktop $d }
        }
    }

    return $results
}
