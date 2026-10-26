<#
.SYNOPSIS
Collects AKS Edge Essentials power-loss, service and VM-start evidence without recovery actions.
.DESCRIPTION
Run elevated on the Windows AKS-EE host before attempting recovery, then again with
CollectGuestJournals after recovery. Partial collections retain their archive and fail explicitly.
CollectGuestJournals uses the HCS guest agent (hcsdiag write/exec/read with collect-aksedge-linux-logs.sh)
and the AKS-EE node-command API; either channel is sufficient.
ConsolePipeName reads an existing local serial pipe only; no VM or guest settings are changed.
#>
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:PUBLIC\AksEdgeDiagnostics",
    [ValidateRange(1, 90)][int]$Days = 7,
    [datetime]$Since = (Get-Date).AddDays(-7),
    [ValidateRange(0, 3600)][int]$WatchSeconds = 0,
    [ValidateRange(1, 60)][int]$PollSeconds = 5,
    [ValidateRange(5, 300)][int]$ProbeTimeoutSeconds = 30,
    [string[]]$AdditionalServiceNames = @(),
    [switch]$CollectGuestJournals,
    [ValidateRange(100, 200000)][int]$JournalLines = 20000,
    [string]$RecoveredJournalPath,
    [ValidatePattern('^[^\\/:*?"<>|]+$')][string]$ConsolePipeName,
    [ValidateRange(1, 3600)][int]$ConsoleSeconds = 120,
    [ValidateRange(1, 256)][int]$ConsoleMaxMB = 16,
    [switch]$IncludeProductBundle,
    [switch]$Library
)

$ErrorActionPreference = 'Stop'
if ($PSBoundParameters.ContainsKey('Days') -and -not $PSBoundParameters.ContainsKey('Since')) {
    $Since = (Get-Date).AddDays(-$Days)
}

function Invoke-AksEdgeDiagnosticProbe {
    param([scriptblock]$Body, [object[]]$Arguments = @(), [int]$Seconds = 30)
    $job = Start-Job -ScriptBlock {
        param($Source, $Values)
        $ErrorActionPreference = 'Stop'
        # Render inside the job: deserialized Format-* objects cannot be rendered by the caller.
        & ([scriptblock]::Create($Source)) @Values | Out-String -Stream -Width 400
    } -ArgumentList $Body.ToString(), $Arguments
    try {
        if (-not (Wait-Job $job -Timeout $Seconds)) {
            Receive-Job $job -ErrorAction Continue
            throw "Diagnostic probe timed out after ${Seconds}s"
        }
        Receive-Job $job -ErrorAction Stop
        if ($job.State -ne 'Completed') { throw "Diagnostic probe ended in $($job.State)" }
    }
    finally {
        Stop-Job $job -ErrorAction Continue
        Remove-Job $job -Force -ErrorAction Continue
    }
}

function Save-AksEdgeDiagnosticSection {
    param([string]$Name, [scriptblock]$Body, [object[]]$Arguments = @(), [int]$Seconds = $ProbeTimeoutSeconds)
    $started = [datetime]::UtcNow
    $status = 'Complete'
    $failure = $null
    try {
        New-Item -ItemType File -Path "$script:CollectionPath\$Name.txt" -ErrorAction Stop | Out-Null
        Invoke-AksEdgeDiagnosticProbe -Body $Body -Arguments $Arguments -Seconds $Seconds |
            ForEach-Object {
                $_ | Out-String -Width 400 | Add-Content -LiteralPath "$script:CollectionPath\$Name.txt" -Encoding UTF8
            }
    }
    catch {
        $status = 'Failed'
        $failure = $_.Exception.Message
        $_ | Format-List * -Force | Out-String |
            Add-Content -LiteralPath "$script:CollectionPath\$Name.txt" -Encoding UTF8
        Write-Warning "COLLECTION_INCOMPLETE $Name : $failure"
    }
    $script:Sections.Add([pscustomobject]@{
        Name = $Name; Status = $status; Error = $failure
        StartedUtc = $started.ToString('o'); FinishedUtc = [datetime]::UtcNow.ToString('o')
    })
}

function Get-AksEdgeServiceSnapshot {
    param([string[]]$AdditionalNames)
    $services = @(Get-Service -ErrorAction Stop)
    $seeds = @('wssdagent', 'vmcompute', 'hns', 'vmms', 'HvHost') + $AdditionalNames +
        @($services | Where-Object { $_.Name -match 'aksedge|wssd|eflow' } | ForEach-Object Name)
    $queue = [Collections.Generic.Queue[string]]::new()
    foreach ($name in $seeds) { $queue.Enqueue($name) }
    $seen = @{}
    $result = @()
    while ($queue.Count) {
        $name = $queue.Dequeue()
        if ($seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        try { $service = Get-Service -Name $name -ErrorAction Stop }
        catch {
            if ($_.FullyQualifiedErrorId -notlike 'NoServiceFoundForGivenName*') { throw }
            $result += [pscustomobject]@{ Name = $name; Installed = $false }
            continue
        }
        foreach ($dependency in $service.ServicesDependedOn) { $queue.Enqueue($dependency.Name) }
        $result += [pscustomobject]@{
            Name = $service.Name; DisplayName = $service.DisplayName; Installed = $true
            Status = "$($service.Status)"; StartType = "$($service.StartType)"
            RequiredServices = @($service.ServicesDependedOn | ForEach-Object Name)
            DependentServices = @($service.DependentServices | ForEach-Object Name)
        }
    }
    [pscustomobject]@{ Utc = [datetime]::UtcNow.ToString('o'); Services = $result }
}

function Export-AksEdgeEventChannel {
    param([string]$Channel, [string]$Directory, [datetime]$Start)
    $metadata = Get-WinEvent -ListLog $Channel -ErrorAction Stop
    $file = ($Channel -replace '[^a-zA-Z0-9-]', '_') + '.evtx'
    $startText = $Start.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $direct = $metadata.LogType -in @('Analytical', 'Debug')
    if ($direct -and $metadata.IsEnabled) {
        throw "Direct channel $Channel is enabled; not disabling/clearing a customer's active trace. Obtain a support-approved trace export."
    }
    $arguments = @('epl', $Channel, (Join-Path $Directory $file), '/ow:true')
    if (-not $direct) { $arguments += "/q:*[System[TimeCreated[@SystemTime >= '$startText']]]" }
    & wevtutil.exe @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Event export $Channel exit=$LASTEXITCODE" }
    [pscustomobject]@{ Channel = $Channel; Enabled = $metadata.IsEnabled; File = $file; SinceUtc = $startText }
}

function Get-AksEdgeServiceEvents {
    param([datetime]$Start)
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = $Start
        } -ErrorAction Stop)
    }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
        return
    }
    foreach ($event in ($events | Sort-Object TimeCreated, RecordId)) {
        [xml]$xml = $event.ToXml()
        [pscustomobject]@{
            Utc = $event.TimeCreated.ToUniversalTime().ToString('o')
            EventId = $event.Id; RecordId = $event.RecordId
            ActivityId = "$($xml.Event.System.Correlation.ActivityID)"
            Data = @($xml.Event.EventData.Data | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Value = $_.'#text' }
            })
            Message = $event.Message
        }
    }
}

function Get-AksEdgeGuestJournalCommand {
    param([int]$Lines, [datetime]$Start)
    $utc = $Start.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    @'
export LC_ALL=C
section() {
    label="$1"; shift
    printf '\nAKSEE_GUEST_SECTION %s\n' "$label"
    "$@"
    rc=$?
    printf '\nAKSEE_GUEST_RESULT %s exit=%s\n' "$label" "$rc"
}
section identity sh -c 'date -u; uname -a; cat /proc/sys/kernel/random/boot_id; cat /proc/cmdline'
section journal-storage sh -c 'for p in /var/log/journal /run/log/journal; do if test -d "$p"; then ls -ld "$p"; else printf "ABSENT %s\n" "$p"; fi; done; df -h /var/log; journalctl --disk-usage'
section boot-index sudo -n journalctl --list-boots --no-pager
section journal-current sudo -n journalctl -b 0 --utc --no-pager -o short-precise -n __LINES__
section journal-previous sudo -n journalctl -b -1 --utc --no-pager -o short-precise -n __LINES__
section journal-incident sudo -n journalctl --since '__UTC__ UTC' --utc --no-pager -o short-precise -n __LINES__
section kernel-current sudo -n journalctl -b 0 -k --utc --no-pager -n __LINES__
section kernel-previous sudo -n journalctl -b -1 -k --utc --no-pager -n __LINES__
section dmesg sudo -n dmesg --time-format iso
section failed-units systemctl --failed --no-pager --full
section guest-services sudo -n journalctl --utc --no-pager -n __LINES__ -u gcs -u containerd -u kubelet -u k3s -u k3s-agent -u kms-plugin
printf '\nAKSEE_GUEST_COLLECTION_END\n'
'@.Replace('__LINES__', "$Lines").Replace('__UTC__', $utc)
}

function Invoke-AksEdgeHcsDiag {
    param([string[]]$Arguments, [int]$Seconds, [string]$HcsDiag = 'hcsdiag.exe')
    $info = [Diagnostics.ProcessStartInfo]::new($HcsDiag)
    $info.Arguments = @($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } }) -join ' '
    $info.UseShellExecute = $false
    # hcsdiag relays stdin to the guest process and waits for it to close.
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $started = [datetime]::UtcNow
    $process = [Diagnostics.Process]::Start($info)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($Seconds * 1000)
    if ($timedOut) {
        try { $process.Kill() } catch { }
        $null = $process.WaitForExit(5000)
    }
    $output = @($stdout, $stderr | ForEach-Object { if ($_.Wait(5000)) { $_.Result } }) -join ''
    [pscustomobject]@{
        Command = "hcsdiag $($info.Arguments)"; ExitCode = $(if ($timedOut) { $null } else { $process.ExitCode })
        TimedOut = $timedOut; Seconds = [int]([datetime]::UtcNow - $started).TotalSeconds; Output = $output
    }
}

function Get-AksEdgeHcsCandidateIds {
    param([string]$RawList)
    $ids = @()
    try {
        foreach ($system in ($RawList | ConvertFrom-Json)) {
            if ($system.SystemType -eq 'VirtualMachine' -and $system.State -eq 'Running') { $ids += "$($system.Id)" }
        }
    }
    catch { }
    if (-not $ids) {
        $ids = @([regex]::Matches($RawList, '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}') | ForEach-Object Value)
    }
    @($ids | Select-Object -Unique)
}

function Invoke-AksEdgeHcsGuestCollection {
    <#
    Pushes collect-aksedge-linux-logs.sh into the running HCS Linux VM through the guest compute
    service (hcsdiag write/exec/read), which needs neither SSH, the VM network nor wssdagent.
    #>
    param([string]$ScriptPath, [string]$Destination, [datetime]$Start, [int]$Lines,
        [string]$HcsDiag = 'hcsdiag.exe', [int]$RunSeconds = 300)
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Guest collector not found next to this script: $ScriptPath" }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $hostScript = Join-Path $Destination 'collect-aksedge-linux-logs.sh'
    [IO.File]::WriteAllText($hostScript, [IO.File]::ReadAllText($ScriptPath).Replace("`r`n", "`n"))
    $list = Invoke-AksEdgeHcsDiag @('list', '-raw') 30 $HcsDiag
    if ($list.ExitCode -ne 0) { throw "hcsdiag list failed: $($list.Output)" }
    $ids = @(Get-AksEdgeHcsCandidateIds $list.Output)
    if (-not $ids) { throw 'No running HCS virtual machine; the Linux node is not running or not HCS-managed.' }
    $epoch = [DateTimeOffset]::new($Start.ToUniversalTime()).ToUnixTimeSeconds()
    $name = 'aksedge-linux-logs-hcs'
    $guestScript = '/tmp/collect-aksedge-linux-logs.sh'
    $guestArchive = "/tmp/$name.tar.gz"
    $hostArchive = Join-Path $Destination "$name.tar.gz"
    $log = Join-Path $Destination 'hcs-attempts.txt'
    foreach ($id in $ids) {
        # The AKS-EE node may be addressed as a utility VM (-uvm) or directly; try both.
        foreach ($mode in @('-uvm', '')) {
            $target = @(@($mode) | Where-Object { $_ }) + $id
            $write = Invoke-AksEdgeHcsDiag (@('write') + $target + @($hostScript, $guestScript)) 60 $HcsDiag
            $write | Format-List | Out-String | Add-Content -LiteralPath $log -Encoding UTF8
            if ($write.ExitCode -ne 0) { continue }
            $exec = Invoke-AksEdgeHcsDiag (@('exec') + $target + @('/bin/bash', $guestScript, '--output-dir', '/tmp',
                    '--name', $name, '--since-epoch', "$epoch", '--lines', "$Lines")) $RunSeconds $HcsDiag
            $exec | Format-List | Out-String | Add-Content -LiteralPath $log -Encoding UTF8
            # hcsdiag exec may return before the guest process ends; the archive is published atomically.
            $pollUntil = [datetime]::UtcNow.AddSeconds($(if ($exec.Seconds -lt 10) { $RunSeconds } else { 30 }))
            do {
                Remove-Item -LiteralPath $hostArchive -Force -ErrorAction SilentlyContinue
                $read = Invoke-AksEdgeHcsDiag (@('read') + $target + @($guestArchive, $hostArchive)) 120 $HcsDiag
                $bytes = if (Test-Path -LiteralPath $hostArchive) { [IO.File]::ReadAllBytes($hostArchive) } else { @() }
                if ($read.ExitCode -eq 0 -and $bytes.Length -gt 2 -and $bytes[0] -eq 0x1f -and $bytes[1] -eq 0x8b) { break }
                $bytes = @()
                Start-Sleep -Seconds 5
            } while ([datetime]::UtcNow -lt $pollUntil)
            $read | Format-List | Out-String | Add-Content -LiteralPath $log -Encoding UTF8
            if (-not $bytes.Length) { continue }
            $null = Invoke-AksEdgeHcsDiag (@('exec') + $target + @('/bin/rm', '-f', $guestScript, $guestArchive)) 30 $HcsDiag
            "HCS guest collection succeeded: id=$id mode=$(if ($mode) { $mode } else { 'direct' }) archive=$hostArchive bytes=$($bytes.Length)"
            $extract = Join-Path $Destination 'extracted'
            New-Item -ItemType Directory -Force -Path $extract | Out-Null
            & tar.exe -xzf $hostArchive -C $extract 2>&1
            $manifest = Get-ChildItem -LiteralPath $extract -Recurse -Filter manifest.txt -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $manifest) { throw 'Archive retrieved but could not be extracted to verify its manifest; inspect the .tar.gz manually.' }
            $failed = (Select-String -LiteralPath $manifest.FullName -Pattern '^required_failed=(\d+)').Matches.Groups[1].Value
            if ($failed -ne '0') { throw "Guest collector reported $failed failed required sections; see sections.tsv in the archive." }
            return
        }
    }
    throw "hcsdiag guest channel unavailable for compute systems $($ids -join ', '); see hcs-attempts.txt (GCS not running or guest not booted)."
}

function Start-AksEdgeConsoleCapture {
    param([string]$PipeName, [string]$Directory, [int]$Seconds, [int]$MaxMB)
    Start-Job -ArgumentList $PipeName, $Directory, $Seconds, $MaxMB -ScriptBlock {
        param($name, $dest, $duration, $max)
        $ErrorActionPreference = 'Stop'
        $status = @{ StartedUtc = [datetime]::UtcNow.ToString('o'); Bytes = 0; Status = 'Failed'; Pipe = $name }
        $pipe = $null
        $file = $null
        try {
            $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $name, [IO.Pipes.PipeDirection]::In, [IO.Pipes.PipeOptions]::Asynchronous)
            $until = [datetime]::UtcNow.AddSeconds($duration)
            $pipe.Connect($duration * 1000)
            $file = [IO.File]::Open((Join-Path $dest 'linux-console.bin'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $buffer = New-Object byte[] 4096
            while ([datetime]::UtcNow -lt $until -and $status.Bytes -lt ($max * 1MB)) {
                $length = [Math]::Min($buffer.Length, ($max * 1MB) - $status.Bytes)
                $read = $pipe.ReadAsync($buffer, 0, $length)
                $remaining = [Math]::Max(1, [int]($until - [datetime]::UtcNow).TotalMilliseconds)
                if (-not $read.Wait($remaining)) { break }
                $count = $read.Result
                if ($count -eq 0) { break }
                $file.Write($buffer, 0, $count)
                $file.Flush()
                $status.Bytes += $count
            }
            if ($status.Bytes -eq 0) { throw 'Connected but no console bytes received; boot output is not established.' }
            $status.Status = 'CapturedWindow'
            $status.LimitReached = $status.Bytes -ge ($max * 1MB)
        }
        catch {
            $status.Error = $_.Exception.Message
            throw
        }
        finally {
            if ($file) { $file.Dispose() }
            if ($pipe) { $pipe.Dispose() }
            $status.FinishedUtc = [datetime]::UtcNow.ToString('o')
            $status | ConvertTo-Json | Set-Content (Join-Path $dest 'linux-console-status.json') -Encoding UTF8
        }
    }
}

function Assert-AksEdgeCollectionAdministrator {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Run from elevated Windows PowerShell on the AKS-EE host.' }
}

function Invoke-AksEdgeCustomerCollection {
    Assert-AksEdgeCollectionAdministrator
    if ($Since.ToUniversalTime() -gt [datetime]::UtcNow) { throw 'Since cannot be in the future.' }
    $script:CollectionPath = Join-Path $OutputRoot ("aksee-start-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:CollectionPath | Out-Null
    $script:Sections = [Collections.Generic.List[object]]::new()
    $console = $null
    try {
        if ($ConsolePipeName) {
            $console = Start-AksEdgeConsoleCapture $ConsolePipeName $script:CollectionPath $ConsoleSeconds $ConsoleMaxMB
        }
        else {
            'Unavailable: no existing console pipe specified. Past, unrecorded serial output cannot be reconstructed. No VM settings were changed.' |
                Set-Content "$script:CollectionPath\linux-console-unavailable.txt"
        }
        Save-AksEdgeDiagnosticSection host {
            Get-Date -Format o
            Get-TimeZone | Format-List
            Get-CimInstance Win32_OperatingSystem | Select-Object Caption, BuildNumber, LastBootUpTime | Format-List
            Get-Module -ListAvailable AksEdge | Select-Object Name, Version, Path | Format-List
        }
        $serviceSource = (Get-Command Get-AksEdgeServiceSnapshot).Definition
        $snapshotBody = {
            param($source, $names)
            Set-Item Function:\Get-AksEdgeServiceSnapshot ([scriptblock]::Create($source))
            Get-AksEdgeServiceSnapshot -AdditionalNames $names | ConvertTo-Json -Depth 8
        }
        Save-AksEdgeDiagnosticSection services $snapshotBody @($serviceSource, $AdditionalServiceNames)
        Save-AksEdgeDiagnosticSection service-process-exits {
            Get-CimInstance Win32_Service |
                Select-Object Name, DisplayName, State, StartMode, ProcessId, ExitCode, ServiceSpecificExitCode, Started |
                ConvertTo-Json -Depth 4
        }
        $until = [datetime]::UtcNow.AddSeconds($WatchSeconds)
        $index = 0
        do {
            Save-AksEdgeDiagnosticSection "vm-state-$index" {
                'HCS compute-system inventory (HCS-managed VMs may not appear in Get-VM):'
                & hcsdiag.exe list -raw 2>&1
                if ($LASTEXITCODE -ne 0) { throw "hcsdiag exit=$LASTEXITCODE" }
            }
            Save-AksEdgeDiagnosticSection "hyperv-state-$index" {
                Get-VM | Select-Object Name, Id, State, Status, Uptime, AutomaticStartAction, AutomaticStopAction |
                    ConvertTo-Json -Depth 5
            }
            if ($WatchSeconds -eq 0 -or [datetime]::UtcNow -ge $until) { break }
            Save-AksEdgeDiagnosticSection "services-$index" $snapshotBody @($serviceSource, $AdditionalServiceNames)
            Start-Sleep -Seconds ([Math]::Min($PollSeconds, [Math]::Max(1, [int]($until - [datetime]::UtcNow).TotalSeconds)))
            $index++
        } while ([datetime]::UtcNow -lt $until)
        Save-AksEdgeDiagnosticSection vm-serial-pipes {
            'vmms provider (Windows Server, Windows 10 LTSC 2019): Hyper-V COM-port mapping. Empty Path = no serial pipe.'
            try { Get-VM | Get-VMComPort | Select-Object VMName, Name, Path | ConvertTo-Json -Depth 3 }
            catch { "Get-VMComPort unavailable: $($_.Exception.Message)" }
            'hcs provider (other client SKUs): the VM is an HCS compute system that Get-VM does not list.'
            $list = @(& hcsdiag.exe list 2>&1 | ForEach-Object { "$_" })
            $list
            $ids = @([regex]::Matches(($list -join "`n"), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}') | ForEach-Object Value | Sort-Object -Unique)
            $pipes = @([IO.Directory]::GetFiles('\\.\pipe\') | ForEach-Object { $_.Substring(9) })
            'Candidate host named pipes (contain a compute-system ID, -ledge, com/serial/console):'
            $candidates = @($pipes | Where-Object {
                    $pipe = $_
                    ($ids | Where-Object { $pipe -like "*$_*" }) -or $pipe -match '(?i)-ledge|com[0-9]|serial|console'
                })
            if ($candidates) { $candidates } else { 'None found: no serial named pipe is exposed for the Linux VM.' }
        }
        Save-AksEdgeDiagnosticSection aksee-node-state {
            Import-Module AksEdge -Force
            $module = Get-Module AksEdge
            & $module {
                $config = Get-ConfigurationStore
                $name = Get-LinuxNodeName
                if (-not $name) { throw 'Linux node identity unavailable; cannot establish its power state.' }
                $power = Get-PowerStateByVmName -VmName $name
                $vmConfig = Get-EflowVmConfigFromNodeAgent -vmName $name
                if (-not $power -or -not $vmConfig) { throw 'Node agent returned no power state/configuration; startup status is unknown.' }
                [pscustomobject]@{
                    LinuxNode = $name; Provider = $config.GetString('wssdProvider')
                    PowerState = $power; Configuration = $vmConfig
                } | ConvertTo-Json -Depth 30
            }
        } -Seconds 90
        Save-AksEdgeDiagnosticSection storage {
            Get-Disk | Select-Object Number, FriendlyName, OperationalStatus, HealthStatus, Size | Format-Table
            Get-Volume | Select-Object DriveLetter, FileSystem, HealthStatus, OperationalStatus, SizeRemaining, Size | Format-Table
            Get-PhysicalDisk | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus | Format-Table
            Get-VM | Get-VMHardDiskDrive | Select-Object VMName, Path, ControllerType | Format-Table
        }
        $eventSource = (Get-Command Get-AksEdgeServiceEvents).Definition
        Save-AksEdgeDiagnosticSection service-event-timeline {
            param($source, $start)
            Set-Item Function:\Get-AksEdgeServiceEvents ([scriptblock]::Create($source))
            ConvertTo-Json -InputObject @(Get-AksEdgeServiceEvents $start) -Depth 8
        } @($eventSource, $Since) -Seconds 60
        Save-AksEdgeDiagnosticSection event-inventory {
            & wevtutil.exe el
            if ($LASTEXITCODE -ne 0) { throw "Event-channel discovery exit=$LASTEXITCODE" }
        }
        $channels = @()
        if (Test-Path "$script:CollectionPath\event-inventory.txt") {
            $channels = Get-Content "$script:CollectionPath\event-inventory.txt" |
                ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
        $selected = @($channels | Where-Object {
            $_ -in @('System', 'Application') -or $_ -match 'Hyper-V-(Compute|Worker|VMMS|Hypervisor|StorageVSP|VmSwitch)|Host-Network-Service|TaskScheduler/Operational|AksEdge|Eflow|wssd'
        })
        $eventDirectory = Join-Path $script:CollectionPath 'events'
        New-Item -ItemType Directory $eventDirectory | Out-Null
        $exportSource = (Get-Command Export-AksEdgeEventChannel).Definition
        foreach ($channel in $selected) {
            Save-AksEdgeDiagnosticSection ("event-" + ($channel -replace '[^a-zA-Z0-9-]', '_')) {
                param($source, $name, $dest, $start)
                Set-Item Function:\Export-AksEdgeEventChannel ([scriptblock]::Create($source))
                Export-AksEdgeEventChannel $name $dest $start | ConvertTo-Json
            } @($exportSource, $channel, $eventDirectory, $Since)
        }
        foreach ($required in @('System', 'Application', 'Microsoft-Windows-Hyper-V-Compute-Admin')) {
            if ($required -notin $selected) {
                $script:Sections.Add([pscustomobject]@{
                    Name = "required-event-$required"; Status = 'Failed'
                    Error = 'Required event channel was not discovered. Do not interpret this as no failure events.'
                })
            }
        }
        Save-AksEdgeDiagnosticSection vm-start-event-timeline {
            param($directory)
            foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*Hyper-V*.evtx') {
                try { $events = @(Get-WinEvent -Path $file.FullName -MaxEvents 2000 -ErrorAction Stop) }
                catch {
                    if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
                    $events = @()
                }
                [pscustomobject]@{
                    Source = $file.Name; TimelineLimit = 2000; LimitReached = $events.Count -eq 2000
                    Events = @($events | Sort-Object TimeCreated, RecordId | ForEach-Object {
                        [xml]$xml = $_.ToXml()
                        [pscustomobject]@{
                            Utc = $_.TimeCreated.ToUniversalTime().ToString('o'); EventId = $_.Id
                            Level = $_.LevelDisplayName; RecordId = $_.RecordId
                            ActivityId = "$($xml.Event.System.Correlation.ActivityID)"
                            Message = $_.Message; Xml = $_.ToXml()
                        }
                    })
                } | ConvertTo-Json -Depth 8
            }
        } @($eventDirectory) -Seconds 90
        Save-AksEdgeDiagnosticSection product-logs {
            param($dest)
            Import-Module AksEdge -Force
            $module = Get-Module AksEdge
            $locations = & $module {
                $config = Get-ConfigurationStore
                [pscustomobject]@{
                    NodeLogs = Join-Path ($config.GetString('nodeConfigLocation')) 'log'
                    ProductLogs = Join-Path $script:productAppDataRoot 'logs'
                    VhdxDirectory = $config.GetString('eflowVhdxDir')
                }
            }
            $locations | ConvertTo-Json
            foreach ($item in @(@{Name='wssdagent';Path=$locations.NodeLogs}, @{Name='aksedge';Path=$locations.ProductLogs})) {
                if (-not (Test-Path -LiteralPath $item.Path -PathType Container)) { throw "Missing log directory $($item.Path)" }
                $sourcePath = [IO.Path]::GetFullPath($item.Path).TrimEnd('\') + '\'
                if ([IO.Path]::GetFullPath($dest).StartsWith($sourcePath, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Output directory must not be inside a source log directory.'
                }
                Copy-Item -LiteralPath $item.Path -Destination (Join-Path $dest $item.Name) -Recurse -ErrorAction Stop
            }
            if ($locations.VhdxDirectory) {
                Get-ChildItem -LiteralPath $locations.VhdxDirectory -Filter *.vhdx |
                    Select-Object Name, Length, LastWriteTimeUtc | Format-Table
            }
        } @($script:CollectionPath) -Seconds 90
        if ($CollectGuestJournals) {
            $hcsFunctions = @('Invoke-AksEdgeHcsDiag', 'Get-AksEdgeHcsCandidateIds', 'Invoke-AksEdgeHcsGuestCollection')
            Save-AksEdgeDiagnosticSection hcs-guest-logs {
                param($names, $sources, $script, $dest, $start, $lines)
                for ($i = 0; $i -lt $names.Count; $i++) { Set-Item "Function:\$($names[$i])" ([scriptblock]::Create($sources[$i])) }
                Invoke-AksEdgeHcsGuestCollection -ScriptPath $script -Destination $dest -Start $start -Lines $lines
            } @($hcsFunctions, @($hcsFunctions | ForEach-Object { (Get-Command $_).Definition }),
                (Join-Path $PSScriptRoot 'collect-aksedge-linux-logs.sh'), (Join-Path $script:CollectionPath 'linux-logs-hcs'),
                $Since, $JournalLines) -Seconds 900
            $guestCommand = Get-AksEdgeGuestJournalCommand $JournalLines $Since
            Save-AksEdgeDiagnosticSection recovered-linux-journals {
                param($command)
                Import-Module AksEdge -Force
                # The node-command API mangles multi-line scripts and treats any stderr as fatal;
                # send a single line, merge stderr and rely on the completion marker instead.
                $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($command))
                $records = @(Invoke-AksEdgeNodeCommand -NodeType Linux -Command "echo $encoded | base64 -d | bash 2>&1" -ignoreError 6>&1)
                $text = @($records | ForEach-Object {
                    if ($_ -is [Management.Automation.InformationRecord]) { "$($_.MessageData)" } else { "$_" }
                }) -join "`n"
                $text
                if ($text -notmatch '(?m)^AKSEE_GUEST_COLLECTION_END\r?$') { throw 'Guest command did not finish; recovered Linux journals are unavailable or incomplete.' }
                # A previous boot may legitimately not exist; it is optional, as in the bash collector.
                $failed = @([regex]::Matches($text, 'AKSEE_GUEST_RESULT (\S+) exit=([1-9]\d*)') |
                    Where-Object { $_.Groups[1].Value -notin @('journal-previous', 'kernel-previous') } | ForEach-Object Value)
                if ($failed) { throw "Guest journal sections failed: $($failed -join '; ')" }
            } @($guestCommand.Replace("`r`n", "`n")) -Seconds 180
            # Either guest channel is sufficient; only report a gap when both failed.
            $guestSections = @($script:Sections | Where-Object { $_.Name -in @('hcs-guest-logs', 'recovered-linux-journals') })
            if ($guestSections | Where-Object Status -eq 'Complete') {
                $guestSections | Where-Object Status -eq 'Failed' | ForEach-Object { $_.Status = 'Unavailable' }
            }
        }
        else {
            'Not requested. Rerun with -CollectGuestJournals after recovery. Previous boots require retained/persistent journal data.' |
                Set-Content "$script:CollectionPath\guest-journals-not-requested.txt"
        }
        if ($RecoveredJournalPath) {
            Save-AksEdgeDiagnosticSection recovered-journal-files {
                param($source, $dest)
                $resolved = Get-Item -LiteralPath $source -ErrorAction Stop
                if (-not $resolved.PSIsContainer) { throw 'RecoveredJournalPath must be a directory of already exported journal files.' }
                $target = Join-Path $dest 'recovered-journal-files'
                $sourceRoot = $resolved.FullName.TrimEnd('\') + '\'
                if ([IO.Path]::GetFullPath($target).StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Output directory must not be inside the recovered journal source.'
                }
                $files = @(Get-ChildItem -LiteralPath $resolved.FullName -Recurse -File |
                    Where-Object { $_.Name -match '\.journal(~)?$' })
                if (-not $files) { throw 'No .journal or .journal~ files found in recovered journal export.' }
                foreach ($file in $files) {
                    $relative = $file.FullName.Substring($sourceRoot.Length)
                    $destination = Join-Path $target $relative
                    New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
                    Copy-Item -LiteralPath $file.FullName -Destination $destination -ErrorAction Stop
                }
                'Copied existing journal export; no disk was mounted or repaired. Decode with journalctl --directory on Linux.'
            } @($RecoveredJournalPath, $script:CollectionPath) -Seconds 90
        }
        if ($IncludeProductBundle) {
            Save-AksEdgeDiagnosticSection product-bundle {
                param($dest)
                Import-Module AksEdge -Force
                $result = Get-AksEdgeLogs -OutputPath $dest -ErrorAction Stop
                if (-not (Get-ChildItem -LiteralPath $dest -Filter *.zip)) { throw "Get-AksEdgeLogs produced no ZIP: $result" }
                $result
            } @($script:CollectionPath) -Seconds 300
        }
    }
    catch {
        $script:Sections.Add([pscustomobject]@{ Name = 'collection-orchestration'; Status = 'Failed'; Error = $_.Exception.Message })
        Write-Warning "COLLECTION_INCOMPLETE $($_.Exception.Message)"
    }
    finally {
        if ($console) {
            try {
                if (-not (Wait-Job $console -Timeout ($ConsoleSeconds + 10))) { throw 'Console reader exceeded its bounded capture window.' }
                Receive-Job $console -ErrorAction Stop | Out-Null
                if ($console.State -ne 'Completed') { throw "Console reader state=$($console.State)" }
                $script:Sections.Add([pscustomobject]@{ Name = 'console'; Status = 'Complete'; Error = $null })
            }
            catch {
                $script:Sections.Add([pscustomobject]@{ Name = 'console'; Status = 'Failed'; Error = $_.Exception.Message })
                Write-Warning "COLLECTION_INCOMPLETE console : $($_.Exception.Message)"
            }
            finally { Stop-Job $console -ErrorAction Continue; Remove-Job $console -Force -ErrorAction Continue }
        }
        $manifest = @{
            CollectedUtc = [datetime]::UtcNow.ToString('o'); SinceUtc = $Since.ToUniversalTime().ToString('o')
            Host = $env:COMPUTERNAME; Sections = @($script:Sections.ToArray())
            StartupCause = 'Not inferred. Correlate VM identity, timestamps, HCS/WSSD errors and service events.'
            GuestJournalsRequested = $CollectGuestJournals.IsPresent
            ConsoleRequested = [bool]$ConsolePipeName; ConsoleHistoryReconstruction = $false
            Safety = 'No service/VM restart, repair, mount, guest setting or channel configuration change performed.'
        }
        $manifest | ConvertTo-Json -Depth 8 | Set-Content "$script:CollectionPath\manifest.json" -Encoding UTF8
        $zip = "$script:CollectionPath.zip"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory([IO.Path]::GetFullPath($script:CollectionPath), [IO.Path]::GetFullPath($zip))
        Write-Host "Review for sensitive information; use the approved support channel: $zip"
    }
    $failed = @($script:Sections | Where-Object Status -eq 'Failed')
    if ($failed) { throw "Partial diagnostics: $($failed.Count) failed sections. Evidence retained: $zip" }
    [pscustomobject]@{ Directory = $script:CollectionPath; Archive = $zip; Complete = $true }
}

if (-not $Library) { Invoke-AksEdgeCustomerCollection }
