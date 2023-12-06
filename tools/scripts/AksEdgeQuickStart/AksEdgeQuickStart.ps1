<#
  QuickStart script for setting up Azure for AKS Edge Essentials and deploying the same on the Windows device
#>
param(
    [Parameter(Mandatory)]
    [String] $AideUserConfigFilePath,
    [Parameter(Mandatory)]
    [string] $AksEdgeConfigFilePath
)
#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeQuickStartVersion -Value "1.0.231206.1130" -Option Constant -ErrorAction SilentlyContinue

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
#Check provided filepaths, and retrieve respective json string
if (!(Test-Path -Path "$AideUserConfigFilePath" -PathType Leaf))
{
    $msg = "Aide-user config file '$AideUserConfigFilePath' could not be found or accessed"
    Write-Host $msg -ForegroundColor Red
    exit -1
}
try
{
    $aideuserConfig = Get-Content "$AideUserConfigFilePath"
}
catch
{
    $err = $_.Exception.Message.ToString()
    $msg = "Failed to read Aide-user config file contents. Error was: $err"
    Write-Host $msg -ForegroundColor Red
    exit -1
}

if (!(Test-Path -Path "$AksEdgeConfigFilePath" -PathType Leaf))
{
    $msg = "Aks-Edge config file '$AksEdgeConfigFilePath' could not be found or accessed"
    Write-Host $msg -ForegroundColor Red
    exit -1
}
try
{
    $aksedgeConfig = Get-Content "$AksEdgeConfigFilePath"
}
catch
{
    $err = $_.Exception.Message.ToString()
    $msg = "Failed to read Aks-Edge config file contents. Error was: $err"
    Write-Host $msg -ForegroundColor Red
    exit -1
}

#Validate inputs
try
{
    $aideConfigObj = ($aideuserConfig| ConvertFrom-Json)
}
catch
{
    $err = $_.Exception.Message.ToString()
    $msg = "Failed to parse aide config string. Error was: $err"
    Write-Host $msg -ForegroundColor Red
    exit -1
}
$skipAzureArc = $false
if ([string]::IsNullOrEmpty($aideConfigObj.Azure.SubscriptionId)) {
    Write-Host "Warning: Require SubscriptionId for Azure Arc" -ForegroundColor Cyan
    $skipAzureArc = $true
}
if ([string]::IsNullOrEmpty($aideConfigObj.Azure.TenantId)) {
    Write-Host "Warning: Require TenantId for Azure Arc" -ForegroundColor Cyan
    $skipAzureArc = $true
}
if ([string]::IsNullOrEmpty($aideConfigObj.Azure.Location)) {
    Write-Host "Warning: Require Location for Azure Arc" -ForegroundColor Cyan
    $skipAzureArc = $true
} elseif ($arcLocations -inotcontains $aideConfigObj.Azure.Location) {
    Write-Host "Error: Location $($aideConfigObj.Azure.Location) is not supported for Azure Arc" -ForegroundColor Red
    Write-Host "Supported Locations : $arcLocations"
    exit -1
}
if ($skipAzureArc) {
    Write-Host "Azure setup and Arc connection will be skipped as required details are not available" -ForegroundColor Yellow
}

#Verify that the right network plugin parameter has been specified
try
{
    $aksConfigObj = ($aksedgeConfig| ConvertFrom-Json)
}
catch
{
    $err = $_.Exception.Message.ToString()
    $msg = "Failed to parse aks edge config string. Error was: $err"
    Write-Host $msg -ForegroundColor Red
    exit -1
}
if(!($UseK8s) -and ($aksConfigObj.Network.NetworkPlugin -ne "flannel"))
{
    Write-Host "Error: Network plugin supported for k3s is 'flannel'" -ForegroundColor Red
    exit -1
}
elseif($UseK8s -and ($aksConfigObj.Network.NetworkPlugin -ne "calico"))
{
    Write-Host "Error: Network plugin supported for k8s is 'calico'" -ForegroundColor Red
    exit -1
}

$installDir = $((Get-Location).Path)
$productName = "AKS Edge Essentials - K3s"
if ($UseK8s) {
    $productName ="AKS Edge Essentials - K8s"
}

$aideConfigObj.AksEdgeProduct = $productName
$aideuserConfig = $aideConfigObj | ConvertTo-Json -Compress

###
# Main
###
if (-not (Test-Path -Path $installDir)) {
    Write-Host "Creating $installDir..."
    New-Item -Path "$installDir" -ItemType Directory | Out-Null
}

$starttime = Get-Date
$starttimeString = $($starttime.ToString("yyMMdd-HHmm"))
$transcriptFile = "$installDir\aksedgedlog-$starttimeString.txt"

Start-Transcript -Path $transcriptFile

Set-ExecutionPolicy Bypass -Scope Process -Force
# Download the AksEdgeDeploy modules from Azure/AksEdge
$fork ="Azure"
$branch="main"
$url = "https://github.com/$fork/AKS-Edge/archive/$branch.zip"
$zipFile = "AKS-Edge-$branch.zip"
$workdir = "$installDir\AKS-Edge-$branch"
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

# Setup Azure 
Write-Host "Step 2: Setup Azure Cloud for Arc connections"
$azcfg = (Get-AideUserConfig).Azure
if ($azcfg.Auth.Password) {
   Write-Host "Password found in json spec. Skipping AksEdgeAzureSetup." -ForegroundColor Cyan
   $skipAzureArc = $false
} elseif ($skipAzureArc) {
    Write-Host ">> skipping step 2" -ForegroundColor Yellow
} else {
    $aksedgeazuresetup = (Get-ChildItem -Path "$workdir" -Filter AksEdgeAzureSetup.ps1 -Recurse).FullName
    & $aksedgeazuresetup -jsonFile $aidejson -spContributorRole -spCredReset

    if ($LastExitCode -eq -1) {
        Write-Host "Error in configuring Azure Cloud for Arc connection" -ForegroundColor Red
        Stop-Transcript | Out-Null
        Pop-Location
        exit -1
    }
}

# Download, install and deploy AKS EE 
Write-Host "Step 3: Download, install and deploy AKS Edge Essentials"
# invoke the workflow, the json file already updated above.
$retval = Start-AideWorkflow -jsonFile $aidejson
if ($retval) {
    Write-Host "Deployment Successful. "
} else {
    Write-Host -Message "Deployment failed" -Category OperationStopped -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1
}

Write-Host "Step 4: Connect to Arc"
if ($skipAzureArc) {
    Write-Host ">> skipping step 4" -ForegroundColor Yellow
} else {
    Write-Host "Installing required Az Powershell modules"
    $arcstatus = Initialize-AideArc
    if ($arcstatus) {
        Write-Host ">Connecting to Azure Arc"
        if (Connect-AideArc) {
            Write-Host "Azure Arc connections successful."
        } else {
            Write-Host "Error: Azure Arc connections failed" -ForegroundColor Red
            Stop-Transcript | Out-Null
            Pop-Location
            exit -1
        }
    } else { Write-Host "Error: Arc Initialization failed. Skipping Arc Connection" -ForegroundColor Red }
}

$endtime = Get-Date
$duration = ($endtime - $starttime)
Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
Stop-Transcript | Out-Null
Pop-Location
exit 0
