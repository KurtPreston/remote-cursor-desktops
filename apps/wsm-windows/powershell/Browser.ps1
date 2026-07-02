Set-StrictMode -Version Latest

# Windows browser launcher: open a URL in a NEW Chromium browser window and
# reliably find its HWND so it can be moved onto a virtual desktop.

function Resolve-WsmBrowserExe {
    [CmdletBinding()]
    param([PSCustomObject]$Config)

    if ($Config.browserExe) {
        if (Test-Path -LiteralPath $Config.browserExe) { return $Config.browserExe }
        throw "Configured browserExe not found: $($Config.browserExe)"
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Google/Chrome/Application/chrome.exe'),
        (Join-Path ${env:ProgramFiles} 'Google/Chrome/Application/chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google/Chrome/Application/chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft/Edge/Application/msedge.exe'),
        (Join-Path ${env:ProgramFiles} 'Microsoft/Edge/Application/msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'BraveSoftware/Brave-Browser/Application/brave.exe'),
        (Join-Path ${env:ProgramFiles} 'BraveSoftware/Brave-Browser/Application/brave.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }

    throw "Could not locate a Chromium browser (Chrome/Edge/Brave). Set 'browserExe' in config."
}

function Get-WsmBrowserProcessName {
    [CmdletBinding()]
    param([PSCustomObject]$Config)

    if ($Config.browserProcessName) { return [string]$Config.browserProcessName }
    $exe = Resolve-WsmBrowserExe -Config $Config
    return [System.IO.Path]::GetFileNameWithoutExtension($exe)
}

function Get-WsmBrowserWindows {
    [CmdletBinding()]
    param([PSCustomObject]$Config)

    $procName = Get-WsmBrowserProcessName -Config $Config
    $procIds = @(Get-Process -Name $procName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    if ($procIds.Count -eq 0) { return @() }

    Get-WsmAllWindows | Where-Object { $procIds -contains $_.Pid }
}

function Open-WsmBrowserWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$Url
    )

    $exe = Resolve-WsmBrowserExe -Config $Config
    Write-WsmDebug "Browser exe: $exe"

    $timeout = [int]$Config.launchTimeoutSec

    $before = @(Get-WsmBrowserWindows -Config $Config | Select-Object -ExpandProperty Hwnd)
    Write-WsmInfo "Launching browser window for URL."
    Write-WsmDebug "$exe --new-window $Url"

    Start-Process -FilePath $exe -ArgumentList @('--new-window', $Url) | Out-Null

    $deadline = (Get-Date).AddSeconds($timeout)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $new = Get-WsmBrowserWindows -Config $Config |
            Where-Object { $before -notcontains $_.Hwnd } |
            Select-Object -First 1
        if ($new) {
            Write-WsmInfo "Matched new browser window '$($new.Title)' (hwnd $($new.Hwnd))."
            return $new.Hwnd
        }
    }

    Write-WsmWarn "No new browser window appeared within ${timeout}s for URL."
    return [IntPtr]::Zero
}

function Find-WsmBrowserWindowOnDesktop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Config,
        [Parameter(Mandatory)][string]$DeskName
    )
    Get-WsmBrowserWindows -Config $Config |
        Where-Object { (Get-WsmDesktopNameForWindow -Hwnd $_.Hwnd) -eq $DeskName } |
        Select-Object -First 1
}
