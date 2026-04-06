## AetherWeb 1.7.7

This release fixes `Get-FileQueueStats` and the `/api/messages/stats` route path handling, and expands comment-based help examples across the exported functions.

# AetherWeb 1.6.0

AetherWeb is a lightweight HTTP server framework for **Windows PowerShell 5.1** built on `System.Net.HttpListener`.

## Features

- Static file hosting
- Exact routes
- Template routes like `/api/items/{id}`
- Prefix routes
- Route groups
- Middleware pipeline
- Per-request context bag
- JSON, text, HTML, file, and error response helpers
- Query-string helper
- Request body helpers
- URL-encoded form parsing
- Multipart form parsing and optional file saving
- Response headers and cookies
- Request logging
- Background hosting in a dedicated PowerShell instance
- Optional token-gated management endpoints
- Reusable CORS middleware
- File-backed message queue for MOM bridge scenarios
- HTTP enqueue middleware with 202 Accepted responses
- Message status routes and queue worker support

## Install

Copy the `AetherWeb` folder under one of these module paths:

- `$env:OneDrive\Documents\WindowsPowerShell\Modules`
- `$env:USERPROFILE\Documents\WindowsPowerShell\Modules`

If OneDrive is unavailable in your environment, use `$env:USERPROFILE\Documents\WindowsPowerShell\Modules`.

## Import

```powershell
Import-Module AetherWeb -Force
Get-Command -Module AetherWeb
```

## Quick smoke test

```powershell
$server = New-HttpServer -Prefix 'http://localhost:8080/' -EnableManagementRoutes
Start-HttpServer -Server $server -RegisterManagementRoutes -Verbose
```

Browse to:

- `http://localhost:8080/health`
- `http://localhost:8080/api/time`

## Pattern 1: Static file server

```powershell
Import-Module AetherWeb -Force

$server = New-HttpServer `
    -Prefix 'http://localhost:8080/' `
    -RootPath 'C:\Temp\Site' `
    -EnableStaticFiles `
    -EnableDirectoryListing `
    -EnableRequestLogging `
    -RequestLogPath 'C:\Temp\AetherWeb.log'

Start-HttpServer -Server $server -Verbose
```

## Pattern 2: Tiny app server

```powershell
Import-Module AetherWeb -Force

$server = New-HttpServer -Prefix 'http://localhost:8080/'

Add-HttpRoute -Server $server -Method GET -Path '/hello' -ScriptBlock {
    param($Context, $Server)

    Write-HttpTextResponse `
        -Response $Context.Response `
        -StatusCode 200 `
        -ContentType 'text/plain; charset=utf-8' `
        -Body 'Hello from PowerShell.' `
        -RequestMethod $Context.Request.HttpMethod
}

Add-HttpRoute -Server $server -Method GET -Path '/api/items/{id}' -ScriptBlock {
    param($Context, $Server)

    $id = Get-HttpRouteValue -Context $Context -Name 'id'
    Write-HttpJsonResponse `
        -Response $Context.Response `
        -InputObject @{ Id = $id; Status = 'OK' } `
        -RequestMethod $Context.Request.HttpMethod
}

Start-HttpServer -Server $server -Verbose
```

## Pattern 3: Middleware and context items

```powershell
Import-Module AetherWeb -Force

$server = New-HttpServer -Prefix 'http://localhost:8080/'

Add-HttpMiddleware -Server $server -Name 'RequestId' -ScriptBlock {
    param($Context, $Server, $Next)

    Set-HttpContextItem -Context $Context -Name 'RequestId' -Value ([guid]::NewGuid().Guid)
    & $Next
}

Add-HttpRoute -Server $server -Method GET -Path '/request-id' -ScriptBlock {
    param($Context, $Server)

    $requestId = Get-HttpContextItem -Context $Context -Name 'RequestId'
    Write-HttpJsonResponse -Response $Context.Response -InputObject @{ RequestId = $requestId } -RequestMethod $Context.Request.HttpMethod
}

Start-HttpServer -Server $server -Verbose
```

## Pattern 4: URL-encoded forms

```powershell
Import-Module AetherWeb -Force

$server = New-HttpServer -Prefix 'http://localhost:8080/'

Add-HttpRoute -Server $server -Method POST -Path '/submit' -ScriptBlock {
    param($Context, $Server)

    $form = Get-HttpRequestFormUrlEncoded -Request $Context.Request
    Write-HttpJsonResponse -Response $Context.Response -InputObject $form -Depth 6 -RequestMethod $Context.Request.HttpMethod
}

Start-HttpServer -Server $server -Verbose
```

## Pattern 5: Multipart uploads

```powershell
Import-Module AetherWeb -Force

$server = New-HttpServer -Prefix 'http://localhost:8080/' -MaxMultipartFileBytes 5MB

Add-HttpRoute -Server $server -Method POST -Path '/upload' -ScriptBlock {
    param($Context, $Server)

    $upload = Get-HttpMultipartFormData -Request $Context.Request -SaveFilesTo 'C:\Temp\Uploads'
    Write-HttpJsonResponse `
        -Response $Context.Response `
        -InputObject @{
            FieldNames = @($upload.Fields.Keys)
            Files      = $upload.Files | Select-Object Name, FileName, Length, SavedPath
        } `
        -Depth 6 `
        -RequestMethod $Context.Request.HttpMethod
}

Start-HttpServer -Server $server -Verbose
```

## Pattern 6: Grouped routes

```powershell
Import-Module AetherWeb -Force

$server = New-HttpServer -Prefix 'http://localhost:8080/'

$definitions = @(
    @{
        Method = 'GET'
        Path = '/status'
        ScriptBlock = {
            param($Context, $Server)
            Write-HttpJsonResponse -Response $Context.Response -InputObject @{ Status = 'OK' } -RequestMethod $Context.Request.HttpMethod
        }
    },
    @{
        Method = 'GET'
        Path = '/time'
        ScriptBlock = {
            param($Context, $Server)
            Write-HttpJsonResponse -Response $Context.Response -InputObject @{ Time = Get-Date } -RequestMethod $Context.Request.HttpMethod
        }
    }
)

Add-HttpRouteGroup -Server $server -Prefix '/api' -Definitions $definitions
Start-HttpServer -Server $server -Verbose
```

## Pattern 7: CORS middleware

### Development policy

```powershell
Import-Module AetherWeb -Force

$server = New-HttpServer -Prefix 'http://localhost:8080/'

Add-HttpCorsMiddleware -Server $server `
    -AllowAnyOrigin `
    -AllowAnyMethod `
    -AllowAnyHeader

Add-HttpRoute -Server $server -Method GET -Path '/api/health' -ScriptBlock {
    param($Context, $Server)

    Write-HttpJsonResponse -Response $Context.Response -InputObject @{ Status = 'OK'; Time = Get-Date } -RequestMethod $Context.Request.HttpMethod
}

Start-HttpServer -Server $server -Verbose
```

### Restricted browser API policy

```powershell
Import-Module AetherWeb -Force

$server = New-HttpServer -Prefix 'http://localhost:8080/'

Add-HttpCorsMiddleware -Server $server `
    -AllowedOrigin 'https://portal.contoso.local' `
    -AllowedMethod 'GET','POST','OPTIONS' `
    -AllowedHeader 'Content-Type','Authorization' `
    -ExposedHeader 'X-Request-Id' `
    -AllowCredentials `
    -PathPrefix '/api'

Add-HttpRoute -Server $server -Method GET -Path '/api/health' -ScriptBlock {
    param($Context, $Server)

    Set-HttpResponseHeader -Response $Context.Response -Name 'X-Request-Id' -Value ([guid]::NewGuid().Guid)
    Write-HttpJsonResponse -Response $Context.Response -InputObject @{ Status = 'OK' } -RequestMethod $Context.Request.HttpMethod
}

Start-HttpServer -Server $server -Verbose
```

## Pattern 8: Background hosting

```powershell
Import-Module AetherWeb -Force

$server = New-HttpServer -Prefix 'http://localhost:8080/' -EnableManagementRoutes
$server = Start-HttpServerBackground -Server $server -RegisterManagementRoutes -Verbose

# Later
Stop-HttpServer -Server $server
```

## Pattern 9: Small HTML admin page

```powershell
Import-Module AetherWeb -Force

$server = New-HttpServer -Prefix 'http://localhost:8080/'

Add-HttpRoute -Server $server -Method GET -Path '/admin' -ScriptBlock {
    param($Context, $Server)

    $page = New-HttpHtmlPage -Title 'AetherWeb Admin' -Body '<h1>Admin</h1><p>OK</p>'
    Write-HttpHtmlResponse -Response $Context.Response -Body $page -RequestMethod $Context.Request.HttpMethod
}

Start-HttpServer -Server $server -Verbose
```

## Validation on a Windows PowerShell 5.1 host

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$sourceRoot = 'C:\Path\To\AetherWeb.Source'
& (Join-Path $sourceRoot 'Tests\Invoke-AetherWebValidation.ps1') -ModuleVersion '1.5.0' -Verbose
```

## Notes

- AetherWeb is designed for internal tooling and labs, not internet-facing production workloads.
- For non-localhost prefixes, configure a URL ACL and firewall rules as required.
- Background hosting is convenient for smoke tests and lightweight services, but foreground hosting is simpler to debug.


## Pattern 8: MOM bridge over HTTP

```powershell
Import-Module AetherWeb -Force

$queue = New-FileMessageQueue -Path 'C:\AetherWeb\Queues\Jobs'
$server = New-HttpServer -Prefix 'http://localhost:8080/'

Add-HttpEnqueueMiddleware -Server $server `
    -QueuePath $queue.Path `
    -PathPrefix '/api/jobs' `
    -Method POST `
    -MessageType 'JobSubmitted'

Add-HttpMessageStatusRoutes -Server $server `
    -QueuePath $queue.Path `
    -BasePath '/api/messages' `
    -IncludeStatisticsRoute

Start-HttpServer -Server $server -Verbose
```

Example client payload:

```json
{
  "jobType": "InventoryScan",
  "computerName": "SRV-001"
}
```

The server returns `202 Accepted` with a `messageId`, `correlationId`, and a status URL.

## Pattern 9: Queue worker

```powershell
Import-Module AetherWeb -Force

Start-FileQueueWorker -Path 'C:\AetherWeb\Queues\Jobs' -UntilEmpty -HandlerScriptBlock {
    param($Message)

    # Simulate work.
    [pscustomobject]@{
        MessageId = $Message.MessageId
        Outcome   = 'Processed'
        When      = Get-Date
    }
}
```

## Pattern 10: Inspect queue state

```powershell
Import-Module AetherWeb -Force

Get-FileQueueStats -Path 'C:\AetherWeb\Queues\Jobs'
Get-FileMessage -Path 'C:\AetherWeb\Queues\Jobs' -MessageId '00000000-0000-0000-0000-000000000000'
```


## 1.7.5 Reliability additions

This release emphasizes correctness and operability. It adds structured request logging, correlation headers, graceful stop coordination, stale-processing recovery, retry helpers, idempotency-aware enqueue behavior, and queue repair functions.

### Example: reliability-focused queue worker

```powershell
Import-Module AetherWeb -Force
Repair-FileMessageQueue -Path 'C:\AetherWeb\Queues\Jobs' -ResumeStaleMessages
Start-FileQueueWorker -Path 'C:\AetherWeb\Queues\Jobs' -ResumeStaleMessages -LeaseSeconds 300 -UntilEmpty -HandlerScriptBlock {
    param($Message)
    [pscustomobject]@{ MessageId = $Message.MessageId; CompletedAt = Get-Date }
}
```

### Example: idempotent HTTP bridge

```powershell
Import-Module AetherWeb -Force
$server = New-HttpServer -Prefix 'http://localhost:8080/' -EnableRequestLogging -RequestLogPath 'C:\Temp\AetherWeb.jsonl'
Add-HttpEnqueueMiddleware -Server $server -QueuePath 'C:\AetherWeb\Queues\Jobs' -ExactPath '/api/jobs' -Method POST -MessageType 'JobSubmitted' -IdempotencyHeaderName 'Idempotency-Key'
Start-HttpServer -Server $server -Verbose
```


## Import validation note

Version 1.7.5 fixes a PowerShell parser issue in `New-HttpDirectoryListingHtml` caused by invalid embedded quote escaping inside HTML anchor generation.

## Help updates

Comment-based help was expanded across the public commands. In addition to command-usage examples, each public function now includes extra `Get-Help` discovery examples such as:

```powershell
Get-Help New-HttpServer -Detailed
Get-Help Add-HttpCorsMiddleware -Examples
```


## Shutdown route example

```powershell
Import-Module AetherWeb -Force
$server = New-HttpServer -Prefix http://localhost:8080/
Add-HttpShutdownRoute -Server $server -Path /admin/stop -Method POST -LocalOnly -Token ChangeMe | Out-Null
Start-HttpServer -Server $server -Verbose
# From another shell:
# Invoke-RestMethod -Method Post -Uri http://localhost:8080/admin/stop -Headers @{ X-Admin-Token = ChangeMe }
```
