<#
  QuickStart script for setting up Azure for AKS Edge Essentials and deploying the same on the Windows device
#>
param(
    [String] $SubscriptionId,
    [String] $TenantId,
    [String] $Location,
    [Switch] $UseK8s
)
#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeQuickStartVersion -Value "1.0.230217.1200" -Option Constant -ErrorAction SilentlyContinue

New-Variable -Option Constant -ErrorAction SilentlyContinue -Name arcLocations -Value @(
    "westeurope", "eastus", "westcentralus", "southcentralus", "southeastasia", "uksouth",
    "eastus2", "westus2", "australiaeast", "northeurope", "francecentral", "centralus",
    "westus", "northcentralus", "koreacentral", "japaneast", "eastasia", "westus3",
    "canadacentral", "eastus2euap"
)

if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}
#Validate inputs
$skipAzureArc = $false
if ([string]::IsNullOrEmpty($SubscriptionId)) {
    Write-Host "Warning: Require SubscriptionId for Azure Arc" -ForegroundColor Cyan
    $skipAzureArc = $true
}
if ([string]::IsNullOrEmpty($TenantId)) {
    Write-Host "Warning: Require TenantId for Azure Arc" -ForegroundColor Cyan
    $skipAzureArc = $true
}
if ([string]::IsNullOrEmpty($Location)) {
    Write-Host "Warning: Require Location for Azure Arc" -ForegroundColor Cyan
    $skipAzureArc = $true
} elseif ($arcLocations -inotcontains $Location) {
    Write-Host "Error: Location $Location is not supported for Azure Arc" -ForegroundColor Red
    Write-Host "Supported Locations : $arcLocations"
    exit -1
}

if ($skipAzureArc) {
    Write-Host "Azure setup and Arc connection will be skipped as required details are not available" -ForegroundColor Yellow
}

$installDir = $((Get-Location).Path)
$productName = "AKS Edge Essentials - K3s (Public Preview)"
$tag = "1.0.358.0"
$networkplugin = "flannel"
if ($UseK8s) {
    $productName ="AKS Edge Essentials - K8s (Public Preview)"
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
        "SubscriptionId": "$SubscriptionId",
        "TenantId": "$TenantId",
        "ResourceGroupName": "aksedge-rg",
        "ServicePrincipalName": "aksedge-sp",
        "Location": "$Location",
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
    "SchemaVersion": "1.5",
    "Version": "1.0",
    "DeploymentType": "SingleMachineCluster",
    "Init": {
        "ServiceIPRangeSize": 0
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
Push-Location $installDir

$starttime = Get-Date
$starttimeString = $($starttime.ToString("yyMMdd-HHmm"))
$transcriptFile = "$installDir\aksedgedlog-$starttimeString.txt"

Start-Transcript -Path $transcriptFile

Set-ExecutionPolicy Bypass -Scope Process -Force
# Download the AksEdgeDeploy modules from Azure/AksEdge
Write-Host "Step 1 : Azure/AKS-Edge repo setup"
$url = "https://github.com/Azure/AKS-Edge/archive/refs/tags/$tag.zip"
$zipFile = "$tag.zip"

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
if (!(Test-Path -Path "$installDir\AKS-Edge-$tag")) {
    Expand-Archive -Path $installDir\$zipFile -DestinationPath "$installDir" -Force
}

$aidejson = (Get-ChildItem -Path "$installDir\AKS-Edge-$tag" -Filter aide-userconfig.json -Recurse).FullName
Set-Content -Path $aidejson -Value $aideuserConfig -Force
$aksedgejson = (Get-ChildItem -Path "$installDir\AKS-Edge-$tag" -Filter aksedge-config.json -Recurse).FullName
Set-Content -Path $aksedgejson -Value $aksedgeConfig -Force


$aksedgeShell = (Get-ChildItem -Path "$installDir\AKS-Edge-$tag" -Filter AksEdgeShell.ps1 -Recurse).FullName
. $aksedgeShell

# Install Azure CLI
Write-Host "Step 2 : Install Azure CLI for Azure setup"
if ($skipAzureArc) {
    Write-Host ">> skipping step 2" -ForegroundColor Yellow
} else {
    Install-AideAzCli
}

# Setup Azure 
Write-Host "Step 3: Setup Azure Cloud for Arc connections"
if ($skipAzureArc) {
    Write-Host ">> skipping step 3" -ForegroundColor Yellow
} else {
    $aksedgeazuresetup = (Get-ChildItem -Path "$installDir\AKS-Edge-$tag" -Filter AksEdgeAzureSetup.ps1 -Recurse).FullName
    & $aksedgeazuresetup -jsonFile $aidejson -spContributorRole -spCredReset

    if ($_ -eq -1) {
        Write-Host "Error in configuring Azure Cloud for Arc connection"
        Stop-Transcript | Out-Null
        Pop-Location
        exit -1
    }
}

# Download, install and deploy AKS EE 
Write-Host "Step 4: Download, install and deploy AKS Edge Essentials"
# invoke the workflow, the json file already updated above.
$retval = Start-AideWorkflow -jsonFile $aidejson
if ($retval) {
    Write-Host "Deployment Successful. "
} else {
    Write-Error -Message "Deployment failed" -Category OperationStopped
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1
}

Write-Host "Step 5: Connect to Arc"
if ($skipAzureArc) {
    Write-Host ">> skipping step 5" -ForegroundColor Yellow
} else {
    $azConfig = (Get-AideUserConfig).Azure
    if ($azConfig.Auth.ServicePrincipalId -and $azConfig.Auth.Password -and $azConfig.TenantId){
        #we have ServicePrincipalId, Password and TenantId
        Write-Host ">Login using az cli"
        $retval = Enter-AideArcSession
        if (!$retval) {
            Write-Error -Message "Azure login failed." -Category OperationStopped
            Stop-Transcript | Out-Null
            Pop-Location
            exit -1
        }
        Write-Host ">Connecting to Azure Arc"
        $retval = Connect-AideArc
        Exit-AideArcSession
        if ($retval) {
            Write-Host "Arc connection successful. "
        } else {
            Write-Error -Message "Arc connection failed" -Category OperationStopped
            Stop-Transcript | Out-Null
            Pop-Location
            exit -1
        }
    } else { Write-Host "No Auth info available. Skipping Arc Connection" }
}

$endtime = Get-Date
$duration = ($endtime - $starttime)
Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
Stop-Transcript | Out-Null
Pop-Location
exit 0
