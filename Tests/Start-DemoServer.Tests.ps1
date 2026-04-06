Describe 'Start-DemoServer example' {
    BeforeAll {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\examples\Start-DemoServer.ps1'
        $parseErrors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    }

    It 'parses without syntax errors' {
        @($parseErrors).Count | Should Be 0
        $null -ne $ast | Should Be $true
    }

    It 'exposes the demo server parameters' {
        $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })

        ($parameterNames -contains 'Prefix') | Should Be $true
        ($parameterNames -contains 'RootPath') | Should Be $true
        ($parameterNames -contains 'QueuePath') | Should Be $true
        ($parameterNames -contains 'RequestLogPath') | Should Be $true
        ($parameterNames -contains 'AllowedOrigin') | Should Be $true
        ($parameterNames -contains 'ManagementToken') | Should Be $true
    }

    It 'supports safe smoke invocation with WhatIf' {
        { & $scriptPath -WhatIf } | Should Not Throw
    }
}
