<#
    .DESCRIPTION
        This module contains the Arc functions to use on Edge Essentials platforms (ArcEdge)
#>
#Requires -RunAsAdministrator
if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}
#Hashtable to store session information
$arciotSession = @{
    "WorkspacePath"  = (Get-Location)
    "azSession"      = $null
    "ClusterName"    = ""
}
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name azcmagentexe -Value "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"

New-Variable -Option Constant -ErrorAction SilentlyContinue -Name arciotEnvConfig -Value @{
    "RPNamespaces"  = @("Microsoft.HybridCompute", "Microsoft.GuestConfiguration", "Microsoft.HybridConnectivity",
        "Microsoft.Kubernetes", "Microsoft.KubernetesConfiguration", "Microsoft.ExtendedLocation", "Microsoft.PolicyInsights")
    "ArcExtensions" = @("MicrosoftMonitoringAgent", "CustomScriptExtension")
    "ReqRoles"      = @("Azure Connected Machine Onboarding", "Kubernetes Cluster - Azure Arc Onboarding")
    "AzExtensions"  = @("connectedmachine", "connectedk8s", "customlocation", "k8s-extension")
    "ArcIotSchema"  = @("SubscriptionName", "SubscriptionId", "TenantId", "ResourceGroupName", "Location", "Auth")
}
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name azMinVersions -Value @{
    "azure-cli"        = "2.41.0"
    "azure-cli-core"   = "2.41.0"
    "connectedk8s"     = "1.3.1"
    "connectedmachine" = "0.5.1"
    "customlocation"   = "0.1.3"
    "k8s-extension"    = "1.3.3"
}
function Get-ArcEdgeUserConfig {
    return (Get-AideUserConfig).Azure
}
function Test-ArcEdgeUserConfig {
    $retval = $true
    $aicfg = Get-ArcEdgeUserConfig
    if (! $aicfg) {
        Write-Host "Error: UserConfig not set. Use Set-AideUserConfig to set." -ForegroundColor Red
        return $false
    }
    foreach ($key in $arciotEnvConfig.ArcIotSchema) {
        if ($aicfg.$key) {
            Write-Verbose "- $key ok"
        } else {
            Write-Host "Error: $key not specified" -ForegroundColor Red
            $retval = $false
        }
    }
    if ((-not $aicfg.Auth.ServicePrincipalId) -and (-not $aicfg.Auth.Password)) {
        Write-Host "Error: Specify Auth parameters" -ForegroundColor Red
        $retval = $false
    }
    return $retval
}
function Test-AzVersions {
    #Function to check if the installed az versions are greater or equal to minVersions
    $retval = $true
    $curVersion = (az version) | ConvertFrom-Json
    if (-not $curVersion) { return $false }
    foreach ($item in $azMinVersions.Keys ) {
        Write-Host " Checking $item minVersion $($azMinVersions.$item).." -NoNewline
        $fgcolor = 'Green'
        if ($curVersion.$item) {
            Write-Verbose " Comparing $($curVersion.$item) -lt $($azMinVersions.$item)."
            if ([version]$($curVersion.$item) -lt [version]$($azMinVersions.$item)) {
                $retval = $false
                $fgcolor = 'Red'
            }
            Write-Host "found $($curVersion.$item)" -ForegroundColor $fgcolor
        } elseif ($curVersion.extensions.$item) {
            Write-Verbose " Comparing $($curVersion.extensions.$item) -lt $($azMinVersions.$item)"
            if ([version]$($curVersion.extensions.$item) -lt [version]$($azMinVersions.$item)) {
                $retval = $false
                $fgcolor = 'Red'
            }
            Write-Host "found $($curVersion.extensions.$item)" -ForegroundColor $fgcolor
        } else {
            Write-Host "Error: $item is not installed" -ForegroundColor Red
            $retval = $false
        }
    }
    return $retval
}
function Install-ArcEdgeAzCLI {
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
        $Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
        az config set core.disable_confirm_prompt=yes
        az config set core.only_show_errors=yes
        #az config set auto-upgrade.enable=yes
    }
    Write-Host "> Azure CLI installed" -ForegroundColor Green
    $extlist = (az extension list --query [].name | ConvertFrom-Json -ErrorAction SilentlyContinue)
    foreach ($ext in $arciotEnvConfig.AzExtensions) {
        if ($extlist -and $extlist.Contains($ext)) {
            Write-Host "> az extension $ext installed" -ForegroundColor Green
        } else {
            Write-Host "Installing az extension $ext"
            az extension add --name $ext
        }
    }
    if (-not (Test-AzVersions)) {
        Write-Host "> Required Az versions are not installed. Attempting az upgrade. This may take a while."
        az upgrade --all --yes
        if (-not (Test-AzVersions)) {
            Write-Host "Error: Required versions not found after az upgrade. Please try uninstalling and reinstalling" -ForegroundColor Red
        }
    }
}
function Enter-ArcEdgeSession {
    $aicfg = Get-ArcEdgeUserConfig
    if (!$arciotSession.azSession) {
        if (-not $aicfg.Auth) {
            Write-Host "Error: no valid credentials." -ForegroundColor Red
            return $false
        }
        $aiauth = $aicfg.Auth
        if ($aiauth.ServicePrincipalId) {
            Write-Host "Using service principal id to login"
            if ($aiauth.Password) {
                $ret = az login --service-principal -u $aiauth.ServicePrincipalId -p $aiauth.Password --tenant $aicfg.TenantId
                if (-not $ret) {
                    Write-Host "Error: ServicePrincipalId/Password possibly expired." -ForegroundColor Red
                    return $false
                }
            } else {
                Write-Host "Error: password not specified." -ForegroundColor Red
                return $false
            }
        } else {
            Write-Host "Error: no valid Auth parameters." -ForegroundColor Red
            return $false
        }
    }
    (az account set --subscription $aicfg.SubscriptionId) | Out-Null
    #az configure --defaults group=$aicfg.ResourceGroupName
    $session = (az account show | ConvertFrom-Json -ErrorAction SilentlyContinue)
    Write-Host "Logged in $($session.name) subscription as $($session.user.name) ($($session.user.type))"
    $roles = (az role assignment list --all --assignee $($session.user.name)) | ConvertFrom-Json
    if (-not $roles) {
        Write-Host "Error: No roles enabled for this account in this subscription" -ForegroundColor Red
        Exit-ArcEdgeSession
        return $false
    }
    Write-Host "Roles enabled for this account are:" -ForegroundColor Cyan
    foreach ($role in $roles) {
        Write-Host "$($role.roleDefinitionName) for scope $($role.scope)" -ForegroundColor Cyan
    }
    $arciotSession.azSession = $session
    return $true
}

function Exit-ArcEdgeSession {
    az logout
    az account clear
    $arciotSession.azSession = $null
}

function Get-ArcEdgeAzureCreds {
    $cred = $null
    $aicfg = Get-ArcEdgeUserConfig
    if ($aicfg.Auth) {
        $aiauth = $aicfg.Auth
        if ($aiauth.Password -and $aiauth.ServicePrincipalId) {
            $cred = @{
                "Username" = $aiauth.ServicePrincipalId
                "Password" = $aiauth.Password
            }
        } else {
            Write-Host "Error: ServicePrincipalId/Password not specified." -ForegroundColor Red
            $cred = $null
        }
    }
    return $cred
}

function Initialize-ArcEdge {
    $status = $true
    $aicfg = Get-ArcEdgeUserConfig
    if (! $aicfg) {
        Write-Host "Error: UserConfig not set. Use Set-AideUserConfig to set" -Foreground Red
        return
    }
    Write-Host "Azure configuration:"
    Write-Host $aicfg
    Install-ArcEdgeAzCLI
    $spLoginSuccess = Enter-ArcEdgeSession
    if (-not $spLoginSuccess) {
        Write-Host "Error: Failed to login into Azure. Check Auth parameters. Initialize-ArcEdge failed." -ForegroundColor Red
        return
    } else {
        $status = Test-AzureResourceGroup $aicfg.ResourceGroupName $aicfg.Location
        $retval = Test-AzureResourceProviders $arciotEnvConfig.RPNamespaces
        if ($status) { $status = $retval }
    }
    if ($status) {
        Write-Host "Initialize-ArcEdge successful." -ForegroundColor Green
    } else {
        Write-Host "Initialize-ArcEdge failed." -ForegroundColor Red
    }
}
function Test-AzureResourceGroup {
    Param
    (
        [Parameter(Position = 0, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$rgname,
        [Parameter(Position = 1, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$location
    )
    # Check if resource group already exists
    $retval = $false
    Write-Host "Checking $rgname..."
    $rgexists = az group exists --name $rgname
    if ($rgexists -ieq 'true') {
        Write-Host "* $rgname exists" -ForegroundColor Green
        $retval = $true
    } else {
        Write-Host "Error: $rgname not found" -ForegroundColor Red
    }
    return $retval
}

function Test-AzureResourceProviders {
    Param(
        [System.Array]$namespaces = $null
    )
    $retval = $false
    if ($namespaces) {
        $retval = $true
        foreach ($namespace in $namespaces) {
            Write-Host "Checking $namespace..."
            $provider = (az provider show -n $namespace | ConvertFrom-Json -ErrorAction SilentlyContinue)
            if ($provider.registrationState -ieq "Registered") {
                Write-Host "* $namespace provider registered" -ForegroundColor Green
            } else {
                Write-Host "Error: $namespace provider not registered" -ForegroundColor Red
                $retval = $false
            }
        }
    }
    return $retval
}

function Test-AzureRoles {
    Param(
        [Parameter(Position = 0, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$appId,
        [Parameter(Position = 1, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.Array]$roles,
        [Parameter(Position = 1, Mandatory = $false)]
        [Switch]$Add
    )
    $retval = $true
    $aicfg = Get-ArcEdgeUserConfig
    #$reqRole = "Azure Connected Machine Onboarding"
    Write-Host "Using principalName $appId"
    Write-Host "Checking for role assignment"
    $query = "[?principalName=='$appId'].roleDefinitionName"
    $scope = "/subscriptions/$($aicfg.SubscriptionId)/resourceGroups/$($aicfg.ResourceGroupName)"
    $curRoles = (az role assignment list --scope $scope --query $query) | ConvertFrom-Json -ErrorAction SilentlyContinue
    foreach ($reqRole in $roles) {
        if ($curRoles.Contains($reqRole)) {
            Write-Host "$reqRole role enabled"
        } else {
            if ($Add) {
                $res = (az role assignment create --assignee $appId --scope $scope --role $reqRole) | ConvertFrom-Json -ErrorAction SilentlyContinue
                Write-Host "Role added. $($res.principalId)"
            } else {
                Write-Host "$reqRole role is not enabled" -ForegroundColor Red
                $retval = $false
            }
        }
    }
    return $retval
}

function Install-ArcEdgeCmAgent {
    if (Test-Path -Path $azcmagentexe -PathType Leaf) {
        Write-Host "> ConnectedMachineAgent is already installed" -ForegroundColor Green
        & $azcmagentexe version
        return
    }
    Write-Host "> Installing ConnectedMachineAgent..."
    Push-Location $env:TEMP
    # Download the installation package
    Invoke-WebRequest -Uri "https://aka.ms/azcmagent-windows" -TimeoutSec 30 -OutFile "$env:TEMP\install_windows_azcmagent.ps1"
    # Install the hybrid agent
    & "$env:TEMP\install_windows_azcmagent.ps1"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to install the ConnectedMachineAgent agent : $LASTEXITCODE" -ForegroundColor Red
    } else {
        Write-Host "Setting up auto update via Microsoft Update"
        $ServiceManager = (New-Object -com "Microsoft.Update.ServiceManager")
        $ServiceID = "7971f918-a847-4430-9279-4a52d1efe18d"
        $ServiceManager.AddService2($ServiceId, 7, "") | Out-Null
    }
    Remove-Item .\AzureConnectedMachineAgent.msi
    Pop-Location
}

function Test-ArcEdgeCmAgent {
    $retval = $false
    if (!(Test-Path -Path $azcmagentexe -PathType Leaf)) {
        Write-Host "ConnectedMachineAgent is not installed" -ForegroundColor Gray
        return $retval
    }
    # Check if the machine is already connected
    $agentstatus = (& $azcmagentexe show -j) | ConvertFrom-Json
    if ($($agentstatus.status) -eq 'Connected') {
        $retval = $true
        Write-Host "ConnectedMachineAgent is connected." -ForegroundColor Green
    } else {
        Write-Host "ConnectedMachineAgent is disconnected." -ForegroundColor Yellow
    }
    return $retval

}

function Get-ArcEdgeCmInfo {
    if (!(Test-ArcEdgeCmAgent)) {
        return $null
    }
    $vmInfo = @{}
    $apiVersion = "2020-06-01"
    $InstanceUri = $env:IMDS_ENDPOINT + "/metadata/instance?api-version=$apiVersion"
    $Proxy = New-Object System.Net.WebProxy
    $WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $WebSession.Proxy = $Proxy
    $response = (Invoke-RestMethod -Headers @{"Metadata" = "true"} -Method GET -Uri $InstanceUri -WebSession $WebSession) 
    $vmInfo.Add("Name", $response.compute.name)
    $vmInfo.Add("ResourceGroupName", $response.compute.resourceGroupName)
    $vmInfo.Add("SubscriptionId", $response.compute.subscriptionId)
    $vmInfo.Add("Location", $response.compute.location)
    return $vmInfo
}
function Connect-ArcEdgeCmAgent {
    if (!(Test-ArcEdgeCmAgent)) {
        Install-ArcEdgeCmAgent
    }
    # Check if the machine is already connected
    $agentstatus = (& $azcmagentexe show)
    if ($($agentstatus | Select-String -Pattern 'Agent Status') -like '*Disconnected') {
        Write-Host "ConnectedMachine Agent state is Disconnected. Connecting now..."
        $aicfg = Get-ArcEdgeUserConfig
        $creds = Get-ArcEdgeAzureCreds
        if (!$creds) {
            Write-Host "Error: No valid credentials found. Connect not attempted." -ForegroundColor Red
            return $false
        }
        $connectargs = @( "--resource-group", "$($aicfg.ResourceGroupName)",
            "--tenant-id", "$($aicfg.TenantId)",
            "--location", "$($aicfg.Location)",
            "--subscription-id", "$($aicfg.SubscriptionId)",
            "--cloud", "$($arciotSession.azSession.environmentName)",
            "--service-principal-id", "$($creds.Username)",
            "--service-principal-secret", "$($creds.Password)"
        )
        if (Test-ArcEdgeK8sConnection) {
            $clustername = Get-ArcEdgeClusterName
            $tags = @("--tags","AKSEE=$clustername")
        }
        $tags = @("--tags","SKU=AksEdgeEssentials")
        $connectargs += $tags
        $hostSettings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyServer, ProxyEnable
        if ($hostSettings.ProxyEnable) {
            & $azcmagentexe config set proxy.url $($hostSettings.ProxyServer)
        }
        & $azcmagentexe connect @connectargs
        if ($LastExitCode -eq 0) {
            Write-Host "ConnectedMachineAgent connected."
        } else {
            Write-Host "Error in connecting to Azure: $LastExitCode" -ForegroundColor Red
            return $false
        }
    } else {
        Write-Host "ConnectedMachineAgent is already connected." -ForegroundColor Green
    }
    return $true
}

function Disconnect-ArcEdgeCmAgent {
    if (! (Test-ArcEdgeCmAgent) ) {
        return $false
    }
    #check and unregister extensions
    Remove-ArcEdgeServerExtension
    # disconnect
    Write-Host "ConnectedMachineAgent state is connected. Disonnecting now..."
    # Get creds
    $creds = Get-ArcEdgeAzureCreds
    if ($creds) {
        $disconnectargs = @(
            "--service-principal-id", "$($creds.Username)",
            "--service-principal-secret", "$($creds.Password)"
        )
        & $azcmagentexe disconnect @disconnectargs
        if ($LastExitCode -eq 0) {
            Write-Host "ConnectedMachineAgent disconnected."
            return $true
        } else {
            Write-Host -ForegroundColor red "Error in disconnecting from Azure: $LastExitCode"
        }

    } else {
        Write-Host "Error: No valid credentials found. Disconnect not attempted." -ForegroundColor Red
    }
    return $false
}
function Set-ArcEdgeCmProxy {
    Param(
        [Parameter(Position = 0, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$proxyUrl
    )
    if (!(Test-Path -Path $azcmagentexe -PathType Leaf)) {
        Write-Host "ConnectedMachineAgent is not installed" -ForegroundColor Gray
        return
    }
    & $azcmagentexe config set proxy.url $proxyUrl
}
function Get-ArcEdgeMIAccessToken {
    # Return the Managed Identity access token
    $token = $null
    $apiVersion = "2020-06-01"
    $resource = "https://management.azure.com/"
    $endpoint = "{0}?resource={1}&api-version={2}" -f $env:IDENTITY_ENDPOINT, $resource, $apiVersion
    $secretFile = ""
    try {
        Invoke-WebRequest -Method GET -Uri $endpoint -Headers @{Metadata = 'True' } -UseBasicParsing
    } catch {
        $wwwAuthHeader = $_.Exception.Response.Headers["WWW-Authenticate"]
        if ($wwwAuthHeader -match "Basic realm=.+") {
            $secretFile = ($wwwAuthHeader -split "Basic realm=")[1]
        }
    }
    Write-Verbose "Secret file path: " $secretFile`n
    $secret = Get-Content -Raw $secretFile
    $response = Invoke-WebRequest -Method GET -Uri $endpoint -Headers @{Metadata = 'True'; Authorization = "Basic $secret" } -UseBasicParsing
    if ($response) {
        $token = (ConvertFrom-Json -InputObject $response.Content).access_token
        Write-Verbose "Access token: " $token
    }
    return $token
}
function New-ArcEdgeServerExtension {
    if (! (Test-ArcEdgeCmAgent) ) {
        return
    }
    $aicfg = Get-ArcEdgeUserConfig
    $protectedsettings = @'
    {
        "fileUris": [ filename.ps1 ]
        "commandToExecute":"powershell.exe -ExecutionPolicy Unrestricted -File filename.ps1 "
    }
'@

    $cmebaseargs = @(
        "--machine-name", "$($arciotMachineName)",
        "--name", "CustomScriptExtension",
        "--resource-group", "$($aicfg.ResourceGroupName)"
    )
    $cmeargs = @(
        "--location", "$($aicfg.Location)",
        "--type", "CustomScriptExtension",
        "--publisher", "Microsoft.HybridCompute",
        "--protected-settings", "$($protectedsettings)",
        "--type-handler-version", "1.10",
        "--tags", "owner=ArcIot"
    )
    az connectedmachine extension create @cmebaseargs @cmeargs --no-wait
    Write-Host "CustomScriptExtension creation in progress. Waiting..."
    az connectedmachine extension wait @cmebaseargs --created
    Write-Host "CustomScriptExtension created successfully"
}

function Remove-ArcEdgeServerExtension {

    if (! (Test-ArcEdgeCmAgent) ) {
        return
    }
    $aicfg = Get-ArcEdgeUserConfig
    $cmeargs = @(
        "--machine-name", "$($arciotMachineName)",
        "--resource-group", "$($aicfg.ResourceGroupName)"
    )
    $extlist = (az connectedmachine extension list @cmeargs --query [].name) | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($extlist) {
        $extensions = [String]::Join(",", $extlist)
        Write-Host "Found : $($extensions)"
        # remove each extension
        foreach ($ext in $extlist) {
            Write-Host "Removing $ext extension"
            az connectedmachine extension delete @cmeargs --name $ext --no-wait --yes
        }
        Write-Host "Waiting..."
        az connectedmachine extension wait @cmebaseargs --deleted
        Write-Host "Extension removal completed successfully"
    } else {
        Write-Host "No extensions to remove."
    }
}
#########################################
# Arc for Kubernetes - Connected Clusters
#########################################

function Get-ArcEdgeClusterName {
    if (-not $arciotSession.ClusterName) {
        $aicfg = Get-ArcEdgeUserConfig
        if ($aicfg.ClusterName) {
            $arciotSession.ClusterName = $aicfg.ClusterName
        } else {
            $clustername = $(kubectl get configmap -n aksedge aksedge -o jsonpath="{.data.clustername}")
            if (!$clustername){
                $clustername = hostname
                $k3s = (kubectl get nodes) | Where-Object { $_ -match "k3s"}
                if ($k3s) {
                    $clustername += "-k3s"
                } else {
                    $clustername += "-k8s"
                }
            }
            $arciotSession.ClusterName = $clustername
        }
    }
    return $arciotSession.ClusterName
}

function Test-ArcEdgeK8sConnection {
    $retval = $false
    if ((!$arciotSession.azSession) -and (!(Enter-ArcEdgeSession))) { return $retval }

    $aicfg = Get-ArcEdgeUserConfig
    # check if this cluster is already registered
    $k8slist = (az connectedk8s list -g $aicfg.ResourceGroupName --query [].name | ConvertFrom-Json -ErrorAction SilentlyContinue)
    $arciotClusterName = Get-ArcEdgeClusterName
    if ($k8slist -and ($k8slist.Contains($arciotClusterName))) {
        Write-Host "$arciotClusterName is connected to Arc" -ForegroundColor Green
        $retval = $true
    } else {
        Write-Host "$arciotClusterName is not connected to Arc" -ForegroundColor Yellow
    }
    return $retval
}

function Connect-ArcEdgeK8s {
    if ((!$arciotSession.azSession) -and (!(Enter-ArcEdgeSession))) { return $false }
    $aicfg = Get-ArcEdgeUserConfig
    # check if this cluster is already registered
    $k8slist = (az connectedk8s list -g $aicfg.ResourceGroupName --query [].name | ConvertFrom-Json -ErrorAction SilentlyContinue)
    $arciotClusterName = Get-ArcEdgeClusterName
    if ($k8slist -and ($k8slist.Contains($arciotClusterName))) {
        Write-Host "$arciotClusterName is already connected to Arc" -ForegroundColor Green
    } else {
        # Get the credentials before connecting to ensure that we have the latest file.
        Write-Host "Updating kubeconfig file with Get-AksEdgeKubeConfig..."
        Get-AksEdgeKubeConfig -KubeConfigPath $($arciotSession.WorkspacePath) -Confirm:$false
        Write-Host "Establishing Azure Connected Kubernetes for $arciotClusterName"
        $connectargs = @(
            "--name", "$($arciotClusterName)",
            "--resource-group", "$($aicfg.ResourceGroupName)",
            "--kube-config", "$($arciotSession.WorkspacePath)\config"
        )
        <#
        $connectargs += @(
            "--distribution","aks_edge",
            "--infrastructure","TBF"
        )
        #>
        $tags = @("Type=AKSEdgeEssentials")
        $modVersion = (Get-Module AksEdge).Version
        if ($modVersion) { $tags += @("Version=$modVersion") }
        $infra = Get-AideInfra
        if ($infra) { $tags += @("Infra=$infra") }
        $hostname = hostname
        if ($hostname) { $tags += @("Hostname=$hostname") }
        $aideConfig = Get-AideUserConfig
        if ($aideConfig) {
            $isProxySet = $false
            $httpsProxy = $($aideConfig.Network.Proxy.Https)
            $httpProxy = $($aideConfig.Network.Proxy.Http)
            if ($httpsProxy) {
                $connectargs += @( "--proxy-https", "$httpsProxy")
                $isProxySet = $true
            }
            if ($httpProxy) {
                $connectargs += @( "--proxy-http", "$httpProxy")
                $isProxySet = $true
            }
            if ($isProxySet) {
                $no_proxy = $($aideConfig.Network.Proxy.No)
                $kubenet =  $(kubectl get services kubernetes -o jsonpath="{$.spec.clusterIP}")
                $octets = $kubenet.Split(".")
                $octets[2] = 0;$octets[3] = 0
                $kubeSubnet = $($octets -join ".") + "/16"
                if ($no_proxy){
                    $no_proxy = "$no_proxy,$kubeSubnet"
                } else {
                    $no_proxy = "localhost,127.0.0.0/8,192.168.0.0/16,172.17.0.0/16,10.96.0.0/12,10.244.0.0/16,,kubernetes.default.svc,.svc.cluster.local,.svc,$kubeSubnet"
                }
                $connectargs += @( "--proxy-skip-range",$no_proxy)
            }
        }
        $connectargs += @( "--tags", $tags)
        $result = (az connectedk8s connect @connectargs ) | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (!$result) {
            Write-Host "Error: arc connect failed." -ForegroundColor Red
            return $false
        }
        Write-Verbose ($result | Out-String)
        #Update the Arc for Server tag if connected
        if (Test-ArcEdgeCmAgent) {
            $cmInfo = Get-ArcEdgeCmInfo
            $resource = "/subscriptions/$($cmInfo.SubscriptionId)/resourceGroups/$($cmInfo.ResourceGroupName)/providers/Microsoft.HybridCompute/machines/$($cmInfo.Name)"
            $result= $(az tag update --resource-id $resource --operation Merge --tags "AKSEE=$arciotClusterName")
            if ($result) {
                Write-Host "Arc for Server tag updated with cluster id"
            } else {
                Write-Host "Error: Arc for Server tag update failed" -ForegroundColor Red
            }
        }
        $token = Get-ArcEdgeK8sServiceToken
        $proxyinfo = @{
            resourcegroup = $aicfg.ResourceGroupName
            clustername   = $arciotClusterName
            token         = $token
        }
        $proxyjson = ConvertTo-Json -InputObject $proxyinfo
        Set-Content -Path "$($arciotSession.WorkspacePath)\proxyinfo.json" -Value $proxyjson -Force
        Remove-Item -Path "$($arciotSession.WorkspacePath)\config" | Out-Null
    }
    return $true
}

function Disconnect-ArcEdgeK8s {
    if ((!$arciotSession.azSession) -and (!(Enter-ArcEdgeSession))) { return $false }
    $aicfg = Get-ArcEdgeUserConfig
    $k8slist = (az connectedk8s list -g $aicfg.ResourceGroupName --query [].name | ConvertFrom-Json -ErrorAction SilentlyContinue)
    $arciotClusterName = Get-ArcEdgeClusterName
    if ($k8slist -and ($k8slist.Contains($arciotClusterName))) {
        # Get the credentials before connecting to ensure that we have the latest file.
        Write-Host "Updating kubeconfig file with Get-AksEdgeKubeConfig..."
        Get-AksEdgeKubeConfig -KubeConfigPath $($arciotSession.WorkspacePath) -Confirm:$false
        Write-Host "Deleting Arc resource for $arciotClusterName"
        $result = (az connectedk8s delete -g $aicfg.ResourceGroupName -n $arciotClusterName --kube-config "$($arciotSession.WorkspacePath)\config" --yes) | ConvertFrom-Json -ErrorAction SilentlyContinue
        Write-Verbose ($result | Out-String)
        Remove-Item -Path "$($arciotSession.WorkspacePath)\config" | Out-Null
        Write-Host "Arc connect for cluster $clusername removed."
    } else {
        Write-Host "$arciotClusterName not connected to Azure Arc." -ForegroundColor Yellow
    }
    return $true
}

function Get-ArcEdgeK8sServiceToken {
    $seraccs = $(kubectl get serviceaccounts)
    if (!($seraccs | Where-Object { $_.Contains('aksedge-admin-user') })) {
        kubectl create serviceaccount aksedge-admin-user | Write-Host
        kubectl create clusterrolebinding aksedge-admin-user --clusterrole cluster-admin --serviceaccount default:aksedge-admin-user | Write-Host
    }
    $secretname = $(kubectl get serviceaccount aksedge-admin-user -o jsonpath='{$.secrets[0].name}')
    $token = $(kubectl get secret ${secretname} -o jsonpath='{$.data.token}')
    $servicetoken = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($token))
    $servicetokenfile = "$($arciotSession.WorkspacePath)\servicetoken.txt"
    Set-Content -Path $servicetokenfile -Value "$servicetoken"
    return $servicetoken
}
