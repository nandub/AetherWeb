@{
    RootModule        = 'AetherWeb.psm1'
    ModuleVersion = '1.7.8'
    GUID              = 'f08eb763-a035-455c-87bf-e69f4075b689'
    Author            = 'OpenAI, Fernando Ortiz'
    CompanyName       = 'OpenAI'
    Copyright         = '(c) OpenAI, Fernando Ortiz. All rights reserved.'
    Description       = 'Lightweight HTTP server framework for Windows PowerShell 5.1 using System.Net.HttpListener.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-HttpContentType',
        'New-FileMessageQueue',
        'New-HttpMessageEnvelope',
        'Send-FileMessage',
        'Get-FileMessage',
        'Get-FileQueueStats',
        'Receive-FileMessage',
        'Complete-FileMessage',
        'Move-FileMessageToDeadLetter',
        'Resume-StaleFileMessages',
        'Retry-FileMessage',
        'Remove-FileMessage',
        'Repair-FileMessageQueue',
        'Write-HttpAcceptedResponse',
        'Get-HttpRequestQueryValue',
        'Get-HttpRouteValue',
        'Get-HttpContextItem',
        'Set-HttpContextItem',
        'Get-HttpRequestBodyBytes',
        'Get-HttpRequestBodyText',
        'Get-HttpRequestBodyJson',
        'Get-HttpRequestFormUrlEncoded',
        'Get-HttpMultipartFormData',
        'Set-HttpResponseHeader',
        'Add-HttpResponseCookie',
        'New-HttpHtmlPage',
        'Write-HttpBytesResponse',
        'Write-HttpTextResponse',
        'Write-HttpHtmlResponse',
        'Write-HttpJsonResponse',
        'Write-HttpFileResponse',
        'Write-HttpErrorResponse',
        'New-HttpServer',
        'Add-HttpRoute',
        'Add-HttpRoutePrefix',
        'Add-HttpRouteGroup',
        'Add-HttpMiddleware',
        'Add-HttpEnqueueMiddleware',
        'Add-HttpMessageStatusRoutes',
        'Add-HttpCorsMiddleware',
        'Add-HttpShutdownRoute',
        'Add-HttpManagementRoutes',
        'Start-HttpServer',
        'Start-FileQueueWorker',
        'Start-HttpServerBackground',
        'Stop-HttpServer'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('HTTP', 'WebServer', 'HttpListener', 'PowerShell', 'StaticFiles', 'API', 'Middleware', 'Multipart', 'CORS', 'MOM', 'Queue')
            ProjectUri   = 'https://github.com/nandub/AetherWeb'
            LicenseUri   = 'https://github.com/nandub/AetherWeb/LICENSE'
            ReleaseNotes = 'Replaced the async listener loop with a synchronous GetContext() acceptance loop for improved PowerShell 5.1 runtime stability, and added per-request verbose logging in Start-HttpServer.'
        }
    }

    HelpInfoURI = 'https://example.invalid/help/AetherWeb'
}
