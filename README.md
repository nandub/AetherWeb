# AetherWeb

AetherWeb is a lightweight HTTP server and middleware toolkit for **Windows PowerShell 5.1**.

It is designed for local tools, internal services, admin dashboards, queue-backed job submission, and small API endpoints built on top of `System.Net.HttpListener`, while staying compatible with classic Windows PowerShell environments.

## Goals

AetherWeb is intended to provide a practical PowerShell-native framework for:

* lightweight HTTP services
* static file serving
* JSON APIs
* middleware pipelines
* browser-facing endpoints with CORS
* internal admin endpoints
* file-backed message queue workflows
* simple background job submission over HTTP

The project emphasizes:

* **Windows PowerShell 5.1 compatibility**
* **comment-based help**
* **ShouldProcess support**
* **clean packaging**
* **installable module ZIP output**
* **practical host validation**

## Current Scope

AetherWeb currently includes support for:

* HTTP server creation with `HttpListener`
* exact routes
* prefix routes
* grouped route registration
* middleware registration
* request/response helpers
* JSON, HTML, text, file, and error responses
* context-item storage
* CORS middleware
* file-backed queue support
* HTTP enqueue middleware for MOM-style workflows
* queue status routes
* shutdown route support
* demo server / worker scenarios
* build packaging and installable ZIP layout

## Important Compatibility Notes

AetherWeb is built specifically for:

* **Windows PowerShell 5.1**
* `System.Net.HttpListener`
* traditional Windows module installation under `Documents\\WindowsPowerShell\\Modules`

It does **not** target PowerShell 7+ first.

## Repository Layout

```text
AetherWeb\\
  LICENSE
  README.md
  CHANGELOG.md
  AGENTS.md
  scripts\\
    Build-AetherWeb.ps1
  Source\\
    LICENSE
    AetherWeb.psd1
    AetherWeb.psm1
    README.md
    EXAMPLES.md
    en-US\\
      AetherWeb-help.xml
  Tests\\
  docs\\
  handoff\\
  dist\\
```

## Source vs Installed Module

### Source folder

The working module source lives under:

```text
Source\\
```

This contains the latest editable module files such as:

* `AetherWeb.psd1`
* `AetherWeb.psm1`
* `README.md`
* `EXAMPLES.md`
* `en-US\\AetherWeb-help.xml`

### Installed module location

The packaged module should be installed under one of these paths:

```text
$env:OneDrive\\Documents\\WindowsPowerShell\\Modules\\AetherWeb\\<Version>\\
```

or, if OneDrive is unavailable:

```text
$env:USERPROFILE\\Documents\\WindowsPowerShell\\Modules\\AetherWeb\\<Version>\\
```

## Installation

### Option 1: Install from a built ZIP

Extract the packaged ZIP so the final structure looks like:

```text
Documents\\WindowsPowerShell\\Modules\\AetherWeb\\<Version>\\AetherWeb.psd1
Documents\\WindowsPowerShell\\Modules\\AetherWeb\\<Version>\\AetherWeb.psm1
Documents\\WindowsPowerShell\\Modules\\AetherWeb\\<Version>\\README.md
Documents\\WindowsPowerShell\\Modules\\AetherWeb\\<Version>\\LICENSE
Documents\\WindowsPowerShell\\Modules\\AetherWeb\\<Version>\\en-US\\AetherWeb-help.xml
```

### Option 2: Import directly from the repo source

For local development, you can import directly from the source manifest:

```powershell
Import-Module .\\Source\\AetherWeb.psd1 -Force
```

## Quick Smoke Test

```powershell
Import-Module .\\Source\\AetherWeb.psd1 -Force

$server = New-HttpServer -Prefix 'http://localhost:8080/'

Add-HttpRoute -Server $server -Method GET -Path '/health' -ScriptBlock {
    param($Context, $Server)

    Write-HttpJsonResponse `
        -Response $Context.Response `
        -InputObject @{
            Status = 'OK'
            Time   = Get-Date
        } `
        -RequestMethod $Context.Request.HttpMethod
} | Out-Null

Start-HttpServer -Server $server -Verbose
```

Then in another PowerShell window:

```powershell
Invoke-RestMethod -Method Get -Uri 'http://localhost:8080/health'
```

## Demo Scripts

Typical demo workflows include:

* `Start-DemoServer.ps1`
* `Start-DemoWorker.ps1`

These demonstrate:

* route registration
* middleware usage
* queue-backed job submission
* message status routes
* shutdown handling

## Building a Release ZIP

The build script lives in:

```text
scripts\\Build-AetherWeb.ps1
```

Example usage:

```powershell
.\\scripts\\Build-AetherWeb.ps1
```

Bump version and rebuild:

```powershell
.\\scripts\\Build-AetherWeb.ps1 -NewVersion '1.7.8'
```

Dry run:

```powershell
.\\scripts\\Build-AetherWeb.ps1 -NewVersion '1.7.8' -WhatIf
```

Return package details:

```powershell
.\\scripts\\Build-AetherWeb.ps1 -PassThru
```

Build output is written to:

```text
dist\\
```

## Documentation

AetherWeb uses:

* comment-based help in public functions
* external help under `Source\\en-US\\AetherWeb-help.xml`
* repo-level docs for project state and workflow

Useful commands:

```powershell
Get-Help AetherWeb -Full
Get-Help New-HttpServer -Detailed
Get-Help Add-HttpCorsMiddleware -Examples
Get-Help Start-FileQueueWorker -Full
```

## Testing

The repository includes smoke tests under:

```text
Tests\\
```

These are intended to verify:

* module import
* exported commands
* basic scenario coverage
* package/build expectations

## Codex CLI Workflow

This repo is structured so Codex CLI can use repo files as durable project context.

Recommended context files:

* `AGENTS.md`
* `docs/current-status.md`
* `docs/decisions.md`
* `docs/known-issues.md`
* `handoff/latest-chat-handoff.md`

Recommended Codex bootstrap prompt:

```text
Read AGENTS.md, docs/current-status.md, docs/decisions.md, docs/known-issues.md, and handoff/latest-chat-handoff.md.

Summarize:
1. the project purpose,
2. the PowerShell constraints,
3. what is currently working,
4. what is currently broken,
5. the next task to perform.

Do not edit files yet.
```

## Design Principles

AetherWeb is intentionally biased toward:

* small, understandable pieces
* PowerShell 5.1-safe syntax
* explicit control over side effects
* buildable/installable module packaging
* internal-service practicality over framework complexity

## Intended Use

AetherWeb is best suited for:

* internal admin APIs
* local machine tools
* lab services
* dashboards
* controlled internal automation workflows
* message submission endpoints for queue-backed processing

It is **not** intended to be a hardened public internet web framework.

## Known Caveats

Because the module evolved through multiple patch cycles, the project should continue to prioritize:

* host-side validation
* demo script/module synchronization
* shutdown/background-hosting stabilization
* careful PowerShell 5.1 runtime testing

## Contributing

When contributing changes:

* keep compatibility with **Windows PowerShell 5.1**
* use approved Verb-Noun naming where practical
* include `\[CmdletBinding(SupportsShouldProcess = $true)]`
* add or update comment-based help
* provide `.EXAMPLE` coverage
* keep changes minimal and targeted
* update tests and docs when behavior changes

## License

Licensed under the MIT License.  
See the [LICENSE](LICENSE) file for details.
