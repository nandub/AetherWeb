<#
.SYNOPSIS
Builds a release ZIP for the AetherWeb module.

.DESCRIPTION
Build-AetherWeb.ps1 packages the module content from the ..\Source folder into a
clean, installable ZIP file under ..\dist.

The script can optionally update the module version and GUID in the source
manifest before packaging. The resulting ZIP is structured so it can be
extracted directly under:

    Documents\WindowsPowerShell\Modules\AetherWeb\<Version>

This script is designed for Windows PowerShell 5.1.

.PARAMETER SourcePath
The source folder containing the latest AetherWeb module files such as
AetherWeb.psd1, AetherWeb.psm1, README.md, and en-US\AetherWeb-help.xml.

.PARAMETER DistPath
The folder where the release ZIP file will be written.

.PARAMETER NewVersion
Optional new module version. When specified, the script updates the source
manifest ModuleVersion and also generates a new GUID.

.PARAMETER RefreshGuid
When specified, the script generates a new GUID even if -NewVersion is not
provided.

.PARAMETER PassThru
Returns an object describing the generated package.

.EXAMPLE
PS C:\AetherWeb\scripts> .\Build-AetherWeb.ps1

Builds a ZIP using the current version in ..\Source\AetherWeb.psd1.

.EXAMPLE
PS C:\AetherWeb\scripts> .\Build-AetherWeb.ps1 -NewVersion '1.7.8'

Updates the source manifest to version 1.7.8, generates a new GUID, and builds
a release ZIP in ..\dist.

.EXAMPLE
PS C:\AetherWeb\scripts> .\Build-AetherWeb.ps1 -NewVersion '1.7.8' -WhatIf

Shows what would happen without changing the manifest or writing the ZIP.

.EXAMPLE
PS C:\AetherWeb\scripts> .\Build-AetherWeb.ps1 -PassThru

Builds the package and returns package details as an object.

.INPUTS
None.

.OUTPUTS
System.Management.Automation.PSCustomObject

.NOTES
Assumptions:
- The script is stored in the AetherWeb\scripts folder.
- The latest module source files are stored in AetherWeb\Source.
- The source manifest file is AetherWeb\Source\AetherWeb.psd1.
- The source folder already contains the files that should be packaged.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Source'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DistPath = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'dist'),

    [Parameter()]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$NewVersion,

    [Parameter()]
    [switch]$RefreshGuid,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version 2.0

try {
    $manifestPath = Join-Path -Path $SourcePath -ChildPath 'AetherWeb.psd1'
    $moduleFilePath = Join-Path -Path $SourcePath -ChildPath 'AetherWeb.psm1'

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Write-Error -Message ('Source path was not found: {0}' -f $SourcePath)
        return
    }

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Write-Error -Message ('Manifest file was not found: {0}' -f $manifestPath)
        return
    }

    if (-not (Test-Path -LiteralPath $moduleFilePath)) {
        Write-Error -Message ('Module file was not found: {0}' -f $moduleFilePath)
        return
    }

    Write-Verbose -Message ('SourcePath   : {0}' -f $SourcePath)
    Write-Verbose -Message ('ManifestPath : {0}' -f $manifestPath)
    Write-Verbose -Message ('DistPath     : {0}' -f $DistPath)

    $manifestContent = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8

    $currentVersionMatch = [regex]::Match($manifestContent, "ModuleVersion\s*=\s*'([^']+)'")
    if (-not $currentVersionMatch.Success) {
        Write-Error -Message 'Unable to locate ModuleVersion in the manifest.'
        return
    }

    $currentGuidMatch = [regex]::Match($manifestContent, "GUID\s*=\s*'([^']+)'")
    if (-not $currentGuidMatch.Success) {
        Write-Error -Message 'Unable to locate GUID in the manifest.'
        return
    }

    $effectiveVersion = $currentVersionMatch.Groups[1].Value
    $effectiveGuid = $currentGuidMatch.Groups[1].Value

    if ($PSBoundParameters.ContainsKey('NewVersion')) {
        $effectiveVersion = $NewVersion
        $effectiveGuid = [guid]::NewGuid().Guid

        $updatedManifestContent = $manifestContent
        $updatedManifestContent = [regex]::Replace(
            $updatedManifestContent,
            "ModuleVersion\s*=\s*'[^']+'",
            ("ModuleVersion = '{0}'" -f $effectiveVersion)
        )
        $updatedManifestContent = [regex]::Replace(
            $updatedManifestContent,
            "GUID\s*=\s*'[^']+'",
            ("GUID = '{0}'" -f $effectiveGuid)
        )

        if ($PSCmdlet.ShouldProcess($manifestPath, ('Update manifest version to {0} and refresh GUID' -f $effectiveVersion))) {
            Set-Content -LiteralPath $manifestPath -Value $updatedManifestContent -Encoding UTF8
            $manifestContent = $updatedManifestContent
            Write-Verbose -Message ('Updated manifest to version {0} with GUID {1}' -f $effectiveVersion, $effectiveGuid)
        }
    }
    elseif ($RefreshGuid) {
        $effectiveGuid = [guid]::NewGuid().Guid

        $updatedManifestContent = [regex]::Replace(
            $manifestContent,
            "GUID\s*=\s*'[^']+'",
            ("GUID = '{0}'" -f $effectiveGuid)
        )

        if ($PSCmdlet.ShouldProcess($manifestPath, 'Refresh manifest GUID')) {
            Set-Content -LiteralPath $manifestPath -Value $updatedManifestContent -Encoding UTF8
            $manifestContent = $updatedManifestContent
            Write-Verbose -Message ('Updated manifest GUID to {0}' -f $effectiveGuid)
        }
    }

    if (-not (Test-Path -LiteralPath $DistPath)) {
        if ($PSCmdlet.ShouldProcess($DistPath, 'Create dist folder')) {
            New-Item -Path $DistPath -ItemType Directory -Force | Out-Null
        }
    }

    $stageRoot = Join-Path -Path $env:TEMP -ChildPath ('AetherWeb.Build.' + [guid]::NewGuid().Guid)
    $stageModuleRoot = Join-Path -Path $stageRoot -ChildPath 'AetherWeb'
    $stageVersionRoot = Join-Path -Path $stageModuleRoot -ChildPath $effectiveVersion
    $zipFileName = 'AetherWeb-{0}.zip' -f $effectiveVersion
    $zipPath = Join-Path -Path $DistPath -ChildPath $zipFileName

    try {
        if ($PSCmdlet.ShouldProcess($stageVersionRoot, 'Create staging folder')) {
            New-Item -Path $stageVersionRoot -ItemType Directory -Force | Out-Null
        }

        $sourceItems = Get-ChildItem -LiteralPath $SourcePath -Force -ErrorAction Stop
        foreach ($item in $sourceItems) {
            $destinationPath = Join-Path -Path $stageVersionRoot -ChildPath $item.Name

            if ($PSCmdlet.ShouldProcess($destinationPath, ('Copy source item {0}' -f $item.Name))) {
                if ($item.PSIsContainer) {
                    Copy-Item -LiteralPath $item.FullName -Destination $destinationPath -Recurse -Force
                }
                else {
                    Copy-Item -LiteralPath $item.FullName -Destination $destinationPath -Force
                }
            }
        }

        if (Test-Path -LiteralPath $zipPath) {
            if ($PSCmdlet.ShouldProcess($zipPath, 'Remove existing release ZIP')) {
                Remove-Item -LiteralPath $zipPath -Force
            }
        }

        if ($PSCmdlet.ShouldProcess($zipPath, 'Create release ZIP')) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::CreateFromDirectory($stageRoot, $zipPath)
            Write-Verbose -Message ('Created release ZIP: {0}' -f $zipPath)
        }

        if ($PassThru) {
            [pscustomobject]@{
                ModuleName   = 'AetherWeb'
                Version      = $effectiveVersion
                Guid         = $effectiveGuid
                SourcePath   = $SourcePath
                ManifestPath = $manifestPath
                DistPath     = $DistPath
                ZipPath      = $zipPath
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $stageRoot) {
            if ($PSCmdlet.ShouldProcess($stageRoot, 'Remove staging folder')) {
                Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
catch {
    Write-Error -Message ('Build failed: {0}' -f $_.Exception.Message)
}