Set-StrictMode -Version Latest

<#
.SYNOPSIS
Pull-mode convenience: enumerate every workspace via the `list` template (over
SSH) and open one window (and, on Windows, one desktop) each.

.DESCRIPTION
This is the only command that still uses the SSH resolver. It requires `host`
and `list` in config. Each entry is opened through Open-DocentWorkspace, so the
push-mode open/focus logic and backend abstraction are shared. Windows are
launched sequentially to keep new-window detection unambiguous.
#>
function Open-DocentAll {
    [CmdletBinding()]
    param(
        [string]$Project,
        [string]$Config,
        [switch]$NoSwitch
    )

    $cfg = Get-DocentConfig -Config $Config
    if (-not $cfg.host) { throw "open-all is pull-mode and requires 'host' in config." }

    $ctx = New-DocentContext -Config $cfg -Ref '' -Project $Project
    $refs = Get-DocentRefList -Config $cfg -Context $ctx

    if ($refs.Count -eq 0) {
        Write-DocentWarn "No refs returned by list template."
        return
    }
    Write-DocentInfo "Opening $($refs.Count) workspace(s)."

    $results = foreach ($r in $refs) {
        try {
            Open-DocentWorkspace -Host $cfg.host -Path $r.Path -Name $r.Ref -ConfigObject $cfg -NoSwitch
        }
        catch {
            Write-DocentError "Failed to open '$($r.Ref)': $($_.Exception.Message)"
            [PSCustomObject]@{ Action = 'error'; Name = $r.Ref; Path = $r.Path; Error = $_.Exception.Message }
        }
    }

    if (-not $NoSwitch -and $results -and (Get-DocentBackendKind) -eq 'windows') {
        $last = $results | Where-Object { $_.PSObject.Properties.Name -contains 'Name' -and $_.Action -ne 'error' } | Select-Object -Last 1
        if ($last) {
            $d = Get-DocentDesktopByName -Name $last.Name
            if ($d) { Switch-DocentDesktop -Desktop $d }
        }
    }

    return $results
}
