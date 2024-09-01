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
    [ValidateNotNullOrEmpty()]
    [String] $ResourceGroupName,
    [ValidateNotNullOrEmpty()]
    [String] $ClusterName,
    [String] $CustomLocationOid,
    [Switch] $UseK8s=$false,
    [string] $Tag
)
#Requires -RunAsAdministrator

function Verify-ConnectedStatus
{
param(
    [Parameter(Mandatory=$true)]
    [object] $arcArgs,
    [Parameter(Mandatory=$true)]
    [string] $clusterName
)

    $k8sConnectArgs = @("-g", $arcArgs.ResourceGroupName)
    $k8sConnectArgs += @("-n", $clusterName)
    $k8sConnectArgs += @("--subscription", $arcArgs.SubscriptionId)

    # 15 min timeout to check for Connected status - as recommended by Arc team
    $retries = 90
    $sleepDurationInSeconds = 10
    for (; $retries -gt 0; $retries--)
    {
        $connectedCluster = az connectedk8s show $k8sConnectArgs | ConvertFrom-Json
        if ($connectedCluster.ConnectivityStatus -eq "Connected")
        {
            Write-Host "Cluster reached connected status"
            break
        }

        Write-Host "Arc connection status is $($connectedCluster.ConnectivityStatus). Waiting for status to be connected..."
        Start-Sleep -Seconds $sleepDurationInSeconds
    }

    if ($retries -eq 0)
    {
        throw "Arc Connection timed out!"
    }
}

function New-ConnectedCluster
{
param(
    [Parameter(Mandatory=$true)]
    [object] $arcArgs,
    [Parameter(Mandatory=$true)]
    [string] $clusterName,
    [Switch] $useK8s=$false
)

    Write-Host "New-ConnectedCluster"

    $tags = @("SKU=AKSEdgeEssentials")
    $aksEdgeVersion = (Get-Module -Name AksEdge).Version.ToString()
    if ($aksEdgeVersion) {
        $tags += @("AKSEE Version=$aksEdgeVersion")
    }
    $infra = Get-AideInfra
    if ($infra) { 
        $tags += @("Host Infra=$infra")
    }
    $clusterid = $(kubectl get configmap -n aksedge aksedge -o jsonpath="{.data.clustername}")
    if ($clusterid) { 
        $tags += @("ClusterId=$clusterid")
    }

    $k8sConnectArgs = @("-g", $arcArgs.ResourceGroupName)
    $k8sConnectArgs += @("-n", $clusterName)
    $k8sConnectArgs += @("-l", $arcArgs.Location)
    $k8sConnectArgs += @("--subscription", $arcArgs.SubscriptionId)
    $k8sConnectArgs += @("--tags", $tags)

    Write-Host "Connect cmd args - $k8sConnectArgs"

    $errOut = $($retVal = & {az connectedk8s connect $k8sConnectArgs}) 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Arc Connection failed with error : $errOut"
    }

    Verify-ConnectedStatus -arcArgs $arcArgs -clusterName $ClusterName
}

New-Variable -Name gAksEdgeQuickStartForAioVersion -Value "1.0.240815.1500" -Option Constant -ErrorAction SilentlyContinue

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

# Validate az cli version.
try {
    $azVersion = (az version)[1].Split(":")[1].Split('"')[1]
    if ($azVersion -lt "2.38.0"){
        Write-Host "Installed Azure CLI version $azVersion is older than 2.38.0. Please upgrade Azure CLI and retry." -ForegroundColor Red
        exit -1
    }
}
catch {
    Write-Host "Please install Azure CLI version 2.38.0 or newer and retry." -ForegroundColor Red
    exit -1
}

# Ensure logged into Azure
$azureLogin = az account show
if ( $null -eq $azureLogin){
    Write-Host "Please login to azure via `az login` and retry." -ForegroundColor Red
    exit -1
}

# Ensure `connectedk8s` az cli extension is installed and up to date.
az extension add --upgrade --name connectedk8s -y

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
    "AksEdgeProductUrl": "https://download.microsoft.com/download/9/d/b/9db70435-27fc-4feb-8792-04444d585526/AksEdge-K3s-1.28.3-1.7.639.0.msi",
    "Azure": {
        "SubscriptionName": "",
        "SubscriptionId": "$SubscriptionId",
        "TenantId": "$TenantId",
        "ResourceGroupName": "$ResourceGroupName",
        "ServicePrincipalName": "aksedge-sp",
        "Location": "$Location",
        "CustomLocationOID":"$CustomLocationOid",
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
    "SchemaVersion": "1.13",
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
                "MemoryInMB": 10240,
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
$fork ="Azure"
$branch="main"
$url = "https://github.com/$fork/AKS-Edge/archive/$branch.zip"
$zipFile = "AKS-Edge-$branch.zip"
$workdir = "$installDir\AKS-Edge-$branch"
if (-Not [string]::IsNullOrEmpty($Tag)) {
    $url = "https://github.com/$fork/AKS-Edge/archive/refs/tags/$Tag.zip"
    $zipFile = "$Tag.zip"
    $workdir = "$installDir\AKS-Edge-$tag"
}
Write-Host "Step 1 : Azure/AKS-Edge repo setup" -ForegroundColor Cyan

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
$aideuserConfigJson = $aideuserConfig | ConvertFrom-Json

$aksedgejson = (Get-ChildItem -Path "$workdir" -Filter aksedge-config.json -Recurse).FullName
Set-Content -Path $aksedgejson -Value $aksedgeConfig -Force

$aksedgeShell = (Get-ChildItem -Path "$workdir" -Filter AksEdgeShell.ps1 -Recurse).FullName
. $aksedgeShell

# Download, install and deploy AKS EE 
Write-Host "Step 2: Download, install and deploy AKS Edge Essentials" -ForegroundColor Cyan
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

Write-Host "Step 3: Connect the cluster to Azure" -ForegroundColor Cyan
# Set the azure subscription
$errOut = $($retVal = & {az account set -s $SubscriptionId}) 2>&1
if ($LASTEXITCODE -ne 0)
{
    throw "Error setting Subscription ($SubscriptionId): $errOut"
}

# Create resource group
$errOut = $($rgExists = & {az group show --resource-group $ResourceGroupName}) 2>&1
if ($null -eq $rgExists) {
    Write-Host "Creating resource group: $ResourceGroupName" -ForegroundColor Cyan
    $errOut = $($retVal = & {az group create --location $Location --resource-group $ResourceGroupName --subscription $SubscriptionId}) 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Error creating ResourceGroup ($ResourceGroupName): $errOut"
    }
} 

# Register the required resource providers 
$resourceProviders = 
@(
    "Microsoft.ExtendedLocation",
    "Microsoft.Kubernetes",
    "Microsoft.KubernetesConfiguration"
)
foreach($rp in $resourceProviders)
{
    $errOut = $($obj = & {az provider show -n $rp | ConvertFrom-Json}) 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Error querying provider $rp : $errOut"
    }

    if ($obj.registrationState -eq "Registered")
    {
        continue
    }

    $errOut = $($retVal = & {az provider register -n $rp}) 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Error registering provider $rp : $errOut"
    }
}

# Arc-enable the Kubernetes cluster
Write-Host "Arc enable the kubernetes cluster $ClusterName" -ForegroundColor Cyan
New-ConnectedCluster -clusterName $ClusterName -arcArgs $aideuserConfigJson.Azure -useK8s:$UseK8s

# Enable custom location support on your cluster using az connectedk8s enable-features command
Write-Host "Associate Custom location with $ClusterName cluster"
$objectId = $aideuserConfigJson.Azure.CustomLocationOID
if ([string]::IsNullOrEmpty($objectId))
{
    $customLocationsAppId = "bc313c14-388c-4e7d-a58e-70017303ee3b"
    $errOut = $($objectId = & {az ad sp show --id $customLocationsAppId --query id -o tsv}) 2>&1
    if ($null -eq $objectId)
    {
        throw "Error querying ObjectId for CustomLocationsAppId : $errOut"
    }
}
$errOut = $($retVal = & {az connectedk8s enable-features -n $ClusterName -g $ResourceGroupName --custom-locations-oid $objectId --features cluster-connect custom-locations}) 2>&1
if ($LASTEXITCODE -ne 0)
{
    throw "Error enabling feature CustomLocations : $errOut"
}

Write-Host "Step 4: Prep for AIO workload deployment" -ForegroundColor Cyan
Write-Host "Deploy local path provisioner"
try {
    $localPathProvisionerYaml= (Get-ChildItem -Path "$workdir" -Filter local-path-storage.yaml -Recurse).FullName
    & kubectl apply -f $localPathProvisionerYaml
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
    $fireWallRuleExists = Get-NetFirewallRule -DisplayName "AIO MQTT Broker"  -ErrorAction SilentlyContinue
    if ( $null -eq $fireWallRuleExists ) {
        Write-Host "Add firewall rule for AIO MQTT Broker"
        New-NetFirewallRule -DisplayName "AIO MQTT Broker" -Direction Inbound -Action Allow | Out-Null
    }
    else {
        Write-Host "firewall rule for AIO MQTT Broker exists, skip configuring firewall rule..."
    }   
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
    $portProxyRulExists = netsh interface portproxy show v4tov4 | findstr /C:"1883" | findstr /C:"$connectAddress"
    if ( $null -eq $portProxyRulExists ) {
        Write-Host "Configure port proxy for AIO"
        netsh interface portproxy add v4tov4 listenport=1883 listenaddress=0.0.0.0 connectport=1883 connectaddress=$connectAddress | Out-Null
    }
    else {
        Write-Host "Port proxy rule for AIO exists, skip configuring port proxy..."
    } 
}
catch {
    Write-Host "Error: port proxy update for AIO failed" -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1 
}

Write-Host "Update the iptables rules"
try {
    $iptableRulesExist = Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo iptables-save | grep -- '-m tcp --dport 9110 -j ACCEPT'" -ignoreError
    if ( $null -eq $iptableRulesExist ) {
        Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport 9110 -j ACCEPT"
        Write-Host "Updated runtime iptable rules for node exporter"
        Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo sed -i '/-A OUTPUT -j ACCEPT/i-A INPUT -p tcp -m tcp --dport 9110 -j ACCEPT' /etc/systemd/scripts/ip4save"
        Write-Host "Persisted iptable rules for node exporter"
    }
    else {
        Write-Host "iptable rule exists, skip configuring iptable rules..."
    }

    # Add additional firewall rules
    $dports = @(10124, 8420, 2379, 50051)
    foreach($port in $dports)
    {
        $iptableRulesExist = Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo iptables-save | grep -- '-m tcp --dport $port -j ACCEPT'" -ignoreError
        if ( $null -eq $iptableRulesExist ) {
            Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo iptables -A INPUT -p tcp --dport $port -j ACCEPT"
            Write-Host "Updated runtime iptable rules for port $port"
        }
        else {
            Write-Host "iptable rule exists, skip configuring iptable rule for port $port..."
        }
    }
}
catch {
    Write-Host "Error: iptable rule update failed" -ForegroundColor Red
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
