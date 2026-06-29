Set-StrictMode -Version Latest

# Session registry: a small JSON state file that augments live Cursor-window
# enumeration with per-session metadata and timestamps. Live enumeration remains
# the source of truth for *liveness* (which windows are open right now); the
# registry adds host/path/color/ticket and the activity timestamps used to
# derive follow-up state.
#
# Keyed by session `name` (the desktop/window label). Records carry:
#   name, host, path, uri, color, colorSource, fg, ticket,
#   createdAt, lastOpenedAt, lastAgentStopAt, lastShellDoneAt, lastFocusedAt
#
# All mutations go through Invoke-DocentRegistryLocked so concurrent writers
# (docent serve handling /event vs. an Open-DocentWorkspace from the CLI) cannot
# corrupt the file via a read-modify-write race.

# ---------------------------------------------------------------------------
# Color: a faithful port of grove's internal/color/color.go ForBranch/FgForHex.
# A branch/worktree name is hashed with the POSIX `cksum` CRC into an OKLCH hue,
# then rendered to an sRGB hex string. This is the FALLBACK color; a Cursor hook
# may later supply the exact titleBar color (colorSource = 'hook').
# ---------------------------------------------------------------------------

$script:DocentCrcTable = $null

# Build (once) the POSIX cksum CRC table for polynomial 0x04C11DB7.
function Get-DocentCrcTable {
    if ($script:DocentCrcTable) { return $script:DocentCrcTable }
    $poly = [long]0x04C11DB7
    $tab = [uint32[]]::new(256)
    for ($i = 0; $i -lt 256; $i++) {
        $c = [long]($i) -shl 24
        for ($k = 0; $k -lt 8; $k++) {
            if (($c -band 0x80000000L) -ne 0) {
                $c = ((($c -shl 1) -band 0xFFFFFFFFL) -bxor $poly)
            }
            else {
                $c = (($c -shl 1) -band 0xFFFFFFFFL)
            }
        }
        $tab[$i] = [uint32]($c -band 0xFFFFFFFFL)
    }
    $script:DocentCrcTable = $tab
    return $tab
}

# Replicate POSIX `cksum` (CRC 0x04C11DB7, length-folded, one's complement) so
# the name->hue mapping is byte-identical to grove (and the bash tool).
function Get-DocentCksum {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Data)

    $tab = Get-DocentCrcTable
    $crc = [long]0
    foreach ($b in $Data) {
        $idx = [int]((((($crc -shr 24) -band 0xFF)) -bxor ($b -band 0xFF)) -band 0xFF)
        $crc = ((($crc -shl 8) -band 0xFFFFFFFFL) -bxor [long]$tab[$idx])
    }
    $n = $Data.Length
    while ($n -gt 0) {
        $idx = [int]((((($crc -shr 24) -band 0xFF)) -bxor ($n -band 0xFF)) -band 0xFF)
        $crc = ((($crc -shl 8) -band 0xFFFFFFFFL) -bxor [long]$tab[$idx])
        $n = $n -shr 8
    }
    return [uint32]((-bnot $crc) -band 0xFFFFFFFFL)
}

# sRGB transfer function + clamp to a 0-255 byte (grove's linearToByte).
function Convert-DocentLinearToByte {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double]$Value)
    $c = $Value
    if ($c -le 0) { return 0 }
    if ($c -ge 1) { return 255 }
    if ($c -le 0.0031308) { $c = 12.92 * $c }
    else { $c = 1.055 * [math]::Pow($c, 1.0 / 2.4) - 0.055 }
    $v = [int][math]::Round($c * 255)
    if ($v -lt 0) { return 0 }
    if ($v -gt 255) { return 255 }
    return $v
}

# OKLCH (L in [0,1], chroma C, hue in degrees) -> sRGB hex (grove's oklch).
function Get-DocentOklchHex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$L,
        [Parameter(Mandatory)][double]$C,
        [Parameter(Mandatory)][double]$HueDegrees
    )
    $h = $HueDegrees * [math]::PI / 180
    $a = $C * [math]::Cos($h)
    $b = $C * [math]::Sin($h)

    $lp = $L + 0.3963377774 * $a + 0.2158037573 * $b
    $mp = $L - 0.1055613458 * $a - 0.0638541728 * $b
    $sp = $L - 0.0894841775 * $a - 1.2914855480 * $b

    $lc = $lp * $lp * $lp
    $mc = $mp * $mp * $mp
    $sc = $sp * $sp * $sp

    $r = 4.0767416621 * $lc - 3.3077115913 * $mc + 0.2309699292 * $sc
    $g = -1.2684380046 * $lc + 2.6097574011 * $mc - 0.3413193965 * $sc
    $bl = -0.0041960863 * $lc - 0.7034186147 * $mc + 1.7076147010 * $sc

    return ('#{0:x2}{1:x2}{2:x2}' -f `
        (Convert-DocentLinearToByte -Value $r),
        (Convert-DocentLinearToByte -Value $g),
        (Convert-DocentLinearToByte -Value $bl))
}

# grove ForBranch: deterministic fallback color for a name.
function Get-DocentColorForName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Name)
    $sum = Get-DocentCksum -Data $bytes
    $hue = [double]($sum % 360)
    return Get-DocentOklchHex -L 0.70 -C 0.14 -HueDegrees $hue
}

# grove FgForHex: pick black/white text for legibility on a background hex.
function Get-DocentForegroundForHex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Hex)
    $h = ([string]$Hex).TrimStart('#')
    if ($h.Length -lt 6) { return '#ffffff' }
    try {
        $r = [Convert]::ToInt32($h.Substring(0, 2), 16)
        $g = [Convert]::ToInt32($h.Substring(2, 2), 16)
        $b = [Convert]::ToInt32($h.Substring(4, 2), 16)
    }
    catch { return '#ffffff' }
    $lum = [int](($r * 299 + $g * 587 + $b * 114) / 1000)
    if ($lum -gt 140) { return '#000000' }
    return '#ffffff'
}

# ---------------------------------------------------------------------------
# State file + concurrency
# ---------------------------------------------------------------------------

# Where the registry lives. Override with config `registryPath`; otherwise
# $HOME/.config/docent/sessions.json (matches the config discovery convention).
function Get-DocentRegistryPath {
    [CmdletBinding()]
    param([PSCustomObject]$Config)

    if ($Config -and ($Config.PSObject.Properties.Name -contains 'registryPath') -and $Config.registryPath) {
        return [string]$Config.registryPath
    }
    $base = if ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }
    return (Join-Path $base '.config/docent/sessions.json')
}

# Run $ScriptBlock while holding a process-wide named mutex, so read-modify-write
# of the state file is atomic across docent serve + CLI invocations.
function Invoke-DocentRegistryLocked {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)

    $mutex = [System.Threading.Mutex]::new($false, 'Docent.Registry.v1')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne([TimeSpan]::FromSeconds(5)) }
        catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { Write-DocentWarn 'registry: timed out waiting for lock; proceeding unlocked.' }
        return & $ScriptBlock
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Read the registry into an ordered hashtable keyed by name. Missing/corrupt
# files yield an empty table (never throws -- the dashboard must degrade).
function Read-DocentRegistryState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $state = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $state }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $state }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($p in $obj.PSObject.Properties) { $state[$p.Name] = $p.Value }
    }
    catch {
        Write-DocentWarn "registry: failed to read '$Path' ($($_.Exception.Message)); starting empty."
    }
    return $state
}

# Write the registry state table atomically (temp file + move).
function Write-DocentRegistryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = $State | ConvertTo-Json -Depth 8
    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ISO-8601 UTC timestamp helper.
function Get-DocentNowIso {
    return (Get-Date).ToUniversalTime().ToString('o')
}

# ---------------------------------------------------------------------------
# Record mutation
# ---------------------------------------------------------------------------

# Upsert a record by name, applying $Patch (a hashtable of field->value). Creates
# the record with createdAt when new. Returns the merged record.
function Update-DocentSessionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Patch
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $path = Get-DocentRegistryPath -Config $Config

    return Invoke-DocentRegistryLocked -ScriptBlock {
        $state = Read-DocentRegistryState -Path $path

        $existing = if ($state.Contains($Name)) { $state[$Name] } else { $null }
        $record = [ordered]@{
            name            = $Name
            host            = $null
            path            = $null
            uri             = $null
            color           = $null
            colorSource     = $null
            fg              = $null
            ticket          = $null
            createdAt       = Get-DocentNowIso
            lastOpenedAt    = $null
            lastPromptAt    = $null
            lastAgentStopAt = $null
            lastShellDoneAt = $null
            lastFocusedAt   = $null
        }
        if ($existing) {
            foreach ($p in $existing.PSObject.Properties) { $record[$p.Name] = $p.Value }
        }
        foreach ($k in $Patch.Keys) { $record[$k] = $Patch[$k] }

        $state[$Name] = [PSCustomObject]$record
        Write-DocentRegistryState -Path $path -State $state
        return $state[$Name]
    }
}

# On open: record host/path/uri, derive a fallback color + ticket (unless a hook
# already supplied an exact one), and stamp lastOpenedAt.
function Register-DocentSessionOpen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Name,
        [string]$RemoteHost,
        [string]$Path,
        [string]$Uri
    )

    $color = Get-DocentColorForName -Name $Name
    $patch = @{
        host         = $RemoteHost
        path         = $Path
        uri          = $Uri
        ticket       = (Resolve-DocentTicketKey -Name $Name -Config $Config)
        lastOpenedAt = Get-DocentNowIso
    }
    # Only set the fallback color when no exact (hook) color is already recorded.
    $path2 = Get-DocentRegistryPath -Config $Config
    $existing = $null
    try {
        $state = Read-DocentRegistryState -Path $path2
        if ($state.Contains($Name)) { $existing = $state[$Name] }
    }
    catch { }
    $hasHookColor = $existing -and ($existing.PSObject.Properties.Name -contains 'colorSource') -and ($existing.colorSource -eq 'hook')
    if (-not $hasHookColor) {
        $patch['color'] = $color
        $patch['colorSource'] = 'derived'
        $patch['fg'] = (Get-DocentForegroundForHex -Hex $color)
    }
    Update-DocentSessionRecord -Config $Config -Name $Name -Patch $patch | Out-Null
}

# Stamp lastFocusedAt = now (clears follow-up for this session on next read).
function Set-DocentSessionFocused {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    Update-DocentSessionRecord -Config $Config -Name $Name -Patch @{ lastFocusedAt = Get-DocentNowIso } | Out-Null
}

# Apply a hook /event to a session record. $Kind is one of
# agent-stop|session-start|session-end|shell-done. An exact $Color (hook-read)
# supersedes the derived color.
function Set-DocentSessionEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Kind,
        [string]$Host,
        [string]$Path,
        [string]$Color,
        [string]$ConversationId
    )

    $now = Get-DocentNowIso
    $patch = @{}
    switch ($Kind) {
        'prompt-submit' { $patch['lastPromptAt'] = $now }
        'agent-stop' { $patch['lastAgentStopAt'] = $now }
        'shell-done' { $patch['lastShellDoneAt'] = $now }
        'session-start' { $patch['lastOpenedAt'] = $now }
        'session-end' { $patch['endedAt'] = $now }
        default { Write-DocentWarn "registry: unknown event kind '$Kind'."; }
    }
    if ($Host) { $patch['host'] = $Host }
    if ($Path) { $patch['path'] = $Path }
    if ($ConversationId) { $patch['conversationId'] = $ConversationId }
    if ($Color) {
        $patch['color'] = $Color
        $patch['colorSource'] = 'hook'
        $patch['fg'] = (Get-DocentForegroundForHex -Hex $Color)
    }
    if (-not ($patch.ContainsKey('ticket'))) {
        $patch['ticket'] = (Resolve-DocentTicketKey -Name $Name -Config $Config)
    }
    Update-DocentSessionRecord -Config $Config -Name $Name -Patch $patch | Out-Null
}

# All registry records as an array of PSCustomObjects.
function Get-DocentRegistryRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Config)
    $path = Get-DocentRegistryPath -Config $Config
    $state = Invoke-DocentRegistryLocked -ScriptBlock { Read-DocentRegistryState -Path $path }
    $records = @()
    foreach ($k in $state.Keys) { $records += $state[$k] }
    return $records
}

# Look up a single record by name ($null if absent).
function Get-DocentRegistryRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Name
    )
    $path = Get-DocentRegistryPath -Config $Config
    $state = Invoke-DocentRegistryLocked -ScriptBlock { Read-DocentRegistryState -Path $path }
    if ($state.Contains($Name)) { return $state[$Name] }
    return $null
}

# Parse an ISO timestamp to a DateTimeOffset, or $null.
function ConvertFrom-DocentIso {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try { return [DateTimeOffset]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) }
    catch { return $null }
}

# Read an ISO field off a record (or $null if absent/empty).
function Get-DocentRecordTime {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$Field)
    if ($Record.PSObject.Properties.Name -contains $Field) { return ConvertFrom-DocentIso $Record.$Field }
    return $null
}

# Derive a session's activity status from its timestamps:
#   working        - a prompt was submitted and the turn has not stopped yet
#                    (lastPromptAt is at/after lastAgentStopAt).
#   needs-followup - the latest turn STOPPED and you have not re-engaged since:
#                    lastAgentStopAt is later than both the last prompt and the
#                    last docent-focus. (Submitting a new prompt or focusing via
#                    docent both count as re-engaging, so it self-clears.)
#   idle           - anything else (never ran a turn, or already handled).
# Note: shell-done is intentionally NOT a follow-up trigger -- it fires on every
# agent shell command (including mid-turn), so it is far too noisy; it is kept
# only for "last activity" display.
function Get-DocentSessionStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)

    $promptAt = Get-DocentRecordTime -Record $Record -Field 'lastPromptAt'
    $stopAt = Get-DocentRecordTime -Record $Record -Field 'lastAgentStopAt'
    $focusAt = Get-DocentRecordTime -Record $Record -Field 'lastFocusedAt'

    if (-not $stopAt) {
        # No turn has ever finished. If a prompt is outstanding, it's working.
        if ($promptAt) { return 'working' }
        return 'idle'
    }
    # A prompt newer than the last stop means a new turn is in flight.
    if ($promptAt -and $promptAt -ge $stopAt) { return 'working' }
    # The turn has stopped: follow-up unless you've focused it via docent since.
    if ($focusAt -and $focusAt -ge $stopAt) { return 'idle' }
    return 'needs-followup'
}

# Back-compat boolean used by grouping/aggregation.
function Test-DocentNeedsFollowup {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    return ((Get-DocentSessionStatus -Record $Record) -eq 'needs-followup')
}
