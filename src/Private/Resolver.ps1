Set-StrictMode -Version Latest

# SSH resolver (pull-mode only). The primary push-mode flow does NOT use this:
# the webhook payload already carries the remote path. These helpers exist only
# for the optional `docent open-all` enumeration.

# Run a resolver/list command on the remote host over SSH. Returns stdout lines.
# stderr from the remote command is surfaced through our own stderr.
function Invoke-DocentSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$RemoteCommand
    )

    if (-not $Config.host) { throw "Pull-mode requires 'host' in config." }

    # Wrap the command in the configured login shell (so PATH and resolver
    # commands resolve in a non-interactive session), escaping single quotes for
    # safe embedding.
    $escaped = $RemoteCommand -replace "'", "'\''"
    $wrapped = Expand-DocentTemplate -Template $Config.remoteShell -Context @{ cmd = $escaped }

    $sshArgs = @()
    if ($Config.sshOptions) { $sshArgs += $Config.sshOptions }
    $sshArgs += $Config.host
    $sshArgs += $wrapped

    Write-DocentDebug "ssh $($sshArgs -join ' ')"

    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = & $Config.sshExe @sshArgs 2>$errFile
        $code = $LASTEXITCODE
        $stderr = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        if ($stderr) {
            foreach ($line in ($stderr -split "`r?`n")) {
                if ($line.Trim()) { Write-DocentDebug "ssh stderr: $line" }
            }
        }
        if ($code -ne 0) {
            throw "SSH command failed (exit $code): $wrapped`n$stderr"
        }
        return @($stdout)
    }
    finally {
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    }
}

# Resolve a ref to its remote absolute folder path using the `resolve` template.
function Resolve-DocentPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][hashtable]$Context
    )
    if (-not $Config.resolve) { throw "Pull-mode requires 'resolve' in config." }
    $cmd = Expand-DocentTemplate -Template $Config.resolve -Context $Context
    Write-DocentInfo "Resolving '$($Context.ref)' via: $cmd"
    $out = Invoke-DocentSsh -Config $Config -RemoteCommand $cmd

    # The contract: stdout is the path. Take the last non-empty line defensively.
    $path = ($out | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 1)
    if (-not $path) { throw "Resolver returned no path for ref '$($Context.ref)'." }
    $path = $path.Trim()
    Write-DocentInfo "Resolved to: $path"
    return $path
}

# Enumerate refs via the `list` template. Returns objects with Ref + Path.
function Get-DocentRefList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][hashtable]$Context
    )
    if (-not $Config.list) { throw "Config has no 'list' template; cannot enumerate." }
    $cmd = Expand-DocentTemplate -Template $Config.list -Context $Context
    Write-DocentInfo "Listing refs via: $cmd"
    $out = Invoke-DocentSsh -Config $Config -RemoteCommand $cmd

    $result = foreach ($line in $out) {
        if (-not $line -or -not $line.Trim()) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -lt 2) {
            Write-DocentWarn "Skipping malformed list line (expected branch<TAB>path): $line"
            continue
        }
        [PSCustomObject]@{ Ref = $parts[0].Trim(); Path = $parts[1].Trim() }
    }
    return @($result)
}
