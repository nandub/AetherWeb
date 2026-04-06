
<#
.SYNOPSIS
AetherWeb module.
.DESCRIPTION
Provides a lightweight HTTP server framework for Windows PowerShell 5.1 using
System.Net.HttpListener. Supports static file serving, exact, template, and prefix
routes, middleware, request logging, request body parsing, form parsing, multipart
uploads, optional background hosting, response headers, cookies, request
size enforcement, route groups, and HTML page helpers.
.NOTES
Designed for Windows PowerShell 5.1 compatibility.
#>

Set-StrictMode -Version 2.0

function ConvertTo-HttpHtmlEncodedText {
<#
.SYNOPSIS
HTML-encodes text.
.DESCRIPTION
Encodes text for safe HTML output.
.PARAMETER Text
Text to encode.
.EXAMPLE
PS C:\> ConvertTo-HttpHtmlEncodedText -Text '<hello>'
.INPUTS
System.String
.OUTPUTS
System.String
.NOTES
Internal helper.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Text
    )
    begin {}
    process { [System.Net.WebUtility]::HtmlEncode($Text) }
    end {}
}

function New-HttpRouteMatchObject {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Route,
        [Parameter(Mandatory = $true)]
        [hashtable]$RouteValues
    )
    [pscustomobject]@{ Route = $Route; RouteValues = $RouteValues }
}

function Ensure-HttpContextItems {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpListenerContext]$Context
    )
    if (-not ($Context.PSObject.Properties.Name -contains 'Items')) {
        Add-Member -InputObject $Context -MemberType NoteProperty -Name Items -Value @{} -Force
    }
    $Context.Items
}

function Ensure-HttpRequestBodyCache {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpListenerRequest]$Request
    )
    if (-not ($Request.PSObject.Properties.Name -contains 'AetherWebBodyBytes')) {
        $stream = $Request.InputStream
        $memory = New-Object System.IO.MemoryStream
        try {
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
            $maxBodyBytes = $null
            if ($Request.PSObject.Properties.Name -contains 'AetherWebMaxRequestBodyBytes') { $maxBodyBytes = $Request.AetherWebMaxRequestBodyBytes }
            if (($null -ne $maxBodyBytes) -and ($maxBodyBytes -gt 0) -and (@($bytes).Count -gt $maxBodyBytes)) {
                Write-Error -Message ('Request body exceeds configured limit of {0} bytes.' -f $maxBodyBytes)
                return $null
            }
        }
        finally {
            $memory.Dispose()
        }
        Add-Member -InputObject $Request -MemberType NoteProperty -Name AetherWebBodyBytes -Value $bytes -Force
    }
    [byte[]]$Request.AetherWebBodyBytes
}

function Get-HttpBoundaryFromContentType {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$ContentType)
    $match = [regex]::Match($ContentType, 'boundary=("(?<q>[^"]+)"|(?<u>[^;]+))', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        if ($match.Groups['q'].Success) { return $match.Groups['q'].Value }
        return $match.Groups['u'].Value.Trim()
    }
    $null
}

function ConvertTo-HttpMultipartSections {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Boundary
    )
    $encoding = [System.Text.Encoding]::ISO8859_1
    $bodyText = $encoding.GetString($Bytes)
    $parts = $bodyText -split ([regex]::Escape('--' + $Boundary))
    $results = New-Object System.Collections.ArrayList
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $trimmedPart = $part.Trim()
        if ($trimmedPart -eq '--') { continue }
        $headerSplit = $part.IndexOf("`r`n`r`n")
        if ($headerSplit -lt 0) { continue }
        $headerText = $part.Substring(0, $headerSplit)
        $contentText = $part.Substring($headerSplit + 4)
        $contentText = $contentText.TrimEnd("`r", "`n")
        $headers = @{}
        foreach ($line in ($headerText -split "`r`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $idx = $line.IndexOf(':')
            if ($idx -gt 0) {
                $name = $line.Substring(0, $idx).Trim()
                $value = $line.Substring($idx + 1).Trim()
                $headers[$name] = $value
            }
        }
        $name = $null
        $fileName = $null
        if ($headers.ContainsKey('Content-Disposition')) {
            $disp = $headers['Content-Disposition']
            $nameMatch = [regex]::Match($disp, 'name="(?<name>[^"]+)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($nameMatch.Success) { $name = $nameMatch.Groups['name'].Value }
            $fileMatch = [regex]::Match($disp, 'filename="(?<filename>[^"]*)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($fileMatch.Success) { $fileName = $fileMatch.Groups['filename'].Value }
        }
        $contentBytes = $encoding.GetBytes($contentText)
        $contentType = $null
        if ($headers.ContainsKey('Content-Type')) { $contentType = $headers['Content-Type'] }
        [void]$results.Add([pscustomobject]@{
            Name        = $name
            FileName    = $fileName
            Headers     = $headers
            ContentType = $contentType
            Text        = $contentText
            Bytes       = $contentBytes
            IsFile      = -not [string]::IsNullOrEmpty($fileName)
        })
    }
    ,$results.ToArray()
}

function Get-HttpContentType {
<#
.SYNOPSIS
Returns a MIME type for a file path.
.DESCRIPTION
Maps common file extensions to content types.
.PARAMETER Path
The file path.
.EXAMPLE
PS C:\> Get-HttpContentType -Path 'C:\Temp\site\index.html'
.EXAMPLE
PS C:\> Get-HttpContentType -Path 'C:\Temp\site\index.html' -WhatIf
.INPUTS
System.String
.OUTPUTS
System.String
.NOTES
Unknown extensions return application/octet-stream.
.EXAMPLE
PS C:\> Get-Help Get-HttpContentType -Detailed

Displays the full comment-based help for Get-HttpContentType.

.EXAMPLE
PS C:\> Get-Help Get-HttpContentType -Examples

Displays the example set for Get-HttpContentType.


.EXAMPLE
PS C:\> Get-Help Get-HttpContentType -Full

Displays the complete help topic for Get-HttpContentType.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][string]$Path)
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($Path, 'Resolve content type')) { return }
        $extension = [System.IO.Path]::GetExtension($Path)
        switch ($extension.ToLowerInvariant()) {
            '.htm'  { 'text/html; charset=utf-8' }
            '.html' { 'text/html; charset=utf-8' }
            '.txt'  { 'text/plain; charset=utf-8' }
            '.css'  { 'text/css; charset=utf-8' }
            '.js'   { 'application/javascript; charset=utf-8' }
            '.json' { 'application/json; charset=utf-8' }
            '.xml'  { 'application/xml; charset=utf-8' }
            '.csv'  { 'text/csv; charset=utf-8' }
            '.jpg'  { 'image/jpeg' }
            '.jpeg' { 'image/jpeg' }
            '.png'  { 'image/png' }
            '.gif'  { 'image/gif' }
            '.svg'  { 'image/svg+xml' }
            '.ico'  { 'image/x-icon' }
            '.pdf'  { 'application/pdf' }
            '.zip'  { 'application/zip' }
            '.ps1'  { 'text/plain; charset=utf-8' }
            '.psm1' { 'text/plain; charset=utf-8' }
            '.psd1' { 'text/plain; charset=utf-8' }
            default { 'application/octet-stream' }
        }
    }
    end {}
}

function Get-HttpRequestQueryValue {
<#
.SYNOPSIS
Gets a query-string value from a request.
.DESCRIPTION
Returns one or more values from the request query string.
.PARAMETER Request
The HttpListenerRequest.
.PARAMETER Name
The query-string key name.
.EXAMPLE
PS C:\> Get-HttpRequestQueryValue -Request $Context.Request -Name 'top'
.EXAMPLE
PS C:\> Get-HttpRequestQueryValue -Request $Context.Request -Name 'top' -WhatIf
.INPUTS
None.
.OUTPUTS
System.String
.NOTES
Returns multiple values one item at a time if the key occurs multiple times.
.EXAMPLE
PS C:\> Get-Help Get-HttpRequestQueryValue -Detailed

Displays the full comment-based help for Get-HttpRequestQueryValue.

.EXAMPLE
PS C:\> Get-Help Get-HttpRequestQueryValue -Examples

Displays the example set for Get-HttpRequestQueryValue.


.EXAMPLE
PS C:\> Get-Help Get-HttpRequestQueryValue -Full

Displays the complete help topic for Get-HttpRequestQueryValue.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerRequest]$Request,
        [Parameter(Mandatory = $true)][string]$Name
    )
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($Name, 'Read query-string value')) { return }
        try {
            $values = $Request.QueryString.GetValues($Name)
            if ($null -ne $values) { foreach ($value in $values) { Write-Output $value } }
        }
        catch {
            Write-Error -Message ('Failed to read query-string value ''{0}'': {1}' -f $Name, $_.Exception.Message)
        }
    }
    end {}
}

function Get-HttpRouteValue {
<#
.SYNOPSIS
Gets a route parameter value from the current context.
.DESCRIPTION
Returns a value captured from a template route such as /api/items/{id}.
.PARAMETER Context
The HttpListenerContext.
.PARAMETER Name
The route parameter name.
.EXAMPLE
PS C:\> Get-HttpRouteValue -Context $Context -Name 'id'
.EXAMPLE
PS C:\> Get-HttpRouteValue -Context $Context -Name 'id' -WhatIf
.INPUTS
None.
.OUTPUTS
System.String
.NOTES
Route values are set by template route matching.
.EXAMPLE
PS C:\> Get-Help Get-HttpRouteValue -Detailed

Displays the full comment-based help for Get-HttpRouteValue.

.EXAMPLE
PS C:\> Get-Help Get-HttpRouteValue -Examples

Displays the example set for Get-HttpRouteValue.


.EXAMPLE
PS C:\> Get-Help Get-HttpRouteValue -Full

Displays the complete help topic for Get-HttpRouteValue.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][string]$Name
    )
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($Name, 'Read route value')) { return }
        $items = Ensure-HttpContextItems -Context $Context
        if ($items.ContainsKey('RouteValues')) {
            $routeValues = $items['RouteValues']
            if ($routeValues.ContainsKey($Name)) { $routeValues[$Name] }
        }
    }
    end {}
}

function Get-HttpContextItem {
<#
.SYNOPSIS
Gets a middleware context item.
.DESCRIPTION
Returns a value from the per-request Items bag.
.PARAMETER Context
The HttpListenerContext.
.PARAMETER Name
The item key name.
.EXAMPLE
PS C:\> Get-HttpContextItem -Context $Context -Name 'RequestId'
.EXAMPLE
PS C:\> Get-HttpContextItem -Context $Context -Name 'RequestId' -WhatIf
.INPUTS
None.
.OUTPUTS
System.Object
.NOTES
The Items bag is per request.
.EXAMPLE
PS C:\> Get-Help Get-HttpContextItem -Detailed

Displays the full comment-based help for Get-HttpContextItem.

.EXAMPLE
PS C:\> Get-Help Get-HttpContextItem -Examples

Displays the example set for Get-HttpContextItem.


.EXAMPLE
PS C:\> Get-Help Get-HttpContextItem -Full

Displays the complete help topic for Get-HttpContextItem.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][string]$Name
    )
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($Name, 'Read context item')) { return }
        $items = Ensure-HttpContextItems -Context $Context
        if ($items.ContainsKey($Name)) { $items[$Name] }
    }
    end {}
}

function Set-HttpContextItem {
<#
.SYNOPSIS
Sets a middleware context item.
.DESCRIPTION
Stores a value in the per-request Items bag.
.PARAMETER Context
The HttpListenerContext.
.PARAMETER Name
The item key name.
.PARAMETER Value
The value to store.
.EXAMPLE
PS C:\> Set-HttpContextItem -Context $Context -Name 'RequestId' -Value ([guid]::NewGuid().Guid)
.EXAMPLE
PS C:\> Set-HttpContextItem -Context $Context -Name 'RequestId' -Value 'abc' -WhatIf
.INPUTS
None.
.OUTPUTS
None.
.NOTES
The Items bag is per request.
.EXAMPLE
PS C:\> Get-Help Set-HttpContextItem -Detailed

Displays the full comment-based help for Set-HttpContextItem.

.EXAMPLE
PS C:\> Get-Help Set-HttpContextItem -Examples

Displays the example set for Set-HttpContextItem.


.EXAMPLE
PS C:\> Get-Help Set-HttpContextItem -Full

Displays the complete help topic for Set-HttpContextItem.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value
    )
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($Name, 'Set context item')) { return }
        $items = Ensure-HttpContextItems -Context $Context
        $items[$Name] = $Value
    }
    end {}
}

function Get-HttpRequestBodyBytes {
<#
.SYNOPSIS
Gets the raw request body as bytes.
.DESCRIPTION
Reads the request body once and caches the result on the request object.
.PARAMETER Request
The HttpListenerRequest.
.EXAMPLE
PS C:\> Get-HttpRequestBodyBytes -Request $Context.Request
.EXAMPLE
PS C:\> Get-HttpRequestBodyBytes -Request $Context.Request -WhatIf
.INPUTS
None.
.OUTPUTS
System.Byte[]
.NOTES
Safe to call more than once during a single request.
.EXAMPLE
PS C:\> Get-Help Get-HttpRequestBodyBytes -Detailed

Displays the full comment-based help for Get-HttpRequestBodyBytes.

.EXAMPLE
PS C:\> Get-Help Get-HttpRequestBodyBytes -Examples

Displays the example set for Get-HttpRequestBodyBytes.


.EXAMPLE
PS C:\> Get-Help Get-HttpRequestBodyBytes -Full

Displays the complete help topic for Get-HttpRequestBodyBytes.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([byte[]])]
    param([Parameter(Mandatory = $true)][System.Net.HttpListenerRequest]$Request)
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($Request.RawUrl, 'Read request body bytes')) { return }
        try { Ensure-HttpRequestBodyCache -Request $Request }
        catch { Write-Error -Message ('Failed to read request body bytes: {0}' -f $_.Exception.Message) }
    }
    end {}
}

function Get-HttpRequestBodyText {
<#
.SYNOPSIS
Gets the request body as text.
.DESCRIPTION
Returns the request body decoded using the supplied encoding or UTF-8.
.PARAMETER Request
The HttpListenerRequest.
.PARAMETER Encoding
Optional text encoding.
.EXAMPLE
PS C:\> Get-HttpRequestBodyText -Request $Context.Request
.EXAMPLE
PS C:\> Get-HttpRequestBodyText -Request $Context.Request -WhatIf
.INPUTS
None.
.OUTPUTS
System.String
.NOTES
Uses cached request body bytes.
.EXAMPLE
PS C:\> Get-Help Get-HttpRequestBodyText -Detailed

Displays the full comment-based help for Get-HttpRequestBodyText.

.EXAMPLE
PS C:\> Get-Help Get-HttpRequestBodyText -Examples

Displays the example set for Get-HttpRequestBodyText.


.EXAMPLE
PS C:\> Get-Help Get-HttpRequestBodyText -Full

Displays the complete help topic for Get-HttpRequestBodyText.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerRequest]$Request,
        [Parameter()][System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8
    )
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($Request.RawUrl, 'Read request body text')) { return }
        try {
            $bytes = Ensure-HttpRequestBodyCache -Request $Request
            $Encoding.GetString($bytes)
        }
        catch { Write-Error -Message ('Failed to read request body text: {0}' -f $_.Exception.Message) }
    }
    end {}
}

function Get-HttpRequestBodyJson {
<#
.SYNOPSIS
Gets the request body as a JSON object.
.DESCRIPTION
Decodes the request body as text and converts it from JSON.
.PARAMETER Request
The HttpListenerRequest.
.PARAMETER Encoding
Optional text encoding.
.EXAMPLE
PS C:\> Get-HttpRequestBodyJson -Request $Context.Request
.EXAMPLE
PS C:\> $body = Get-HttpRequestBodyJson -Request $Context.Request
PS C:\> Write-HttpJsonResponse -Response $Context.Response -InputObject $body -RequestMethod $Context.Request.HttpMethod
.EXAMPLE
PS C:\> Get-HttpRequestBodyJson -Request $Context.Request -WhatIf
.INPUTS
None.
.OUTPUTS
System.Object
.NOTES
Uses cached request body bytes.
.EXAMPLE
PS C:\> Get-Help Get-HttpRequestBodyJson -Detailed

Displays the full comment-based help for Get-HttpRequestBodyJson.

.EXAMPLE
PS C:\> Get-Help Get-HttpRequestBodyJson -Examples

Displays the example set for Get-HttpRequestBodyJson.


.EXAMPLE
PS C:\> Get-Help Get-HttpRequestBodyJson -Full

Displays the complete help topic for Get-HttpRequestBodyJson.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerRequest]$Request,
        [Parameter()][System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8
    )
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($Request.RawUrl, 'Read request body JSON')) { return }
        try {
            $text = Get-HttpRequestBodyText -Request $Request -Encoding $Encoding
            if (-not [string]::IsNullOrWhiteSpace($text)) { $text | ConvertFrom-Json }
        }
        catch { Write-Error -Message ('Failed to parse request body JSON: {0}' -f $_.Exception.Message) }
    }
    end {}
}

function Get-HttpRequestFormUrlEncoded {
<#
.SYNOPSIS
Parses an application/x-www-form-urlencoded request body.
.DESCRIPTION
Returns a hashtable of keys to arrays of decoded values.
.PARAMETER Request
The HttpListenerRequest.
.PARAMETER Encoding
Optional text encoding.
.EXAMPLE
PS C:\> Get-HttpRequestFormUrlEncoded -Request $Context.Request
.EXAMPLE
PS C:\> $form = Get-HttpRequestFormUrlEncoded -Request $Context.Request
PS C:\> $form['Name']
.EXAMPLE
PS C:\> Get-HttpRequestFormUrlEncoded -Request $Context.Request -WhatIf
.INPUTS
None.
.OUTPUTS
System.Collections.Hashtable
.NOTES
Values are returned as string arrays.
.EXAMPLE
PS C:\> Get-Help Get-HttpRequestFormUrlEncoded -Detailed

Displays the full comment-based help for Get-HttpRequestFormUrlEncoded.

.EXAMPLE
PS C:\> Get-Help Get-HttpRequestFormUrlEncoded -Examples

Displays the example set for Get-HttpRequestFormUrlEncoded.


.EXAMPLE
PS C:\> Get-Help Get-HttpRequestFormUrlEncoded -Full

Displays the complete help topic for Get-HttpRequestFormUrlEncoded.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerRequest]$Request,
        [Parameter()][System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8
    )
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($Request.RawUrl, 'Parse URL-encoded form')) { return }
        try {
            $text = Get-HttpRequestBodyText -Request $Request -Encoding $Encoding
            $result = @{}
            if ([string]::IsNullOrEmpty($text)) { return $result }
            foreach ($pair in ($text -split '&')) {
                if ([string]::IsNullOrEmpty($pair)) { continue }
                $parts = $pair -split '=', 2
                $name = [System.Uri]::UnescapeDataString(($parts[0] -replace '\+', ' '))
                $value = ''
                if ($parts.Count -gt 1) { $value = [System.Uri]::UnescapeDataString(($parts[1] -replace '\+', ' ')) }
                if (-not $result.ContainsKey($name)) { $result[$name] = @() }
                $result[$name] = @($result[$name]) + $value
            }
            $result
        }
        catch { Write-Error -Message ('Failed to parse URL-encoded form: {0}' -f $_.Exception.Message) }
    }
    end {}
}

function Get-HttpMultipartFormData {
<#
.SYNOPSIS
Parses a multipart/form-data request body.
.DESCRIPTION
Returns an object with Fields and Files collections. Optionally saves uploaded files to disk.
.PARAMETER Request
The HttpListenerRequest.
.PARAMETER SaveFilesTo
Optional folder where uploaded files should be written.
.PARAMETER Overwrite
When specified, allows overwriting files already present in SaveFilesTo.
.EXAMPLE
PS C:\> Get-HttpMultipartFormData -Request $Context.Request
.EXAMPLE
PS C:\> Get-HttpMultipartFormData -Request $Context.Request -SaveFilesTo 'C:\Temp\Uploads' -WhatIf
.INPUTS
None.
.OUTPUTS
System.Management.Automation.PSCustomObject
.NOTES
Uses a simple parser suitable for lightweight internal tooling.
.EXAMPLE
PS C:\> Get-Help Get-HttpMultipartFormData -Detailed

Displays the full comment-based help for Get-HttpMultipartFormData.

.EXAMPLE
PS C:\> Get-Help Get-HttpMultipartFormData -Examples

Displays the example set for Get-HttpMultipartFormData.


.EXAMPLE
PS C:\> Get-Help Get-HttpMultipartFormData -Full

Displays the complete help topic for Get-HttpMultipartFormData.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerRequest]$Request,
        [Parameter()][string]$SaveFilesTo,
        [Parameter()][switch]$Overwrite,
        [Parameter()][ValidateRange(1, 2147483647)][int]$MaxFileBytes
    )
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($Request.RawUrl, 'Parse multipart form data')) { return }
        try {
            $contentType = $Request.ContentType
            if ([string]::IsNullOrEmpty($contentType)) { Write-Error -Message 'Request has no Content-Type header.'; return }
            $boundary = Get-HttpBoundaryFromContentType -ContentType $contentType
            if ([string]::IsNullOrEmpty($boundary)) { Write-Error -Message 'Multipart boundary not found in Content-Type.'; return }
            if ($PSBoundParameters.ContainsKey('SaveFilesTo')) {
                if (-not (Test-Path -LiteralPath $SaveFilesTo)) { Write-Error -Message ('SaveFilesTo path not found: {0}' -f $SaveFilesTo); return }
            }
            $bytes = Ensure-HttpRequestBodyCache -Request $Request
            $sections = ConvertTo-HttpMultipartSections -Bytes $bytes -Boundary $boundary
            $fields = @{}
            $files = New-Object System.Collections.ArrayList
            foreach ($section in $sections) {
                if ($section.IsFile) {
                    $savedPath = $null
                    $maxFileBytes = $null
                    if ($PSBoundParameters.ContainsKey('MaxFileBytes')) { $maxFileBytes = $MaxFileBytes }
                    elseif ($Request.PSObject.Properties.Name -contains 'AetherWebMaxMultipartFileBytes') { $maxFileBytes = $Request.AetherWebMaxMultipartFileBytes }
                    if (($null -ne $maxFileBytes) -and ($maxFileBytes -gt 0) -and (@($section.Bytes).Count -gt $maxFileBytes)) {
                        Write-Error -Message ('Multipart file exceeds configured limit of {0} bytes.' -f $maxFileBytes)
                        continue
                    }
                    if ($PSBoundParameters.ContainsKey('SaveFilesTo') -and -not [string]::IsNullOrEmpty($section.FileName)) {
                        $leaf = [System.IO.Path]::GetFileName($section.FileName)
                        $candidate = Join-Path -Path $SaveFilesTo -ChildPath $leaf
                        if ((Test-Path -LiteralPath $candidate) -and -not $Overwrite) {
                            Write-Error -Message ('File already exists: {0}' -f $candidate)
                        }
                        else {
                            if ($PSCmdlet.ShouldProcess($candidate, 'Write uploaded multipart file')) {
                                [System.IO.File]::WriteAllBytes($candidate, $section.Bytes)
                                $savedPath = $candidate
                            }
                        }
                    }
                    [void]$files.Add([pscustomobject]@{ Name = $section.Name; FileName = $section.FileName; ContentType = $section.ContentType; Length = @($section.Bytes).Count; Bytes = $section.Bytes; SavedPath = $savedPath })
                }
                else {
                    if (-not $fields.ContainsKey($section.Name)) { $fields[$section.Name] = @() }
                    $fields[$section.Name] = @($fields[$section.Name]) + $section.Text
                }
            }
            [pscustomobject]@{ Fields = $fields; Files = @($files.ToArray()) }
        }
        catch { Write-Error -Message ('Failed to parse multipart form data: {0}' -f $_.Exception.Message) }
    }
    end {}
}

function Write-HttpBytesResponse {
<#
.SYNOPSIS
Writes a byte-array response.
.DESCRIPTION
Writes a raw response to an HttpListenerResponse.
.PARAMETER Response
The HttpListenerResponse object.
.PARAMETER StatusCode
The HTTP status code.
.PARAMETER ContentType
The response content type.
.PARAMETER Bytes
The response body bytes.
.PARAMETER Encoding
The encoding used for text-based metadata.
.PARAMETER RequestMethod
The request method used for HEAD-aware behavior.
.EXAMPLE
PS C:\> Write-HttpBytesResponse -Response $Context.Response -StatusCode 200 -ContentType 'text/plain; charset=utf-8' -Bytes $Bytes -Encoding ([System.Text.Encoding]::UTF8) -RequestMethod $Context.Request.HttpMethod
.EXAMPLE
PS C:\> Write-HttpBytesResponse -Response $Context.Response -StatusCode 200 -ContentType 'text/plain; charset=utf-8' -Bytes $Bytes -Encoding ([System.Text.Encoding]::UTF8) -RequestMethod $Context.Request.HttpMethod -WhatIf
.INPUTS
None.
.OUTPUTS
None.
.NOTES
If RequestMethod is HEAD, only headers are written.
.EXAMPLE
PS C:\> Get-Help Write-HttpBytesResponse -Detailed

Displays the full comment-based help for Write-HttpBytesResponse.

.EXAMPLE
PS C:\> Get-Help Write-HttpBytesResponse -Examples

Displays the example set for Write-HttpBytesResponse.


.EXAMPLE
PS C:\> Get-Help Write-HttpBytesResponse -Full

Displays the complete help topic for Write-HttpBytesResponse.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][string]$ContentType,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][System.Text.Encoding]$Encoding,
        [Parameter()][string]$RequestMethod = 'GET'
    )
    if (-not $PSCmdlet.ShouldProcess(('HTTP {0}' -f $StatusCode), 'Write byte response')) { return }
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentEncoding = $Encoding
    $Response.ContentLength64 = @($Bytes).Count
    if ($RequestMethod -ne 'HEAD') { $Response.OutputStream.Write($Bytes, 0, @($Bytes).Count) }
}

function Write-HttpTextResponse {
<#
.SYNOPSIS
Writes a text response.
.DESCRIPTION
Encodes a string and writes it to the response stream.
.PARAMETER Response
The HttpListenerResponse object.
.PARAMETER StatusCode
The HTTP status code.
.PARAMETER ContentType
The response content type.
.PARAMETER Body
The body text.
.PARAMETER Encoding
The text encoding.
.PARAMETER RequestMethod
The request method used for HEAD-aware behavior.
.EXAMPLE
PS C:\> Write-HttpTextResponse -Response $Context.Response -StatusCode 200 -ContentType 'text/plain; charset=utf-8' -Body 'OK' -Encoding ([System.Text.Encoding]::UTF8) -RequestMethod $Context.Request.HttpMethod
.EXAMPLE
PS C:\> Write-HttpTextResponse -Response $Context.Response -StatusCode 200 -ContentType 'text/plain; charset=utf-8' -Body 'OK' -Encoding ([System.Text.Encoding]::UTF8) -RequestMethod $Context.Request.HttpMethod -WhatIf
.INPUTS
None.
.OUTPUTS
None.
.NOTES
If RequestMethod is HEAD, only headers are written.
.EXAMPLE
PS C:\> Get-Help Write-HttpTextResponse -Detailed

Displays the full comment-based help for Write-HttpTextResponse.

.EXAMPLE
PS C:\> Get-Help Write-HttpTextResponse -Examples

Displays the example set for Write-HttpTextResponse.


.EXAMPLE
PS C:\> Get-Help Write-HttpTextResponse -Full

Displays the complete help topic for Write-HttpTextResponse.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][string]$ContentType,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body,
        [Parameter()][System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8,
        [Parameter()][string]$RequestMethod = 'GET'
    )
    if (-not $PSCmdlet.ShouldProcess(('HTTP {0}' -f $StatusCode), 'Write text response')) { return }
    $bytes = $Encoding.GetBytes($Body)
    Write-HttpBytesResponse -Response $Response -StatusCode $StatusCode -ContentType $ContentType -Bytes $bytes -Encoding $Encoding -RequestMethod $RequestMethod
}

function Write-HttpHtmlResponse {
<#
.SYNOPSIS
Writes an HTML response.
.DESCRIPTION
Writes an HTML response using UTF-8 by default.
.PARAMETER Response
The HttpListenerResponse object.
.PARAMETER Body
The HTML body.
.PARAMETER StatusCode
The HTTP status code.
.PARAMETER Encoding
The text encoding.
.PARAMETER RequestMethod
The request method used for HEAD-aware behavior.
.EXAMPLE
PS C:\> Write-HttpHtmlResponse -Response $Context.Response -Body '<h1>Hello</h1>' -RequestMethod $Context.Request.HttpMethod
.EXAMPLE
PS C:\> Write-HttpHtmlResponse -Response $Context.Response -Body '<h1>Hello</h1>' -RequestMethod $Context.Request.HttpMethod -WhatIf
.INPUTS
None.
.OUTPUTS
None.
.NOTES
Uses text/html; charset=utf-8.
.EXAMPLE
PS C:\> Get-Help Write-HttpHtmlResponse -Detailed

Displays the full comment-based help for Write-HttpHtmlResponse.

.EXAMPLE
PS C:\> Get-Help Write-HttpHtmlResponse -Examples

Displays the example set for Write-HttpHtmlResponse.


.EXAMPLE
PS C:\> Get-Help Write-HttpHtmlResponse -Full

Displays the complete help topic for Write-HttpHtmlResponse.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body,
        [Parameter()][int]$StatusCode = 200,
        [Parameter()][System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8,
        [Parameter()][string]$RequestMethod = 'GET'
    )
    if (-not $PSCmdlet.ShouldProcess(('HTTP {0}' -f $StatusCode), 'Write HTML response')) { return }
    Write-HttpTextResponse -Response $Response -StatusCode $StatusCode -ContentType 'text/html; charset=utf-8' -Body $Body -Encoding $Encoding -RequestMethod $RequestMethod
}

function Write-HttpJsonResponse {
<#
.SYNOPSIS
Writes a JSON response.
.DESCRIPTION
Serializes an object to JSON and writes it as an application/json response.
.PARAMETER Response
The HttpListenerResponse object.
.PARAMETER InputObject
The object to serialize to JSON.
.PARAMETER StatusCode
The HTTP status code.
.PARAMETER Depth
ConvertTo-Json depth.
.PARAMETER Encoding
The response encoding.
.PARAMETER RequestMethod
The request method used for HEAD-aware behavior.
.EXAMPLE
PS C:\> Write-HttpJsonResponse -Response $Context.Response -InputObject @{ Status = 'OK' } -RequestMethod $Context.Request.HttpMethod
.EXAMPLE
PS C:\> Write-HttpJsonResponse -Response $Context.Response -InputObject @{ Status = 'OK' } -RequestMethod $Context.Request.HttpMethod -WhatIf
.INPUTS
None.
.OUTPUTS
None.
.NOTES
Uses application/json; charset=utf-8.
.EXAMPLE
PS C:\> Get-Help Write-HttpJsonResponse -Detailed

Displays the full comment-based help for Write-HttpJsonResponse.

.EXAMPLE
PS C:\> Get-Help Write-HttpJsonResponse -Examples

Displays the example set for Write-HttpJsonResponse.


.EXAMPLE
PS C:\> Get-Help Write-HttpJsonResponse -Full

Displays the complete help topic for Write-HttpJsonResponse.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory = $true)][AllowNull()][object]$InputObject,
        [Parameter()][int]$StatusCode = 200,
        [Parameter()][ValidateRange(1, 100)][int]$Depth = 5,
        [Parameter()][System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8,
        [Parameter()][string]$RequestMethod = 'GET'
    )
    if (-not $PSCmdlet.ShouldProcess(('HTTP {0}' -f $StatusCode), 'Write JSON response')) { return }
    $body = $InputObject | ConvertTo-Json -Depth $Depth
    Write-HttpTextResponse -Response $Response -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Body $body -Encoding $Encoding -RequestMethod $RequestMethod
}

function Write-HttpFileResponse {
<#
.SYNOPSIS
Writes a file response.
.DESCRIPTION
Streams a file to the response output stream.
.PARAMETER Response
The HttpListenerResponse object.
.PARAMETER Path
The local file path.
.PARAMETER RequestMethod
The request method used for HEAD-aware behavior.
.PARAMETER ContentType
Optional explicit content type.
.EXAMPLE
PS C:\> Write-HttpFileResponse -Response $Context.Response -Path 'C:\Temp\file.txt' -RequestMethod $Context.Request.HttpMethod
.EXAMPLE
PS C:\> Write-HttpFileResponse -Response $Context.Response -Path 'C:\Temp\file.txt' -RequestMethod $Context.Request.HttpMethod -WhatIf
.INPUTS
None.
.OUTPUTS
None.
.NOTES
If RequestMethod is HEAD, only headers are written.
.EXAMPLE
PS C:\> Get-Help Write-HttpFileResponse -Detailed

Displays the full comment-based help for Write-HttpFileResponse.

.EXAMPLE
PS C:\> Get-Help Write-HttpFileResponse -Examples

Displays the example set for Write-HttpFileResponse.


.EXAMPLE
PS C:\> Get-Help Write-HttpFileResponse -Full

Displays the complete help topic for Write-HttpFileResponse.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter()][string]$RequestMethod = 'GET',
        [Parameter()][string]$ContentType
    )
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write file response')) { return }
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
        $fileInfo = New-Object System.IO.FileInfo($resolved)
        $Response.StatusCode = 200
        if ([string]::IsNullOrEmpty($ContentType)) { $Response.ContentType = Get-HttpContentType -Path $resolved } else { $Response.ContentType = $ContentType }
        $Response.ContentLength64 = $fileInfo.Length
        if ($RequestMethod -ne 'HEAD') {
            $stream = [System.IO.File]::OpenRead($resolved)
            try { $stream.CopyTo($Response.OutputStream) } finally { $stream.Dispose() }
        }
    }
    catch { Write-Error -Message ('Failed to write file response: {0}' -f $_.Exception.Message) }
}

function Write-HttpErrorResponse {
<#
.SYNOPSIS
Writes a simple HTML error response.
.DESCRIPTION
Writes a minimal HTML page for an error status.
.PARAMETER Response
The HttpListenerResponse object.
.PARAMETER StatusCode
The HTTP status code.
.PARAMETER StatusDescription
The text description.
.PARAMETER Encoding
The response encoding.
.PARAMETER RequestMethod
The request method used for HEAD-aware behavior.
.EXAMPLE
PS C:\> Write-HttpErrorResponse -Response $Context.Response -StatusCode 404 -StatusDescription '404 Not Found' -RequestMethod $Context.Request.HttpMethod
.EXAMPLE
PS C:\> Write-HttpErrorResponse -Response $Context.Response -StatusCode 404 -StatusDescription '404 Not Found' -RequestMethod $Context.Request.HttpMethod -WhatIf
.INPUTS
None.
.OUTPUTS
None.
.NOTES
Minimal HTML body.
.EXAMPLE
PS C:\> Get-Help Write-HttpErrorResponse -Detailed

Displays the full comment-based help for Write-HttpErrorResponse.

.EXAMPLE
PS C:\> Get-Help Write-HttpErrorResponse -Examples

Displays the example set for Write-HttpErrorResponse.


.EXAMPLE
PS C:\> Get-Help Write-HttpErrorResponse -Full

Displays the complete help topic for Write-HttpErrorResponse.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][string]$StatusDescription,
        [Parameter()][System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8,
        [Parameter()][string]$RequestMethod = 'GET'
    )
    if (-not $PSCmdlet.ShouldProcess(('HTTP {0}' -f $StatusCode), 'Write error response')) { return }
    $safeText = ConvertTo-HttpHtmlEncodedText -Text $StatusDescription
    $body = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>$safeText</title>
</head>
<body>
    <h1>$safeText</h1>
</body>
</html>
"@
    Write-HttpHtmlResponse -Response $Response -StatusCode $StatusCode -Body $body -Encoding $Encoding -RequestMethod $RequestMethod
}

function Resolve-HttpLocalPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$RequestPath
    )
    $relativePath = [System.Uri]::UnescapeDataString($RequestPath)
    if ([string]::IsNullOrEmpty($relativePath)) { $relativePath = '/' }
    if ($relativePath.StartsWith('/')) { $relativePath = $relativePath.Substring(1) }
    $relativePath = $relativePath -replace '/', '\'
    $fullRoot = [System.IO.Path]::GetFullPath($RootPath)
    $combined = [System.IO.Path]::Combine($fullRoot, $relativePath)
    $fullTarget = [System.IO.Path]::GetFullPath($combined)
    if (-not $fullTarget.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    $fullTarget
}

function New-HttpDirectoryListingHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$RequestPath,
        [Parameter()][switch]$SortByName
    )
    $items = Get-ChildItem -LiteralPath $LocalPath -Force -ErrorAction Stop
    if ($SortByName) { $items = $items | Sort-Object -Property Name }
    $safePath = ConvertTo-HttpHtmlEncodedText -Text $RequestPath
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('<!DOCTYPE html>')
    [void]$builder.AppendLine('<html>')
    [void]$builder.AppendLine('<head>')
    [void]$builder.AppendLine('    <meta charset="utf-8" />')
    [void]$builder.AppendLine("    <title>Index of $safePath</title>")
    [void]$builder.AppendLine('</head>')
    [void]$builder.AppendLine('<body>')
    [void]$builder.AppendLine("    <h1>Index of $safePath</h1>")
    [void]$builder.AppendLine('    <ul>')
    if ($RequestPath -ne '/') { [void]$builder.AppendLine('        <li><a href="/">/</a></li>') }
    foreach ($item in $items) {
        $name = $item.Name
        $safeName = ConvertTo-HttpHtmlEncodedText -Text $name
        if ($RequestPath.EndsWith('/')) { $href = $RequestPath + $name } else { $href = $RequestPath + '/' + $name }
        if ($item.PSIsContainer) { $href = $href + '/'; [void]$builder.AppendLine("        <li><a href=""$href"">$safeName/</a></li>") }
        else { [void]$builder.AppendLine("        <li><a href=""$href"">$safeName</a></li>") }
    }
    [void]$builder.AppendLine('    </ul>')
    [void]$builder.AppendLine('</body>')
    [void]$builder.AppendLine('</html>')
    $builder.ToString()
}

function Write-HttpRequestLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Server,
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][datetime]$Started,
        [Parameter()][int]$StatusCode = 0
    )
    if (-not $Server.EnableRequestLogging) { return }
    if ([string]::IsNullOrEmpty($Server.RequestLogPath)) { return }
    try {
        $elapsed = (Get-Date) - $Started
        $remote = $null
        if ($Context.Request.RemoteEndPoint) { $remote = $Context.Request.RemoteEndPoint.ToString() }
        $line = '{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}' -f (Get-Date).ToString('o'), $Context.Request.HttpMethod, $Context.Request.RawUrl, $remote, $StatusCode, [int]$elapsed.TotalMilliseconds, $env:COMPUTERNAME
        Add-Content -LiteralPath $Server.RequestLogPath -Value $line -Encoding UTF8
    }
    catch { Write-Verbose -Message ('Request log write failed: {0}' -f $_.Exception.Message) }
}

function New-HttpServer {
<#
.SYNOPSIS
Creates a new in-memory HTTP server configuration object.
.DESCRIPTION
Initializes a server configuration object that can later be started with Start-HttpServer and stopped with Stop-HttpServer.
.PARAMETER Prefix
One or more HttpListener prefixes.
.PARAMETER RootPath
Optional static-file root path.
.PARAMETER DefaultDocument
Default document names for directories.
.PARAMETER EnableDirectoryListing
Enables directory listing for folders without a default document.
.PARAMETER SortDirectoryListing
Sorts directory entries by name.
.PARAMETER EnableStaticFiles
Enables static-file serving.
.PARAMETER EnableManagementRoutes
Registers built-in diagnostic endpoints when the server starts.
.PARAMETER EnableRequestLogging
Enables tab-delimited request logging.
.PARAMETER RequestLogPath
Path to the request log file.
.PARAMETER ManagementToken
Optional shared token checked against X-AetherWeb-Token for management routes.
.EXAMPLE
PS C:\> $server = New-HttpServer -Prefix 'http://localhost:8080/' -RootPath 'C:\Temp\Site' -EnableStaticFiles
.EXAMPLE
PS C:\> $server = New-HttpServer -Prefix 'http://localhost:8080/' -EnableManagementRoutes -EnableRequestLogging -RequestLogPath 'C:\Temp\AetherWeb.log'
.EXAMPLE
PS C:\> New-HttpServer -Prefix 'http://localhost:8080/' -WhatIf
.INPUTS
None.
.OUTPUTS
System.Management.Automation.PSCustomObject
.NOTES
Prefix values must end with '/'.
.EXAMPLE
PS C:\> Get-Help New-HttpServer -Detailed

Displays the full comment-based help for New-HttpServer.

.EXAMPLE
PS C:\> Get-Help New-HttpServer -Examples

Displays the example set for New-HttpServer.


.EXAMPLE
PS C:\> Get-Help New-HttpServer -Full

Displays the complete help topic for New-HttpServer.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$Prefix,
        [Parameter()][string]$RootPath,
        [Parameter()][string[]]$DefaultDocument = @('index.html', 'default.html'),
        [Parameter()][switch]$EnableDirectoryListing,
        [Parameter()][switch]$SortDirectoryListing,
        [Parameter()][switch]$EnableStaticFiles,
        [Parameter()][switch]$EnableManagementRoutes,
        [Parameter()][switch]$EnableRequestLogging,
        [Parameter()][string]$RequestLogPath,
        [Parameter()][string]$ManagementToken,
        [Parameter()][ValidateRange(1, 2147483647)][int]$MaxRequestBodyBytes,
        [Parameter()][ValidateRange(1, 2147483647)][int]$MaxMultipartFileBytes
    )
    begin {}
    process {
        foreach ($item in $Prefix) { if (-not $item.EndsWith('/')) { Write-Error -Message ('Prefix must end with ''/'': {0}' -f $item); return } }
        $resolvedRoot = $null
        if ($PSBoundParameters.ContainsKey('RootPath') -and -not [string]::IsNullOrEmpty($RootPath)) {
            try { $resolvedRoot = (Resolve-Path -LiteralPath $RootPath -ErrorAction Stop).ProviderPath }
            catch { Write-Error -Message ('RootPath not found: {0}' -f $RootPath); return }
        }
        if ($PSBoundParameters.ContainsKey('RequestLogPath') -and -not [string]::IsNullOrEmpty($RequestLogPath)) {
            try {
                $parent = Split-Path -Path $RequestLogPath -Parent
                if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) { Write-Error -Message ('Request log parent path not found: {0}' -f $parent); return }
            }
            catch { Write-Error -Message ('Invalid RequestLogPath: {0}' -f $_.Exception.Message); return }
        }
        if (-not $PSCmdlet.ShouldProcess(($Prefix -join ', '), 'Create HTTP server object')) { return }
        $listener = New-Object System.Net.HttpListener
        foreach ($item in $Prefix) { [void]$listener.Prefixes.Add($item) }
        [pscustomobject]@{
            PSTypeName              = 'AetherWeb.Server'
            Prefix                  = @($Prefix)
            RootPath                = $resolvedRoot
            DefaultDocument         = @($DefaultDocument)
            EnableDirectoryListing  = [bool]$EnableDirectoryListing
            SortDirectoryListing    = [bool]$SortDirectoryListing
            EnableStaticFiles       = [bool]$EnableStaticFiles
            EnableManagementRoutes  = [bool]$EnableManagementRoutes
            EnableRequestLogging    = [bool]$EnableRequestLogging
            RequestLogPath          = $RequestLogPath
            ManagementToken         = $ManagementToken
            MaxRequestBodyBytes     = $MaxRequestBodyBytes
            MaxMultipartFileBytes   = $MaxMultipartFileBytes
            Listener                = $listener
            Routes                  = New-Object System.Collections.ArrayList
            PrefixRoutes            = New-Object System.Collections.ArrayList
            TemplateRoutes          = New-Object System.Collections.ArrayList
            Middleware              = New-Object System.Collections.ArrayList
            IsRunning               = $false
            StartTime               = $null
            ResponseEncoding        = [System.Text.Encoding]::UTF8
            BackgroundPowerShell    = $null
            BackgroundHandle        = $null
        }
    }
    end {}
}

function Add-HttpRoute {
<#
.SYNOPSIS
Adds an exact-match or template route to a server.
.DESCRIPTION
Registers a route based on HTTP method and path. Paths containing segment placeholders such as /api/items/{id} are treated as template routes. The handler ScriptBlock receives $Context and $Server.
.PARAMETER Server
The server object returned by New-HttpServer.
.PARAMETER Method
The HTTP method, such as GET or HEAD.
.PARAMETER Path
The exact request path or template path.
.PARAMETER ScriptBlock
The route handler.
.EXAMPLE
PS C:\> Add-HttpRoute -Server $server -Method GET -Path '/health' -ScriptBlock { param($Context, $Server) Write-HttpJsonResponse -Response $Context.Response -InputObject @{ Status = 'OK' } -RequestMethod $Context.Request.HttpMethod }
.EXAMPLE
PS C:\> Add-HttpRoute -Server $server -Method GET -Path '/api/items/{id}' -ScriptBlock { param($Context, $Server) $id = Get-HttpRouteValue -Context $Context -Name 'id'; Write-HttpJsonResponse -Response $Context.Response -InputObject @{ Id = $id } -RequestMethod $Context.Request.HttpMethod }
.EXAMPLE
PS C:\> $server | Add-HttpRoute -Method GET -Path '/api/items/{id}' -ScriptBlock { param($Context, $Server) } -WhatIf
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
System.Management.Automation.PSCustomObject
.EXAMPLE
PS C:\> Get-Help Add-HttpRoute -Detailed

Displays the full comment-based help for Add-HttpRoute.

.EXAMPLE
PS C:\> Get-Help Add-HttpRoute -Examples

Displays the example set for Add-HttpRoute.


.EXAMPLE
PS C:\> Get-Help Add-HttpRoute -Full

Displays the complete help topic for Add-HttpRoute.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Method,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true)][ValidateNotNull()][scriptblock]$ScriptBlock
    )
    begin {}
    process {
        $normalizedMethod = $Method.ToUpperInvariant()
        if (-not $Path.StartsWith('/')) { Write-Error -Message ('Route path must begin with ''/'': {0}' -f $Path); return }
        $isTemplate = $Path -match '\{[^/]+\}'
        $routeKey = '{0}:{1}' -f $normalizedMethod, $Path
        if (-not $PSCmdlet.ShouldProcess($routeKey, 'Add HTTP route')) { return }
        $route = [pscustomobject]@{ PSTypeName='AetherWeb.Route'; Method=$normalizedMethod; Path=$Path; Key=$routeKey; ScriptBlock=$ScriptBlock; IsTemplate=$isTemplate }
        if ($isTemplate) { [void]$Server.TemplateRoutes.Add($route) } else { [void]$Server.Routes.Add($route) }
        Write-Output $route
    }
    end {}
}

function Add-HttpRoutePrefix {
<#
.SYNOPSIS
Adds a prefix route to a server.
.DESCRIPTION
Registers a route that matches when the request path starts with the specified prefix. The handler ScriptBlock receives $Context and $Server.
.PARAMETER Server
The server object returned by New-HttpServer.
.PARAMETER Method
The HTTP method, such as GET or POST.
.PARAMETER Prefix
The route prefix.
.PARAMETER ScriptBlock
The route handler.
.EXAMPLE
PS C:\> Add-HttpRoutePrefix -Server $server -Method GET -Prefix '/api/files/' -ScriptBlock { param($Context, $Server) }
.EXAMPLE
PS C:\> Add-HttpRoutePrefix -Server $server -Method GET -Prefix '/admin/' -ScriptBlock { param($Context, $Server) $page = New-HttpHtmlPage -Title 'Admin' -Body '<h1>Admin</h1>'; Write-HttpHtmlResponse -Response $Context.Response -Body $page -RequestMethod $Context.Request.HttpMethod }
.EXAMPLE
PS C:\> $server | Add-HttpRoutePrefix -Method GET -Prefix '/api/files/' -ScriptBlock { param($Context, $Server) } -WhatIf
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
System.Management.Automation.PSCustomObject
.EXAMPLE
PS C:\> Get-Help Add-HttpRoutePrefix -Detailed

Displays the full comment-based help for Add-HttpRoutePrefix.

.EXAMPLE
PS C:\> Get-Help Add-HttpRoutePrefix -Examples

Displays the example set for Add-HttpRoutePrefix.


.EXAMPLE
PS C:\> Get-Help Add-HttpRoutePrefix -Full

Displays the complete help topic for Add-HttpRoutePrefix.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Method,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Prefix,
        [Parameter(Mandatory = $true)][ValidateNotNull()][scriptblock]$ScriptBlock
    )
    begin {}
    process {
        if (-not $Prefix.StartsWith('/')) { Write-Error -Message ('Prefix route must begin with ''/'': {0}' -f $Prefix); return }
        $key = '{0}:{1}' -f $Method.ToUpperInvariant(), $Prefix
        if (-not $PSCmdlet.ShouldProcess($key, 'Add HTTP prefix route')) { return }
        $route = [pscustomobject]@{ PSTypeName='AetherWeb.PrefixRoute'; Method=$Method.ToUpperInvariant(); Prefix=$Prefix; Key=$key; ScriptBlock=$ScriptBlock }
        [void]$Server.PrefixRoutes.Add($route)
        Write-Output $route
    }
    end {}
}

function Add-HttpMiddleware {
<#
.SYNOPSIS
Adds middleware to the request pipeline.
.DESCRIPTION
Registers middleware executed before route handling. The middleware receives $Context, $Server, and $Next. Use & $Next to continue.
.PARAMETER Server
The server object.
.PARAMETER Name
A descriptive middleware name.
.PARAMETER ScriptBlock
The middleware implementation.
.EXAMPLE
PS C:\> Add-HttpMiddleware -Server $server -Name 'RequestId' -ScriptBlock { param($Context, $Server, $Next) Set-HttpContextItem -Context $Context -Name 'RequestId' -Value ([guid]::NewGuid().Guid); & $Next }
.EXAMPLE
PS C:\> Add-HttpMiddleware -Server $server -Name 'Timer' -ScriptBlock { param($Context, $Server, $Next) $started = Get-Date; & $Next; $elapsed = (Get-Date) - $started; Write-Verbose ('Elapsed: {0} ms' -f [int]$elapsed.TotalMilliseconds) }
.EXAMPLE
PS C:\> $server | Add-HttpMiddleware -Name 'RequestId' -ScriptBlock { param($Context, $Server, $Next) & $Next } -WhatIf
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
System.Management.Automation.PSCustomObject
.EXAMPLE
PS C:\> Get-Help Add-HttpMiddleware -Detailed

Displays the full comment-based help for Add-HttpMiddleware.

.EXAMPLE
PS C:\> Get-Help Add-HttpMiddleware -Examples

Displays the example set for Add-HttpMiddleware.


.EXAMPLE
PS C:\> Get-Help Add-HttpMiddleware -Full

Displays the complete help topic for Add-HttpMiddleware.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory = $true)][ValidateNotNull()][scriptblock]$ScriptBlock
    )
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($Name, 'Add HTTP middleware')) { return }
        $middleware = [pscustomobject]@{ PSTypeName='AetherWeb.Middleware'; Name=$Name; ScriptBlock=$ScriptBlock }
        [void]$Server.Middleware.Add($middleware)
        Write-Output $middleware
    }
    end {}
}

function Test-HttpManagementToken {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][psobject]$Server
    )
    if ([string]::IsNullOrEmpty($Server.ManagementToken)) { return $true }
    $value = $Context.Request.Headers['X-AetherWeb-Token']
    if ([string]::Equals($value, $Server.ManagementToken, [System.StringComparison]::Ordinal)) { return $true }
    return $false
}

function Add-HttpManagementRoutes {
<#
.SYNOPSIS
Adds built-in management routes to a server.
.DESCRIPTION
Registers a starter set of diagnostic routes for internal use.
.PARAMETER Server
The server object.
.EXAMPLE
PS C:\> Add-HttpManagementRoutes -Server $server
.EXAMPLE
PS C:\> $server = New-HttpServer -Prefix 'http://localhost:8080/' -EnableManagementRoutes -ManagementToken 'ChangeMe'
PS C:\> Add-HttpManagementRoutes -Server $server
.EXAMPLE
PS C:\> $server | Add-HttpManagementRoutes -WhatIf
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
System.Management.Automation.PSCustomObject
.EXAMPLE
PS C:\> Get-Help Add-HttpManagementRoutes -Detailed

Displays the full comment-based help for Add-HttpManagementRoutes.

.EXAMPLE
PS C:\> Get-Help Add-HttpManagementRoutes -Examples

Displays the example set for Add-HttpManagementRoutes.


.EXAMPLE
PS C:\> Get-Help Add-HttpManagementRoutes -Full

Displays the complete help topic for Add-HttpManagementRoutes.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server)
    begin { $addedRoutes = @() }
    process {
        $addedRoutes += Add-HttpRoute -Server $Server -Method GET -Path '/health' -ScriptBlock {
            param($Context, $Server)
            if (-not (Test-HttpManagementToken -Context $Context -Server $Server)) { Write-HttpErrorResponse -Response $Context.Response -StatusCode 401 -StatusDescription '401 Unauthorized' -RequestMethod $Context.Request.HttpMethod; return }
            Write-HttpJsonResponse -Response $Context.Response -InputObject ([ordered]@{ Status='OK'; ServerTime=(Get-Date); Uptime=if ($Server.StartTime) { ((Get-Date) - $Server.StartTime).ToString() } else { $null } }) -RequestMethod $Context.Request.HttpMethod
        }
        $addedRoutes += Add-HttpRoute -Server $Server -Method GET -Path '/api/time' -ScriptBlock {
            param($Context, $Server)
            if (-not (Test-HttpManagementToken -Context $Context -Server $Server)) { Write-HttpErrorResponse -Response $Context.Response -StatusCode 401 -StatusDescription '401 Unauthorized' -RequestMethod $Context.Request.HttpMethod; return }
            Write-HttpJsonResponse -Response $Context.Response -InputObject ([ordered]@{ Now=(Get-Date); MachineName=$env:COMPUTERNAME }) -RequestMethod $Context.Request.HttpMethod
        }
        $addedRoutes += Add-HttpRoute -Server $Server -Method GET -Path '/api/server' -ScriptBlock {
            param($Context, $Server)
            if (-not (Test-HttpManagementToken -Context $Context -Server $Server)) { Write-HttpErrorResponse -Response $Context.Response -StatusCode 401 -StatusDescription '401 Unauthorized' -RequestMethod $Context.Request.HttpMethod; return }
            Write-HttpJsonResponse -Response $Context.Response -InputObject ([ordered]@{ Prefix=$Server.Prefix; RootPath=$Server.RootPath; EnableStaticFiles=$Server.EnableStaticFiles; EnableDirectoryListing=$Server.EnableDirectoryListing; RouteCount=@($Server.Routes).Count + @($Server.TemplateRoutes).Count + @($Server.PrefixRoutes).Count; MiddlewareCount=@($Server.Middleware).Count; StartTime=$Server.StartTime }) -RequestMethod $Context.Request.HttpMethod
        }
        $addedRoutes += Add-HttpRoute -Server $Server -Method GET -Path '/api/processes' -ScriptBlock {
            param($Context, $Server)
            if (-not (Test-HttpManagementToken -Context $Context -Server $Server)) { Write-HttpErrorResponse -Response $Context.Response -StatusCode 401 -StatusDescription '401 Unauthorized' -RequestMethod $Context.Request.HttpMethod; return }
            $top = Get-HttpRequestQueryValue -Request $Context.Request -Name 'top' | Select-Object -First 1
            if ([string]::IsNullOrEmpty($top)) { $top = 25 }
            $payload = Get-Process | Select-Object -First ([int]$top) -Property Name, Id, CPU, WS, Handles
            Write-HttpJsonResponse -Response $Context.Response -InputObject $payload -Depth 4 -RequestMethod $Context.Request.HttpMethod
        }
        $addedRoutes += Add-HttpRoute -Server $Server -Method GET -Path '/api/services' -ScriptBlock {
            param($Context, $Server)
            if (-not (Test-HttpManagementToken -Context $Context -Server $Server)) { Write-HttpErrorResponse -Response $Context.Response -StatusCode 401 -StatusDescription '401 Unauthorized' -RequestMethod $Context.Request.HttpMethod; return }
            $payload = Get-Service | Sort-Object -Property Status, DisplayName | Select-Object -First 50 -Property Status, Name, DisplayName
            Write-HttpJsonResponse -Response $Context.Response -InputObject $payload -Depth 4 -RequestMethod $Context.Request.HttpMethod
        }
    }
    end { Write-Output $addedRoutes }
}

function Find-HttpRoute {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory = $true)][psobject]$Server,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $key = '{0}:{1}' -f $Method.ToUpperInvariant(), $Path
    foreach ($route in $Server.Routes) { if ($route.Key -eq $key) { return (New-HttpRouteMatchObject -Route $route -RouteValues @{}) } }
    foreach ($route in $Server.TemplateRoutes) {
        if ($route.Method -ne $Method.ToUpperInvariant()) { continue }
        $templateSegments = @($route.Path.Trim('/').Split('/'))
        $requestSegments = @($Path.Trim('/').Split('/'))
        if ($route.Path -eq '/') { $templateSegments = @('') }
        if ($Path -eq '/') { $requestSegments = @('') }
        if (@($templateSegments).Count -ne @($requestSegments).Count) { continue }
        $matched = $true
        $routeValues = @{}
        for ($i = 0; $i -lt @($templateSegments).Count; $i++) {
            $templateSegment = $templateSegments[$i]
            $requestSegment = $requestSegments[$i]
            if ($templateSegment -match '^\{(?<name>[^}]+)\}$') { $routeValues[$matches['name']] = [System.Uri]::UnescapeDataString($requestSegment); continue }
            if (-not [string]::Equals($templateSegment, $requestSegment, [System.StringComparison]::OrdinalIgnoreCase)) { $matched = $false; break }
        }
        if ($matched) { return (New-HttpRouteMatchObject -Route $route -RouteValues $routeValues) }
    }
    foreach ($route in $Server.PrefixRoutes) {
        if ($route.Method -ne $Method.ToUpperInvariant()) { continue }
        if ($Path.StartsWith($route.Prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return (New-HttpRouteMatchObject -Route $route -RouteValues @{}) }
    }
    return $null
}

function Invoke-HttpStaticFileHandler {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][psobject]$Server
    )
    $request = $Context.Request
    $response = $Context.Response
    if (-not $Server.EnableStaticFiles) { return $false }
    if ([string]::IsNullOrEmpty($Server.RootPath)) { return $false }
    if ($request.HttpMethod -ne 'GET' -and $request.HttpMethod -ne 'HEAD') { return $false }
    $localPath = Resolve-HttpLocalPath -RootPath $Server.RootPath -RequestPath $request.Url.AbsolutePath
    if ($null -eq $localPath) { Write-HttpErrorResponse -Response $response -StatusCode 403 -StatusDescription '403 Forbidden' -RequestMethod $request.HttpMethod; return $true }
    if ([System.IO.Directory]::Exists($localPath)) { foreach ($name in $Server.DefaultDocument) { $candidate = [System.IO.Path]::Combine($localPath, $name); if ([System.IO.File]::Exists($candidate)) { $localPath = $candidate; break } } }
    if ([System.IO.File]::Exists($localPath)) { Write-HttpFileResponse -Response $response -Path $localPath -RequestMethod $request.HttpMethod; return $true }
    if ([System.IO.Directory]::Exists($localPath)) {
        if (-not $Server.EnableDirectoryListing) { Write-HttpErrorResponse -Response $response -StatusCode 403 -StatusDescription '403 Directory browsing disabled' -RequestMethod $request.HttpMethod; return $true }
        $html = New-HttpDirectoryListingHtml -LocalPath $localPath -RequestPath $request.Url.AbsolutePath -SortByName:$Server.SortDirectoryListing
        Write-HttpHtmlResponse -Response $response -StatusCode 200 -Body $html -RequestMethod $request.HttpMethod
        return $true
    }
    return $false
}

function Invoke-HttpEndpointCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][psobject]$Server
    )
    $request = $Context.Request
    $response = $Context.Response
    $allowed = @('GET','HEAD','POST','PUT','PATCH','DELETE','OPTIONS')
    if ($allowed -notcontains $request.HttpMethod.ToUpperInvariant()) { Write-HttpErrorResponse -Response $response -StatusCode 405 -StatusDescription '405 Method Not Allowed' -RequestMethod $request.HttpMethod; return }
    if ($request.HttpMethod -eq 'OPTIONS') { $response.StatusCode = 204; $response.Headers['Allow'] = 'GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS'; return }
    $match = Find-HttpRoute -Server $Server -Method $request.HttpMethod -Path $request.Url.AbsolutePath
    if ($null -ne $match) {
        $items = Ensure-HttpContextItems -Context $Context
        $items['RouteValues'] = $match.RouteValues
        & $match.Route.ScriptBlock $Context $Server
        return
    }
    $handled = Invoke-HttpStaticFileHandler -Context $Context -Server $Server
    if (-not $handled) { Write-HttpErrorResponse -Response $response -StatusCode 404 -StatusDescription '404 Not Found' -RequestMethod $request.HttpMethod }
}

function Invoke-HttpMiddlewarePipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][psobject]$Server
    )
    $items = Ensure-HttpContextItems -Context $Context
    if (-not $items.ContainsKey('RouteValues')) { $items['RouteValues'] = @{} }
    $index = 0
    $invokeCore = { param() Invoke-HttpEndpointCore -Context $Context -Server $Server }
    $next = $null
    $next = {
        if ($index -lt @($Server.Middleware).Count) {
            $current = $Server.Middleware[$index]
            $index++
            & $current.ScriptBlock $Context $Server $next
        }
        else {
            & $invokeCore
        }
    }
    & $next
}

function Invoke-HttpRequestHandler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][psobject]$Server
    )
    $response = $Context.Response
    if (-not ($Context.Request.PSObject.Properties.Name -contains 'AetherWebMaxRequestBodyBytes')) { Add-Member -InputObject $Context.Request -MemberType NoteProperty -Name AetherWebMaxRequestBodyBytes -Value $Server.MaxRequestBodyBytes -Force }
    if (-not ($Context.Request.PSObject.Properties.Name -contains 'AetherWebMaxMultipartFileBytes')) { Add-Member -InputObject $Context.Request -MemberType NoteProperty -Name AetherWebMaxMultipartFileBytes -Value $Server.MaxMultipartFileBytes -Force }
    $started = Get-Date
    $statusCode = 0
    try {
        Invoke-HttpMiddlewarePipeline -Context $Context -Server $Server
        $statusCode = $response.StatusCode
    }
    catch {
        Write-Error -Message ('Request handling failed: {0}' -f $_.Exception.Message)
        try {
            if ($response.OutputStream.CanWrite) {
                Write-HttpErrorResponse -Response $response -StatusCode 500 -StatusDescription '500 Internal Server Error' -RequestMethod $Context.Request.HttpMethod
                $statusCode = 500
            }
        }
        catch { Write-Verbose -Message 'Unable to send 500 response.' }
    }
    finally {
        if ($statusCode -eq 0) { $statusCode = $response.StatusCode }
        Write-HttpRequestLog -Server $Server -Context $Context -Started $started -StatusCode $statusCode
        $response.Close()
    }
}

function Start-HttpServer {
<#
.SYNOPSIS
Starts an HTTP server.
.DESCRIPTION
Starts the listener loop for a server object created by New-HttpServer.
.PARAMETER Server
The server object.
.PARAMETER RequestTimeoutSeconds
Compatibility parameter retained for earlier releases. The foreground server loop now uses synchronous request acceptance with GetContext().
.PARAMETER RegisterManagementRoutes
Registers built-in management routes when the server starts.
.EXAMPLE
PS C:\> $server = New-HttpServer -Prefix 'http://localhost:8080/' -RootPath 'C:\Temp\Site' -EnableStaticFiles
PS C:\> Start-HttpServer -Server $server -Verbose
.EXAMPLE
PS C:\> Start-HttpServer -Server $server -RegisterManagementRoutes -WhatIf
.EXAMPLE
PS C:\> $server = New-HttpServer -Prefix 'http://localhost:8080/' -RootPath 'C:\Temp\Site' -EnableStaticFiles -EnableRequestLogging -RequestLogPath 'C:\Temp\AetherWeb.log'
PS C:\> Start-HttpServer -Server $server -Verbose
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
None.
.NOTES
Runs in the foreground until stopped or interrupted.
.EXAMPLE
PS C:\> Get-Help Start-HttpServer -Detailed

Displays the full comment-based help for Start-HttpServer.

.EXAMPLE
PS C:\> Get-Help Start-HttpServer -Examples

Displays the example set for Start-HttpServer.


.EXAMPLE
PS C:\> Get-Help Start-HttpServer -Full

Displays the complete help topic for Start-HttpServer.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server,
        [Parameter()][ValidateRange(1, 3600)][int]$RequestTimeoutSeconds = 2,
        [Parameter()][switch]$RegisterManagementRoutes
    )
    begin {}
    process {
        if ($Server.IsRunning) { Write-Error -Message 'Server is already running.'; return }
        if ($RegisterManagementRoutes -or $Server.EnableManagementRoutes) {
            if (@(($Server.Routes + $Server.TemplateRoutes) | Where-Object { $_.Path -eq '/health' -or $_.Path -eq '/api/time' -or $_.Path -eq '/api/server' }).Count -eq 0) { Add-HttpManagementRoutes -Server $Server | Out-Null }
        }
        if (-not $PSCmdlet.ShouldProcess(($Server.Prefix -join ', '), 'Start HTTP server')) { return }
        try {
            $Server.Listener.Start()
            $Server.IsRunning = $true
            $Server.StartTime = Get-Date
            Write-Verbose -Message ('Server started on: {0}' -f ($Server.Prefix -join ', '))
            if ($Server.RootPath) { Write-Verbose -Message ('Static root: {0}' -f $Server.RootPath) }
            $Server.StopRequested = $false
            while ($Server.Listener.IsListening -and -not $Server.StopRequested) {
                try {
                    $context = $Server.Listener.GetContext()
                    Write-Verbose -Message ('{0} {1}' -f $context.Request.HttpMethod, $context.Request.RawUrl)
                    Invoke-HttpRequestHandler -Context $context -Server $Server
                }
                catch [System.ObjectDisposedException] { break }
                catch [System.InvalidOperationException] { break }
                catch { Write-Error -Message ('Listener loop failure: {0}' -f $_.Exception.Message) }
            }
        }
        catch { Write-Error -Message ('Failed to start server: {0}' -f $_.Exception.Message) }
        finally {
            if ($Server.Listener -and $Server.Listener.IsListening) { $Server.Listener.Stop() }
            $Server.IsRunning = $false
        }
    }
    end {}
}

function Start-HttpServerBackground {
<#
.SYNOPSIS
Starts an HTTP server in a background runspace.
.DESCRIPTION
Starts the listener loop on a dedicated runspace using the same in-memory server object.
.PARAMETER Server
The server object.
.PARAMETER RequestTimeoutSeconds
Compatibility parameter retained for earlier releases. The foreground server loop now uses synchronous request acceptance with GetContext().
.PARAMETER RegisterManagementRoutes
Registers built-in management routes when the server starts.
.EXAMPLE
PS C:\> Start-HttpServerBackground -Server $server
.EXAMPLE
PS C:\> $server = Start-HttpServerBackground -Server $server -RegisterManagementRoutes -Verbose
.EXAMPLE
PS C:\> Start-HttpServerBackground -Server $server -WhatIf
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
System.Management.Automation.PSCustomObject
.NOTES
This uses a background PowerShell instance in the current process.
.EXAMPLE
PS C:\> Get-Help Start-HttpServerBackground -Detailed

Displays the full comment-based help for Start-HttpServerBackground.

.EXAMPLE
PS C:\> Get-Help Start-HttpServerBackground -Examples

Displays the example set for Start-HttpServerBackground.


.EXAMPLE
PS C:\> Get-Help Start-HttpServerBackground -Full

Displays the complete help topic for Start-HttpServerBackground.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server,
        [Parameter()][ValidateRange(1, 3600)][int]$RequestTimeoutSeconds = 2,
        [Parameter()][switch]$RegisterManagementRoutes
    )
    begin {}
    process {
        if ($Server.BackgroundPowerShell) { Write-Error -Message 'Server already has a background host.'; return }
        if (-not $PSCmdlet.ShouldProcess(($Server.Prefix -join ', '), 'Start HTTP server in background runspace')) { return }
        try {
            $modulePath = $MyInvocation.MyCommand.Module.Path
            $ps = [System.Management.Automation.PowerShell]::Create()
            $null = $ps.AddScript({
                param($ModulePath, $Server, $RequestTimeoutSeconds, $RegisterManagementRoutes)
                Import-Module -Name $ModulePath -Force
                Start-HttpServer -Server $Server -RequestTimeoutSeconds $RequestTimeoutSeconds -RegisterManagementRoutes:$RegisterManagementRoutes
            }).AddArgument($modulePath).AddArgument($Server).AddArgument($RequestTimeoutSeconds).AddArgument([bool]$RegisterManagementRoutes)
            $handle = $ps.BeginInvoke()
            $Server.BackgroundPowerShell = $ps
            $Server.BackgroundHandle = $handle
            Write-Output $Server
        }
        catch { Write-Error -Message ('Failed to start background server: {0}' -f $_.Exception.Message) }
    }
    end {}
}

function Stop-HttpServer {
<#
.SYNOPSIS
Stops a running HTTP server.
.DESCRIPTION
Stops and closes the listener associated with a server object.
.PARAMETER Server
The server object.
.EXAMPLE
PS C:\> Stop-HttpServer -Server $server
.EXAMPLE
PS C:\> $server | Stop-HttpServer -WhatIf
.EXAMPLE
PS C:\> $server = Start-HttpServerBackground -Server $server
PS C:\> Stop-HttpServer -Server $server
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
None.
.EXAMPLE
PS C:\> Get-Help Stop-HttpServer -Detailed

Displays the full comment-based help for Stop-HttpServer.

.EXAMPLE
PS C:\> Get-Help Stop-HttpServer -Examples

Displays the example set for Stop-HttpServer.


.EXAMPLE
PS C:\> Get-Help Stop-HttpServer -Full

Displays the complete help topic for Stop-HttpServer.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server)
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess(($Server.Prefix -join ', '), 'Stop HTTP server')) { return }
        try {
            if ($Server.Listener) {
                if ($Server.Listener.IsListening) { $Server.Listener.Stop() }
                $Server.Listener.Close()
            }
            if ($Server.BackgroundPowerShell) {
                try { if ($Server.BackgroundHandle) { $Server.BackgroundPowerShell.EndInvoke($Server.BackgroundHandle) | Out-Null } }
                catch { Write-Verbose -Message ('Background EndInvoke returned: {0}' -f $_.Exception.Message) }
                finally {
                    $Server.BackgroundPowerShell.Dispose()
                    $Server.BackgroundPowerShell = $null
                    $Server.BackgroundHandle = $null
                }
            }
            $Server.IsRunning = $false
        }
        catch { Write-Error -Message ('Failed to stop server: {0}' -f $_.Exception.Message) }
    }
    end {}
}



function Set-HttpResponseHeader {
<#
.SYNOPSIS
Sets an HTTP response header.
.DESCRIPTION
Sets or replaces a named header on the HttpListenerResponse.
.PARAMETER Response
The HttpListenerResponse object.
.PARAMETER Name
The header name.
.PARAMETER Value
The header value.
.EXAMPLE
PS C:\> Set-HttpResponseHeader -Response $Context.Response -Name 'X-Request-Id' -Value '123'
.EXAMPLE
PS C:\> Set-HttpResponseHeader -Response $Context.Response -Name 'X-Frame-Options' -Value 'DENY'
.EXAMPLE
PS C:\> Set-HttpResponseHeader -Response $Context.Response -Name 'X-Request-Id' -Value '123' -WhatIf
.INPUTS
None.
.OUTPUTS
None.
.EXAMPLE
PS C:\> Get-Help Set-HttpResponseHeader -Detailed

Displays the full comment-based help for Set-HttpResponseHeader.

.EXAMPLE
PS C:\> Get-Help Set-HttpResponseHeader -Examples

Displays the example set for Set-HttpResponseHeader.


.EXAMPLE
PS C:\> Get-Help Set-HttpResponseHeader -Full

Displays the complete help topic for Set-HttpResponseHeader.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )
    if (-not $PSCmdlet.ShouldProcess($Name, 'Set HTTP response header')) { return }
    try { $Response.Headers[$Name] = $Value }
    catch { Write-Error -Message ('Failed to set HTTP response header: {0}' -f $_.Exception.Message) }
}

function Add-HttpResponseCookie {
<#
.SYNOPSIS
Adds a cookie to an HTTP response.
.DESCRIPTION
Creates a System.Net.Cookie and appends it to the response.
.PARAMETER Response
The HttpListenerResponse object.
.PARAMETER Name
The cookie name.
.PARAMETER Value
The cookie value.
.PARAMETER Path
The cookie path.
.PARAMETER Domain
Optional cookie domain.
.PARAMETER Expires
Optional cookie expiration date.
.PARAMETER HttpOnly
Marks the cookie as HttpOnly.
.PARAMETER Secure
Marks the cookie as Secure.
.EXAMPLE
PS C:\> Add-HttpResponseCookie -Response $Context.Response -Name 'session' -Value 'abc' -HttpOnly
.EXAMPLE
PS C:\> Add-HttpResponseCookie -Response $Context.Response -Name 'theme' -Value 'dark' -Path '/admin'
.EXAMPLE
PS C:\> Add-HttpResponseCookie -Response $Context.Response -Name 'session' -Value 'abc' -HttpOnly -WhatIf
.INPUTS
None.
.OUTPUTS
System.Net.Cookie
.EXAMPLE
PS C:\> Get-Help Add-HttpResponseCookie -Detailed

Displays the full comment-based help for Add-HttpResponseCookie.

.EXAMPLE
PS C:\> Get-Help Add-HttpResponseCookie -Examples

Displays the example set for Add-HttpResponseCookie.


.EXAMPLE
PS C:\> Get-Help Add-HttpResponseCookie -Full

Displays the complete help topic for Add-HttpResponseCookie.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([System.Net.Cookie])]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter()][string]$Path = '/',
        [Parameter()][string]$Domain,
        [Parameter()][datetime]$Expires,
        [Parameter()][switch]$HttpOnly,
        [Parameter()][switch]$Secure
    )
    if (-not $PSCmdlet.ShouldProcess($Name, 'Add HTTP response cookie')) { return }
    try {
        $cookie = New-Object System.Net.Cookie
        $cookie.Name = $Name
        $cookie.Value = $Value
        $cookie.Path = $Path
        if ($PSBoundParameters.ContainsKey('Domain') -and -not [string]::IsNullOrEmpty($Domain)) { $cookie.Domain = $Domain }
        if ($PSBoundParameters.ContainsKey('Expires')) { $cookie.Expires = $Expires }
        $cookie.HttpOnly = [bool]$HttpOnly
        $cookie.Secure = [bool]$Secure
        $Response.Cookies.Add($cookie)
        Write-Output $cookie
    }
    catch { Write-Error -Message ('Failed to add HTTP response cookie: {0}' -f $_.Exception.Message) }
}

function New-HttpHtmlPage {
<#
.SYNOPSIS
Builds a simple HTML page.
.DESCRIPTION
Creates a minimal HTML5 page with optional head markup and body content.
.PARAMETER Title
The page title.
.PARAMETER Body
The HTML body content.
.PARAMETER HeadContent
Optional raw HTML to append within the head element.
.EXAMPLE
PS C:\> New-HttpHtmlPage -Title 'Status' -Body '<h1>OK</h1>'
.EXAMPLE
PS C:\> New-HttpHtmlPage -Title 'Admin' -HeadContent '<meta http-equiv="refresh" content="30" />' -Body '<h1>Admin</h1><p>Refreshing</p>'
.EXAMPLE
PS C:\> New-HttpHtmlPage -Title 'Status' -Body '<h1>OK</h1>' -WhatIf
.INPUTS
None.
.OUTPUTS
System.String
.EXAMPLE
PS C:\> Get-Help New-HttpHtmlPage -Detailed

Displays the full comment-based help for New-HttpHtmlPage.

.EXAMPLE
PS C:\> Get-Help New-HttpHtmlPage -Examples

Displays the example set for New-HttpHtmlPage.


.EXAMPLE
PS C:\> Get-Help New-HttpHtmlPage -Full

Displays the complete help topic for New-HttpHtmlPage.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body,
        [Parameter()][AllowEmptyString()][string]$HeadContent = ''
    )
    if (-not $PSCmdlet.ShouldProcess($Title, 'Create HTML page')) { return }
    $safeTitle = ConvertTo-HttpHtmlEncodedText -Text $Title
@"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>$safeTitle</title>
$HeadContent
</head>
<body>
$Body
</body>
</html>
"@
}



function Add-HttpCorsMiddleware {
<#
.SYNOPSIS
Adds Cross-Origin Resource Sharing (CORS) middleware to a server.
.DESCRIPTION
Registers middleware that applies CORS headers to matching requests and handles
CORS preflight OPTIONS requests. Use this to centralize browser-origin policy
for APIs, admin routes, and dashboard backends.
.PARAMETER Server
The server object returned by New-HttpServer.
.PARAMETER Name
A descriptive middleware name.
.PARAMETER AllowedOrigin
One or more allowed origin values such as https://portal.contoso.local.
Ignored when -AllowAnyOrigin is specified.
.PARAMETER AllowAnyOrigin
Allows any origin. When used together with -AllowCredentials, the middleware
reflects the caller Origin instead of returning '*'.
.PARAMETER AllowedMethod
One or more allowed HTTP methods for cross-origin requests.
.PARAMETER AllowAnyMethod
Allows any requested method during preflight processing.
.PARAMETER AllowedHeader
One or more allowed request headers for preflight requests.
.PARAMETER AllowAnyHeader
Allows any requested request header during preflight processing.
.PARAMETER ExposedHeader
One or more response headers that browser JavaScript may read.
.PARAMETER AllowCredentials
Adds Access-Control-Allow-Credentials: true.
.PARAMETER MaxAgeSeconds
Adds Access-Control-Max-Age to successful preflight responses.
.PARAMETER PathPrefix
Optional request path prefix filter. When specified, the middleware only
applies to matching paths.
.PARAMETER PassThru
Returns the registered middleware object.
.EXAMPLE
PS C:\> Add-HttpCorsMiddleware -Server $server -AllowAnyOrigin -AllowAnyMethod -AllowAnyHeader

Adds a permissive development CORS policy.
.EXAMPLE
PS C:\> Add-HttpCorsMiddleware -Server $server -AllowedOrigin 'https://portal.contoso.local' -AllowedMethod 'GET','POST','OPTIONS' -AllowedHeader 'Content-Type','Authorization' -PathPrefix '/api'

Adds a restricted CORS policy that applies only to /api routes.
.EXAMPLE
PS C:\> Add-HttpCorsMiddleware -Server $server -AllowedOrigin 'https://portal.contoso.local' -AllowedMethod 'GET','POST','OPTIONS' -AllowedHeader 'Content-Type','Authorization' -ExposedHeader 'X-Request-Id' -AllowCredentials -MaxAgeSeconds 900

Adds a credential-aware policy that exposes a custom response header.
.EXAMPLE
PS C:\> $server | Add-HttpCorsMiddleware -AllowAnyOrigin -AllowAnyMethod -AllowAnyHeader -WhatIf

Shows what would happen without adding the middleware.
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
System.Management.Automation.PSCustomObject
.NOTES
This middleware is intended for use with Add-HttpMiddleware and the AetherWeb
request pipeline.
.EXAMPLE
PS C:\> Get-Help Add-HttpCorsMiddleware -Detailed

Displays the full comment-based help for Add-HttpCorsMiddleware.

.EXAMPLE
PS C:\> Get-Help Add-HttpCorsMiddleware -Examples

Displays the example set for Add-HttpCorsMiddleware.


.EXAMPLE
PS C:\> Get-Help Add-HttpCorsMiddleware -Full

Displays the complete help topic for Add-HttpCorsMiddleware.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server,
        [Parameter()][ValidateNotNullOrEmpty()][string]$Name = 'Cors',
        [Parameter()][string[]]$AllowedOrigin,
        [Parameter()][switch]$AllowAnyOrigin,
        [Parameter()][string[]]$AllowedMethod = @('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'),
        [Parameter()][switch]$AllowAnyMethod,
        [Parameter()][string[]]$AllowedHeader,
        [Parameter()][switch]$AllowAnyHeader,
        [Parameter()][string[]]$ExposedHeader,
        [Parameter()][switch]$AllowCredentials,
        [Parameter()][ValidateRange(0, 86400)][int]$MaxAgeSeconds = 600,
        [Parameter()][string]$PathPrefix,
        [Parameter()][switch]$PassThru
    )
    begin {}
    process {
        if (-not $AllowAnyOrigin -and @($AllowedOrigin).Count -eq 0) {
            Write-Error -Message 'Specify -AllowedOrigin or use -AllowAnyOrigin.'
            return
        }
        if (-not $AllowAnyMethod -and @($AllowedMethod).Count -eq 0) {
            Write-Error -Message 'Specify -AllowedMethod or use -AllowAnyMethod.'
            return
        }

        $normalizedAllowedOrigins = @()
        foreach ($origin in @($AllowedOrigin)) {
            if (-not [string]::IsNullOrWhiteSpace($origin)) {
                $normalizedAllowedOrigins += $origin.Trim()
            }
        }

        $normalizedAllowedMethods = @()
        foreach ($method in @($AllowedMethod)) {
            if (-not [string]::IsNullOrWhiteSpace($method)) {
                $normalizedAllowedMethods += $method.Trim().ToUpperInvariant()
            }
        }

        $normalizedAllowedHeaders = @()
        foreach ($header in @($AllowedHeader)) {
            if (-not [string]::IsNullOrWhiteSpace($header)) {
                $normalizedAllowedHeaders += $header.Trim()
            }
        }

        $normalizedExposedHeaders = @()
        foreach ($header in @($ExposedHeader)) {
            if (-not [string]::IsNullOrWhiteSpace($header)) {
                $normalizedExposedHeaders += $header.Trim()
            }
        }

        $middlewareScript = {
            param($Context, $Server, $Next)

            function Test-HttpCorsOriginAllowed {
                param([string]$OriginValue, [bool]$UseAllowAnyOrigin, [string[]]$UseAllowedOrigins)
                if ([string]::IsNullOrWhiteSpace($OriginValue)) { return $false }
                if ($UseAllowAnyOrigin) { return $true }
                foreach ($item in @($UseAllowedOrigins)) {
                    if ([string]::Equals($item, $OriginValue, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
                }
                return $false
            }

            function Test-HttpCorsMethodAllowed {
                param([string]$MethodValue, [bool]$UseAllowAnyMethod, [string[]]$UseAllowedMethods)
                if ([string]::IsNullOrWhiteSpace($MethodValue)) { return $false }
                if ($UseAllowAnyMethod) { return $true }
                foreach ($item in @($UseAllowedMethods)) {
                    if ([string]::Equals($item, $MethodValue, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
                }
                return $false
            }

            function Test-HttpCorsHeadersAllowed {
                param([string[]]$RequestedHeaders, [bool]$UseAllowAnyHeader, [string[]]$UseAllowedHeaders)
                if ($UseAllowAnyHeader) { return $true }
                if (@($RequestedHeaders).Count -eq 0) { return $true }
                foreach ($requestedHeader in @($RequestedHeaders)) {
                    $found = $false
                    foreach ($allowedHeader in @($UseAllowedHeaders)) {
                        if ([string]::Equals($allowedHeader, $requestedHeader, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $found = $true
                            break
                        }
                    }
                    if (-not $found) { return $false }
                }
                return $true
            }

            function Add-HttpCorsVaryHeader {
                param([System.Net.HttpListenerResponse]$Response, [string]$Value)
                $existing = $Response.Headers['Vary']
                if ([string]::IsNullOrWhiteSpace($existing)) {
                    $Response.Headers['Vary'] = $Value
                    return
                }
                $parts = @($existing -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($parts -notcontains $Value) {
                    $Response.Headers['Vary'] = ($parts + $Value) -join ', '
                }
            }

            $request = $Context.Request
            $response = $Context.Response
            $origin = $request.Headers['Origin']
            $requestPath = $request.Url.AbsolutePath

            if (-not [string]::IsNullOrEmpty($PathPrefix)) {
                if (-not $requestPath.StartsWith($PathPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    & $Next
                    return
                }
            }

            if ([string]::IsNullOrWhiteSpace($origin)) {
                & $Next
                return
            }

            $isPreflight = $false
            $requestedMethod = $null
            $requestedHeaderLine = $request.Headers['Access-Control-Request-Headers']
            $requestedHeaders = @()
            if ($request.HttpMethod -eq 'OPTIONS' -and -not [string]::IsNullOrWhiteSpace($request.Headers['Access-Control-Request-Method'])) {
                $isPreflight = $true
                $requestedMethod = $request.Headers['Access-Control-Request-Method'].Trim().ToUpperInvariant()
                if (-not [string]::IsNullOrWhiteSpace($requestedHeaderLine)) {
                    $requestedHeaders = @($requestedHeaderLine -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                }
            }

            $originAllowed = Test-HttpCorsOriginAllowed -OriginValue $origin -UseAllowAnyOrigin ([bool]$AllowAnyOrigin) -UseAllowedOrigins $normalizedAllowedOrigins
            if (-not $originAllowed) {
                if ($isPreflight) {
                    Write-HttpErrorResponse -Response $response -StatusCode 403 -StatusDescription '403 CORS origin not allowed' -Encoding ([System.Text.Encoding]::UTF8) -RequestMethod $request.HttpMethod
                    return
                }
                & $Next
                return
            }

            if ($AllowAnyOrigin -and -not $AllowCredentials) {
                Set-HttpResponseHeader -Response $response -Name 'Access-Control-Allow-Origin' -Value '*'
            }
            else {
                Set-HttpResponseHeader -Response $response -Name 'Access-Control-Allow-Origin' -Value $origin
                Add-HttpCorsVaryHeader -Response $response -Value 'Origin'
            }

            if ($AllowCredentials) {
                Set-HttpResponseHeader -Response $response -Name 'Access-Control-Allow-Credentials' -Value 'true'
            }
            if (@($normalizedExposedHeaders).Count -gt 0) {
                Set-HttpResponseHeader -Response $response -Name 'Access-Control-Expose-Headers' -Value ($normalizedExposedHeaders -join ', ')
            }

            if ($isPreflight) {
                $methodAllowed = Test-HttpCorsMethodAllowed -MethodValue $requestedMethod -UseAllowAnyMethod ([bool]$AllowAnyMethod) -UseAllowedMethods $normalizedAllowedMethods
                $headersAllowed = Test-HttpCorsHeadersAllowed -RequestedHeaders $requestedHeaders -UseAllowAnyHeader ([bool]$AllowAnyHeader) -UseAllowedHeaders $normalizedAllowedHeaders

                if (-not $methodAllowed) {
                    Write-HttpErrorResponse -Response $response -StatusCode 403 -StatusDescription '403 CORS method not allowed' -Encoding ([System.Text.Encoding]::UTF8) -RequestMethod $request.HttpMethod
                    return
                }
                if (-not $headersAllowed) {
                    Write-HttpErrorResponse -Response $response -StatusCode 403 -StatusDescription '403 CORS header not allowed' -Encoding ([System.Text.Encoding]::UTF8) -RequestMethod $request.HttpMethod
                    return
                }

                if ($AllowAnyMethod) {
                    Set-HttpResponseHeader -Response $response -Name 'Access-Control-Allow-Methods' -Value 'GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS'
                }
                else {
                    Set-HttpResponseHeader -Response $response -Name 'Access-Control-Allow-Methods' -Value ($normalizedAllowedMethods -join ', ')
                }

                if ($AllowAnyHeader) {
                    if (-not [string]::IsNullOrWhiteSpace($requestedHeaderLine)) {
                        Set-HttpResponseHeader -Response $response -Name 'Access-Control-Allow-Headers' -Value $requestedHeaderLine
                        Add-HttpCorsVaryHeader -Response $response -Value 'Access-Control-Request-Headers'
                    }
                }
                elseif (@($normalizedAllowedHeaders).Count -gt 0) {
                    Set-HttpResponseHeader -Response $response -Name 'Access-Control-Allow-Headers' -Value ($normalizedAllowedHeaders -join ', ')
                }

                Set-HttpResponseHeader -Response $response -Name 'Access-Control-Max-Age' -Value ([string]$MaxAgeSeconds)
                Add-HttpCorsVaryHeader -Response $response -Value 'Access-Control-Request-Method'

                Write-HttpTextResponse -Response $response -StatusCode 204 -ContentType 'text/plain; charset=utf-8' -Body '' -Encoding ([System.Text.Encoding]::UTF8) -RequestMethod $request.HttpMethod
                return
            }

            & $Next
        }.GetNewClosure()

        if (-not $PSCmdlet.ShouldProcess($Name, 'Add CORS middleware')) { return }
        $result = Add-HttpMiddleware -Server $Server -Name $Name -ScriptBlock $middlewareScript
        if ($PassThru) { Write-Output $result }
    }
    end {}
}

function Add-HttpRouteGroup {
<#
.SYNOPSIS
Adds a group of routes under a shared path prefix.
.DESCRIPTION
Registers multiple route or prefix-route definitions using a common prefix.
Each definition is a hashtable or PSCustomObject with Method, Path, and ScriptBlock.
Set IsPrefix = $true to register a prefix route instead of an exact/template route.
.PARAMETER Server
The server object.
.PARAMETER Prefix
The shared prefix applied to each route definition path.
.PARAMETER Definitions
The route definitions to register.
.EXAMPLE
PS C:\> Add-HttpRouteGroup -Server $server -Prefix '/api' -Definitions @(
>>     @{ Method = 'GET'; Path = '/time'; ScriptBlock = { param($Context, $Server) Write-HttpJsonResponse -Response $Context.Response -InputObject @{ Now = Get-Date } -RequestMethod $Context.Request.HttpMethod } },
>>     @{ Method = 'GET'; Path = '/files/'; IsPrefix = $true; ScriptBlock = { param($Context, $Server) Write-HttpTextResponse -Response $Context.Response -StatusCode 200 -ContentType 'text/plain; charset=utf-8' -Body $Context.Request.RawUrl -RequestMethod $Context.Request.HttpMethod } }
>> )
.EXAMPLE
PS C:\> $server | Add-HttpRouteGroup -Prefix '/api' -Definitions $defs -WhatIf
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
System.Object[]
.EXAMPLE
PS C:\> Get-Help Add-HttpRouteGroup -Detailed

Displays the full comment-based help for Add-HttpRouteGroup.

.EXAMPLE
PS C:\> Get-Help Add-HttpRouteGroup -Examples

Displays the example set for Add-HttpRouteGroup.


.EXAMPLE
PS C:\> Get-Help Add-HttpRouteGroup -Full

Displays the complete help topic for Add-HttpRouteGroup.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Prefix,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][object[]]$Definitions
    )
    begin { $results = @() }
    process {
        foreach ($definition in $Definitions) {
            $method = $definition.Method
            $path = $definition.Path
            $scriptBlock = $definition.ScriptBlock
            $isPrefix = $false
            if ($definition.PSObject.Properties.Name -contains 'IsPrefix') { $isPrefix = [bool]$definition.IsPrefix }
            if ([string]::IsNullOrEmpty($method) -or [string]::IsNullOrEmpty($path) -or $null -eq $scriptBlock) {
                Write-Error -Message 'Each route definition must provide Method, Path, and ScriptBlock.'
                continue
            }
            $combinedPath = (($Prefix.TrimEnd('/')) + '/' + ($path.TrimStart('/')))
            if (-not $combinedPath.StartsWith('/')) { $combinedPath = '/' + $combinedPath }
            if ($isPrefix) {
                $results += Add-HttpRoutePrefix -Server $Server -Method $method -Prefix $combinedPath -ScriptBlock $scriptBlock
            }
            else {
                $results += Add-HttpRoute -Server $Server -Method $method -Path $combinedPath -ScriptBlock $scriptBlock
            }
        }
    }
    end { Write-Output $results }
}


function Resolve-FileMessageQueueDirectories {
<#
.SYNOPSIS
Resolves standard directory paths for a file-backed message queue.
.DESCRIPTION
Returns the standard queue directory layout used by the AetherWeb MOM bridge.
.PARAMETER Path
The root queue path.
.EXAMPLE
PS C:\> Resolve-FileMessageQueueDirectories -Path 'C:\QueueRoot'
.EXAMPLE
PS C:\> Resolve-FileMessageQueueDirectories -Path 'C:\QueueRoot' -WhatIf
.INPUTS
System.String
.OUTPUTS
System.Management.Automation.PSCustomObject
.NOTES
Internal helper.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Resolve queue directories')) { return }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    [pscustomobject]@{
        Root       = $fullPath
        Incoming   = [System.IO.Path]::Combine($fullPath, 'incoming')
        Processing = [System.IO.Path]::Combine($fullPath, 'processing')
        Completed  = [System.IO.Path]::Combine($fullPath, 'completed')
        DeadLetter = [System.IO.Path]::Combine($fullPath, 'deadletter')
    }
}

function New-FileMessageQueue {
<#
.SYNOPSIS
Creates a file-backed message queue layout.
.DESCRIPTION
Creates the standard queue folders used by the AetherWeb MOM bridge: incoming,
processing, completed, and deadletter.
.PARAMETER Path
The root queue path.
.EXAMPLE
PS C:\> New-FileMessageQueue -Path 'C:\Queues\Orders'
.EXAMPLE
PS C:\> New-FileMessageQueue -Path 'C:\Queues\Orders' -WhatIf
.EXAMPLE
PS C:\> 'C:\Queues\Orders' | New-FileMessageQueue
.INPUTS
System.String
.OUTPUTS
System.Management.Automation.PSCustomObject
.NOTES
This function creates directories only. It does not start any worker.
.EXAMPLE
PS C:\> Get-Help New-FileMessageQueue -Detailed

Displays the full comment-based help for New-FileMessageQueue.

.EXAMPLE
PS C:\> Get-Help New-FileMessageQueue -Examples

Displays the example set for New-FileMessageQueue.


.EXAMPLE
PS C:\> Get-Help New-FileMessageQueue -Full

Displays the complete help topic for New-FileMessageQueue.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    begin {}
    process {
        $dirs = Resolve-FileMessageQueueDirectories -Path $Path
        if ($null -eq $dirs) { return }
        if (-not $PSCmdlet.ShouldProcess($dirs.Root, 'Create file-backed message queue')) { return }
        foreach ($dir in @($dirs.Root, $dirs.Incoming, $dirs.Processing, $dirs.Completed, $dirs.DeadLetter)) {
            try {
                if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -Path $dir -ItemType Directory -Force) }
            }
            catch {
                Write-Error -Message ('Failed to create queue directory ''{0}'': {1}' -f $dir, $_.Exception.Message)
                return
            }
        }
        [pscustomobject]@{
            PSTypeName = 'AetherWeb.FileMessageQueue'
            Path       = $dirs.Root
            Incoming   = $dirs.Incoming
            Processing = $dirs.Processing
            Completed  = $dirs.Completed
            DeadLetter = $dirs.DeadLetter
        }
    }
    end {}
}

function New-HttpMessageEnvelope {
<#
.SYNOPSIS
Creates a message envelope for queue handoff.
.DESCRIPTION
Builds a standard message envelope used by the AetherWeb MOM bridge. The
envelope contains identifiers, timestamps, request metadata, payload, and
initial queue status values.
.PARAMETER MessageType
The logical message type.
.PARAMETER Payload
The message payload object.
.PARAMETER Context
Optional HttpListenerContext used to enrich the envelope with request metadata.
.PARAMETER CorrelationId
Optional correlation identifier. If omitted, a new GUID is generated.
.PARAMETER MessageId
Optional message identifier. If omitted, a new GUID is generated.
.PARAMETER Headers
Optional additional envelope headers.
.EXAMPLE
PS C:\> $envelope = New-HttpMessageEnvelope -MessageType 'OrderSubmitted' -Payload @{ OrderId = 42 }
.EXAMPLE
PS C:\> $envelope = New-HttpMessageEnvelope -MessageType 'OrderSubmitted' -Payload $body -Context $Context
.EXAMPLE
PS C:\> New-HttpMessageEnvelope -MessageType 'InventoryScan' -Payload @{ ComputerName = 'SRV-01' } -WhatIf
.INPUTS
None.
.OUTPUTS
System.Management.Automation.PSCustomObject
.NOTES
The envelope format is intentionally simple so it can be stored as JSON.
.EXAMPLE
PS C:\> Get-Help New-HttpMessageEnvelope -Detailed

Displays the full comment-based help for New-HttpMessageEnvelope.

.EXAMPLE
PS C:\> Get-Help New-HttpMessageEnvelope -Examples

Displays the example set for New-HttpMessageEnvelope.


.EXAMPLE
PS C:\> Get-Help New-HttpMessageEnvelope -Full

Displays the complete help topic for New-HttpMessageEnvelope.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$MessageType,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Payload,
        [Parameter()][System.Net.HttpListenerContext]$Context,
        [Parameter()][string]$CorrelationId,
        [Parameter()][string]$MessageId,
        [Parameter()][hashtable]$Headers
    )
    if ([string]::IsNullOrEmpty($CorrelationId)) { $CorrelationId = [guid]::NewGuid().Guid }
    if ([string]::IsNullOrEmpty($MessageId)) { $MessageId = [guid]::NewGuid().Guid }
    if (-not $PSCmdlet.ShouldProcess($MessageId, 'Create HTTP message envelope')) { return }
    $meta = [ordered]@{}
    if ($null -ne $Context) {
        $meta['Method'] = $Context.Request.HttpMethod
        $meta['Path'] = $Context.Request.Url.AbsolutePath
        $meta['RawUrl'] = $Context.Request.RawUrl
        $meta['RemoteEndPoint'] = if ($Context.Request.RemoteEndPoint) { $Context.Request.RemoteEndPoint.ToString() } else { $null }
        $meta['ContentType'] = $Context.Request.ContentType
        $meta['UserAgent'] = $Context.Request.UserAgent
    }
    if ($Headers) {
        foreach ($key in $Headers.Keys) { $meta[$key] = $Headers[$key] }
    }
    [pscustomobject]@{
        PSTypeName      = 'AetherWeb.MessageEnvelope'
        MessageId       = $MessageId
        CorrelationId   = $CorrelationId
        MessageType     = $MessageType
        ReceivedAtUtc   = [datetime]::UtcNow.ToString('o')
        Status          = 'Queued'
        RetryCount      = 0
        Request         = $meta
        Payload         = $Payload
        QueueFolder     = 'incoming'
        QueuePath       = $null
        LastError       = $null
        CompletedAtUtc  = $null
    }
}

function Send-FileMessage {
<#
.SYNOPSIS
Enqueues a message envelope into a file-backed queue.
.DESCRIPTION
Writes a message envelope to the incoming folder of a file-backed queue as a
JSON document.
.PARAMETER Path
The root queue path.
.PARAMETER Envelope
The message envelope to persist.
.EXAMPLE
PS C:\> Send-FileMessage -Path 'C:\Queues\Orders' -Envelope $envelope
.EXAMPLE
PS C:\> $envelope | Send-FileMessage -Path 'C:\Queues\Orders'
.EXAMPLE
PS C:\> Send-FileMessage -Path 'C:\Queues\Orders' -Envelope $envelope -WhatIf
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
System.Management.Automation.PSCustomObject
.NOTES
Messages are stored as UTF-8 JSON files named by MessageId.
.EXAMPLE
PS C:\> Get-Help Send-FileMessage -Detailed

Displays the full comment-based help for Send-FileMessage.

.EXAMPLE
PS C:\> Get-Help Send-FileMessage -Examples

Displays the example set for Send-FileMessage.


.EXAMPLE
PS C:\> Get-Help Send-FileMessage -Full

Displays the complete help topic for Send-FileMessage.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Envelope
    )
    begin {}
    process {
        $queue = New-FileMessageQueue -Path $Path
        if ($null -eq $queue) { return }
        $messageId = $Envelope.MessageId
        if ([string]::IsNullOrEmpty($messageId)) {
            Write-Error -Message 'Envelope must contain a MessageId.'
            return
        }
        $targetPath = Join-Path -Path $queue.Incoming -ChildPath ($messageId + '.json')
        if (-not $PSCmdlet.ShouldProcess($targetPath, 'Enqueue file-backed message')) { return }
        try {
            if ($Envelope.PSObject.Properties.Name -contains 'QueueFolder') { $Envelope.QueueFolder = 'incoming' }
            if ($Envelope.PSObject.Properties.Name -contains 'QueuePath') { $Envelope.QueuePath = $queue.Path }
            $json = $Envelope | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($targetPath, $json, [System.Text.Encoding]::UTF8)
            Add-Member -InputObject $Envelope -MemberType NoteProperty -Name FilePath -Value $targetPath -Force
            Write-Output $Envelope
        }
        catch {
            Write-Error -Message ('Failed to enqueue message ''{0}'': {1}' -f $messageId, $_.Exception.Message)
        }
    }
    end {}
}

function Get-FileMessage {
<#
.SYNOPSIS
Gets a message from a file-backed queue by message identifier.
.DESCRIPTION
Searches the incoming, processing, completed, and deadletter folders for a
message JSON file and returns its parsed content.
.PARAMETER Path
The root queue path.
.PARAMETER MessageId
The message identifier.
.EXAMPLE
PS C:\> Get-FileMessage -Path 'C:\Queues\Orders' -MessageId $messageId
.EXAMPLE
PS C:\> '7b6e4c1f-5b1a-4782-9178-1176d8a4db33' | Get-FileMessage -Path 'C:\Queues\Orders'
.EXAMPLE
PS C:\> Get-FileMessage -Path 'C:\Queues\Orders' -MessageId $messageId -WhatIf
.INPUTS
System.String
.OUTPUTS
System.Management.Automation.PSCustomObject
.EXAMPLE
PS C:\> Get-Help Get-FileMessage -Detailed

Displays the full comment-based help for Get-FileMessage.

.EXAMPLE
PS C:\> Get-Help Get-FileMessage -Examples

Displays the example set for Get-FileMessage.


.EXAMPLE
PS C:\> Get-Help Get-FileMessage -Full

Displays the complete help topic for Get-FileMessage.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][ValidateNotNullOrEmpty()][string]$MessageId
    )
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($MessageId, 'Read queued message')) { return }
        $dirs = Resolve-FileMessageQueueDirectories -Path $Path
        foreach ($folderName in 'incoming','processing','completed','deadletter') {
            $folderPath = $dirs.($folderName.Substring(0,1).ToUpper()+$folderName.Substring(1))
            $candidate = Join-Path -Path $folderPath -ChildPath ($MessageId + '.json')
            if (Test-Path -LiteralPath $candidate) {
                try {
                    $json = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8
                    $message = $json | ConvertFrom-Json
                    Add-Member -InputObject $message -MemberType NoteProperty -Name FilePath -Value $candidate -Force
                    Add-Member -InputObject $message -MemberType NoteProperty -Name QueueFolder -Value $folderName -Force
                    Add-Member -InputObject $message -MemberType NoteProperty -Name QueuePath -Value $dirs.Root -Force
                    Write-Output $message
                    return
                }
                catch {
                    Write-Error -Message ('Failed to read message ''{0}'': {1}' -f $MessageId, $_.Exception.Message)
                    return
                }
            }
        }
    }
    end {}
}

function Get-FileQueueStats {
<#
.SYNOPSIS
Returns counts for each folder in a file-backed queue.
.DESCRIPTION
Counts the JSON files and support artifacts in the queue folders so callers can
inspect queue depth and queue health.
.PARAMETER Path
The root queue path.
.EXAMPLE
PS C:\> Get-FileQueueStats -Path 'C:\Queues\Orders'

Returns a summary object for the Orders queue.

.EXAMPLE
PS C:\> 'C:\Queues\Orders' | Get-FileQueueStats

Uses pipeline input to return queue statistics.

.EXAMPLE
PS C:\> Get-FileQueueStats -Path 'C:\Queues\Orders' -Verbose

Shows the queue path being resolved before the counts are returned.

.EXAMPLE
PS C:\> Get-FileQueueStats -Path 'C:\Queues\Orders' -WhatIf

Shows what would happen without reading the queue statistics.

.INPUTS
System.String
.OUTPUTS
System.Management.Automation.PSCustomObject
.EXAMPLE
PS C:\> Get-Help Get-FileQueueStats -Detailed

Displays the full comment-based help for Get-FileQueueStats.

.EXAMPLE
PS C:\> Get-Help Get-FileQueueStats -Examples

Displays the example set for Get-FileQueueStats.

.EXAMPLE
PS C:\> Get-Help Get-FileQueueStats -Full

Displays the complete help topic for Get-FileQueueStats.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][ValidateNotNullOrEmpty()][string]$Path)
    begin {}
    process {
        if (-not $PSCmdlet.ShouldProcess($Path, 'Read file queue statistics')) { return }
        try {
            $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
        }
        catch {
            Write-Error -Message ('Queue path not found: {0}' -f $Path)
            return
        }
        $folders = [ordered]@{
            Incoming      = Join-Path $resolvedPath 'incoming'
            Processing    = Join-Path $resolvedPath 'processing'
            Completed     = Join-Path $resolvedPath 'completed'
            DeadLetter    = Join-Path $resolvedPath 'deadletter'
            Idempotency   = Join-Path $resolvedPath 'idempotency'
            Metadata      = Join-Path $resolvedPath 'metadata'
        }
        [pscustomobject]@{
            Path             = $resolvedPath
            IncomingCount    = @(Get-ChildItem -LiteralPath $folders.Incoming -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
            ProcessingCount  = @(Get-ChildItem -LiteralPath $folders.Processing -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
            CompletedCount   = @(Get-ChildItem -LiteralPath $folders.Completed -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
            DeadLetterCount  = @(Get-ChildItem -LiteralPath $folders.DeadLetter -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
            IdempotencyCount = @(Get-ChildItem -LiteralPath $folders.Idempotency -File -ErrorAction SilentlyContinue).Count
            MetadataCount    = @(Get-ChildItem -LiteralPath $folders.Metadata -File -ErrorAction SilentlyContinue).Count
        }
    }
    end {}
}

function Receive-FileMessage {
<#
.SYNOPSIS
Dequeues the next message from a file-backed queue.
.DESCRIPTION
Moves the oldest available message from the incoming folder to the processing
folder and returns the parsed envelope.
.PARAMETER Path
The root queue path.
.EXAMPLE
PS C:\> Receive-FileMessage -Path 'C:\Queues\Orders'
.EXAMPLE
PS C:\> Receive-FileMessage -Path 'C:\Queues\Orders' -WhatIf
.INPUTS
System.String
.OUTPUTS
System.Management.Automation.PSCustomObject
.NOTES
The function selects the oldest JSON file by LastWriteTime.
.EXAMPLE
PS C:\> Get-Help Receive-FileMessage -Detailed

Displays the full comment-based help for Receive-FileMessage.

.EXAMPLE
PS C:\> Get-Help Receive-FileMessage -Examples

Displays the example set for Receive-FileMessage.


.EXAMPLE
PS C:\> Get-Help Receive-FileMessage -Full

Displays the complete help topic for Receive-FileMessage.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path)
    $queue = New-FileMessageQueue -Path $Path
    if ($null -eq $queue) { return }
    $nextFile = Get-ChildItem -LiteralPath $queue.Incoming -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime, Name | Select-Object -First 1
    if ($null -eq $nextFile) { return }
    $targetPath = Join-Path -Path $queue.Processing -ChildPath $nextFile.Name
    if (-not $PSCmdlet.ShouldProcess($nextFile.FullName, 'Move message to processing')) { return }
    try {
        Move-Item -LiteralPath $nextFile.FullName -Destination $targetPath -Force
        $json = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8
        $message = $json | ConvertFrom-Json
        if ($message.PSObject.Properties.Name -contains 'QueueFolder') { $message.QueueFolder = 'processing' }
        if ($message.PSObject.Properties.Name -contains 'QueuePath') { $message.QueuePath = $queue.Path }
        Add-Member -InputObject $message -MemberType NoteProperty -Name FilePath -Value $targetPath -Force
        $updatedJson = $message | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($targetPath, $updatedJson, [System.Text.Encoding]::UTF8)
        Write-Output $message
    }
    catch {
        Write-Error -Message ('Failed to receive next message: {0}' -f $_.Exception.Message)
    }
}

function Complete-FileMessage {
<#
.SYNOPSIS
Moves a processing message to the completed folder.
.DESCRIPTION
Marks a message as completed and moves its JSON file from processing to the
completed folder.
.PARAMETER Path
The root queue path.
.PARAMETER Message
The message object returned by Receive-FileMessage or Get-FileMessage.
.PARAMETER Result
Optional result payload stored on the message before it is completed.
.EXAMPLE
PS C:\> $message = Receive-FileMessage -Path 'C:\Queues\Orders'
PS C:\> Complete-FileMessage -Path 'C:\Queues\Orders' -Message $message
.EXAMPLE
PS C:\> Complete-FileMessage -Path 'C:\Queues\Orders' -Message $message -Result @{ Outcome = 'OK' } -WhatIf
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
System.Management.Automation.PSCustomObject
.EXAMPLE
PS C:\> Get-Help Complete-FileMessage -Detailed

Displays the full comment-based help for Complete-FileMessage.

.EXAMPLE
PS C:\> Get-Help Complete-FileMessage -Examples

Displays the example set for Complete-FileMessage.


.EXAMPLE
PS C:\> Get-Help Complete-FileMessage -Full

Displays the complete help topic for Complete-FileMessage.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Message,
        [Parameter()][AllowNull()][object]$Result
    )
    begin {}
    process {
        $queue = New-FileMessageQueue -Path $Path
        if ($null -eq $queue) { return }
        $messageId = $Message.MessageId
        $sourcePath = if ($Message.PSObject.Properties.Name -contains 'FilePath') { $Message.FilePath } else { Join-Path -Path $queue.Processing -ChildPath ($messageId + '.json') }
        $targetPath = Join-Path -Path $queue.Completed -ChildPath ($messageId + '.json')
        if (-not $PSCmdlet.ShouldProcess($messageId, 'Complete queued message')) { return }
        try {
            if ($Message.PSObject.Properties.Name -contains 'Status') { $Message.Status = 'Completed' }
            if ($Message.PSObject.Properties.Name -contains 'QueueFolder') { $Message.QueueFolder = 'completed' }
            if ($Message.PSObject.Properties.Name -contains 'QueuePath') { $Message.QueuePath = $queue.Path }
            Add-Member -InputObject $Message -MemberType NoteProperty -Name Result -Value $Result -Force
            Add-Member -InputObject $Message -MemberType NoteProperty -Name CompletedAtUtc -Value ([datetime]::UtcNow.ToString('o')) -Force
            $json = $Message | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($targetPath, $json, [System.Text.Encoding]::UTF8)
            if (Test-Path -LiteralPath $sourcePath) { Remove-Item -LiteralPath $sourcePath -Force }
            Add-Member -InputObject $Message -MemberType NoteProperty -Name FilePath -Value $targetPath -Force
            Write-Output $Message
        }
        catch {
            Write-Error -Message ('Failed to complete message ''{0}'': {1}' -f $messageId, $_.Exception.Message)
        }
    }
    end {}
}

function Move-FileMessageToDeadLetter {
<#
.SYNOPSIS
Moves a processing message to the deadletter folder.
.DESCRIPTION
Marks a message as failed and writes it to the deadletter folder.
.PARAMETER Path
The root queue path.
.PARAMETER Message
The message object.
.PARAMETER ErrorMessage
The failure reason.
.EXAMPLE
PS C:\> Move-FileMessageToDeadLetter -Path 'C:\Queues\Orders' -Message $message -ErrorMessage 'Handler failed.'
.EXAMPLE
PS C:\> $message | Move-FileMessageToDeadLetter -Path 'C:\Queues\Orders' -ErrorMessage $_.Exception.Message
.EXAMPLE
PS C:\> Move-FileMessageToDeadLetter -Path 'C:\Queues\Orders' -Message $message -ErrorMessage 'Handler failed.' -WhatIf
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
System.Management.Automation.PSCustomObject
.EXAMPLE
PS C:\> Get-Help Move-FileMessageToDeadLetter -Detailed

Displays the full comment-based help for Move-FileMessageToDeadLetter.

.EXAMPLE
PS C:\> Get-Help Move-FileMessageToDeadLetter -Examples

Displays the example set for Move-FileMessageToDeadLetter.


.EXAMPLE
PS C:\> Get-Help Move-FileMessageToDeadLetter -Full

Displays the complete help topic for Move-FileMessageToDeadLetter.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Message,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ErrorMessage
    )
    begin {}
    process {
        $queue = New-FileMessageQueue -Path $Path
        if ($null -eq $queue) { return }
        $messageId = $Message.MessageId
        $sourcePath = if ($Message.PSObject.Properties.Name -contains 'FilePath') { $Message.FilePath } else { Join-Path -Path $queue.Processing -ChildPath ($messageId + '.json') }
        $targetPath = Join-Path -Path $queue.DeadLetter -ChildPath ($messageId + '.json')
        if (-not $PSCmdlet.ShouldProcess($messageId, 'Move queued message to deadletter')) { return }
        try {
            if ($Message.PSObject.Properties.Name -contains 'Status') { $Message.Status = 'DeadLettered' }
            if ($Message.PSObject.Properties.Name -contains 'QueueFolder') { $Message.QueueFolder = 'deadletter' }
            if ($Message.PSObject.Properties.Name -contains 'QueuePath') { $Message.QueuePath = $queue.Path }
            Add-Member -InputObject $Message -MemberType NoteProperty -Name LastError -Value $ErrorMessage -Force
            Add-Member -InputObject $Message -MemberType NoteProperty -Name FailedAtUtc -Value ([datetime]::UtcNow.ToString('o')) -Force
            $json = $Message | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($targetPath, $json, [System.Text.Encoding]::UTF8)
            if (Test-Path -LiteralPath $sourcePath) { Remove-Item -LiteralPath $sourcePath -Force }
            Add-Member -InputObject $Message -MemberType NoteProperty -Name FilePath -Value $targetPath -Force
            Write-Output $Message
        }
        catch {
            Write-Error -Message ('Failed to dead-letter message ''{0}'': {1}' -f $messageId, $_.Exception.Message)
        }
    }
    end {}
}

function Write-HttpAcceptedResponse {
<#
.SYNOPSIS
Writes a 202 Accepted response for asynchronous processing.
.DESCRIPTION
Writes a JSON response shaped for queue handoff scenarios where work will be
processed later by a background worker.
.PARAMETER Response
The HttpListenerResponse object.
.PARAMETER MessageId
The accepted message identifier.
.PARAMETER CorrelationId
The correlation identifier.
.PARAMETER StatusUrl
An optional status URL the caller can poll.
.PARAMETER RequestMethod
The request method used for HEAD-aware behavior.
.EXAMPLE
PS C:\> Write-HttpAcceptedResponse -Response $Context.Response -MessageId $messageId -CorrelationId $correlationId -StatusUrl '/api/messages/123' -RequestMethod $Context.Request.HttpMethod
.EXAMPLE
PS C:\> Write-HttpAcceptedResponse -Response $Context.Response -MessageId $messageId -CorrelationId $correlationId -RequestMethod $Context.Request.HttpMethod -WhatIf
.INPUTS
None.
.OUTPUTS
None.
.EXAMPLE
PS C:\> Get-Help Write-HttpAcceptedResponse -Detailed

Displays the full comment-based help for Write-HttpAcceptedResponse.

.EXAMPLE
PS C:\> Get-Help Write-HttpAcceptedResponse -Examples

Displays the example set for Write-HttpAcceptedResponse.


.EXAMPLE
PS C:\> Get-Help Write-HttpAcceptedResponse -Full

Displays the complete help topic for Write-HttpAcceptedResponse.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$MessageId,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$CorrelationId,
        [Parameter()][string]$StatusUrl,
        [Parameter()][string]$RequestMethod = 'GET'
    )
    if (-not $PSCmdlet.ShouldProcess($MessageId, 'Write accepted response')) { return }
    $payload = [ordered]@{ MessageId = $MessageId; CorrelationId = $CorrelationId; Status = 'Accepted'; StatusUrl = $StatusUrl }
    Write-HttpJsonResponse -Response $Response -InputObject $payload -StatusCode 202 -RequestMethod $RequestMethod
}

function Add-HttpEnqueueMiddleware {
<#
.SYNOPSIS
Adds middleware that bridges HTTP requests into a file-backed message queue.
.DESCRIPTION
Registers middleware that matches selected HTTP requests, creates a message
envelope, persists it to a file-backed queue, and returns 202 Accepted instead
of continuing through the route pipeline.
.PARAMETER Server
The server object.
.PARAMETER QueuePath
The root queue path.
.PARAMETER Name
A descriptive middleware name.
.PARAMETER PathPrefix
Optional path prefix filter.
.PARAMETER ExactPath
Optional exact request path filter.
.PARAMETER Method
One or more allowed HTTP methods.
.PARAMETER MessageType
The logical message type written into the envelope.
.PARAMETER MessageTypePropertyName
When set, the middleware tries to read the message type from the JSON payload
property with this name before falling back to -MessageType.
.PARAMETER StatusBasePath
The base path used to generate a status URL in the 202 response.
.PARAMETER AdditionalHeaders
Optional additional metadata added to the envelope.
.PARAMETER PassThru
Returns the registered middleware object.
.EXAMPLE
PS C:\> Add-HttpEnqueueMiddleware -Server $server -QueuePath 'C:\Queues\Orders' -PathPrefix '/api/jobs' -Method POST -MessageType 'JobSubmitted'
.EXAMPLE
PS C:\> Add-HttpEnqueueMiddleware -Server $server -QueuePath 'C:\Queues\Orders' -ExactPath '/api/orders' -Method POST -MessageTypePropertyName 'messageType'
.EXAMPLE
PS C:\> Add-HttpEnqueueMiddleware -Server $server -QueuePath 'C:\Queues\Orders' -PathPrefix '/api/jobs' -Method POST -MessageType 'JobSubmitted' -WhatIf
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
System.Management.Automation.PSCustomObject
.NOTES
This middleware is intended to be the HTTP front door for asynchronous work.
.EXAMPLE
PS C:\> Get-Help Add-HttpEnqueueMiddleware -Detailed

Displays the full comment-based help for Add-HttpEnqueueMiddleware.

.EXAMPLE
PS C:\> Get-Help Add-HttpEnqueueMiddleware -Examples

Displays the example set for Add-HttpEnqueueMiddleware.


.EXAMPLE
PS C:\> Get-Help Add-HttpEnqueueMiddleware -Full

Displays the complete help topic for Add-HttpEnqueueMiddleware.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$QueuePath,
        [Parameter()][ValidateNotNullOrEmpty()][string]$Name = 'EnqueueBridge',
        [Parameter()][string]$PathPrefix,
        [Parameter()][string]$ExactPath,
        [Parameter()][string[]]$Method = @('POST'),
        [Parameter()][string]$MessageType = 'HttpMessage',
        [Parameter()][string]$MessageTypePropertyName,
        [Parameter()][string]$StatusBasePath = '/api/messages',
        [Parameter()][hashtable]$AdditionalHeaders,
        [Parameter()][switch]$PassThru
    )
    begin {}
    process {
        if ([string]::IsNullOrEmpty($PathPrefix) -and [string]::IsNullOrEmpty($ExactPath)) {
            Write-Error -Message 'Specify -PathPrefix or -ExactPath.'
            return
        }
        $queue = New-FileMessageQueue -Path $QueuePath
        if ($null -eq $queue) { return }
        $normalizedMethods = @($Method | ForEach-Object { $_.ToUpperInvariant() })
        $middlewareScript = {
            param($Context, $Server, $Next)
            $requestPath = $Context.Request.Url.AbsolutePath
            $requestMethod = $Context.Request.HttpMethod.ToUpperInvariant()
            if ($using:normalizedMethods -notcontains $requestMethod) { & $Next; return }
            if (-not [string]::IsNullOrEmpty($using:ExactPath)) {
                if (-not [string]::Equals($requestPath, $using:ExactPath, [System.StringComparison]::OrdinalIgnoreCase)) { & $Next; return }
            }
            elseif (-not [string]::IsNullOrEmpty($using:PathPrefix)) {
                if (-not $requestPath.StartsWith($using:PathPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { & $Next; return }
            }
            $payload = $null
            $bodyText = Get-HttpRequestBodyText -Request $Context.Request
            if (-not [string]::IsNullOrWhiteSpace($Context.Request.ContentType) -and $Context.Request.ContentType.ToLowerInvariant().Contains('application/json')) {
                $payload = Get-HttpRequestBodyJson -Request $Context.Request
                if ($null -eq $payload) { $payload = $bodyText }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($bodyText)) {
                $payload = $bodyText
            }
            else {
                $payload = [ordered]@{}
            }
            $resolvedMessageType = $using:MessageType
            if (($null -ne $payload) -and (-not [string]::IsNullOrEmpty($using:MessageTypePropertyName))) {
                if ($payload.PSObject.Properties.Name -contains $using:MessageTypePropertyName) {
                    $candidate = $payload.$($using:MessageTypePropertyName)
                    if (-not [string]::IsNullOrEmpty([string]$candidate)) { $resolvedMessageType = [string]$candidate }
                }
            }
            $correlationId = $Context.Request.Headers['X-Correlation-Id']
            if ([string]::IsNullOrEmpty($correlationId)) { $correlationId = [guid]::NewGuid().Guid }
            Set-HttpContextItem -Context $Context -Name 'CorrelationId' -Value $correlationId
            $envelope = New-HttpMessageEnvelope -MessageType $resolvedMessageType -Payload $payload -Context $Context -CorrelationId $correlationId -Headers $using:AdditionalHeaders
            $saved = Send-FileMessage -Path $using:QueuePath -Envelope $envelope
            if ($null -eq $saved) {
                Write-HttpErrorResponse -Response $Context.Response -StatusCode 500 -StatusDescription '500 Failed to enqueue message' -RequestMethod $Context.Request.HttpMethod
                return
            }
            $trimmedStatusBasePath = $using:StatusBasePath
            if ([string]::IsNullOrEmpty($trimmedStatusBasePath)) { $trimmedStatusBasePath = '/api/messages' }
            $trimmedStatusBasePath = $trimmedStatusBasePath.TrimEnd('/')
            $statusUrl = ($trimmedStatusBasePath + '/' + $saved.MessageId)
            Write-HttpAcceptedResponse -Response $Context.Response -MessageId $saved.MessageId -CorrelationId $saved.CorrelationId -StatusUrl $statusUrl -RequestMethod $Context.Request.HttpMethod
        }
        if (-not $PSCmdlet.ShouldProcess($Name, 'Add HTTP enqueue middleware')) { return }
        $result = Add-HttpMiddleware -Server $Server -Name $Name -ScriptBlock $middlewareScript
        if ($PassThru) { Write-Output $result }
    }
    end {}
}

function Add-HttpMessageStatusRoutes {
<#
.SYNOPSIS
Adds queue status routes for the MOM bridge.
.DESCRIPTION
Registers HTTP routes that expose queue statistics and individual message status
lookups for a file-backed queue.
.PARAMETER Server
The server object.
.PARAMETER QueuePath
The root queue path.
.PARAMETER BasePath
The base route path for message operations.
.PARAMETER IncludeStatisticsRoute
Adds a queue statistics route at <BasePath>/stats.
.PARAMETER UseManagementToken
When specified, the server's management token is enforced for these routes.
.EXAMPLE
PS C:\> Add-HttpMessageStatusRoutes -Server $server -QueuePath 'C:\Queues\Orders'
.EXAMPLE
PS C:\> Add-HttpMessageStatusRoutes -Server $server -QueuePath 'C:\Queues\Orders' -BasePath '/api/jobs' -UseManagementToken

Registers secured message status routes below /api/jobs.

.EXAMPLE
PS C:\> Add-HttpMessageStatusRoutes -Server $server -QueuePath 'C:\Queues\Orders' -BasePath '/api/messages' -IncludeStatisticsRoute

Adds /api/messages/{id} and /api/messages/stats routes for the queue.

.EXAMPLE
PS C:\> $server | Add-HttpMessageStatusRoutes -QueuePath 'C:\Queues\Orders' -WhatIf
.INPUTS
System.Management.Automation.PSCustomObject
.OUTPUTS
System.Object[]
.EXAMPLE
PS C:\> Get-Help Add-HttpMessageStatusRoutes -Detailed

Displays the full comment-based help for Add-HttpMessageStatusRoutes.

.EXAMPLE
PS C:\> Get-Help Add-HttpMessageStatusRoutes -Examples

Displays the example set for Add-HttpMessageStatusRoutes.


.EXAMPLE
PS C:\> Get-Help Add-HttpMessageStatusRoutes -Full

Displays the complete help topic for Add-HttpMessageStatusRoutes.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$QueuePath,
        [Parameter()][ValidateNotNullOrEmpty()][string]$BasePath = '/api/messages',
        [Parameter()][switch]$IncludeStatisticsRoute,
        [Parameter()][switch]$UseManagementToken
    )
    begin { $results = @() }
    process {
        $queue = New-FileMessageQueue -Path $QueuePath
        if ($null -eq $queue) { return }
        $normalizedBasePath = $BasePath.TrimEnd('/')
        if (-not $normalizedBasePath.StartsWith('/')) { $normalizedBasePath = '/' + $normalizedBasePath }
        $capturedQueuePath = $QueuePath
        $capturedUseManagementToken = [bool]$UseManagementToken
        $messageRouteScript = {
            param($Context, $Server)
            if ($capturedUseManagementToken -and -not (Test-HttpManagementToken -Context $Context -Server $Server)) {
                Write-HttpErrorResponse -Response $Context.Response -StatusCode 401 -StatusDescription '401 Unauthorized' -RequestMethod $Context.Request.HttpMethod
                return
            }
            $messageId = Get-HttpRouteValue -Context $Context -Name 'id'
            $message = Get-FileMessage -Path $capturedQueuePath -MessageId $messageId
            if ($null -eq $message) {
                Write-HttpErrorResponse -Response $Context.Response -StatusCode 404 -StatusDescription '404 Message Not Found' -RequestMethod $Context.Request.HttpMethod
                return
            }
            Write-HttpJsonResponse -Response $Context.Response -InputObject $message -Depth 20 -RequestMethod $Context.Request.HttpMethod
        }.GetNewClosure()
        $results += Add-HttpRoute -Server $Server -Method GET -Path ($normalizedBasePath + '/{id}') -ScriptBlock $messageRouteScript
        if ($IncludeStatisticsRoute) {
            $statsRouteScript = {
                param($Context, $Server)
                if ($capturedUseManagementToken -and -not (Test-HttpManagementToken -Context $Context -Server $Server)) {
                    Write-HttpErrorResponse -Response $Context.Response -StatusCode 401 -StatusDescription '401 Unauthorized' -RequestMethod $Context.Request.HttpMethod
                    return
                }
                $stats = Get-FileQueueStats -Path $capturedQueuePath
                Write-HttpJsonResponse -Response $Context.Response -InputObject $stats -Depth 10 -RequestMethod $Context.Request.HttpMethod
            }.GetNewClosure()
            $results += Add-HttpRoute -Server $Server -Method GET -Path ($normalizedBasePath + '/stats') -ScriptBlock $statsRouteScript
        }
    }
    end { Write-Output $results }
}

function Start-FileQueueWorker {
<#
.SYNOPSIS
Processes messages from a file-backed queue.
.DESCRIPTION
Dequeues messages from the incoming folder, invokes a handler script block, and
moves each message to completed or deadletter based on the outcome.
.PARAMETER Path
The root queue path.
.PARAMETER HandlerScriptBlock
The message handler. It receives the message object as its only parameter.
.PARAMETER PollIntervalMilliseconds
The polling interval used when waiting for new messages.
.PARAMETER MaxMessages
Optional maximum number of messages to process before returning.
.PARAMETER UntilEmpty
Returns when the queue has no more incoming messages.
.EXAMPLE
PS C:\> Start-FileQueueWorker -Path 'C:\Queues\Orders' -HandlerScriptBlock { param($Message) 'done' } -UntilEmpty
.EXAMPLE
PS C:\> Start-FileQueueWorker -Path 'C:\Queues\Orders' -HandlerScriptBlock { param($Message) Invoke-Something -InputObject $Message } -MaxMessages 10
.EXAMPLE
PS C:\> Start-FileQueueWorker -Path 'C:\Queues\Orders' -HandlerScriptBlock { param($Message) 'done' } -UntilEmpty -WhatIf
.INPUTS
None.
.OUTPUTS
System.Management.Automation.PSCustomObject
.NOTES
Use Ctrl+C to stop a long-running worker loop.
.EXAMPLE
PS C:\> Get-Help Start-FileQueueWorker -Detailed

Displays the full comment-based help for Start-FileQueueWorker.

.EXAMPLE
PS C:\> Get-Help Start-FileQueueWorker -Examples

Displays the example set for Start-FileQueueWorker.


.EXAMPLE
PS C:\> Get-Help Start-FileQueueWorker -Full

Displays the complete help topic for Start-FileQueueWorker.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true)][ValidateNotNull()][scriptblock]$HandlerScriptBlock,
        [Parameter()][ValidateRange(100, 60000)][int]$PollIntervalMilliseconds = 1000,
        [Parameter()][ValidateRange(1, 2147483647)][int]$MaxMessages,
        [Parameter()][switch]$UntilEmpty
    )
    if (-not $PSCmdlet.ShouldProcess($Path, 'Start file queue worker')) { return }
    $processed = 0
    $completed = 0
    $deadLettered = 0
    while ($true) {
        if ($PSBoundParameters.ContainsKey('MaxMessages') -and ($processed -ge $MaxMessages)) { break }
        $message = Receive-FileMessage -Path $Path
        if ($null -eq $message) {
            if ($UntilEmpty) { break }
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
            continue
        }
        $processed++
        try {
            $result = & $HandlerScriptBlock $message
            Complete-FileMessage -Path $Path -Message $message -Result $result | Out-Null
            $completed++
        }
        catch {
            Move-FileMessageToDeadLetter -Path $Path -Message $message -ErrorMessage $_.Exception.Message | Out-Null
            $deadLettered++
            Write-Error -Message ('Message handler failed for ''{0}'': {1}' -f $message.MessageId, $_.Exception.Message)
        }
    }
    [pscustomobject]@{
        Path         = [System.IO.Path]::GetFullPath($Path)
        Processed    = $processed
        Completed    = $completed
        DeadLettered = $deadLettered
        FinishedAt   = Get-Date
    }
}


function Get-AetherWebCorrelationId {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter()][switch]$CreateIfMissing
    )
    $existing = Get-HttpContextItem -Context $Context -Name 'CorrelationId'
    if (-not [string]::IsNullOrEmpty([string]$existing)) { return [string]$existing }
    $headerValue = $Context.Request.Headers['X-Correlation-Id']
    if (-not [string]::IsNullOrEmpty($headerValue)) {
        Set-HttpContextItem -Context $Context -Name 'CorrelationId' -Value $headerValue
        return $headerValue
    }
    if ($CreateIfMissing) {
        $newValue = [guid]::NewGuid().Guid
        Set-HttpContextItem -Context $Context -Name 'CorrelationId' -Value $newValue
        return $newValue
    }
    return $null
}

function Read-AetherWebMessageFile {
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    $json = Get-Content -LiteralPath $LiteralPath -Raw -Encoding UTF8
    $message = $json | ConvertFrom-Json
    Add-Member -InputObject $message -MemberType NoteProperty -Name FilePath -Value $LiteralPath -Force
    return $message
}

function Write-AetherWebMessageFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][psobject]$Message
    )
    $json = $Message | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($LiteralPath, $json, [System.Text.Encoding]::UTF8)
}

function New-HttpServer {
<##>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$Prefix,
        [Parameter()][string]$RootPath,
        [Parameter()][string[]]$DefaultDocument = @('index.html', 'default.html'),
        [Parameter()][switch]$EnableDirectoryListing,
        [Parameter()][switch]$SortDirectoryListing,
        [Parameter()][switch]$EnableStaticFiles,
        [Parameter()][switch]$EnableManagementRoutes,
        [Parameter()][switch]$EnableRequestLogging,
        [Parameter()][string]$RequestLogPath,
        [Parameter()][ValidateSet('JsonLines','TabDelimited')][string]$RequestLogFormat = 'JsonLines',
        [Parameter()][switch]$EnableCorrelationHeaders,
        [Parameter()][string]$ManagementToken,
        [Parameter()][ValidateRange(1, 2147483647)][int]$MaxRequestBodyBytes,
        [Parameter()][ValidateRange(1, 2147483647)][int]$MaxMultipartFileBytes
    )
    foreach ($item in $Prefix) {
        if (-not $item.EndsWith('/')) {
            Write-Error -Message ('Prefix must end with ''/'': {0}' -f $item)
            return
        }
    }
    $resolvedRoot = $null
    if ($PSBoundParameters.ContainsKey('RootPath') -and -not [string]::IsNullOrEmpty($RootPath)) {
        try { $resolvedRoot = (Resolve-Path -LiteralPath $RootPath -ErrorAction Stop).ProviderPath }
        catch { Write-Error -Message ('RootPath not found: {0}' -f $RootPath); return }
    }
    if ($PSBoundParameters.ContainsKey('RequestLogPath') -and -not [string]::IsNullOrEmpty($RequestLogPath)) {
        try {
            $parent = Split-Path -Path $RequestLogPath -Parent
            if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
                Write-Error -Message ('Request log parent path not found: {0}' -f $parent)
                return
            }
        }
        catch { Write-Error -Message ('Invalid RequestLogPath: {0}' -f $_.Exception.Message); return }
    }
    if (-not $PSCmdlet.ShouldProcess(($Prefix -join ', '), 'Create HTTP server object')) { return }
    $listener = New-Object System.Net.HttpListener
    foreach ($item in $Prefix) { [void]$listener.Prefixes.Add($item) }
    [pscustomobject]@{
        PSTypeName              = 'AetherWeb.Server'
        Prefix                  = @($Prefix)
        RootPath                = $resolvedRoot
        DefaultDocument         = @($DefaultDocument)
        EnableDirectoryListing  = [bool]$EnableDirectoryListing
        SortDirectoryListing    = [bool]$SortDirectoryListing
        EnableStaticFiles       = [bool]$EnableStaticFiles
        EnableManagementRoutes  = [bool]$EnableManagementRoutes
        EnableRequestLogging    = [bool]$EnableRequestLogging
        RequestLogPath          = $RequestLogPath
        RequestLogFormat        = $RequestLogFormat
        EnableCorrelationHeaders = if ($PSBoundParameters.ContainsKey('EnableCorrelationHeaders')) { [bool]$EnableCorrelationHeaders } else { $true }
        ManagementToken         = $ManagementToken
        MaxRequestBodyBytes     = $MaxRequestBodyBytes
        MaxMultipartFileBytes   = $MaxMultipartFileBytes
        Listener                = $listener
        Routes                  = New-Object System.Collections.ArrayList
        PrefixRoutes            = New-Object System.Collections.ArrayList
        TemplateRoutes          = New-Object System.Collections.ArrayList
        Middleware              = New-Object System.Collections.ArrayList
        IsRunning               = $false
        StopRequested           = $false
        StartTime               = $null
        ResponseEncoding        = [System.Text.Encoding]::UTF8
        BackgroundPowerShell    = $null
        BackgroundHandle        = $null
    }
}

function Write-HttpRequestLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Server,
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][datetime]$Started,
        [Parameter()][int]$StatusCode = 0,
        [Parameter()][string]$ErrorMessage
    )
    if (-not $Server.EnableRequestLogging) { return }
    if ([string]::IsNullOrEmpty($Server.RequestLogPath)) { return }
    try {
        $elapsed = (Get-Date) - $Started
        $remote = $null
        if ($Context.Request.RemoteEndPoint) { $remote = $Context.Request.RemoteEndPoint.ToString() }
        $correlationId = Get-HttpContextItem -Context $Context -Name 'CorrelationId'
        $messageId = Get-HttpContextItem -Context $Context -Name 'MessageId'
        if (($Server.PSObject.Properties.Name -contains 'RequestLogFormat') -and ($Server.RequestLogFormat -eq 'TabDelimited')) {
            $line = '{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}' -f (Get-Date).ToString('o'), $Context.Request.HttpMethod, $Context.Request.RawUrl, $remote, $StatusCode, [int]$elapsed.TotalMilliseconds, $env:COMPUTERNAME, $correlationId, $messageId
        }
        else {
            $record = [ordered]@{
                TimestampUtc      = (Get-Date).ToUniversalTime().ToString('o')
                MachineName       = $env:COMPUTERNAME
                Method            = $Context.Request.HttpMethod
                Path              = $Context.Request.Url.AbsolutePath
                RawUrl            = $Context.Request.RawUrl
                QueryString       = $Context.Request.Url.Query
                RemoteEndPoint    = $remote
                UserAgent         = $Context.Request.UserAgent
                Origin            = $Context.Request.Headers['Origin']
                StatusCode        = $StatusCode
                ElapsedMs         = [int]$elapsed.TotalMilliseconds
                CorrelationId     = $correlationId
                MessageId         = $messageId
                ErrorMessage      = $ErrorMessage
            }
            $line = ($record | ConvertTo-Json -Depth 6 -Compress)
        }
        Add-Content -LiteralPath $Server.RequestLogPath -Value $line -Encoding UTF8
    }
    catch { Write-Verbose -Message ('Request log write failed: {0}' -f $_.Exception.Message) }
}

function Invoke-HttpRequestHandler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][psobject]$Server
    )
    $response = $Context.Response
    if (-not ($Context.Request.PSObject.Properties.Name -contains 'AetherWebMaxRequestBodyBytes')) { Add-Member -InputObject $Context.Request -MemberType NoteProperty -Name AetherWebMaxRequestBodyBytes -Value $Server.MaxRequestBodyBytes -Force }
    if (-not ($Context.Request.PSObject.Properties.Name -contains 'AetherWebMaxMultipartFileBytes')) { Add-Member -InputObject $Context.Request -MemberType NoteProperty -Name AetherWebMaxMultipartFileBytes -Value $Server.MaxMultipartFileBytes -Force }
    $started = Get-Date
    $statusCode = 0
    $errorMessage = $null
    try {
        $correlationId = Get-AetherWebCorrelationId -Context $Context -CreateIfMissing
        if (($Server.PSObject.Properties.Name -contains 'EnableCorrelationHeaders') -and $Server.EnableCorrelationHeaders) {
            try { Set-HttpResponseHeader -Response $response -Name 'X-Correlation-Id' -Value $correlationId -Confirm:$false } catch {}
        }
        Invoke-HttpMiddlewarePipeline -Context $Context -Server $Server
        $statusCode = $response.StatusCode
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Error -Message ('Request handling failed: {0}' -f $errorMessage)
        try {
            if ($response.OutputStream.CanWrite) {
                Write-HttpErrorResponse -Response $response -StatusCode 500 -StatusDescription '500 Internal Server Error' -RequestMethod $Context.Request.HttpMethod -Confirm:$false
                $statusCode = 500
            }
        }
        catch { Write-Verbose -Message 'Unable to send 500 response.' }
    }
    finally {
        if ($statusCode -eq 0) { $statusCode = $response.StatusCode }
        Write-HttpRequestLog -Server $Server -Context $Context -Started $started -StatusCode $statusCode -ErrorMessage $errorMessage
        $response.Close()
    }
}

function New-FileMessageQueue {
<##>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][ValidateNotNullOrEmpty()][string]$Path)
    process {
        $root = [System.IO.Path]::GetFullPath($Path)
        $folders = @{
            Root = $root
            Incoming = (Join-Path $root 'incoming')
            Processing = (Join-Path $root 'processing')
            Completed = (Join-Path $root 'completed')
            DeadLetter = (Join-Path $root 'deadletter')
            Metadata = (Join-Path $root 'metadata')
            Idempotency = (Join-Path $root 'idempotency')
        }
        if (-not $PSCmdlet.ShouldProcess($root, 'Create or validate file message queue')) { return }
        foreach ($pair in $folders.GetEnumerator()) {
            if ($pair.Key -eq 'Root') {
                if (-not (Test-Path -LiteralPath $pair.Value)) { [void](New-Item -ItemType Directory -Path $pair.Value -Force) }
            }
            else {
                if (-not (Test-Path -LiteralPath $pair.Value)) { [void](New-Item -ItemType Directory -Path $pair.Value -Force) }
            }
        }
        [pscustomobject]$folders
    }
}

function New-HttpMessageEnvelope {
<##>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$MessageType,
        [Parameter()][AllowNull()][object]$Payload,
        [Parameter()][System.Net.HttpListenerContext]$Context,
        [Parameter()][string]$CorrelationId,
        [Parameter()][string]$MessageId,
        [Parameter()][hashtable]$Headers,
        [Parameter()][string]$IdempotencyKey,
        [Parameter()][ValidateRange(1, 1000)][int]$MaxAttempts = 3,
        [Parameter()][int]$TimeToLiveSeconds
    )
    if (-not $PSCmdlet.ShouldProcess($MessageType, 'Create HTTP message envelope')) { return }
    if ([string]::IsNullOrEmpty($MessageId)) { $MessageId = [guid]::NewGuid().Guid }
    if ([string]::IsNullOrEmpty($CorrelationId)) { $CorrelationId = [guid]::NewGuid().Guid }
    $now = (Get-Date).ToUniversalTime()
    $meta = [ordered]@{}
    if ($null -ne $Context) {
        $meta.Method = $Context.Request.HttpMethod
        $meta.RawUrl = $Context.Request.RawUrl
        $meta.AbsolutePath = $Context.Request.Url.AbsolutePath
        $meta.ContentType = $Context.Request.ContentType
        $meta.UserAgent = $Context.Request.UserAgent
        $meta.RemoteEndPoint = if ($Context.Request.RemoteEndPoint) { $Context.Request.RemoteEndPoint.ToString() } else { $null }
    }
    [pscustomobject]@{
        MessageId           = $MessageId
        CorrelationId       = $CorrelationId
        MessageType         = $MessageType
        IdempotencyKey      = $IdempotencyKey
        Status              = 'Queued'
        CreatedAtUtc        = $now.ToString('o')
        UpdatedAtUtc        = $now.ToString('o')
        ExpiresAtUtc        = if ($PSBoundParameters.ContainsKey('TimeToLiveSeconds') -and ($TimeToLiveSeconds -gt 0)) { $now.AddSeconds($TimeToLiveSeconds).ToString('o') } else { $null }
        RetryCount          = 0
        MaxAttempts         = $MaxAttempts
        LeaseExpiresAtUtc   = $null
        CompletedAtUtc      = $null
        LastError           = $null
        Headers             = $Headers
        Request             = $meta
        Payload             = $Payload
        Result              = $null
        QueueFolder         = 'incoming'
        QueuePath           = $null
    }
}

function Send-FileMessage {
<##>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Envelope
    )
    process {
        $queue = New-FileMessageQueue -Path $Path -Confirm:$false
        if ($null -eq $queue) { return }
        $messageId = [string]$Envelope.MessageId
        if ([string]::IsNullOrEmpty($messageId)) { Write-Error -Message 'Envelope must contain a MessageId.'; return }
        if ($Envelope.PSObject.Properties.Name -contains 'QueueFolder') { $Envelope.QueueFolder = 'incoming' }
        if ($Envelope.PSObject.Properties.Name -contains 'QueuePath') { $Envelope.QueuePath = $queue.Root }
        if ($Envelope.PSObject.Properties.Name -contains 'UpdatedAtUtc') { $Envelope.UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
        $targetPath = Join-Path -Path $queue.Incoming -ChildPath ($messageId + '.json')
        if (-not $PSCmdlet.ShouldProcess($targetPath, 'Enqueue file-backed message')) { return }
        try {
            $idem = $null
            if ($Envelope.PSObject.Properties.Name -contains 'IdempotencyKey') { $idem = [string]$Envelope.IdempotencyKey }
            if (-not [string]::IsNullOrEmpty($idem)) {
                $indexPath = Join-Path -Path $queue.Idempotency -ChildPath (([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($idem))).Replace('/','_').Replace('+','-').TrimEnd('=') + '.json')
                if (Test-Path -LiteralPath $indexPath) {
                    $existingIndex = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $existingMessage = Get-FileMessage -Path $Path -MessageId $existingIndex.MessageId -Confirm:$false
                    if ($null -ne $existingMessage) { return $existingMessage }
                }
            }
            Write-AetherWebMessageFile -LiteralPath $targetPath -Message $Envelope
            if (-not [string]::IsNullOrEmpty($idem)) {
                $indexPayload = [pscustomobject]@{ IdempotencyKey = $idem; MessageId = $messageId; CreatedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
                Write-AetherWebMessageFile -LiteralPath $indexPath -Message $indexPayload
            }
            return (Get-FileMessage -Path $Path -MessageId $messageId -Confirm:$false)
        }
        catch { Write-Error -Message ('Failed to enqueue message ''{0}'': {1}' -f $messageId, $_.Exception.Message) }
    }
}

function Receive-FileMessage {
<##>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter()][ValidateRange(1, 86400)][int]$LeaseSeconds = 300
    )
    $queue = New-FileMessageQueue -Path $Path -Confirm:$false
    if ($null -eq $queue) { return }
    $nextFile = Get-ChildItem -LiteralPath $queue.Incoming -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime, Name | Select-Object -First 1
    if ($null -eq $nextFile) { return }
    $targetPath = Join-Path -Path $queue.Processing -ChildPath $nextFile.Name
    if (-not $PSCmdlet.ShouldProcess($nextFile.FullName, 'Move message to processing')) { return }
    try {
        Move-Item -LiteralPath $nextFile.FullName -Destination $targetPath -Force
        $message = Read-AetherWebMessageFile -LiteralPath $targetPath
        $now = (Get-Date).ToUniversalTime()
        if ($message.PSObject.Properties.Name -contains 'RetryCount') { $message.RetryCount = [int]$message.RetryCount + 1 }
        if ($message.PSObject.Properties.Name -contains 'Status') { $message.Status = 'Processing' }
        if ($message.PSObject.Properties.Name -contains 'QueueFolder') { $message.QueueFolder = 'processing' }
        if ($message.PSObject.Properties.Name -contains 'QueuePath') { $message.QueuePath = $queue.Root }
        if ($message.PSObject.Properties.Name -contains 'UpdatedAtUtc') { $message.UpdatedAtUtc = $now.ToString('o') }
        if ($message.PSObject.Properties.Name -contains 'LeaseExpiresAtUtc') { $message.LeaseExpiresAtUtc = $now.AddSeconds($LeaseSeconds).ToString('o') }
        Write-AetherWebMessageFile -LiteralPath $targetPath -Message $message
        return $message
    }
    catch { Write-Error -Message ('Failed to receive next message: {0}' -f $_.Exception.Message) }
}

function Complete-FileMessage {
<##>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Message,
        [Parameter()][AllowNull()][object]$Result
    )
    process {
        $queue = New-FileMessageQueue -Path $Path -Confirm:$false
        if ($null -eq $queue) { return }
        $messageId = [string]$Message.MessageId
        $sourcePath = if ($Message.PSObject.Properties.Name -contains 'FilePath') { $Message.FilePath } else { Join-Path -Path $queue.Processing -ChildPath ($messageId + '.json') }
        $targetPath = Join-Path -Path $queue.Completed -ChildPath ($messageId + '.json')
        if (-not $PSCmdlet.ShouldProcess($messageId, 'Complete queued message')) { return }
        try {
            if ($Message.PSObject.Properties.Name -contains 'Status') { $Message.Status = 'Completed' }
            if ($Message.PSObject.Properties.Name -contains 'QueueFolder') { $Message.QueueFolder = 'completed' }
            if ($Message.PSObject.Properties.Name -contains 'QueuePath') { $Message.QueuePath = $queue.Root }
            if ($Message.PSObject.Properties.Name -contains 'CompletedAtUtc') { $Message.CompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
            if ($Message.PSObject.Properties.Name -contains 'UpdatedAtUtc') { $Message.UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
            if ($Message.PSObject.Properties.Name -contains 'LeaseExpiresAtUtc') { $Message.LeaseExpiresAtUtc = $null }
            if ($PSBoundParameters.ContainsKey('Result')) {
                if ($Message.PSObject.Properties.Name -contains 'Result') { $Message.Result = $Result } else { Add-Member -InputObject $Message -MemberType NoteProperty -Name Result -Value $Result -Force }
            }
            Write-AetherWebMessageFile -LiteralPath $sourcePath -Message $Message
            Move-Item -LiteralPath $sourcePath -Destination $targetPath -Force
            return (Get-FileMessage -Path $Path -MessageId $messageId -Confirm:$false)
        }
        catch { Write-Error -Message ('Failed to complete queued message ''{0}'': {1}' -f $messageId, $_.Exception.Message) }
    }
}

function Move-FileMessageToDeadLetter {
<##>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Message,
        [Parameter()][string]$ErrorMessage
    )
    process {
        $queue = New-FileMessageQueue -Path $Path -Confirm:$false
        if ($null -eq $queue) { return }
        $messageId = [string]$Message.MessageId
        $sourcePath = if ($Message.PSObject.Properties.Name -contains 'FilePath') { $Message.FilePath } else { Join-Path -Path $queue.Processing -ChildPath ($messageId + '.json') }
        $targetPath = Join-Path -Path $queue.DeadLetter -ChildPath ($messageId + '.json')
        if (-not $PSCmdlet.ShouldProcess($messageId, 'Move queued message to deadletter')) { return }
        try {
            if ($Message.PSObject.Properties.Name -contains 'Status') { $Message.Status = 'DeadLettered' }
            if ($Message.PSObject.Properties.Name -contains 'QueueFolder') { $Message.QueueFolder = 'deadletter' }
            if ($Message.PSObject.Properties.Name -contains 'QueuePath') { $Message.QueuePath = $queue.Root }
            if ($Message.PSObject.Properties.Name -contains 'UpdatedAtUtc') { $Message.UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
            if ($Message.PSObject.Properties.Name -contains 'LeaseExpiresAtUtc') { $Message.LeaseExpiresAtUtc = $null }
            if (-not [string]::IsNullOrEmpty($ErrorMessage)) {
                if ($Message.PSObject.Properties.Name -contains 'LastError') { $Message.LastError = $ErrorMessage } else { Add-Member -InputObject $Message -MemberType NoteProperty -Name LastError -Value $ErrorMessage -Force }
            }
            Write-AetherWebMessageFile -LiteralPath $sourcePath -Message $Message
            Move-Item -LiteralPath $sourcePath -Destination $targetPath -Force
            return (Get-FileMessage -Path $Path -MessageId $messageId -Confirm:$false)
        }
        catch { Write-Error -Message ('Failed to dead-letter queued message ''{0}'': {1}' -f $messageId, $_.Exception.Message) }
    }
}

function Retry-FileMessage {
<#
.EXAMPLE
PS C:\> Get-Help Retry-FileMessage -Full

Displays the complete help topic for Retry-FileMessage.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Message,
        [Parameter()][string]$ErrorMessage,
        [Parameter()][ValidateRange(0, 86400)][int]$DelaySeconds = 0
    )
    process {
        $queue = New-FileMessageQueue -Path $Path -Confirm:$false
        if ($null -eq $queue) { return }
        $messageId = [string]$Message.MessageId
        $sourcePath = if ($Message.PSObject.Properties.Name -contains 'FilePath') { $Message.FilePath } else { Join-Path -Path $queue.Processing -ChildPath ($messageId + '.json') }
        $targetPath = Join-Path -Path $queue.Incoming -ChildPath ($messageId + '.json')
        if (-not $PSCmdlet.ShouldProcess($messageId, 'Retry queued message')) { return }
        try {
            if ($Message.PSObject.Properties.Name -contains 'Status') { $Message.Status = 'Queued' }
            if ($Message.PSObject.Properties.Name -contains 'QueueFolder') { $Message.QueueFolder = 'incoming' }
            if ($Message.PSObject.Properties.Name -contains 'QueuePath') { $Message.QueuePath = $queue.Root }
            if ($Message.PSObject.Properties.Name -contains 'UpdatedAtUtc') { $Message.UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
            if ($Message.PSObject.Properties.Name -contains 'LeaseExpiresAtUtc') { $Message.LeaseExpiresAtUtc = $null }
            if (-not [string]::IsNullOrEmpty($ErrorMessage)) {
                if ($Message.PSObject.Properties.Name -contains 'LastError') { $Message.LastError = $ErrorMessage } else { Add-Member -InputObject $Message -MemberType NoteProperty -Name LastError -Value $ErrorMessage -Force }
            }
            Write-AetherWebMessageFile -LiteralPath $sourcePath -Message $Message
            if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
            Move-Item -LiteralPath $sourcePath -Destination $targetPath -Force
            return (Get-FileMessage -Path $Path -MessageId $messageId -Confirm:$false)
        }
        catch { Write-Error -Message ('Failed to retry queued message ''{0}'': {1}' -f $messageId, $_.Exception.Message) }
    }
}

function Remove-FileMessage {
<#
.EXAMPLE
PS C:\> Get-Help Remove-FileMessage -Full

Displays the complete help topic for Remove-FileMessage.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][ValidateNotNullOrEmpty()][string]$MessageId
    )
    process {
        $message = Get-FileMessage -Path $Path -MessageId $MessageId -Confirm:$false
        if ($null -eq $message) { return $false }
        if (-not $PSCmdlet.ShouldProcess($MessageId, 'Remove file-backed message')) { return $false }
        Remove-Item -LiteralPath $message.FilePath -Force -ErrorAction Stop
        return $true
    }
}

function Resume-StaleFileMessages {
<#
.EXAMPLE
PS C:\> Get-Help Resume-StaleFileMessages -Full

Displays the complete help topic for Resume-StaleFileMessages.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter()][switch]$IncludeExpired
    )
    $queue = New-FileMessageQueue -Path $Path -Confirm:$false
    if ($null -eq $queue) { return }
    $results = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $queue.Processing -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $message = Read-AetherWebMessageFile -LiteralPath $file.FullName
            $leaseExpired = $false
            if ($message.PSObject.Properties.Name -contains 'LeaseExpiresAtUtc' -and -not [string]::IsNullOrEmpty([string]$message.LeaseExpiresAtUtc)) {
                $leaseExpired = ([datetime]$message.LeaseExpiresAtUtc).ToUniversalTime() -lt (Get-Date).ToUniversalTime()
            }
            $ttlExpired = $false
            if ($IncludeExpired -and ($message.PSObject.Properties.Name -contains 'ExpiresAtUtc') -and -not [string]::IsNullOrEmpty([string]$message.ExpiresAtUtc)) {
                $ttlExpired = ([datetime]$message.ExpiresAtUtc).ToUniversalTime() -lt (Get-Date).ToUniversalTime()
            }
            if ($ttlExpired) {
                if ($PSCmdlet.ShouldProcess($message.MessageId, 'Move expired message to deadletter')) {
                    $results += Move-FileMessageToDeadLetter -Path $Path -Message $message -ErrorMessage 'Message expired before processing.' -Confirm:$false
                }
            }
            elseif ($leaseExpired) {
                if ($PSCmdlet.ShouldProcess($message.MessageId, 'Resume stale processing message')) {
                    $results += Retry-FileMessage -Path $Path -Message $message -ErrorMessage 'Recovered stale processing lease.' -Confirm:$false
                }
            }
        }
        catch { Write-Error -Message ('Failed to inspect processing message ''{0}'': {1}' -f $file.FullName, $_.Exception.Message) }
    }
    return $results
}

function Repair-FileMessageQueue {
<#
.EXAMPLE
PS C:\> Get-Help Repair-FileMessageQueue -Full

Displays the complete help topic for Repair-FileMessageQueue.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter()][switch]$ResumeStaleMessages
    )
    $queue = New-FileMessageQueue -Path $Path -Confirm:$false
    if ($null -eq $queue) { return }
    $result = [ordered]@{
        Path = $queue.Root
        FoldersValidated = $true
        ResumedMessages = @()
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($ResumeStaleMessages) {
        if ($PSCmdlet.ShouldProcess($queue.Root, 'Resume stale messages during queue repair')) {
            $result.ResumedMessages = @(Resume-StaleFileMessages -Path $Path -IncludeExpired -Confirm:$false)
        }
    }
    [pscustomobject]$result
}

function Add-HttpEnqueueMiddleware {
<##>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$QueuePath,
        [Parameter()][ValidateNotNullOrEmpty()][string]$Name = 'EnqueueBridge',
        [Parameter()][string]$PathPrefix,
        [Parameter()][string]$ExactPath,
        [Parameter()][string[]]$Method = @('POST'),
        [Parameter()][string]$MessageType = 'HttpMessage',
        [Parameter()][string]$MessageTypePropertyName,
        [Parameter()][string]$StatusBasePath = '/api/messages',
        [Parameter()][hashtable]$AdditionalHeaders,
        [Parameter()][string]$IdempotencyHeaderName = 'Idempotency-Key',
        [Parameter()][ValidateRange(1, 1000)][int]$MaxAttempts = 3,
        [Parameter()][int]$TimeToLiveSeconds,
        [Parameter()][switch]$PassThru
    )
    process {
        if ([string]::IsNullOrEmpty($PathPrefix) -and [string]::IsNullOrEmpty($ExactPath)) {
            Write-Error -Message 'Specify -PathPrefix or -ExactPath.'
            return
        }
        $queue = New-FileMessageQueue -Path $QueuePath -Confirm:$false
        if ($null -eq $queue) { return }
        $normalizedMethods = @($Method | ForEach-Object { $_.ToUpperInvariant() })
        $capturedNormalizedMethods = @($normalizedMethods)
        $capturedExactPath = $ExactPath
        $capturedPathPrefix = $PathPrefix
        $capturedMessageType = $MessageType
        $capturedMessageTypePropertyName = $MessageTypePropertyName
        $capturedStatusBasePath = $StatusBasePath
        $capturedAdditionalHeaders = $AdditionalHeaders
        $capturedQueuePath = $QueuePath
        $capturedIdempotencyHeaderName = $IdempotencyHeaderName
        $capturedMaxAttempts = $MaxAttempts
        $capturedTimeToLiveSeconds = $TimeToLiveSeconds
        $middlewareScript = {
            param($Context, $Server, $Next)
            $requestPath = $Context.Request.Url.AbsolutePath
            $requestMethod = $Context.Request.HttpMethod.ToUpperInvariant()
            $methods = $capturedNormalizedMethods
            $exactPath = $capturedExactPath
            $pathPrefix = $capturedPathPrefix
            $messageType = $capturedMessageType
            $messageTypePropertyName = $capturedMessageTypePropertyName
            $statusBasePath = $capturedStatusBasePath
            $additionalHeaders = $capturedAdditionalHeaders
            $queuePath = $capturedQueuePath
            $idempotencyHeaderName = $capturedIdempotencyHeaderName
            $maxAttempts = $capturedMaxAttempts
            $timeToLiveSeconds = $capturedTimeToLiveSeconds
            if ($methods -notcontains $requestMethod) { & $Next; return }
            if (-not [string]::IsNullOrEmpty($exactPath)) {
                if (-not [string]::Equals($requestPath, $exactPath, [System.StringComparison]::OrdinalIgnoreCase)) { & $Next; return }
            }
            elseif (-not [string]::IsNullOrEmpty($pathPrefix)) {
                if (-not $requestPath.StartsWith($pathPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { & $Next; return }
            }
            $payload = $null
            $bodyText = Get-HttpRequestBodyText -Request $Context.Request -Confirm:$false
            if (-not [string]::IsNullOrWhiteSpace($Context.Request.ContentType) -and $Context.Request.ContentType.ToLowerInvariant().Contains('application/json')) {
                $payload = Get-HttpRequestBodyJson -Request $Context.Request -Confirm:$false
                if ($null -eq $payload) { $payload = $bodyText }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($bodyText)) { $payload = $bodyText }
            else { $payload = [ordered]@{} }
            $resolvedMessageType = $messageType
            if (($null -ne $payload) -and (-not [string]::IsNullOrEmpty($messageTypePropertyName))) {
                if ($payload.PSObject.Properties.Name -contains $messageTypePropertyName) {
                    $candidate = $payload.$($messageTypePropertyName)
                    if (-not [string]::IsNullOrEmpty([string]$candidate)) { $resolvedMessageType = [string]$candidate }
                }
            }
            $correlationId = Get-AetherWebCorrelationId -Context $Context -CreateIfMissing
            $idempotencyKey = $Context.Request.Headers[$idempotencyHeaderName]
            $envelope = New-HttpMessageEnvelope -MessageType $resolvedMessageType -Payload $payload -Context $Context -CorrelationId $correlationId -Headers $additionalHeaders -IdempotencyKey $idempotencyKey -MaxAttempts $maxAttempts -TimeToLiveSeconds $timeToLiveSeconds -Confirm:$false
            $saved = Send-FileMessage -Path $queuePath -Envelope $envelope -Confirm:$false
            if ($null -eq $saved) {
                Write-HttpErrorResponse -Response $Context.Response -StatusCode 500 -StatusDescription '500 Failed to enqueue message' -RequestMethod $Context.Request.HttpMethod -Confirm:$false
                return
            }
            Set-HttpContextItem -Context $Context -Name 'MessageId' -Value $saved.MessageId -Confirm:$false
            try { Set-HttpResponseHeader -Response $Context.Response -Name 'X-Message-Id' -Value $saved.MessageId -Confirm:$false } catch {}
            if ([string]::IsNullOrEmpty($statusBasePath)) { $statusBasePath = '/api/messages' }
            $statusUrl = ($statusBasePath.TrimEnd('/') + '/' + $saved.MessageId)
            Write-HttpAcceptedResponse -Response $Context.Response -MessageId $saved.MessageId -CorrelationId $saved.CorrelationId -StatusUrl $statusUrl -RequestMethod $Context.Request.HttpMethod -Confirm:$false
        }
        if (-not $PSCmdlet.ShouldProcess($Name, 'Add HTTP enqueue middleware')) { return }
        $result = Add-HttpMiddleware -Server $Server -Name $Name -ScriptBlock ($middlewareScript.GetNewClosure()) -Confirm:$false
        if ($PassThru) { return $result }
    }
}

function Start-FileQueueWorker {
<##>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true)][ValidateNotNull()][scriptblock]$HandlerScriptBlock,
        [Parameter()][ValidateRange(100, 60000)][int]$PollIntervalMilliseconds = 1000,
        [Parameter()][ValidateRange(1, 2147483647)][int]$MaxMessages,
        [Parameter()][switch]$UntilEmpty,
        [Parameter()][ValidateRange(1, 86400)][int]$LeaseSeconds = 300,
        [Parameter()][switch]$ResumeStaleMessages,
        [Parameter()][string]$StopFilePath
    )
    if (-not $PSCmdlet.ShouldProcess($Path, 'Start file queue worker')) { return }
    $processed = 0
    $completed = 0
    $retried = 0
    $deadLettered = 0
    while ($true) {
        if (-not [string]::IsNullOrEmpty($StopFilePath) -and (Test-Path -LiteralPath $StopFilePath)) { break }
        if ($PSBoundParameters.ContainsKey('MaxMessages') -and ($processed -ge $MaxMessages)) { break }
        if ($ResumeStaleMessages) { [void](Resume-StaleFileMessages -Path $Path -IncludeExpired -Confirm:$false) }
        $message = Receive-FileMessage -Path $Path -LeaseSeconds $LeaseSeconds -Confirm:$false
        if ($null -eq $message) {
            if ($UntilEmpty) { break }
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
            continue
        }
        $processed++
        try {
            if (($message.PSObject.Properties.Name -contains 'ExpiresAtUtc') -and -not [string]::IsNullOrEmpty([string]$message.ExpiresAtUtc)) {
                if ([datetime]$message.ExpiresAtUtc -lt (Get-Date).ToUniversalTime()) {
                    Move-FileMessageToDeadLetter -Path $Path -Message $message -ErrorMessage 'Message expired before handler execution.' -Confirm:$false | Out-Null
                    $deadLettered++
                    continue
                }
            }
            $result = & $HandlerScriptBlock $message
            Complete-FileMessage -Path $Path -Message $message -Result $result -Confirm:$false | Out-Null
            $completed++
        }
        catch {
            $maxAttempts = 3
            if ($message.PSObject.Properties.Name -contains 'MaxAttempts' -and ($message.MaxAttempts -gt 0)) { $maxAttempts = [int]$message.MaxAttempts }
            if (($message.PSObject.Properties.Name -contains 'RetryCount') -and ([int]$message.RetryCount -lt $maxAttempts)) {
                Retry-FileMessage -Path $Path -Message $message -ErrorMessage $_.Exception.Message -Confirm:$false | Out-Null
                $retried++
            }
            else {
                Move-FileMessageToDeadLetter -Path $Path -Message $message -ErrorMessage $_.Exception.Message -Confirm:$false | Out-Null
                $deadLettered++
            }
            Write-Error -Message ('Message handler failed for ''{0}'': {1}' -f $message.MessageId, $_.Exception.Message)
        }
    }
    [pscustomobject]@{
        Path         = [System.IO.Path]::GetFullPath($Path)
        Processed    = $processed
        Completed    = $completed
        Retried      = $retried
        DeadLettered = $deadLettered
        FinishedAt   = Get-Date
    }
}


function Add-HttpShutdownRoute {
<#
.EXAMPLE
PS C:\> Get-Help Add-HttpShutdownRoute -Full

Displays the complete help topic for Add-HttpShutdownRoute.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server,
        [Parameter()][ValidateNotNullOrEmpty()][string]$Path = '/admin/stop',
        [Parameter()][ValidateSet('GET','POST')][string]$Method = 'POST',
        [Parameter()][string]$Token,
        [Parameter()][ValidateNotNullOrEmpty()][string]$TokenHeaderName = 'X-Admin-Token',
        [Parameter()][switch]$LocalOnly,
        [Parameter()][string]$Message = 'Server stopping',
        [Parameter()][switch]$PassThru
    )
    process {
        if (-not $Path.StartsWith('/')) {
            Write-Error -Message ('Path must begin with ''/'': {0}' -f $Path)
            return
        }
        $capturedPath = $Path
        $capturedMethod = $Method.ToUpperInvariant()
        $capturedToken = $Token
        $capturedTokenHeaderName = $TokenHeaderName
        $capturedLocalOnly = [bool]$LocalOnly
        $capturedMessage = $Message
        if (-not $PSCmdlet.ShouldProcess(('{0}:{1}' -f $capturedMethod, $capturedPath), 'Add HTTP shutdown route')) { return }
        $route = Add-HttpRoute -Server $Server -Method $capturedMethod -Path $capturedPath -ScriptBlock {
            param($Context, $Server)
            if ($capturedLocalOnly) {
                $remoteAddress = $null
                if ($Context.Request.RemoteEndPoint -and $Context.Request.RemoteEndPoint.Address) {
                    $remoteAddress = $Context.Request.RemoteEndPoint.Address
                }
                $isLoopback = $false
                if ($remoteAddress) {
                    $isLoopback = [System.Net.IPAddress]::IsLoopback($remoteAddress)
                }
                if (-not $isLoopback) {
                    Write-HttpErrorResponse -Response $Context.Response -StatusCode 403 -StatusDescription '403 Shutdown route is restricted to localhost' -RequestMethod $Context.Request.HttpMethod -Confirm:$false
                    return
                }
            }
            if (-not [string]::IsNullOrEmpty($capturedToken)) {
                $suppliedToken = $Context.Request.Headers[$capturedTokenHeaderName]
                if ([string]::IsNullOrEmpty($suppliedToken) -or ($suppliedToken -ne $capturedToken)) {
                    Write-HttpErrorResponse -Response $Context.Response -StatusCode 403 -StatusDescription '403 Invalid shutdown token' -RequestMethod $Context.Request.HttpMethod -Confirm:$false
                    return
                }
            }
            $payload = [ordered]@{
                Status        = 'Stopping'
                Message       = $capturedMessage
                Time          = Get-Date
                CorrelationId = Get-HttpContextItem -Context $Context -Name 'CorrelationId'
                Path          = $capturedPath
                Method        = $capturedMethod
            }
            Write-HttpJsonResponse -Response $Context.Response -InputObject $payload -RequestMethod $Context.Request.HttpMethod -Confirm:$false
            if ($Server.PSObject.Properties.Name -contains 'StopRequested') {
                $Server.StopRequested = $true
            }
        }.GetNewClosure()
        if ($PassThru) { Write-Output $route }
    }
}

function Stop-HttpServer {
<##>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][psobject]$Server)
    process {
        if (-not $PSCmdlet.ShouldProcess(($Server.Prefix -join ', '), 'Stop HTTP server')) { return }
        try {
            if ($Server.PSObject.Properties.Name -contains 'StopRequested') { $Server.StopRequested = $true }
            if ($Server.Listener) {
                if ($Server.Listener.IsListening) { $Server.Listener.Stop() }
                $Server.Listener.Close()
            }
            if ($Server.BackgroundPowerShell) {
                try { if ($Server.BackgroundHandle) { $Server.BackgroundPowerShell.EndInvoke($Server.BackgroundHandle) | Out-Null } }
                catch { Write-Verbose -Message ('Background EndInvoke returned: {0}' -f $_.Exception.Message) }
                finally {
                    $Server.BackgroundPowerShell.Dispose()
                    $Server.BackgroundPowerShell = $null
                    $Server.BackgroundHandle = $null
                }
            }
            $Server.IsRunning = $false
        }
        catch { Write-Error -Message ('Failed to stop server: {0}' -f $_.Exception.Message) }
    }
}

Export-ModuleMember -Function @(
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
