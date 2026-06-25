Set-StrictMode -Version Latest

<#
.SYNOPSIS
Bring an already-open remote Cursor workspace to the foreground, by explicit
host/path/name (push-mode; no SSH resolution).

.DESCRIPTION
Locates the Cursor window for the path's leaf and focuses it (Windows: switch to
its named virtual desktop + foreground; macOS: raise). If no window is found but
a matching virtual desktop exists on Windows, switches to that desktop.

.EXAMPLE
Focus-DocentWorkspace -Path /home/me/Code/salsa/my-feature
Focus-DocentWorkspace -Name my-feature -Host ubuntu
#>
function Focus-DocentWorkspace {
    [CmdletBinding()]
    param(
        [Alias('h')][string]$Host,
        [string]$Path,
        [string]$Name,
        [string]$Config,
        [PSCustomObject]$ConfigObject
    )

    $cfg = if ($ConfigObject) { $ConfigObject } else { Get-DocentConfig -Config $Config }

    if (-not $Path -and -not $Name) { throw "Focus-DocentWorkspace requires -Path or -Name." }

    $leaf = if ($Path) { Get-DocentLeafName -Path $Path } else { $Name }
    $nameVal = if ($Name) { $Name } else { $leaf }
    $tokens = @{ host = $Host; path = $Path; name = $nameVal; ref = $nameVal }
    $deskTemplate = if ($cfg.desktopName) { $cfg.desktopName } else { '{name}' }
    $deskName = Expand-DocentTemplate -Template $deskTemplate -Context $tokens

    $handle = Find-DocentWindowHandle -Config $cfg -Leaf $leaf -RemoteHost $Host
    if ($handle) {
        Invoke-DocentFocusWindow -Config $cfg -Handle $handle -Name $deskName
        Write-DocentInfo "Focused '$leaf'."
        return [PSCustomObject]@{ Action = 'focused'; Name = $deskName; Leaf = $leaf; Hwnd = $handle.Hwnd }
    }

    # No window found: on Windows, at least switch to the desktop if it exists.
    if ((Get-DocentBackendKind) -eq 'windows') {
        $desktop = Get-DocentDesktopByName -Name $deskName
        if ($desktop) {
            Switch-DocentDesktop -Desktop $desktop
            Write-DocentInfo "No window found; switched to desktop '$deskName'."
            return [PSCustomObject]@{ Action = 'switched'; Name = $deskName; Leaf = $leaf }
        }
    }

    Write-DocentWarn "No Cursor window or workspace target found for '$deskName'."
    return [PSCustomObject]@{ Action = 'none'; Name = $deskName; Leaf = $leaf }
}

Set-Alias -Name Focus-Docent -Value Focus-DocentWorkspace
