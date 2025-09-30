<#
  QuickStart script for setting up Azure for AKS Edge Essentials and deploying the same on the Windows device
#>
param(
    [Parameter(Mandatory)]
    [String] $aideUserConfigfile,
    [Parameter(Mandatory)]
    [String] $aksedgeConfigFile,
    [string] $Tag
)
#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeQuickStartForAioVersion -Value "1.0.250313.1500" -Option Constant -ErrorAction SilentlyContinue

# Specify only AIO supported regions
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name arcLocations -Value @(
    "eastus", "eastus2", "northeurope", "westeurope", "westus", "westus2", "westus3", "germanywestcentral"
)

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
        throw "waiting for API server timed out!"
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
        throw "waiting for cluster connected status timed out!"
    }
}

function New-ConnectedCluster
{
param(
    [Parameter(Mandatory=$true)]
    [object] $arcArgs,
    [Parameter(Mandatory=$true)]
    [string] $clusterName,
    [object] $proxyArgs,
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
    $k8sConnectArgs += @("--disable-auto-upgrade")
    if ($null -ne $proxyArgs)
    {
        if (-Not [string]::IsNullOrEmpty($proxyArgs.Http))
        {
            $k8sConnectArgs += @("--proxy-http", $proxyArgs.Http)
        }
        if (-Not [string]::IsNullOrEmpty($proxyArgs.Https))
        {
            $k8sConnectArgs += @("--proxy-https", $proxyArgs.Https)
        }
        if (-Not [string]::IsNullOrEmpty($proxyArgs.No))
        {
            $k8sConnectArgs += @("--proxy-skip-range", $proxyArgs.No)
        }
    }

    if ($arcArgs.EnableWorkloadIdentity)
    {
        $k8sConnectArgs += @("--enable-oidc-issuer", "--enable-workload-identity")
    }

    if (-Not [string]::IsNullOrEmpty($arcArgs.GatewayResourceId))
    {
        $k8sConnectArgs += @("--gateway-resource-id", $arcArgs.GatewayResourceId)
    }

    # Use kubectl.exe from AKSEE deployment
    $env:KUBECTL_CLIENT_PATH = "$env:ProgramFiles\AksEdge\kubectl\kubectl.exe"

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

        Write-Host "Restart ARC agents."
        & kubectl -n azure-arc rollout restart deployment
    }
}

#Validate inputs
##
function ValidateConfigFile {
param(
    [ValidateNotNullOrEmpty()]
    [string] $filePath
)

    if (!(Test-Path -Path $filePath -PathType Leaf))
    {
        throw "Config file '$filePath' not found!"
    }

    try
    {
        $configJson = Get-Content "$filePath"
    }
    catch
    {
        $err = $_.Exception.Message.ToString()
        throw "Failed to read $filePath content with error $err"
    }

    try
    {
        $configObj = ($configJson | ConvertFrom-Json)
    }
    catch
    {
        $err = $_.Exception.Message.ToString()
        throw "Failed to parse $filePath with error $err"
    }

    return $configObj
}

function ValidateConfig {
param(
    [object] $aideUserConfig,
    [object] $aksedgeConfig
)

    #Validate inputs
    $supportedProductTypes = @("AKS Edge Essentials - K3s")
    if ([string]::IsNullOrEmpty($aideuserConfig.AksEdgeProduct) -or $supportedProductTypes -notcontains $aideuserConfig.AksEdgeProduct)
    {
        throw "AideUserConfig.AksEdgeProduct $($aideuserConfig.AksEdgeProduct) is invalid! Supported values: $supportedProductTypes." 
    }
    if ([string]::IsNullOrEmpty($aideuserConfig.Azure.SubscriptionId)) {
        throw "Require SubscriptionId for Azure Arc"
    }
    if ([string]::IsNullOrEmpty($aideuserConfig.Azure.TenantId)) {
        throw "Require TenantId for Azure Arc" 
    }
    if ([string]::IsNullOrEmpty($aideuserConfig.Azure.Location)) {
        throw "Require Location for Azure Arc"
    } elseif ($arcLocations -inotcontains $aideuserConfig.Azure.Location) {
        Write-Host "Supported Locations : $arcLocations"
        throw "Location $($aideuserConfig.Azure.Location) is not supported for Azure Arc"
    }
    if ([string]::IsNullOrEmpty($aksedgeConfig.Arc.ClusterName)) {
        throw "Require ClusterName for Azure Arc" 
    }
}

function Get-AkseeInstalledProductName
{

    return (Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' | Get-ItemProperty |  Where-Object {$_.DisplayName -like "*Aks Edge Essentials*"}).DisplayName
}

function EnsurePreRequisites
{

    if (! [Environment]::Is64BitProcess) {
        throw "Error: Run this in 64bit Powershell session"
    }

    # Validate az cli version.
    $azVersion = (az version)[1].Split(":")[1].Split('"')[1]
    $azMinRequiredVersion = "2.64.0"
    if ($azVersion -lt $azMinRequiredVersion){
        throw "Installed Azure CLI version $azVersion is older than $azMinRequiredVersion. Please upgrade Azure CLI and retry."
    }

    $installedAkseeProductName = Get-AkseeInstalledProductName
    if (-Not [string]::IsNullOrEmpty($installedAkseeProductName)) {
        if ($installedAkseeProductName -like "*K8s*") {
            throw "Detected AKSEE k8s installation. Please uninstall and run the script again!"
        }
    }

    # Ensure logged into Azure
    $azureLogin = az account show
    if ( $null -eq $azureLogin){
        throw "Please login to azure via `az login` and retry."
    }

    $errOut = $($retVal = & {az extension add --upgrade --name connectedk8s -y}) 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Error upgrading extension connecktedk8s : $errOut"
    }

}

function EnsureDeploymentPrerequisites {
param(
    [object] $aideUserConfig,
    [object] $aksedgeConfig,
    [string ] $workdir
)

    ValidateConfig -aideUserConfig $aideuserConfig -aksedgeConfig $aksedgeConfig

    $aksedgeShell = (Get-ChildItem -Path "$workdir" -Filter AksEdgeShell.ps1 -Recurse).FullName
    . $aksedgeShell
}

function SetupAksEdgeRepo {
param(
    [string] $installDir,
    [string] $fork ="Azure",
    [string] $branch="main",
    [string] $Tag
)

    $url = "https://github.com/$fork/AKS-Edge/archive/$branch.zip"
    $zipFile = "AKS-Edge-$branch.zip"
    $workdir = "$installDir\AKS-Edge-$branch"
    if (-Not [string]::IsNullOrEmpty($Tag)) {
        $url = "https://github.com/$fork/AKS-Edge/archive/refs/tags/$Tag.zip"
        $zipFile = "$Tag.zip"
        $workdir = "$installDir\AKS-Edge-$tag"
    }

    if (!(Test-Path -Path "$installDir\$zipFile")) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $installDir\$zipFile -UseBasicParsing
        }
        catch {
            throw "Error: Downloading Aide Powershell Modules failed"
        }
    }

    if (!(Test-Path -Path "$workdir")) {
        Expand-Archive -Path $installDir\$zipFile -DestinationPath "$installDir" -Force
    }

    return $workdir
}

function DeployAksEdge
{
param (
    [String] $aideUserConfigFile
)

    # invoke the workflow, the json file already updated above.
    $retval = Start-AideWorkflow -jsonFile $aideUserConfigFile
    if ($retval) {
        Write-Host "Deployment Successful. "
    } else {
        throw "Deployment failed"
    }
}

function ConnectAksEdgeArc
{
param (
    [object] $aideUserConfig,
    [object] $aksedgeConfig
)

    $SubscriptionId = $aideuserConfig.Azure.SubscriptionId
    $ResourceGroupName = $aideuserConfig.Azure.ResourceGroupName
    $ClusterName = $aksedgeConfig.Arc.ClusterName

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

    New-ConnectedCluster -clusterName $ClusterName -arcArgs $aideuserConfig.Azure -proxyArgs $aksedgeConfig.Network.Proxy

    # Enable custom location support on your cluster using az connectedk8s enable-features command
    $objectId = $aideuserConfig.Azure.CustomLocationOID
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
}

function PrepareForAioWorkloadDeployment {
param(
    [string] $workdir
)

    Write-Host "Deploy local path provisioner"
    try {
        $localPathProvisionerYaml= (Get-ChildItem -Path "$workdir" -Filter local-path-storage.yaml -Recurse).FullName
        & kubectl apply -f $localPathProvisionerYaml
        Write-Host "Successfully deployment the local path provisioner"
    }
    catch {
        throw "Error: local path provisioner deployment failed"
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
        throw "Error: Firewall rule addition for AIO MQTT broker failed"
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
        throw "Error: port proxy update for AIO failed"
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
        throw "iptable rule update failed"
    }
}

###
# Main
###

try {
    EnsurePrerequisites

    $installDir = $((Get-Location).Path)
    $starttime = Get-Date
    $starttimeString = $($starttime.ToString("yyMMdd-HHmm"))
    $transcriptFile = "$installDir\aksedgedlog-$starttimeString.txt"
    Start-Transcript -Path $transcriptFile

    Set-ExecutionPolicy Bypass -Scope Process -Force

    Write-Host "Step 1 : Azure/AKS-Edge repo setup" -ForegroundColor Cyan
    $workdir = SetupAksEdgeRepo -installDir $installDir -Tag $Tag

    Write-Host "Step 2 : Ensure Deployment prerequisites"
    if ([string]::IsNullOrEmpty($aksedgeConfigFile))
    {
        $aksedgeConfigFile = "$workdir\tools\aio-aksedge-config.json"
    }
    $aksedgeConfig = ValidateConfigFile -filePath $aksedgeConfigFile
    $aksedgeConfigRepoFile = (Get-ChildItem -Path "$workdir" -Filter aksedge-config.json -Recurse).FullName
    Set-Content -Path $aksedgeConfigRepoFile -Value ($aksedgeConfig | ConvertTo-Json -Depth 6) -Force

    if ([string]::IsNullOrEmpty($aideUserConfigFile))
    {
        $aideUserConfigFile = "$workdir\tools\aio-aide-userconfig.json"
    }
    $aideuserConfig = ValidateConfigFile -filePath $aideUserConfigFile
    $aideuserConfig.AksEdgeConfigFile = "aksedge-config.json"
    $aideuserConfig.AksEdgeProductUrl = "https://download.microsoft.com/download/67fee208-b68d-47a3-81a5-454382df99a6/AksEdge-K3s-1.30.6.msi"
    $aideuserConfigRepoFile = (Get-ChildItem -Path "$workdir" -Filter aide-userconfig.json -Recurse).FullName
    Set-Content -Path $aideuserConfigRepoFile -Value ($aideuserConfig | ConvertTo-Json -Depth 6) -Force
    EnsureDeploymentPrerequisites -aideUserConfig $aideUserConfig -aksedgeConfig $aksedgeConfig -workdir $workdir

    Write-Host "Step 3: Download, install and deploy AKS Edge Essentials" -ForegroundColor Cyan
    DeployAksEdge -aideUserConfigFile $aideuserConfigRepoFile

    Write-Host "Step 4: Connect the cluster to Azure" -ForegroundColor Cyan
    ConnectAksEdgeArc -aideUserConfig $aideUserConfig -aksedgeConfig $aksedgeConfig

    Write-Host "Step 5: Prep for AIO workload deployment" -ForegroundColor Cyan
    PrepareForAioWorkloadDeployment -workdir $workdir
}
catch {
    $fileName = Split-Path -Path ($_.InvocationInfo.ScriptName) -Leaf
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Host "AIO-QuickStart failed with error: $_" -ForegroundColor Red
    Write-Host "at file: $fileName, line: $lineNumber" -ForegroundColor Red
}
finally {
    $endtime = Get-Date
    $duration = ($endtime - $starttime)
    Write-Host "Duration: $($duration.Hours) hrs $($duration.Minutes) mins $($duration.Seconds) seconds"
    Stop-Transcript | Out-Null
    Pop-Location
    exit -1
}

exit 0
