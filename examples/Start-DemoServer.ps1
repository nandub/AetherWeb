<#
.SYNOPSIS
Starts a complete AetherWeb demo server with CORS and MOM bridge support.

.DESCRIPTION
This script demonstrates a full AetherWeb server setup using:
- static/admin routes
- CORS middleware
- file-backed message queue
- HTTP enqueue middleware
- message status routes
- structured request logging
- correlation-aware request handling

The script is intended as a practical starter example for Windows PowerShell 5.1.

.PARAMETER Prefix
The HTTP prefix to bind to.

.PARAMETER RootPath
The root folder for demo content.

.PARAMETER QueuePath
The queue root folder.

.PARAMETER RequestLogPath
The path to the request log file.

.PARAMETER AllowedOrigin
The browser origin allowed for API CORS access.

.PARAMETER ManagementToken
Optional token for management-style routes if you choose to add token checks.

.EXAMPLE
PS C:\> .\Start-DemoServer.ps1 -Verbose

Starts the demo server on the default localhost prefix.

.EXAMPLE
PS C:\> .\Start-DemoServer.ps1 -Prefix 'http://localhost:8090/' -AllowedOrigin 'https://portal.contoso.local' -Verbose

Starts the demo server on a different port and origin policy.

.INPUTS
None.

.OUTPUTS
None.

.NOTES
Assumptions:
- AetherWeb 1.7.0 is installed and importable.
- Designed for Windows PowerShell 5.1.
- This is a demo/internal service example, not a hardened public internet service.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string[]]$Prefix = @(
        'http://localhost:8080/',
        'http://127.0.0.1:8080/',
        ("http://{0}:8080/" -f $env:COMPUTERNAME),
        'http://192.168.1.134:8080/'
    ),

    [Parameter()]
    [string]$RootPath = 'C:\AetherWebDemo',

    [Parameter()]
    [string]$QueuePath = 'C:\AetherWebDemo\Queue',

    [Parameter()]
    [string]$RequestLogPath = 'C:\AetherWebDemo\Logs\Requests.jsonl',

    [Parameter()]
    [string]$AllowedOrigin = 'http://localhost',

    [Parameter()]
    [string]$ManagementToken
)

Import-Module AetherWeb -Force -ErrorAction Stop

$logsPath = Split-Path -Path $RequestLogPath -Parent

foreach ($path in @($RootPath, $logsPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        if ($PSCmdlet.ShouldProcess($path, 'Create directory')) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $RootPath 'wwwroot'))) {
    if ($PSCmdlet.ShouldProcess((Join-Path $RootPath 'wwwroot'), 'Create directory')) {
        New-Item -Path (Join-Path $RootPath 'wwwroot') -ItemType Directory -Force | Out-Null
    }
}

$queue = New-FileMessageQueue -Path $QueuePath

$server = New-HttpServer `
    -Prefix $Prefix `
    -RootPath (Join-Path $RootPath 'wwwroot') `
    -EnableStaticFiles `
    -EnableRequestLogging `
    -RequestLogPath $RequestLogPath `
    -RequestLogFormat JsonLines `
    -MaxRequestBodyBytes 1MB `
    -MaxMultipartFileBytes 10MB

# Correlation middleware
Add-HttpMiddleware -Server $server -Name 'Correlation' -ScriptBlock {
    param($Context, $Server, $Next)

    $correlationId = $Context.Request.Headers['X-Correlation-Id']

    if ([string]::IsNullOrWhiteSpace($correlationId)) {
        $correlationId = [guid]::NewGuid().Guid
    }

    Set-HttpContextItem -Context $Context -Name 'CorrelationId' -Value $correlationId
    Set-HttpResponseHeader -Response $Context.Response -Name 'X-Correlation-Id' -Value $correlationId

    & $Next
}

# Simple request timing middleware
Add-HttpMiddleware -Server $server -Name 'Timing' -ScriptBlock {
    param($Context, $Server, $Next)

    $started = Get-Date
    Set-HttpContextItem -Context $Context -Name 'StartedAt' -Value $started

    & $Next
}

# CORS for API endpoints
Add-HttpCorsMiddleware -Server $server `
    -Name 'CorsApi' `
    -AllowedOrigin $AllowedOrigin `
    -AllowedMethod 'GET', 'POST', 'OPTIONS' `
    -AllowedHeader 'Content-Type', 'Authorization', 'Idempotency-Key', 'X-Correlation-Id' `
    -ExposedHeader 'X-Correlation-Id', 'X-Message-Id' `
    -AllowCredentials `
    -MaxAgeSeconds 600 `
    -PathPrefix '/api'

# Optional token middleware for /admin or management areas
if (-not [string]::IsNullOrWhiteSpace($ManagementToken)) {
    Add-HttpMiddleware -Server $server -Name 'AdminToken' -ScriptBlock {
        param($Context, $Server, $Next)

        $path = $Context.Request.Url.AbsolutePath

        if ($path.StartsWith('/admin', [System.StringComparison]::OrdinalIgnoreCase)) {
            $supplied = $Context.Request.Headers['X-Admin-Token']
            if ($supplied -ne $ManagementToken) {
                Write-HttpErrorResponse `
                    -Response $Context.Response `
                    -StatusCode 403 `
                    -StatusDescription '403 Forbidden' `
                    -RequestMethod $Context.Request.HttpMethod
                return
            }
        }

        & $Next
    }
}

Add-HttpShutdownRoute -Server $server `
    -Path '/admin/stop' `
    -Method POST `
    -LocalOnly `
    -Token "$ManagementToken" | Out-Null

# Health route
Add-HttpRoute -Server $server -Method GET -Path '/health' -ScriptBlock {
    param($Context, $Server)

    $correlationId = Get-HttpContextItem -Context $Context -Name 'CorrelationId'

    Write-HttpJsonResponse `
        -Response $Context.Response `
        -InputObject @{
            Status        = 'OK'
            Time          = Get-Date
            MachineName   = $env:COMPUTERNAME
            CorrelationId = $correlationId
        } `
        -RequestMethod $Context.Request.HttpMethod
}

# Admin HTML route
Add-HttpRoute -Server $server -Method GET -Path '/admin' -ScriptBlock {
    param($Context, $Server)

    $stats = Get-FileQueueStats -Path $QueuePath
    $correlationId = Get-HttpContextItem -Context $Context -Name 'CorrelationId'

    $body = @"
<h1>AetherWeb Demo</h1>
<p><strong>Machine:</strong> $($env:COMPUTERNAME)</p>
<p><strong>CorrelationId:</strong> $correlationId</p>
<h2>Queue Stats</h2>
<ul>
    <li>Incoming: $($stats.IncomingCount)</li>
    <li>Processing: $($stats.ProcessingCount)</li>
    <li>Completed: $($stats.CompletedCount)</li>
    <li>DeadLetter: $($stats.DeadLetterCount)</li>
</ul>
<p><a href="/health">Health</a></p>
<p><a href="/api/messages/stats">Message Stats API</a></p>
"@

    $page = New-HttpHtmlPage -Title 'AetherWeb Demo Admin' -Body $body

    Write-HttpHtmlResponse `
        -Response $Context.Response `
        -Body $page `
        -RequestMethod $Context.Request.HttpMethod
}

# MOM bridge:
# POST /api/jobs -> enqueue into file-backed queue and return 202 Accepted
Add-HttpEnqueueMiddleware -Server $server `
    -QueuePath $QueuePath `
    -ExactPath '/api/jobs' `
    -Method POST `
    -MessageType 'JobSubmitted' `
    -IdempotencyHeaderName 'Idempotency-Key'

# Status routes:
# GET /api/messages/{id}
# GET /api/messages/stats
Add-HttpMessageStatusRoutes -Server $server `
    -QueuePath $QueuePath `
    -BasePath '/api/messages' `
    -IncludeStatisticsRoute

# Optional demo route showing that normal API routes can coexist
Add-HttpRoute -Server $server -Method GET -Path '/api/time' -ScriptBlock {
    param($Context, $Server)

    $correlationId = Get-HttpContextItem -Context $Context -Name 'CorrelationId'

    Write-HttpJsonResponse `
        -Response $Context.Response `
        -InputObject @{
            Now           = Get-Date
            CorrelationId = $correlationId
        } `
        -RequestMethod $Context.Request.HttpMethod
}

if ($PSCmdlet.ShouldProcess($Prefix, 'Start demo server')) {
    Start-HttpServer -RegisterManagementRoutes -Server $server -Verbose:$VerbosePreference
}