<#
  QuickStart script for setting up Azure for AKS Edge Essentials and deploying the same on the Windows device
#>
param(
    [ValidateNotNullOrEmpty()]
    [String] $SubscriptionId,
    [ValidateNotNullOrEmpty()]
    [String] $TenantId,
    [ValidateNotNullOrEmpty()]
    [String] $Location,
    [Switch] $UseK8s,
    [string] $Tag
)
#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeQuickStartForAioVersion -Value "1.0.231016.1400" -Option Constant -ErrorAction SilentlyContinue

# Specify only AIO supported regions
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name arcLocations -Value @(
    "eastus", "eastus2", "northeurope", "westeurope", "westus", "westus2", "westus3"
)

if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}
#Validate inputs
if ($arcLocations -inotcontains $Location) {
    Write-Host "Error: Location $Location is not supported for Azure Arc" -ForegroundColor Red
    Write-Host "Supported Locations : $arcLocations"
    exit -1
}

$installDir = $((Get-Location).Path)
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
        "SubscriptionId": "$SubscriptionId",
        "TenantId": "$TenantId",
        "ResourceGroupName": "angop-test-aksedge-rg",
        "ServicePrincipalName": "angop-test-aksedge-sp",
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
                "CpuCount": 8,
                "MemoryInMB": 8192,
                "DataSizeInGB": 40,
                "LogSizeInGB": 4
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
$transcriptFile = "$installDir\aksedgedlog-$starttimeString.txt"

Start-Transcript -Path $transcriptFile

Set-ExecutionPolicy Bypass -Scope Process -Force
# Download the AksEdgeDeploy modules from Azure/AksEdge
$fork ="angop95"
$branch="users/angop/testAideScript"
$url = "https://github.com/$fork/AKS-Edge/archive/$branch.zip"
$zipFile = "AKS-Edge-$branch.zip"
$workdir = "$installDir\AKS-Edge-$branch"
if (-Not [string]::IsNullOrEmpty($Tag)) {
    $url = "https://github.com/$fork/AKS-Edge/archive/refs/tags/$Tag.zip"
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
} 
else { 
    Write-Host "Error: Arc Initialization failed." -ForegroundColor Red 
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1
}

Write-Host "Step 5: Prep for AIO workload deployment"
Write-Host "Deploy local path provisioner"
try {
    & kubectl apply -f 'https://raw.githubusercontent.com/Azure/AKS-Edge/main/samples/storage/local-path-provisioner/local-path-storage.yaml' 
    Write-Host "Successfully deployment the local path provisioner"
}
catch {
    Write-Host "Error: local path provisioner deployment failed" -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1 
}

Write-Host "Configuring firewall specific to AIO"
try {
    New-NetFirewallRule -DisplayName "AIO MQTT Broker" -Direction Inbound -Action Allow | Out-Null
    Write-Host "Successfully added firewall rule for AIO MQTT Broker"
}
catch {
    Write-Host "Error: Firewall rule addition for AIO MQTT broker failed" -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1 
}

Write-Host "Configuring port proxy for AIO"
try {
    $deploymentInfo = Get-AksEdgeDeploymentInfo
    # Get the service ip address start to determine the connect address
    $connectAddress = $deploymentInfo.LinuxNodeConfig.ServiceIpRange.split("-")[0]
    netsh interface portproxy add v4tov4 listenport=1883 listenaddress=0.0.0.0 connectport=1883 connectaddress=$connectAddress | Out-Null
    Write-Host "Successfully added port proxy for AIO"
}
catch {
    Write-Host "Error: port proxy update for AIO failed" -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1 
}

Write-Host "Update the iptables rules"
try {
    Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 9110 -j ACCEPT"
    Write-Host "Updated runtime iptable rules for node exporter"
}
catch {
    Write-Host "Error: runtime iptable rules update failed" -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1 
}

try {
    Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo sed -i '/-A OUTPUT -j ACCEPT/i-A INPUT -p tcp -m tcp --dport 9110 -j ACCEPT' /etc/systemd/scripts/ip4save"
    Write-Host "Persisted iptable rules for node exporter"
}
catch {
    Write-Host "Error: failed to persist iptable rules for node exporter" -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1 
}

$endtime = Get-Date
$duration = ($endtime - $starttime)
Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
Stop-Transcript | Out-Null
Pop-Location
exit 0
