<#
  Sample script to deploy AksEdge via Intune
#>
param(
    [Switch] $IncludeWindows,
    [Switch] $UseK8s
)

#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeRemoteDeployVersion -Value "1.0.221010.1200" -Option Constant -ErrorAction SilentlyContinue
$installDir = "C:\AksEdgeScript"
$msiName = "AksEdge-K3s.msi"
if ($UseK8s) {
    $msiName ="AksEdge-K8s.msi"
}

$msifile = "$installDir\$msiName"
# Here string for the json content
$jsonContent = @"
{
    "SchemaVersion": "1.1",
    "Version": "1.0",
    "AksEdgeProduct": "Azure Kubernetes Service Edge Essentials (Public Preview)",
    "AksEdgeProductUrl": "$($msifile.Replace("\","\\"))",
    "DeployOptions": {
        "SingleMachineCluster": true,
        "NodeType": "Linux",
        "NetworkPlugin": "flannel",
        "Headless": true
    },
    "EndUser": {
        "AcceptEula": true
    },
    "LinuxVm": {
        "CpuCount": 4,
        "MemoryInMB": 4096,
        "DataSizeinGB": 20
    },
    "Azure": {
        "SubscriptionName": "Visual Studio Enterprise",
        "SubscriptionId": "",
        "TenantId": "",
        "ResourceGroupName": "aksedgepreview-rg",
        "ServicePrincipalName": "aksedge-sp",
        "Location": "EastUS",
        "Auth":{
            "ServicePrincipalId":"",
            "Password":""
        }
    }
}
"@
$blobJson = @"
{
    "Storage": {
        "ConnectionString": "",
        "ContainerName": "",
        "BlobNames":["$msiName","AksEdge-preview.zip"],
        "WinBlobs":["AksEdgeWindows-v1.7z.001","AksEdgeWindows-v1.7z.002","AksEdgeWindows-v1.7z.003","AksEdgeWindows-v1.exe"]
    }
}
"@

function Install-AzCli {
    #Check if Az CLI is installed. If not install it.
    $AzCommand = Get-Command -Name az -ErrorAction SilentlyContinue
    if (!$AzCommand) {
        Write-Host "> Installing AzCLI..."
        Push-Location $env:TEMP
        $progressPreference = 'silentlyContinue'
        Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
        $progressPreference = 'Continue'
        Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /passive'
        Remove-Item .\AzureCLI.msi
        Pop-Location
        #Refresh the env variables to include path from installed MSI
        $Env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")
        az config set core.disable_confirm_prompt=yes
        az config set core.only_show_errors=yes
        #az config set auto-upgrade.enable=yes
    }
    Write-Host "> Azure CLI installed" -ForegroundColor Green
    $extlist = (az extension list --query [].name | ConvertFrom-Json -ErrorAction SilentlyContinue)
    $reqExts = @("connectedmachine", "connectedk8s", "customlocation")
    foreach ($ext in $reqExts) {
        if ($extlist -and $extlist.Contains($ext)) {
            Write-Host "> az extension $ext installed" -ForegroundColor Green
        } else {
            Write-Host "Installing az extension $ext"
            az extension add --name $ext
        }
    }
}

function DownloadFromBlobStorage {
    param (
        [string]
        $downloadPath = "$(Get-Location)"
    )
    if (-not (Test-Path "$downloadPath")) {
        Write-Host "Creating $downloadPath..."
        New-Item -Path "$downloadPath\Scripts" -ItemType Directory
    }
    Push-Location "$downloadPath"
    $store = $Script:blobJson | ConvertFrom-Json
    Write-Host "Download from Azure blob storage..."
    $files = $store.Storage.BlobNames
    if ($IncludeWindows) { $files += $store.Storage.WinBlobs }
    foreach ($file in $files) {
        if (-not (Test-Path -Path ".\$file")) {
            Write-Host "Downloading $file" -NoNewline
            $res = az storage blob download --connection-string $($store.Storage.ConnectionString) --container-name $($store.Storage.ContainerName) --file $file --name $file
            if ($res) { Write-Host " success.." }
            if (($file.contains('.zip')) -and (Test-Path -Path ".\$file")) {
                Write-Host "Expanding $file"
                Expand-Archive -Path "$file" -DestinationPath "$downloadPath\Scripts" -Force
            }
        } else { Write-Host "$file found. Skipping download."}
    }
    Pop-Location
}

function UploadToBlobStorage {
    param (
        [System.Array]
        $filesToUpload = $null
    )
    if (!$filesToUpload) { Write-Host "Nothing to upload"; return $false }
    $store = $Script:blobJson | ConvertFrom-Json
    foreach ($file in $filesToUpload){
        if (Test-Path "$file" -PathType Leaf) {
            Write-Host "Uploading $file..."
            $res = az storage blob upload --connection-string $store.Storage.ConnectionString --container-name $store.Storage.ContainerName --file $file
            if ($res) { Write-Host "Upload success.."}
        }
    }
}

###
# Main
###

#Download the AutoDeploy script
$starttime = Get-Date
$transcriptFile = "$PSScriptRoot\aksedgedlog-$($starttime.ToString("yyMMdd-HHmm")).txt"
Start-Transcript -Path $transcriptFile

Set-ExecutionPolicy Bypass -Scope Process -Force
# Install Cli so that download from blob storage can be done
Install-AzCli
# Download the files from the azure blob storage
DownloadFromBlobStorage $installDir
# Load the modules
if (!(Test-Path -Path "$installDir\Scripts")) {
    Write-Host "Error: Aide Powershell Modules not found" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit -1
}
$modulePath = (Get-ChildItem -Path "$installDir\Scripts" -Filter AksEdgeDeploy -Recurse).FullName | Split-Path -Parent
if (!(($env:PSModulePath).Contains($modulePath))) {
    $env:PSModulePath = "$modulePath;$env:PSModulePath"
}

Write-Host "Loading AksEdgeDeploy module.." -ForegroundColor Cyan
Import-Module AksEdgeDeploy.psd1 -Force
$aideVersion = (Get-Module -Name AksEdgeDeploy).Version.ToString()
Write-Host "AksEdgeRemoteDeploy version  `t: $gAksEdgeRemoteDeployVersion"
Write-Host "AksEdgeDeploy       version  `t: $aideVersion"

# invoke the workflow
$retval = Start-AideWorkflow -jsonString $jsonContent
# report error via Write-Error for Intune to show proper status
if ($retval) {
    Write-Host "Deployment Successful. "
} else {
    Write-Error -Message "Deployment failed" -Category OperationStopped
    Stop-Transcript | Out-Null
    exit -1
}

$azConfig = (Get-AideUserConfig).Azure
if ($azConfig.Auth.ServicePrincipalId -and $azConfig.Auth.Password -and $azConfig.TenantId){
    #we have ServicePrincipalId, Password and TenantId
    $retval = Enter-ArcIotSession
    if (!$retval) {
        Write-Error -Message "Azure login failed." -Category OperationStopped
        Stop-Transcript | Out-Null
        exit -1
    }
    # Arc for Servers
    Write-Host "Connecting to Azure Arc for Servers"
    $retval = Connect-ArcIotCmAgent
    Write-Host "Connecting to Azure Arc for Kubernetes"
    $retval = Connect-ArcIotK8s
    Exit-ArcIotSession
    if ($retval) {
        Write-Host "Arc connection successful. "
    } else {
        Write-Error -Message "Arc connection failed" -Category OperationStopped
        Stop-Transcript | Out-Null
        exit -1
    }
} else { Write-Host "No Auth info available. Skipping Arc Connection" }
# Arc for Kubernetes
$endtime = Get-Date
$duration = ($endtime - $starttime)
Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
Stop-Transcript | Out-Null
exit 0
