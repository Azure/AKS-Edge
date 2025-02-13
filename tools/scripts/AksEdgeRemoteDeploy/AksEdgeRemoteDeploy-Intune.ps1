<#
    .SYNOPSIS
        Sample script to deploy AksEdge via Intune

    .DESCRIPTION
        PowerShell script to deply AKS Edge Essentials using Intune
        In Intune, set the following for the return values
            -1 : Retry
            2 : Hard reboot
            0 : Success

    .PARAMETER RunToComplete
        Retry continuously until deployment is completed

    .PARAMETER UseK8s
        Use K8s distribution if present - If not, use default K3S
    
    .PARAMETER Tag
        Release Tag of AKS Edge Essentials release artifacts
        For more information, check https://github.com/Azure/AKS-Edge/releases
#>
param(
    [Switch] $RunToComplete,
    [Switch] $UseK8s,
    [string] $Tag
)
#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeRemoteDeployVersion -Value "1.0.241002.1000" -Option Constant -ErrorAction SilentlyContinue
if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}

$installDir = "C:\AksEdgeScript"
$productName = "AKS Edge Essentials - K3s"
$networkplugin = "flannel"
if ($UseK8s) {
    $productName ="AKS Edge Essentials - K8s"
    $networkplugin = "calico"
}

# Here string for the json content
$aideuserConfig = @"
{
    "SchemaVersion": "1.3",
    "Version": "1.0",
    "AksEdgeProduct": "$productName",
    "AksEdgeProductUrl": "",
    "Azure": {
        "SubscriptionName": "",
        "SubscriptionId": "",
        "TenantId": "",
        "ResourceGroupName": "aksedge-rg",
        "ServicePrincipalName": "aksedge-sp",
        "Location": "",
        "CustomLocationOID":"",
        "Auth":{
            "ServicePrincipalId":"",
            "Password":""
        },
        "ConnectedMachineName": ""
    },
    "AksEdgeConfigFile": "aksedge-config.json"
}
"@
$aksedgeConfig = @"
{
    "SchemaVersion": "1.14",
    "Version": "1.0",
    "DeploymentType": "SingleMachineCluster",
    "Init": {
        "ServiceIPRangeSize": 10
    },
    "Network": {
        "NetworkPlugin": "$networkplugin",
        "InternetDisabled": false
    },
    "User": {
        "AcceptEula": true,
        "AcceptOptionalTelemetry": true
    },
    "Machines": [
        {
            "LinuxNode": {
                "CpuCount": 4,
                "MemoryInMB": 4096,
                "DataSizeInGB": 20
            }
        }
    ]
}
"@

function Import-AksEdgeModule {
    if (Get-Command New-AksEdgeDeployment -ErrorAction SilentlyContinue) { return }
    # Load the modules
    $aksedgeShell = (Get-ChildItem -Path "$workdir" -Filter AksEdgeShell.ps1 -Recurse).FullName
    . $aksedgeShell
}
###
# Main
###
if (-not (Test-Path -Path $installDir)) {
    Write-Host "Creating $installDir..."
    New-Item -Path "$installDir" -ItemType Directory | Out-Null
}

Set-ExecutionPolicy Bypass -Scope Process -Force
# Download the AksEdgeDeploy modules from Azure/AksEdge

$url = "https://github.com/Azure/AKS-Edge/archive/main.zip"
$zipFile = "main-$starttimeString.zip"
$workdir = "$installDir\AKS-Edge-main"
if (-Not [string]::IsNullOrEmpty($Tag)) {
    $url = "https://github.com/Azure/AKS-Edge/archive/refs/tags/$Tag.zip"
    $zipFile = "$Tag.zip"
    $workdir = "$installDir\AKS-Edge-$tag"
}

$loop = $RunToComplete
do {
    $step = Get-ItemPropertyValue -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -ErrorAction SilentlyContinue

    if (!$step) {
        New-Item -Path HKLM:\SOFTWARE\AksEdgeScript | Out-Null
        New-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -PropertyType String -Value "CheckHyperV" | Out-Null
        $step = "CheckHyperV"
    }
    
    $errCode = 1
    switch ($step) {
        "CheckHyperV" {
            $starttime = Get-Date
            $transcriptFile = "$installDir\aksedgedlog-hyperv-$($starttime.ToString("yyMMdd-HHmm")).txt"
            Start-Transcript -Path $transcriptFile
            $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V
            if ($feature.State -ne "Enabled") {
                Write-Host "Hyper-V is disabled" -ForegroundColor Red
                Write-Host "Enabling Hyper-V"
                Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
                if ($aideSession.HostOS.IsServerSKU) {
                    Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-Management-PowerShell'
                    #Install-WindowsFeature -Name RSAT-Hyper-V-Tools -IncludeAllSubFeature
                }
                Write-Host "Reboot machine for enabling Hyper-V" -ForegroundColor Yellow
                $loop = $false
                $errCode = 2
                shutdown /r /t 30
            } else {
                Write-Host "Hyper-V is enabled" -ForegroundColor Green
                Set-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -Value "init"
                New-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name HyperVEnabled -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Stop-Transcript | Out-Null
            break;
        }
        "init" { # download bits
            $starttime = Get-Date
            $transcriptFile = "$installDir\aksedgedlog-init-$($starttime.ToString("yyMMdd-HHmm")).txt"
            Start-Transcript -Path $transcriptFile
            # Download the AksEdgeDeploy modules from Azure/AksEdge
            if (!(Test-Path -Path "$installDir\$zipFile")) {
                try {
                    Invoke-WebRequest -Uri $url -OutFile $installDir\$zipFile
                } catch {
		    Write-Error -Message "Error: Downloading Aide Powershell Modules from $installDir\$zipFile failed" -Category OperationStopped
                    Stop-Transcript | Out-Null
                    exit -1
                }
            }
            Expand-Archive -Path $installDir\$zipFile -DestinationPath "$installDir" -Force
            $aidejson = (Get-ChildItem -Path "$workdir" -Filter aide-userconfig.json -Recurse).FullName
            Set-Content -Path $aidejson -Value $aideuserConfig -Force
	    $aksedgejson = (Get-ChildItem -Path "$workdir" -Filter aksedge-config.json -Recurse).FullName
	    Set-Content -Path $aksedgejson -Value $aksedgeConfig -Force
            Set-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -Value "DownloadDone"
            New-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name DownloadDone -PropertyType DWord -Value 1 | Out-Null
            $endtime = Get-Date
            $duration = ($endtime - $starttime)
            Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
            Stop-Transcript | Out-Null
            break;
        }
        "DownloadDone" {
            $starttime = Get-Date
            $transcriptFile = "$installDir\aksedgedlog-download-$($starttime.ToString("yyMMdd-HHmm")).txt"
            Start-Transcript -Path $transcriptFile
            Import-AksEdgeModule
            if (!(Test-AideMsiInstall -Install)) {
		Write-Error -Message "Error: Test-AideMsiInstall -Install failed" -Category OperationStopped
                Stop-Transcript | Out-Null
                exit -1
            }
            Set-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -Value "InstallDone"
            New-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallDone -PropertyType DWord -Value 1 | Out-Null
            $endtime = Get-Date
            $duration = ($endtime - $starttime)
            Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
            Stop-Transcript | Out-Null
            break;
        }
        "InstallDone" {
            $starttime = Get-Date
            $transcriptFile = "$installDir\aksedgedlog-install-$($starttime.ToString("yyMMdd-HHmm")).txt"
            Start-Transcript -Path $transcriptFile
            Import-AksEdgeModule
	    Write-Host "Running Install-AksEdgeHostFeatures" -ForegroundColor Cyan
            if (!(Install-AksEdgeHostFeatures -Confirm:$false)) { 
		Write-Error -Message "Error: Install-AksEdgeHostFeatures failed" -Category OperationStopped
                Stop-Transcript | Out-Null
                exit -1
	    }
            if (Test-AideDeployment) {
                Write-Host "AKS edge VM is already deployed." -ForegroundColor Yellow
            } else {
                if (!(Test-AideVmSwitch -Create)) { 
		    Write-Error -Message "Error: Switch creation failed" -Category OperationStopped
                    Stop-Transcript | Out-Null
                    exit -1
                } #create switch if specified
                # We are here.. all is good so far. Validate and deploy aksedge
                if (!(Invoke-AideDeployment)) {
		    Write-Error -Message "Error: Invoke-AideDeployment failed" -Category OperationStopped
                    Stop-Transcript | Out-Null
                    exit -1
                }
            }
            Set-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -Value "DeployDone"
            New-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name DeployDone -PropertyType DWord -Value 1 | Out-Null
            $endtime = Get-Date
            $duration = ($endtime - $starttime)
            Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
            Stop-Transcript  | Out-Null
            break;
        }
        "DeployDone" {
            $starttime = Get-Date
            $transcriptFile = "$installDir\aksedgedlog-deploy-$($starttime.ToString("yyMMdd-HHmm")).txt"
            Start-Transcript -Path $transcriptFile
            Import-AksEdgeModule
            $status = Initialize-AideArc
            if ($status){
                Write-Host "Connecting to Azure Arc"
                $retval = Connect-AideArc
                if ($retval) {
                    Write-Host "Azure Arc connections successful."
                } else {
                    Write-Error -Message "Azure Arc connections failed" -Category OperationStopped
                    Stop-Transcript | Out-Null
                    exit -1
                }
            } else { Write-Host "Error: Arc Initialization failed. Skipping Arc Connection" -ForegroundColor Red }
            Set-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name InstallStep -Value "AllDone"
            New-ItemProperty -Path HKLM:\SOFTWARE\AksEdgeScript -Name AllDone -PropertyType DWord -Value 1 | Out-Null
            $endtime = Get-Date
            $duration = ($endtime - $starttime)
            Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
            Stop-Transcript  | Out-Null
            $errCode = 0
            $loop = $false
            break;
        }
        default {
            Write-Host "AKS edge is installed, deployed and connected to Arc"
            $errCode = 0
            $loop = $false
            break;
        }
    }
} While ($loop)

exit $errCode
