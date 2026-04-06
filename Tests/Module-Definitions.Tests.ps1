Describe 'AetherWeb module definitions' {
    BeforeAll {
        $moduleManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\Source\AetherWeb.psd1'
        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\Source\AetherWeb.psm1'
        $parseErrors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
    }

    It 'parses without syntax errors' {
        @($parseErrors).Count | Should Be 0
        $null -ne $ast | Should Be $true
    }

    It 'does not contain duplicate function definitions' {
        $functionDefinitions = @(
            $ast.FindAll(
                {
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                },
                $true
            )
        )

        $duplicateNames = @(
            $functionDefinitions |
                Group-Object Name |
                Where-Object { $_.Count -gt 1 } |
                ForEach-Object { $_.Name }
        )

        @($duplicateNames).Count | Should Be 0
    }

    It 'imports from the module manifest' {
        Remove-Module AetherWeb -ErrorAction SilentlyContinue
        { Import-Module $moduleManifestPath -Force -ErrorAction Stop } | Should Not Throw
    }
}
