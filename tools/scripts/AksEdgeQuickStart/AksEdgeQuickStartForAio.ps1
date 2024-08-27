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
    [string] $Tag,
    # Temporary params for private bits
    [Parameter(Mandatory=$true)]
    [string] $privateArtifactsPath
)
#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeQuickStartForAioVersion -Value "1.0.240419.1300" -Option Constant -ErrorAction SilentlyContinue

function Wait-ApiServerReady
{
    $retries = 120
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
        Invoke-AksEdgeNodeCommand -command "sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml | tee /home/aksedge-user/kube-apiserver.yaml | tee /home/aksedge-user/kube-apiserver.yaml.working > /dev/null"
        Invoke-AksEdgeNodeCommand -command "sudo sed -i 's|service-account-issuer.*|service-account-issuer=$serviceAccountIssuer|' /home/aksedge-user/kube-apiserver.yaml"
        Invoke-AksEdgeNodeCommand -command "sudo cp /home/aksedge-user/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml"
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
    [string] $subscriptionId,
    [Switch] $enableWorkloadIdentity=$false
)

    $retries = 90
    for (; $retries -gt 0; $retries--)
    {
        $connectedCluster = az connectedk8s show -g $resourceGroup -n $clusterName --subscription $subscriptionId | ConvertFrom-Json

        if ($enableWorkloadIdentity)
        {
            $agentState = $connectedCluster.arcAgentProfile.agentState
            Write-Host "$retries, AgentState = $agentState"
        }

        $connectivityStatus = $connectedCluster.ConnectivityStatus
        Write-Host "$retries, connectivityStatus = $connectivityStatus"

        if ($connectedCluster.ConnectivityStatus -eq "Connected")
        {
            if ((-Not $enableWorkloadIdentity) -Or ($connectedCluster.arcAgentProfile.agentState -eq "Succeeded"))
            {
                Write-Host "Cluster reached connected status"
                break
            }
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
    [object] $arcArgs,
    [Parameter(Mandatory=$true)]
    [string] $clusterName,
    [Parameter(Mandatory=$true)]
    [string] $privateArtifactsPath,
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

    $errOut = $($retVal = & {az extension remove --name connectedk8s}) 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Error removing extension connecktedk8s : $errOut"
    }

    $connectedK8sWhlFile = (Get-ChildItem $privateArtifactsPath -Filter "connectedk8s*.whl").FullName
    $errOut = $($retVal = & {az extension add --source $connectedK8sWhlFile --allow-preview true -y}) 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Error installing extension connectedk8s ($connectedK8sWhlFile) : $errOut"
    }

    $k8sConnectArgs = @("-g", $arcArgs.ResourceGroupName)
    $k8sConnectArgs += @("-n", $clusterName)
    $k8sConnectArgs += @("-l", $arcArgs.Location)
    $k8sConnectArgs += @("--subscription", $arcArgs.SubscriptionId)
    $k8sConnectArgs += @("--tags", $tags)
    $k8sConnectArgs += @("--disable-auto-upgrade")
    $tag = "0.1.15269-private"
    $env:HELMREGISTRY="azurearcfork8sdev.azurecr.io/merge/private/azure-arc-k8sagents:$tag"
    if ($arcArgs.EnableWorkloadIdentity)
    {
        $k8sConnectArgs += @("--enable-oidc-issuer", "--enable-workload-identity")
    }

    if (-Not [string]::IsNullOrEmpty($arcArgs.GatewayResourceId))
    {
        $k8sConnectArgs += @("--gateway-resource-id", $arcArgs.GatewayResourceId)
    }

    Write-Host "Connect cmd args - $k8sConnectArgs"
    $errOut = $($retVal = & {az connectedk8s connect $k8sConnectArgs}) 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Arc Connection failed with error : $errOut"
    }

    # For debugging
    Write-Host "az connectedk8s out : $retVal"

    Verify-ConnectedStatus -clusterName $ClusterName -resourcegroup $arcArgs.ResourceGroupName -subscriptionId $arcArgs.SubscriptionId -enableWorkloadIdentity:$arcArgs.EnableWorkloadIdentity

    if ($arcArgs.EnableWorkloadIdentity)
    {
        $errOut = $($obj = & {az connectedk8s show -g $arcArgs.ResourceGroupName -n $clusterName  | ConvertFrom-Json}) 2>&1
        if ($null -eq $obj)
        {
            throw "Invalid, empty IssuerUrl!"
        }

        $serviceAccountIssuer = $obj.oidcIssuerProfile.issuerUrl
        if ([string]::IsNullOrEmpty($serviceAccountIssuer))
        {
            throw "Invalid, empty IssuerUrl!"
        }

        Write-Host "serviceAccountIssuer = $serviceAccountIssuer"
        Restart-ApiServer -serviceAccountIssuer $serviceAccountIssuer -useK8s:$useK8s
    }
}

# Specify only AIO supported regions
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name arcLocations -Value @(
    # Adding eastus2euap for PublicPreview - might need to remove later
    "eastus", "eastus2", "northeurope", "westeurope", "westus", "westus2", "westus3", "eastus2euap"
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
$errOut = $($retVal = & {az extension add --upgrade --name connectedk8s -y}) 2>&1
if ($LASTEXITCODE -ne 0)
{
    throw "Error upgrading extension connecktedk8s : $errOut"
}

$installDir = $((Get-Location).Path)
$productName = "AKS Edge Essentials - K3s"
$networkplugin = "flannel"
$msiFile = (Get-ChildItem -Path $privateArtifactsPath -Filter "k3s.msi").FullName
if ($UseK8s) {
    $productName ="AKS Edge Essentials - K8s"
    $networkplugin = "calico"
    $msiFile = (Get-ChildItem -Path $privateArtifactsPath -Filter "k8s.msi").FullName
}
$msiFile = $msiFile.Replace("\","\\")

# Here string for the json content
$aideuserConfig = @"
{
    "SchemaVersion": "1.1",
    "Version": "1.0",
    "AksEdgeProduct": "$productName",
    "AksEdgeProductUrl": "$msiFile",
    "Azure": {
        "SubscriptionName": "",
        "SubscriptionId": "$SubscriptionId",
        "TenantId": "$TenantId",
        "ResourceGroupName": "$ResourceGroupName",
        "ServicePrincipalName": "aksedge-sp",
        "Location": "$Location",
        "CustomLocationOID":"$CustomLocationOid",
        "EnableWorkloadIdentity": true,
        "EnableKeyManagement": true,
        "GatewayResourceId": "",
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
    Write-Host -Message "Deployment failed" -Category OperationStopped -ForegroundColor Red
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
Write-Host "Registering the required resource providers for AIO" -ForegroundColor Cyan
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

New-ConnectedCluster -clusterName $ClusterName -arcArgs $aideuserConfigJson.Azure -privateArtifactsPath $privateArtifactsPath -useK8s:$UseK8s

# Enable custom location support on your cluster using az connectedk8s enable-features command
$objectId = $aideuserConfigJson.Azure.CustomLocationOID
if ([string]::IsNullOrEmpty($objectId))
{
    Write-Host "Associate Custom location with $ClusterName cluster"
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
