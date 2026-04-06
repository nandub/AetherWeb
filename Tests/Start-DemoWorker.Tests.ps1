Describe 'Start-DemoWorker example' {
    BeforeAll {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\examples\Start-DemoWorker.ps1'
        $parseErrors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    }

    It 'parses without syntax errors' {
        @($parseErrors).Count | Should Be 0
        $null -ne $ast | Should Be $true
    }

    It 'exposes the reconciled worker parameters' {
        $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })

        ($parameterNames -contains 'QueuePath') | Should Be $true
        ($parameterNames -contains 'LeaseSeconds') | Should Be $true
        ($parameterNames -contains 'PollIntervalSeconds') | Should Be $true
        ($parameterNames -contains 'StopFilePath') | Should Be $true
        ($parameterNames -contains 'UntilEmpty') | Should Be $true
    }

    It 'supports safe smoke invocation with WhatIf' {
        { & $scriptPath -WhatIf } | Should Not Throw
    }
}
