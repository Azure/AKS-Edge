<#
    .SYNOPSIS
        Sample script to deploy AksEdge via Arc for Servers

    .DESCRIPTION
        PowerShell script to deply AKS Edge Essentials using Arc for Server remote PowerShell script extension.
        For more information, check https://learn.microsoft.com/azure/azure-arc/servers/manage-vm-extensions-powershell    

    .PARAMETER UseK8s
        Use K8s distribution if present - If not, use default K3S
    
    .PARAMETER Tag
        Release Tag of AKS Edge Essentials release artifacts
        For more information, check https://github.com/Azure/AKS-Edge/releases
    
    .PARAMETER GetManagedServiceToken
        Get the Managed Service Token of the AKS Edge Essentials cluster and print it out in the logs.
#>
param(
    [Switch] $UseK8s,
    [string] $Tag,
    [Switch] $GetManagedServiceToken
)
#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeRemoteDeployVersion -Value "1.0.230628.1000" -Option Constant -ErrorAction SilentlyContinue
if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}
Push-Location $PSScriptRoot
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
    "SchemaVersion": "1.1",
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
        }
    },
    "AksEdgeConfigFile": "aksedge-config.json"
}
"@
$aksedgeConfig = @"
{
    "SchemaVersion": "1.9",
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

###
# Main
###
if (-not (Test-Path -Path $installDir)) {
    Write-Host "Creating $installDir..."
    New-Item -Path "$installDir" -ItemType Directory | Out-Null
}

$starttime = Get-Date
$starttimeString = $($starttime.ToString("yyMMdd-HHmm"))
$transcriptFile = "$PSScriptRoot\aksedgedlog-$starttimeString.txt"
Start-Transcript -Path $transcriptFile

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
Write-Host "Step 1 : Azure/AKS-Edge repo setup"

if (!(Test-Path -Path "$installDir\$zipFile")) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $installDir\$zipFile
    } catch {
        Write-Host "Error: Downloading Aide Powershell Modules failed" -ForegroundColor Red
        Stop-Transcript | Out-Null
        Pop-Location
        exit -1
    }
}
if (!(Test-Path -Path "$workdir")) {
    Expand-Archive -Path $installDir\$zipFile -DestinationPath "$installDir" -Force
}

$aidejson = (Get-ChildItem -Path "$workdir" -Filter aide-userconfig.json -Recurse).FullName
Set-Content -Path $aidejson -Value $aideuserConfig -Force
$aksedgejson = (Get-ChildItem -Path "$workdir" -Filter aksedge-config.json -Recurse).FullName
Set-Content -Path $aksedgejson -Value $aksedgeConfig -Force

$aksedgeShell = (Get-ChildItem -Path "$workdir" -Filter AksEdgeShell.ps1 -Recurse).FullName
. $aksedgeShell

# Download, install and deploy AKS EE 
Write-Host "Step 2: Download, install and deploy AKS Edge Essentials"
# invoke the workflow, the json file already updated above.
$retval = Start-AideWorkflow -jsonFile $aidejson
# report error via Write-Error for Intune to show proper status
if ($retval) {
    Write-Host "Deployment Successful. "
} else {
    Write-Error -Message "Deployment failed" -Category OperationStopped
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1
}

Write-Host "Step 3: Connect to Arc"
$status = Initialize-AideArc
if ($status){
    Write-Host "Connecting to Azure Arc"
    if (Connect-AideArc) {
        Write-Host "Azure Arc connections successful."
    } else {
        Write-Error -Message "Azure Arc connections failed" -Category OperationStopped
        Stop-Transcript | Out-Null
        Pop-Location
        exit -1
    }
} else { Write-Host "Error: Arc Initialization failed. Skipping Arc Connection" -ForegroundColor Red }

if ($GetManagedServiceToken.IsPresent)
{
    Write-Host "Step 4: Get AKS Edge managed service token"
    Get-AksEdgeManagedServiceToken
}

$endtime = Get-Date
$duration = ($endtime - $starttime)
Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
Stop-Transcript | Out-Null
Pop-Location
exit 0
