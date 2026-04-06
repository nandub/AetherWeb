Describe 'Start-FileQueueWorker module definition' {
    BeforeAll {
        $moduleManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\Source\AetherWeb.psd1'
        $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\Source\AetherWeb.psm1'
        $parseErrors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)

        Remove-Module AetherWeb -ErrorAction SilentlyContinue
        Import-Module $moduleManifestPath -Force -ErrorAction Stop
        $command = Get-Command -Module AetherWeb -Name Start-FileQueueWorker -ErrorAction Stop
    }

    It 'parses without syntax errors' {
        @($parseErrors).Count | Should Be 0
        $null -ne $ast | Should Be $true
    }

    It 'has only one Start-FileQueueWorker function definition in the module file' {
        $workerDefinitions = @(
            $ast.FindAll(
                {
                    param($node)
                    ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                    ($node.Name -eq 'Start-FileQueueWorker')
                },
                $true
            )
        )

        $workerDefinitions.Count | Should Be 1
    }

    It 'exports the current worker parameter set' {
        ($command.Parameters.ContainsKey('Path')) | Should Be $true
        ($command.Parameters.ContainsKey('HandlerScriptBlock')) | Should Be $true
        ($command.Parameters.ContainsKey('PollIntervalMilliseconds')) | Should Be $true
        ($command.Parameters.ContainsKey('MaxMessages')) | Should Be $true
        ($command.Parameters.ContainsKey('UntilEmpty')) | Should Be $true
        ($command.Parameters.ContainsKey('LeaseSeconds')) | Should Be $true
        ($command.Parameters.ContainsKey('ResumeStaleMessages')) | Should Be $true
        ($command.Parameters.ContainsKey('StopFilePath')) | Should Be $true
    }
}
