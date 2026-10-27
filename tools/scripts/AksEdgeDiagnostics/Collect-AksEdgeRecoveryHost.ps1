<#
.SYNOPSIS
Bounded host observation around an independently initiated AKS-EE startup or recovery.
.DESCRIPTION
Watches the host for a bounded window while an AKS-EE startup or recovery is initiated separately.
Uses the shared collector, including historical SCM/crash and VM-start events. Does not start or repair the VM.
#>
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:PUBLIC\AksEdgeDiagnostics",
    [datetime]$Since = (Get-Date).AddDays(-7),
    [ValidateRange(0, 3600)][int]$WatchSeconds = 300,
    [ValidateRange(1, 60)][int]$PollSeconds = 5,
    [string[]]$AdditionalServiceNames = @(),
    [switch]$CollectGuestJournals,
    [string]$RecoveredJournalPath,
    [ValidatePattern('^[^\\/:*?"<>|]+$')][string]$ConsolePipeName,
    [ValidateRange(1, 3600)][int]$ConsoleSeconds = 300
)

$ErrorActionPreference = 'Stop'
$PSBoundParameters['WatchSeconds'] = $WatchSeconds
$PSBoundParameters['ConsoleSeconds'] = $ConsoleSeconds
& "$PSScriptRoot\Collect-AksEdgeDebug.ps1" @PSBoundParameters
