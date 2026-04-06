## AetherWeb 1.7.7

This release fixes `Get-FileQueueStats` and the `/api/messages/stats` route path handling, and expands comment-based help examples across the exported functions.

# AetherWeb Examples

This document collects practical examples for common public functions.

## New-HttpServer

```powershell
New-HttpServer -Prefix 'http://localhost:8080/'
New-HttpServer -Prefix 'http://localhost:8080/' -RootPath 'C:\Temp\Site' -EnableStaticFiles -EnableDirectoryListing
New-HttpServer -Prefix 'http://localhost:8080/' -EnableRequestLogging -RequestLogPath 'C:\Temp\AetherWeb.log' -WhatIf
```

## Add-HttpRoute

```powershell
Add-HttpRoute -Server $server -Method GET -Path '/health' -ScriptBlock { param($Context, $Server) Write-HttpJsonResponse -Response $Context.Response -InputObject @{ Status = 'OK' } -RequestMethod $Context.Request.HttpMethod }
Add-HttpRoute -Server $server -Method GET -Path '/api/items/{id}' -ScriptBlock { param($Context, $Server) $id = Get-HttpRouteValue -Context $Context -Name 'id'; Write-HttpJsonResponse -Response $Context.Response -InputObject @{ Id = $id } -RequestMethod $Context.Request.HttpMethod }
```

## Add-HttpRoutePrefix

```powershell
Add-HttpRoutePrefix -Server $server -Method GET -Prefix '/api/files/' -ScriptBlock { param($Context, $Server) Write-HttpJsonResponse -Response $Context.Response -InputObject @{ Path = $Context.Request.RawUrl } -RequestMethod $Context.Request.HttpMethod }
```

## Add-HttpMiddleware

```powershell
Add-HttpMiddleware -Server $server -Name 'Timer' -ScriptBlock { param($Context, $Server, $Next) $start = Get-Date; & $Next; $elapsed = (Get-Date) - $start; Write-Verbose ('Elapsed: {0} ms' -f [int]$elapsed.TotalMilliseconds) }
```

## Add-HttpCorsMiddleware

```powershell
Add-HttpCorsMiddleware -Server $server -AllowAnyOrigin -AllowAnyMethod -AllowAnyHeader
Add-HttpCorsMiddleware -Server $server -AllowedOrigin 'https://portal.contoso.local' -AllowedMethod 'GET','POST','OPTIONS' -AllowedHeader 'Content-Type','Authorization' -AllowCredentials -PathPrefix '/api'
```

## Request parsing

```powershell
Get-HttpRequestBodyText -Request $Context.Request
Get-HttpRequestBodyJson -Request $Context.Request
Get-HttpRequestFormUrlEncoded -Request $Context.Request
Get-HttpMultipartFormData -Request $Context.Request -SaveFilesTo 'C:\Temp\Uploads'
```

## Response helpers

```powershell
Set-HttpResponseHeader -Response $Context.Response -Name 'X-Request-Id' -Value ([guid]::NewGuid().Guid)
Add-HttpResponseCookie -Response $Context.Response -Name 'session' -Value 'abc' -HttpOnly -Path '/'
$page = New-HttpHtmlPage -Title 'Status' -Body '<h1>OK</h1>'
Write-HttpHtmlResponse -Response $Context.Response -Body $page -RequestMethod $Context.Request.HttpMethod
Write-HttpErrorResponse -Response $Context.Response -StatusCode 404 -StatusDescription '404 Not Found' -RequestMethod $Context.Request.HttpMethod
```


## MOM bridge

```powershell
$queue = New-FileMessageQueue -Path 'C:\AetherWeb\Queues\Jobs'
Add-HttpEnqueueMiddleware -Server $server -QueuePath $queue.Path -PathPrefix '/api/jobs' -Method POST -MessageType 'JobSubmitted'
Add-HttpEnqueueMiddleware -Server $server -QueuePath $queue.Path -ExactPath '/api/orders' -Method POST -MessageTypePropertyName 'messageType'
Add-HttpMessageStatusRoutes -Server $server -QueuePath $queue.Path -BasePath '/api/messages' -IncludeStatisticsRoute
```

## File-backed queue helpers

```powershell
New-FileMessageQueue -Path 'C:\AetherWeb\Queues\Jobs'
$envelope = New-HttpMessageEnvelope -MessageType 'InventoryScan' -Payload @{ ComputerName = 'SRV-01' }
Send-FileMessage -Path 'C:\AetherWeb\Queues\Jobs' -Envelope $envelope
Receive-FileMessage -Path 'C:\AetherWeb\Queues\Jobs'
Get-FileQueueStats -Path 'C:\AetherWeb\Queues\Jobs'
Start-FileQueueWorker -Path 'C:\AetherWeb\Queues\Jobs' -UntilEmpty -HandlerScriptBlock { param($Message) 'done' }
```


# Reliability examples (1.7.5)

## Structured JSONL request logging

```powershell
$server = New-HttpServer -Prefix 'http://localhost:8080/' -EnableRequestLogging -RequestLogPath 'C:\Temp\AetherWeb.jsonl' -RequestLogFormat JsonLines
```

## Resume stale messages

```powershell
Resume-StaleFileMessages -Path 'C:\AetherWeb\Queues\Jobs' -IncludeExpired
```

## Retry a failed processing message

```powershell
$message = Get-FileMessage -Path 'C:\AetherWeb\Queues\Jobs' -MessageId '00000000-0000-0000-0000-000000000000'
Retry-FileMessage -Path 'C:\AetherWeb\Queues\Jobs' -Message $message
```

## Remove a completed or dead-lettered message

```powershell
Remove-FileMessage -Path 'C:\AetherWeb\Queues\Jobs' -MessageId '00000000-0000-0000-0000-000000000000'
```


## Help discovery examples

```powershell
Get-Help New-HttpServer -Detailed
Get-Help Add-HttpEnqueueMiddleware -Examples
Get-Help Start-FileQueueWorker -Full
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
