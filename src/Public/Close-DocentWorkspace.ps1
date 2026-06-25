Set-StrictMode -Version Latest

<#
.SYNOPSIS
Close the Cursor window(s) for a workspace, by explicit path/name.

.DESCRIPTION
Windows: closes every Cursor window on the named virtual desktop and, with
-RemoveDesktop, removes the desktop too. macOS: closes the Cursor window whose
title contains the path leaf (window-only; no Spaces).

.EXAMPLE
Close-DocentWorkspace -Name my-feature -RemoveDesktop
Close-DocentWorkspace -Path /home/me/Code/salsa/my-feature
#>
function Close-DocentWorkspace {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Name,
        [string]$Config,
        [PSCustomObject]$ConfigObject,
        [switch]$RemoveDesktop
    )

    $cfg = if ($ConfigObject) { $ConfigObject } else { Get-DocentConfig -Config $Config }
    if (-not $Path -and -not $Name) { throw "Close-DocentWorkspace requires -Path or -Name." }

    $leaf = if ($Path) { Get-DocentLeafName -Path $Path } else { $Name }
    $nameVal = if ($Name) { $Name } else { $leaf }
    $tokens = @{ path = $Path; name = $nameVal; ref = $nameVal }
    $deskTemplate = if ($cfg.desktopName) { $cfg.desktopName } else { '{name}' }
    $deskName = Expand-DocentTemplate -Template $deskTemplate -Context $tokens

    if ((Get-DocentBackendKind) -eq 'macos') {
        Close-DocentMacWindow -Config $cfg -Leaf $leaf
        return
    }

    # Windows: close every Cursor window currently on the named desktop.
    $windows = Get-DocentCursorWindows -Config $cfg
    $onDesk = @($windows | Where-Object { (Get-DocentDesktopNameForWindow -Hwnd $_.Hwnd) -eq $deskName })

    if ($onDesk.Count -eq 0) {
        Write-DocentWarn "No Cursor windows found on desktop '$deskName'."
    }
    foreach ($w in $onDesk) {
        Write-DocentInfo "Closing '$($w.Title)' (hwnd $($w.Hwnd))."
        Close-DocentWindowHandle -Hwnd $w.Hwnd
    }

    if ($RemoveDesktop) {
        Start-Sleep -Milliseconds 500
        Remove-DocentDesktopByName -Name $deskName
    }
}
