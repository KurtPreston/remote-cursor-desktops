Set-StrictMode -Version Latest

<#
.SYNOPSIS
Show the current Cursor windows docent can see, plus virtual desktops on Windows.

.DESCRIPTION
Windows: lists every virtual desktop alongside the Cursor windows currently
placed on it. macOS: lists Cursor window titles (window-only; no Spaces).
#>
function Get-DocentStatus {
    [CmdletBinding()]
    param(
        [string]$Config,
        [PSCustomObject]$ConfigObject
    )

    $cfg = if ($ConfigObject) { $ConfigObject } else { Get-DocentConfig -Config $Config }

    if ((Get-DocentBackendKind) -eq 'macos') {
        return [PSCustomObject]@{
            Backend = 'macos'
            Config  = $cfg._path
            Port    = [int]$cfg.port
            Windows = @(Get-DocentMacWindowTitles -Config $cfg)
        }
    }

    Assert-DocentVirtualDesktop
    $windows = Get-DocentCursorWindows -Config $cfg
    $rows = foreach ($w in $windows) {
        [PSCustomObject]@{
            Desktop = (Get-DocentDesktopNameForWindow -Hwnd $w.Hwnd)
            Hwnd    = $w.Hwnd
            Title   = $w.Title
        }
    }

    [PSCustomObject]@{
        Backend  = 'windows'
        Config   = $cfg._path
        Port     = [int]$cfg.port
        Desktops = @(Get-DesktopList | ForEach-Object { Get-DesktopName -Desktop (Get-Desktop -Index $_.Number) })
        Windows  = @($rows)
    }
}
