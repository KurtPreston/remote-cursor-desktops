Set-StrictMode -Version Latest

<#
.SYNOPSIS
Start the docent webhook receiver: a localhost-only HTTP server that brings the
right remote Cursor workspace into focus on this machine.

.DESCRIPTION
Binds a System.Net.HttpListener to http://127.0.0.1:<port>/ (127.0.0.1 ONLY --
never a public interface). Routes:
  GET  /health  -> 200 "ok"
  POST /open    -> parse JSON {host, path, name}, run the open-or-focus handler,
                   return 200 + a small JSON result (4xx bad body, 5xx failure).

The dev box (running grove / `wt`) POSTs to 127.0.0.1:<port>/open, reaching this
machine through a reverse SSH tunnel (RemoteForward). All logs go to stderr;
honor DOCENT_LOG_LEVEL.

.EXAMPLE
Start-DocentServer
Start-DocentServer -Port 39787
#>
function Start-DocentServer {
    [CmdletBinding()]
    param(
        [int]$Port,
        [string]$Config
    )

    $cfg = Get-DocentConfig -Config $Config
    $resolvedPort = if ($Port) { $Port } elseif ($cfg.port) { [int]$cfg.port } else { 39787 }
    $prefix = "http://127.0.0.1:$resolvedPort/"

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)

    try {
        $listener.Start()
    }
    catch {
        throw "Failed to bind $prefix : $($_.Exception.Message)"
    }

    Write-DocentInfo "docent serving on $prefix (backend: $(Get-DocentBackendKind))"
    if ($cfg._path) { Write-DocentInfo "config: $($cfg._path)" } else { Write-DocentInfo "config: <defaults>" }

    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            try {
                Invoke-DocentRequest -Context $context -Config $cfg
            }
            catch {
                Write-DocentError "Unhandled request error: $($_.Exception.Message)"
                try { Send-DocentResponse -Context $context -StatusCode 500 -Object @{ ok = $false; error = $_.Exception.Message } } catch { }
            }
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
        Write-DocentInfo "docent stopped."
    }
}

# Route a single HttpListener request.
function Invoke-DocentRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][PSCustomObject]$Config
    )

    $req = $Context.Request
    $method = $req.HttpMethod
    $path = $req.Url.AbsolutePath
    Write-DocentDebug "$method $path from $($req.RemoteEndPoint)"

    if ($method -eq 'GET' -and $path -eq '/health') {
        Send-DocentResponse -Context $Context -StatusCode 200 -Text 'ok'
        return
    }

    if ($method -eq 'POST' -and $path -eq '/open') {
        $body = Read-DocentRequestBody -Request $req
        $payload = $null
        try {
            $payload = $body | ConvertFrom-Json
        }
        catch {
            Write-DocentWarn "Bad JSON body: $($_.Exception.Message)"
            Send-DocentResponse -Context $Context -StatusCode 400 -Object @{ ok = $false; error = 'invalid JSON body' }
            return
        }

        $h = if ($payload.PSObject.Properties.Name -contains 'host') { [string]$payload.host } else { $null }
        $p = if ($payload.PSObject.Properties.Name -contains 'path') { [string]$payload.path } else { $null }
        $n = if ($payload.PSObject.Properties.Name -contains 'name') { [string]$payload.name } else { $null }

        if (-not $h -or -not $p) {
            Send-DocentResponse -Context $Context -StatusCode 400 -Object @{ ok = $false; error = 'body must include non-empty {host, path}' }
            return
        }

        try {
            $result = Open-DocentWorkspace -Host $h -Path $p -Name $n -ConfigObject $Config
            Send-DocentResponse -Context $Context -StatusCode 200 -Object @{
                ok     = $true
                action = $result.Action
                host   = $result.Host
                path   = $result.Path
                name   = $result.Name
                uri    = $result.Uri
            }
        }
        catch {
            Write-DocentError "open failed: $($_.Exception.Message)"
            Send-DocentResponse -Context $Context -StatusCode 500 -Object @{ ok = $false; error = $_.Exception.Message }
        }
        return
    }

    Send-DocentResponse -Context $Context -StatusCode 404 -Object @{ ok = $false; error = 'not found' }
}

# Read the full request body as a string using the request's content encoding.
function Read-DocentRequestBody {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request)

    if (-not $Request.HasEntityBody) { return '' }
    $encoding = if ($Request.ContentEncoding) { $Request.ContentEncoding } else { [System.Text.Encoding]::UTF8 }
    $reader = [System.IO.StreamReader]::new($Request.InputStream, $encoding)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}

# Write a response. Provide either -Text (text/plain) or -Object (JSON).
function Send-DocentResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][int]$StatusCode,
        [string]$Text,
        $Object
    )

    $resp = $Context.Response
    if ($PSBoundParameters.ContainsKey('Object')) {
        $payload = ($Object | ConvertTo-Json -Compress -Depth 6)
        $resp.ContentType = 'application/json'
    }
    else {
        $payload = $Text
        $resp.ContentType = 'text/plain'
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $resp.StatusCode = $StatusCode
    $resp.ContentLength64 = $bytes.Length
    try {
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $resp.OutputStream.Close()
    }
}
