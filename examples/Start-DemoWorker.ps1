<#
.SYNOPSIS
Starts a demo AetherWeb file-queue worker.

.DESCRIPTION
This script processes messages from the AetherWeb file-backed queue and
simulates handling submitted jobs.

It demonstrates:
- stale message recovery
- lease-based dequeue processing
- completion and retry/dead-letter flow handled by the module

.PARAMETER QueuePath
The queue root folder.

.PARAMETER LeaseSeconds
The processing lease duration in seconds.

.PARAMETER PollIntervalSeconds
The polling interval when waiting for work.

.PARAMETER UntilEmpty
When specified, the worker exits after the queue becomes empty.

.EXAMPLE
PS C:\> .\Start-DemoWorker.ps1 -Verbose

Starts the worker and keeps polling for work.

.EXAMPLE
PS C:\> .\Start-DemoWorker.ps1 -UntilEmpty -Verbose

Processes until the queue is empty, then exits.

.INPUTS
None.

.OUTPUTS
None.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string]$QueuePath = 'C:\AetherWebDemo\Queue',

    [Parameter()]
    [ValidateRange(30, 3600)]
    [int]$LeaseSeconds = 300,

    [Parameter()]
    [switch]$UntilEmpty
)

Import-Module AetherWeb -Force -ErrorAction Stop

if ($PSCmdlet.ShouldProcess($QueuePath, 'Repair queue and start worker')) {
    Repair-FileMessageQueue -Path $QueuePath -ResumeStaleMessages | Out-Null

    Start-FileQueueWorker `
        -Path $QueuePath `
        -ResumeStaleMessages `
        -LeaseSeconds $LeaseSeconds `
        -UntilEmpty:$UntilEmpty `
        -HandlerScriptBlock {
            param($Message)

            $payload = $Message.Payload
            $target = $null
            $jobType = $null

            if ($payload) {
                if ($payload.PSObject.Properties['target']) {
                    $target = $payload.target
                }

                if ($payload.PSObject.Properties['jobType']) {
                    $jobType = $payload.jobType
                }
            }

            Start-Sleep -Seconds 2

            [pscustomobject]@{
                MessageId      = $Message.MessageId
                MessageType    = $Message.MessageType
                Target         = $target
                JobType        = $jobType
                ProcessedAt    = Get-Date
                WorkerMachine  = $env:COMPUTERNAME
                Outcome        = 'Completed'
            }
        } `
        -Verbose:$VerbosePreference
}