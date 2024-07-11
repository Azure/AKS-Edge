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
    [Switch] $UseK8s=$false,
    [string] $Tag,
    # Temporary params for private bits
    [Parameter(Mandatory=$true)]
    [string] $connectedK8sPrivateWhlPath,
    [Parameter(Mandatory=$true)]
    [string] $helmPath
)
#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeQuickStartForAioVersion -Value "1.0.240419.1300" -Option Constant -ErrorAction SilentlyContinue

function Wait-ApiServerReady
{
    $retries = 10
    for (; $retries -gt 0; $retries--)
    {
        $ret = & kubectl get --raw='/readyz'
        if ($ret -eq "ok")
        {
            Write-Host "ApiServerReady!"
            break
        }

        Write-Host "WaitForApiServer - Retry..."
        Start-Sleep -Seconds 1
    }

    if ($retries -eq 0)
    {
        exit -1
    }
}

function Restart-ApiServer
{
param(
    [Parameter(Mandatory=$true)]
    [string] $serviceAccountIssuer,
    [Switch] $useK8s=$false
)

    Write-Host "serviceAccountIssuer = $serviceAccountIssuer"

    if ($useK8s)
    {
        & kubectl delete pod -n kube-system -l component=kube-apiserver
    }
    else
    {
        Invoke-AksEdgeNodeCommand -command "sudo cat /var/.eflow/config/k3s/k3s-config.yml | tee /home/aksedge-user/k3s-config.yml | tee /home/aksedge-user/k3s-config.yml.working > /dev/null"
        Invoke-AksEdgeNodeCommand -command "sudo sed -i 's|service-account-issuer.*|service-account-issuer=$serviceAccountIssuer|' /home/aksedge-user/k3s-config.yml"
        Invoke-AksEdgeNodeCommand -command "sudo cp /home/aksedge-user/k3s-config.yml /var/.eflow/config/k3s/k3s-config.yml"
        Invoke-AksEdgeNodeCommand -command "sudo systemctl restart k3s.service"
    }

    Wait-ApiServerReady
}

function Verify-ConnectedStatus
{
param(
    [Parameter(Mandatory=$true)]
    [string] $resourceGroup,
    [Parameter(Mandatory=$true)]
    [string] $clusterName,
    [Parameter(Mandatory=$true)]
    [string] $subscriptionId
)

    $retries = 60
    for (; $retries -gt 0; $retries--)
    {
        $connectedCluster = az connectedk8s show -g $resourceGroup -n $clusterName --subscription $subscriptionId | ConvertFrom-Json
        if($connectedCluster.ConnectivityStatus -eq "Connected")
        {
            Write-Host "Cluster reached connected status"
            break
        }

        Write-Host "Arc connection status is $($connectedCluster.ConnectivityStatus). Waiting for status to be connected..."
        Start-Sleep -Seconds 10
    }

    if ($retries -eq 0)
    {
        exit -1
    }
}

function New-ConnectedCluster
{
param(
    [Parameter(Mandatory=$true)]
    [string] $resourceGroup,
    [Parameter(Mandatory=$true)]
    [string] $location,
    [Parameter(Mandatory=$true)]
    [string] $clusterName,
    [Parameter(Mandatory=$true)]
    [string] $subscriptionId,
    [Parameter(Mandatory=$true)]
    [string] $connectedK8sPrivateWhlPath,
    [Switch] $useK8s=$false
)

    Write-Host "New-ConnectedCluster"
    $tags = @("SKU=AKSEdgeEssentials")
    $modVersion = (Get-Module AksEdge).Version
    if ($modVersion) { 
        $tags += @("Version=$modVersion")
    }
    $infra = Get-AideInfra
    if ($infra) { 
        $tags += @("Infra=$infra")
    }
    $clusterid = $(kubectl get configmap -n aksedge aksedge -o jsonpath="{.data.clustername}")
    if ($clusterid) { 
        $tags += @("ClusterId=$clusterid")
    }

    az extension remove --name connectedk8s
    az extension add --source $connectedK8sPrivateWhlPath --allow-preview true -y
    $env:HELMREGISTRY="azurearcfork8sdev.azurecr.io/merge/private/azure-arc-k8sagents:0.1.14275-private"
    az connectedk8s connect -g $resourceGroup -n $clusterName --subscription $subscriptionId --tags $tags --disable-auto-upgrade --enable-oidc-issuer

    Verify-ConnectedStatus -clusterName $ClusterName -resourcegroup $ResourceGroupName -subscriptionId $SubscriptionId

    $serviceAccountIssuer = az connectedk8s show-issuer-url
    if ([string]::IsNullOrEmpty($serviceAccountIssuer))
    {
        Write-Host "az connectedk8s show-issuer-url returned empty URL!"
        $jsonString = & kubectl get signingkeys.clusterconfig.azure.com -n azure-arc signingkey -o json
        $jsonObj = $jsonString | ConvertFrom-Json
        $serviceAccountIssuer = $jObj.status.clusterIssuerUrl
        if ([string]::IsNullOrEmpty($serviceAccountIssuer))
        {
            throw "Invalid, empty IssuerUrl!"
        }
    }

    Write-Host "serviceAccountIssuer = $serviceAccountIssuer"
    Restart-ApiServer -serviceAccountIssuer $serviceAccountIssuer -useK8s:$useK8s

    & $helmPath repo add azure-workload-identity https://azure.github.io/azure-workload-identity/charts
    & $helmPath repo update
    & $helmPath install workload-identity-webhook azure-workload-identity/workload-identity-webhook --namespace azure-workload-identity-system --create-namespace --set azureTenantID="$tenantId"
}

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
    "AksEdgeProductUrl": "C:\\Users\\Public\\msi\\K3s.msi",
    "Azure": {
        "SubscriptionName": "",
        "SubscriptionId": "$SubscriptionId",
        "TenantId": "$TenantId",
        "ResourceGroupName": "aksedge-rg",
        "ServicePrincipalName": "aksedge-sp",
        "Location": "$Location",
        "CustomLocationOID":"",
        "EnableWorkloadIdentity": true,
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
                "CpuCount": 8,
                "MemoryInMB": 16384,
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
$fork ="jagadishmurugan"
$branch="users/jagamu/Bugfix-EdgeConfigVersionCompare"
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
    Write-Host -Message "Deployment failed" -Category OperationStopped -ForegroundColor Red
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1
}

Write-Host "Step 3: Connect the cluster to Azure" -ForegroundColor Cyan
# Set the azure subscription
az account set -s $SubscriptionId

# Create resource group
$rgExists = az group show --resource-group $ResourceGroupName | Out-Null
if ($null -eq $rgExists) {
    Write-Host "Creating resource group: $ResourceGroupName" -ForegroundColor Cyan
    az group create --location $Location --resource-group $ResourceGroupName --subscription $SubscriptionId | Out-Null
} 

# Register the required resource providers 
Write-Host "Registering the required resource providers for AIO" -ForegroundColor Cyan
az provider register -n "Microsoft.ExtendedLocation"
az provider register -n "Microsoft.Kubernetes"
az provider register -n "Microsoft.KubernetesConfiguration"
az provider register -n "Microsoft.IoTOperationsOrchestrator"
az provider register -n "Microsoft.IoTOperationsMQ"
az provider register -n "Microsoft.IoTOperationsDataProcessor"
az provider register -n "Microsoft.DeviceRegistry"

# Arc-enable the Kubernetes cluster
Write-Host "Arc enable the kubernetes cluster $ClusterName" -ForegroundColor Cyan

New-ConnectedCluster -clusterName $ClusterName -location $Location -resourcegroup $ResourceGroupName -subscriptionId $SubscriptionId -connectedK8sPrivateWhlPath $connectedK8sPrivateWhlPath -useK8s:$UseK8s

# Enable custom location support on your cluster using az connectedk8s enable-features command
Write-Host "Associate Custom location with $ClusterName cluster"
$objectId = az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv
az connectedk8s enable-features -n $ClusterName -g $ResourceGroupName --custom-locations-oid $objectId --features cluster-connect custom-locations | Out-Null

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
