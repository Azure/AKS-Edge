# AKS Edge Essentials VM-start diagnostics

Run these scripts **elevated on the affected Windows AKS-EE host** using
Windows PowerShell 5.1 or later. Keep all three scripts together
(`Collect-AksEdgeDebug.ps1`, `Collect-AksEdgeRecoveryHost.ps1` and the guest
collector `collect-aksedge-linux-logs.sh`). They write local
evidence only; review bundles for sensitive information and transfer them using
the approved support channel.

## Collect before recovery, then after recovery

Before restarting services, removing compute systems, mounting disks or
attempting another recovery:

```powershell
.\Collect-AksEdgeDebug.ps1 -Days 7 -OutputRoot C:\Temp\AksEdgeDiagnostics
```

For an incident with a known time, prefer an explicit offset/UTC timestamp:

```powershell
.\Collect-AksEdgeDebug.ps1 -Since ([datetime]'2026-10-25T12:00:00Z')
```

To observe an independently initiated startup/recovery in another window:

```powershell
.\Collect-AksEdgeRecoveryHost.ps1 -WatchSeconds 300 -PollSeconds 5
```

This companion entry point collects the same evidence and samples services and
HCS/Hyper-V VM state during the observation window. Probes run sequentially,
so samples are not guaranteed to be exactly five seconds apart. Watch duration
is followed by final log collection; this is not the total script runtime.
The script does **not** initiate a start, restart, power loss or recovery and
does not automatically resume when the Windows host itself reboots.

Once the Linux node is accessible, including after an ad-hoc restoration:

```powershell
.\Collect-AksEdgeDebug.ps1 -Since ([datetime]'2026-10-25T12:00:00Z') -CollectGuestJournals
```

`-CollectGuestJournals` tries two independent guest channels. Either one is
sufficient: when one succeeds, the other is marked `Unavailable` rather than
failing the collection. Only when both fail is the collection partial.

| Channel | Section | Needs | Output |
|---|---|---|---|
| HCS guest compute service | `hcs-guest-logs` | Running HCS compute system with the `gcs` service up (enabled in the AKS-EE image, `WantedBy=multi-user.target`). **No SSH, VM network, node agent or wssdagent required.** | `linux-logs-hcs\aksedge-linux-logs-hcs.tar.gz`, extracted to `linux-logs-hcs\extracted\`, plus `hcs-attempts.txt` |
| AKS-EE node-command API | `recovered-linux-journals` | Installed `Invoke-AksEdgeNodeCommand` (SSH), noninteractive sudo | `recovered-linux-journals.txt` |

The HCS channel copies `collect-aksedge-linux-logs.sh` (keep it next to the
PowerShell scripts) into the guest with `hcsdiag write`, runs it with
`hcsdiag exec`, and pulls the archive back with `hcsdiag read`. It selects
running `VirtualMachine` compute systems from `hcsdiag list -raw` and tries
each with `-uvm` and then directly, recording every attempt and its output in
`hcs-attempts.txt`. Systems where the guest agent is absent (for example the
Windows node or a `vmms`-provider VM) fail that probe and are skipped. A guest
that has not reached `multi-user.target` cannot run GCS, so this channel does
not replace the serial console for early-boot failures.

Both channels record the retained boot index, current/previous boot journals,
the incident-time journal, current/previous kernel journals, dmesg, failed
units, and gcs/containerd/kubelet/k3s/k3s-agent/kms-plugin journals. The HCS
archive additionally contains unit state, boot timing, storage/filesystem
state, memory, network, container/Kubernetes state when available, small
`/var/log` files and raw journal files (for `journalctl --directory`). Output
is bounded by `-JournalLines` (20,000 per journal query by default).
The reported boot IDs and retained boot index, not `-b -1` alone, establish
which boot corresponds to the incident after multiple recovery attempts.

### Collecting inside the Linux node with the bash script

When neither host channel works but the node can be logged into by another
route (SSH with the node key, `hcsdiag console <id> /bin/bash`, or a local
console login), run the same collector manually as root:

```bash
sudo bash collect-aksedge-linux-logs.sh --since-epoch $(date -d '2026-10-25 12:00:00Z' +%s)
# AKSEDGE_LINUX_LOGS archive=/tmp/aksedge-linux-logs-<host>-<utc>.tar.gz required_failed=0
```

Options: `--output-dir`, `--name`, `--lines` (default 20000), `--timeout`
(per command, default 60 s), `--max-journal-mb` (raw journal copy limit,
default 256, `0` skips) and `--max-file-mb` (per `/var/log` file, default 20).
It is read-only, every command has a timeout, and `sections.tsv` records each
command's exit status. Exit status is 0 only when every required section
succeeded; optional sections (previous boot, absent services, `crictl`) may
fail without affecting it. The archive is published atomically.

Copy the archive to the host using whichever route is available, for example
`Copy-AksEdgeNodeFile -FromFile /tmp/<archive> -ToFile C:\Temp\<archive>`,
`hcsdiag read <id> /tmp/<archive> C:\Temp\<archive>`, or `scp`.

If recovery bypassed AKS-EE management and no guest channel works, the script
reports that failure. Separately export journal files
through the support-approved recovery path and collect that existing directory:

```powershell
.\Collect-AksEdgeDebug.ps1 -RecoveredJournalPath C:\Temp\RecoveredJournal
```

Only `.journal`/`.journal~` files are copied, preserving relative paths. Inspect
them on Linux with `journalctl --directory <copied-directory> --list-boots`,
then select the incident boot/time. The collector **does not mount or repair
a VHDX**, use WSL to attach a live disk, or invent logs when persistent
journals were disabled/overwritten. Collect before further guest reboots.

## What is collected

| Requirement | Evidence and limits |
|---|---|
| AKS-EE dependency services | Seeds `wssdagent`, `vmcompute` (HCS), `hns`, `vmms`, `HvHost`, discovered AKS-EE/WSSD/EFLOW services and **recursive SCM required-service dependencies**. Records installed/not-installed, state, start type and direct dependents. Use `-AdditionalServiceNames` for externally supplied dependencies not declared in SCM. |
| Starts, stops, crashes, start failures | All retained **Service Control Manager** System events, UTC timestamps, IDs, record IDs, activity IDs, event data and full messages. Time-windowed System/Application EVTX also preserve service failure codes, WER/application crashes, power/boot/storage events. Process IDs and Win32 service exit codes are a current snapshot, not proof of a past crash. |
| Linux VM start failure/reason | HCS raw inventory, Hyper-V inventory, AKS-EE node identity/provider/current node-agent power state/configuration, WSSD/product logs, Compute/Worker/VMMS/Hypervisor/network/storage event channels. A readable Hyper-V timeline includes messages, full event XML and correlation IDs (latest 2,000 events per exported channel; full EVTX retained). HCS-managed VMs need not appear in `Get-VM`. |
| Failure versus inference | A Running state does not prove guest boot or application readiness. Current state cannot reconstruct a destroyed HCS instance. Use timestamp + VM/compute-system identity + activity/error codes to correlate the timeout and underlying failure. The manifest deliberately does **not** infer a root cause from a generic timeout. |
| Power/storage context | OS build, host last boot/timezone, disk/volume health/free space and configured VHDX file metadata. No filesystem scan, repair, attachment test or disk modification is performed. |
| Existing product bundle | Optional `-IncludeProductBundle` calls installed `Get-AksEdgeLogs` with a 300-second bound and verifies a ZIP exists. Existing product-command behavior applies; collection does not substitute for the explicit host/guest checks. |

Each section has a timeout, and failures are recorded in `manifest.json`.
Other sections continue. A partial ZIP is retained and its path printed before
the script throws; **do not discard partial evidence or treat exit failure as
meaning no bundle exists**. Expected unavailable features (such as console
capture not requested) are explicitly documented in the bundle. The manifest's
section completion does not imply all historical evidence still existed.

Event retention is determined by the customer's configured Windows logs.
Disabled channels may contain no records; the collector does not enable,
clear or resize them. Enabled Analytic/Debug channels are not disabled or
cleared to force an export: those sections explicitly fail with a request for
a support-approved trace export. This preserves ongoing customer tracing.

## Linux serial console: conditional, not automatic

AKS-EE's ordinary guest-command interface requires a responsive guest; it cannot
retrieve early firmware/kernel serial output from a guest that never booted.

### Finding the serial named-pipe name

`hcsdiag.exe` has **no serial-console command**. `hcsdiag console`/`exec`
start a process through the guest agent, so they need a booted guest and
cannot show firmware/kernel output from a VM that is stuck starting. They are
used for post-boot guest logs instead (see `-CollectGuestJournals` above).
`hcsdiag list` only shows whether the compute system exists and its state.

How the Linux node VM is created depends on the wssdagent provider, which the
AKS-EE installer selects from the host OS:

| Host OS | Provider | Linux VM visible to `Get-VM`? |
|---|---|---|
| Windows 10 Enterprise LTSC 2021, Windows 11 Enterprise (client SKUs other than build 17763) | `hcs` | **No** — HCS compute system, listed only by `hcsdiag list` |
| Windows 10 Enterprise LTSC 2019 (build 17763), Windows Server | `vmms` | Yes |

Check the provider in the collection's `aksee-node-state.txt` (`Provider`,
read from the AKS-EE configuration store).

**`vmms` provider** — read the Hyper-V COM-port mapping:

```powershell
Get-VMComPort -VMName (Get-AksEdgeNodeName -NodeType Linux) | Select-Object VMName, Name, Path
```

A `Path` such as `\\.\pipe\<name>` gives the basename `<name>` for
`-ConsolePipeName`; an empty `Path` means no serial pipe is configured.

**`hcs` provider** — the COM port, if any, is defined in the HCS
compute-system document that wssdagent submits (`ComPorts.<n>.NamedPipe`).
Neither `hcsdiag` nor the Hyper-V cmdlets expose that document, and it has
**not been verified that wssdagent configures a COM pipe for the AKS-EE Linux
VM**. While the VM is running or starting, list host pipes that could belong to
it:

```powershell
$ids = [regex]::Matches((hcsdiag list | Out-String), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
[IO.Directory]::GetFiles('\\.\pipe\') | ForEach-Object { $_.Substring(9) } |
    Where-Object { $p = $_; ($ids | Where-Object { $p -like "*$_*" }) -or $p -match '(?i)-ledge|com[0-9]|serial|console' }
```

Use a returned name as `-ConsolePipeName` only after confirming with the
product team that it is the Linux VM's serial port. If nothing is returned,
no serial console is exposed and it cannot be captured on that host. Do not
change the HCS document or guest boot arguments on a customer system without
a separately approved plan; the guest kernel must also log to the serial port
(`console=ttyS0`) for Linux messages to reach it.

Every collection records both views read-only in `vm-serial-pipes.txt`.

### Capturing the console during a VM start that times out

Both providers run the VM in a Hyper-V worker process (`vmwp.exe`), which
creates a configured COM pipe server when the VM starts and removes it when the
VM is turned off. The pipe does **not buffer**: only bytes
written while a reader is connected are captured. To capture a start that
times out (for example a 240-second `Start-AksEdgeNode -TimeoutSeconds 240`):

1. In elevated window A, start the collector **before** starting the VM, with a
   capture window longer than the start timeout plus the diagnostics phase:

   ```powershell
   .\Collect-AksEdgeRecoveryHost.ps1 -WatchSeconds 420 `
       -ConsolePipeName '<pipe-name>' -ConsoleSeconds 420
   ```

2. In elevated window B, start the node:
   `Start-AksEdgeNode -NodeType Linux -TimeoutSeconds 240`.

The reader keeps retrying the connection until the pipe appears or
`-ConsoleSeconds` ends (validated with a pipe created after the reader starts),
so it attaches as soon as Hyper-V creates the pipe. When the 240-second wait
expires, `Start-AksEdgeNode` saves its own diagnostics and returns an error, but
it does **not** turn off the VM, so capture continues until `-ConsoleSeconds`
ends or the VM is turned off (pipe closed). Results:

| Outcome in `linux-console-status.json` | Meaning |
|---|---|
| `CapturedWindow`, bytes > 0 | Console output during the stuck start; read `linux-console.bin`. |
| Connect timeout | The pipe never appeared: no serial pipe is configured, or the VM worker never started (a host-side failure before firmware, so check the service/VMMS/HCS sections). |
| Connected, 0 bytes | The pipe exists but the guest wrote nothing to the serial port (for example, no `console=ttyS0`). |

A start that has already timed out can still be attached to while the VM
remains on, but only output written after the reader connects is recorded.
After a power outage the VM starts automatically during host boot, before
anyone can launch the reader, so early boot output from that start is lost;
capture it on the next manual start using the steps above.

### Reader behaviour

Pass the pipe's basename, not `\\.\pipe\...`. The reader sends **no input**.
A Hyper-V COM pipe accepts one client; close PuTTY or any other reader first.
It waits for the endpoint to appear within the requested capture window and
saves raw bytes to `linux-console.bin` and status/timestamps/byte count to
`linux-console-status.json`. Default capture cap is 16 MiB; a reached cap is
reported. Connection failure, an incompatible endpoint or zero bytes is an
explicit collection failure, not a successful console capture.

This is an opt-in generic pipe reader, **not a verified AKS-EE HCS console
integration**. Do not guess a pipe name, compete with an existing reader, or
change production VM settings/guest boot arguments merely to run this script.
HCS's schema exposes `ComPort.NamedPipe` and firmware serial-console options,
but the deployed provider/image must actually route Linux output to a
compatible endpoint. This has not been established for the affected customer.
Any change to enable serial output requires a separate supported plan.
Past serial bytes that were never recorded cannot be recovered afterward.
Recovered kernel journals/dmesg may help, but are **not** a complete serial
boot-console recording.

References:
[Get-VMComPort](https://learn.microsoft.com/powershell/module/hyper-v/get-vmcomport),
[HCS ComPort schema](https://learn.microsoft.com/en-us/virtualization/api/hcs/schemareference#comport),
[HCS SerialConsole schema](https://learn.microsoft.com/en-us/virtualization/api/hcs/schemareference#serialconsole).

