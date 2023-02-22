<#
    .DESCRIPTION
        This module contains the Arc functions to use on Edge Essentials platforms (AksEdgeDeploy-Arc)
#>
#Requires -RunAsAdministrator
if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}

function Initialize-AideArc {
    <#
    .SYNOPSIS
        Checks and installs Azure CLI and validates the Azure configuration using the service principal credentials.

    .DESCRIPTION
        This command checks and installs Azure CLI by invoking Install-AideAzCli and validates the Azure configuration such as resource group, resource provider status using the service principal credentials..

    .OUTPUTS
        Boolean
        True if all ok.

    .EXAMPLE
        Initialize-AideArc
    #>
    $status = Test-AideArcUserConfig
    if (!$status) { return $false }
    $aicfg = Get-AideArcUserConfig
    if (! $aicfg) {
        Write-Host "Error: UserConfig not set. Use Set-AideUserConfig to set" -Foreground Red
        return $false
    }
    Write-Host "Azure configuration:"
    Write-Host $aicfg
    $status = Test-ArcEdgeAzModules -Install
    if ($status) {
        Write-Host "Initialize-AideArc successful." -ForegroundColor Green
    } else {
        Write-Host "Initialize-AideArc failed." -ForegroundColor Red
    }
    return $status
}

function Enter-AideArcSession {
    <#
    .SYNOPSIS
        Logs into Azure using the service principal credentials supplied.

    .DESCRIPTION
        Logs into Azure using the service principal credentials supplied in the json file (Azure.Auth.ServicePrincipalId and Azure.Auth.Password).

    .OUTPUTS
        None

    .EXAMPLE
        Enter-AideArcSession
    #>
    $aicfg = Get-AideArcUserConfig
    $context = Get-AzContext
    if ($context) {
        Write-Host "Azure session active with $($context.Account)"
        return
    }
    if (!$context) {
        if (-not $aicfg.Auth) {
            Write-Host "Error: no valid credentials." -ForegroundColor Red
            return $false
        }
        $aiauth = $aicfg.Auth
        if ($aiauth.ServicePrincipalId) {
            Write-Host "Using service principal id to login"
            if ($aiauth.Password) {
                $secPwd = ConvertTo-SecureString -String $aiauth.Password -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential($aiauth.ServicePrincipalId, $secPwd)
                $ret = Connect-AzAccount -Tenant $aicfg.TenantId -Subscription $aicfg.SubscriptionId -ServicePrincipal -Credential $Credential
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
    <#
    (az account set --subscription $aicfg.SubscriptionId) | Out-Null
    #az configure --defaults group=$aicfg.ResourceGroupName
    $session = (az account show | ConvertFrom-Json -ErrorAction SilentlyContinue)
    Write-Host "Logged in $($session.name) subscription as $($session.user.name) ($($session.user.type))"
    $roles = (az role assignment list --all --assignee $($session.user.name)) | ConvertFrom-Json
    if (-not $roles) {
        Write-Host "Error: No roles enabled for this account in this subscription" -ForegroundColor Red
        Exit-AideArcSession
        return $false
    }
    Write-Host "Roles enabled for this account are:" -ForegroundColor Cyan
    foreach ($role in $roles) {
        Write-Host "$($role.roleDefinitionName) for scope $($role.scope)" -ForegroundColor Cyan
    }
    $arciotSession.azSession = $session#>
    return $true
}

function Exit-AideArcSession {
    <#
    .SYNOPSIS
        Logs out of Azure session and clears account cache.

    .DESCRIPTION
        Logs out of Azure session and clears account cache.

    .OUTPUTS
        None

    .EXAMPLE
        Exit-AideArcSession
    #>
    #az logout
    #az account clear
    $context = Get-AzContext
    if ($context) {
        Write-Host "Azure session active with $($context.Account)"
        Disconnect-AzAccount # -ContextName $($context.Name)
        return
    }
}

#########################################
# Arc-enabled Kubernetes - Connected Clusters
#########################################

function Get-AideArcClusterName {
    <#
    .SYNOPSIS
        Returns the cluster name for the deployed cluster.

    .DESCRIPTION
        This command returns the cluster name for the deployed cluster. If the user has specified Clustername in the aide-userconfig.json, the same is returned.
        If there is no user specifcation, it returns the clustername as hostname-k8s or hostname-k3s based on the kubernetes flavour installed.

    .OUTPUTS
        String

    .EXAMPLE
        Get-AideArcClusterName

    #>
    $aicfg = Get-AideArcUserConfig
    if ($aicfg.ClusterName) {
        $arciotSession.ClusterName = $aicfg.ClusterName
    } else {
        #$clustername = $(kubectl get configmap -n aksedge aksedge -o jsonpath="{.data.clustername}")
        #if (!$clustername){
        $clustername = hostname
        $k3s = (kubectl get nodes) | Where-Object { $_ -match "k3s"}
        if ($k3s) {
            $clustername += "-k3s"
        } else {
            $clustername += "-k8s"
        }
        #}
    }
    return $clustername
}

function Test-AideArcKubernetes {
    return Test-AksEdgeArcConnection
}

function Get-AideArcKubernetesServiceToken {
    return Get-AksEdgeManagedServiceToken
}

function Connect-AideArc {
    <#
    .SYNOPSIS
        Connects the machine and the running kubernetes cluster to Azure Arc.

    .DESCRIPTION
        This command invokes Connect-AideArcServer which installs and connects Azure Arc Connected machine agent to Arc-enabled Server. 
        Then it invokes Connect-AideArcKubernetes to connect the kubernetes cluster running on the machine (should be running control plane) to Arc-enabled Kubernetes.
        The inputs required are consumed from the aide-userconfig.json file.

    .OUTPUTS
        Boolean
        True if both the connection is successful and false if either one fails.

    .EXAMPLE
        Connect-AideArc

    #>

    Write-Host "Checking Azure Arc-enabled Kubernetes.."
    $kubernetesStatus = Test-AksEdgeArcConnection
    if ($kubernetesStatus) {
        Write-Host "-- Connection already exists." -ForegroundColor Yellow
    } else {
        Write-Host "Connecting Azure Arc-enabled Kubernetes.."
        $kubernetesStatus = Connect-AideArcKubernetes
        if ($kubernetesStatus) {
            Write-Host "-- Connection succeeded." -ForegroundColor Green
        } else {
            Write-Host "-- Connection failed." -ForegroundColor Red
        }
    }

    Write-Host "Connecting Azure Arc-enabled Server.."
    $serverStatus = Connect-AideArcServer
    if ($serverStatus) {
        Write-Host "-- Connection succeeded." -ForegroundColor Green
    } else {
        Write-Host "-- Connection failed." -ForegroundColor Red
    }

    return ($serverStatus -and $kubernetesStatus)
}

function Disconnect-AideArc {
    <#
    .SYNOPSIS
        Disconnects the machine and the running kubernetes cluster from Azure Arc.

    .DESCRIPTION
        This command invokes Disconnect-AideArcServer which disconnects from Arc-enabled Server, if connected.
        Then it invokes Disconnect-AideArcKubernetes to disconnect from Arc-enabled Kubernetes,if connected.
        The inputs required are consumed from the aide-userconfig.json file.

    .OUTPUTS
        Boolean
        True if both the disconnection is successful and false if either one fails.

    .EXAMPLE
        Disconnect-AideArc

    #>

    Write-Host "Disconnecting Azure Arc-enabled Kubernetes.."
    $kubernetesStatus = Disconnect-AideArcKubernetes
    if ($kubernetesStatus) {
        Write-Host "-- Disconnection succeeded." -ForegroundColor Green
    } else {
        Write-Host "-- Disconnection failed." -ForegroundColor Red
    }
    Write-Host "Disconnecting Azure Arc-enabled Server.."
    $serverStatus = Disconnect-AideArcServer
    if ($serverStatus) {
        Write-Host "-- Disconnection succeeded." -ForegroundColor Green
    } else {
        Write-Host "-- Disconnection failed." -ForegroundColor Red
    }
    return ($serverStatus -and $kubernetesStatus)
}

New-Variable -Option Constant -ErrorAction SilentlyContinue -Name arcEdgeInstallConfig -Value @{
    "PSModules" = @(
        @{Name="Az.Resources"; Version="6.4.1"; Flags="-AllowClobber"},
        @{Name="Az.Accounts"; Version="2.11.2"; Flags="-AllowClobber"}, 
        @{Name="Az.ConnectedKubernetes"; Version="0.8.0"; Flags="-AllowClobber"}
        )
    "Urls" = @{
        helm = "https://k8connecthelm.azureedge.net/helm/helm-v3.6.3-windows-amd64.zip"
    }
}
function Test-ArcEdgeAzModules {
    Param
    (
        [Switch] $Install
    )
    $errCnt = 0

    $modules = Get-Module -ListAvailable

    #Install the required PowerShell modules
    $psgallery = Get-PSRepository | Where-Object { $_.Name -like "PSGallery" }
    if ($psgallery.InstallationPolicy -ine "Trusted") {
        # Do this always as by default PSGallery is untrusted. 
        # See alternate means to force install rather than making this trusted.
        Write-Host "Setting PSGallery as Trusted Source"
        Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted
    }
    else { Write-Host "PSGallery is trusted" -ForegroundColor Green }

    $pkgproviders = Get-PackageProvider
    if ($pkgproviders.Name -notcontains "NuGet"){
        Write-Host "Installing NuGet"
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    } else { Write-Host "NuGet found" -ForegroundColor Green }

    Write-Host "Checking Helm"
    $helmRoot = "$env:USERPROFILE\.Azure\helm"
    $helmDir = "$helmRoot\windows-amd64"
    if (!(($env:Path).Contains($helmDir))) {
        $env:Path = "$helmDir;$env:Path"
	[Environment]::SetEnvironmentVariable('Path', $env:Path)
    }
    $cmd = Get-Command helm -ErrorAction SilentlyContinue
    if ($null -eq $cmd)
    {
        Write-Host "- Helm not found. A helm version of at least 3.0 but less than 3.7 is required."
        $installHelm = $true
        $errCnt += 1
    } else {
        $version = helm version --template='{{.Version}}'
        $version = ($version -split 'v')[1]
        if (([version]$version -lt [version]"3.0.0") -Or ([version]$version -ge [version]"3.7.0"))
        {
            Write-Host "- Found $version. A helm version of at least 3.0 but less than 3.7 is required."
            $installHelm = $true
            $errCnt += 1
        } else {
            Write-Host "* Found helm version $version" -ForegroundColor Green
        }    
    }
    if ($installHelm -and $Install) {
        $url = $arcEdgeInstallConfig.Urls.helm
        $outFile = "$env:TEMP\helm.zip"
        Write-Host "Installing helm from $url"
        try {
            Invoke-WebRequest -Uri $url -TimeoutSec 30 -OutFile $outFile
            if (Test-Path $outFile) {
                Expand-Archive -Path $outFile -DestinationPath $helmRoot -Force
                $errCnt -=1
            } else {
                Write-Host "Download failed. Try again or install helm manually from $url"
            }
        } catch {
            Write-Host "Error : Failed to install helm. try again or install helm manually from $url"
        }
    }

    Write-Host "Checking Az Powershell modules....."
    $reqmods = $arcEdgeInstallConfig.PSModules
    foreach ($mod in $reqmods) {
        $module = $modules | Where-Object { $_.Name -like $mod.Name }
        if ($module ) {
            $installedVersion = $module.Version | Sort-Object -Descending | Select-Object -First 1
            if ((-not $mod.version) -or ([version]$installedVersion -ge [version]$mod.Version)) {
                Write-Host "* $($mod.Name) - $installedVersion found" -ForegroundColor Green
                continue
            } else {
                Write-Host "- $($mod.Name) - $installedVersion. Req: $($mod.Version)"
                $errCnt += 1
            }
        }
        if ($Install) {
            Write-Host "Installing [$($mod.Name)-$($mod.Version) $($mod.Flags)].."
            $installcmd = "Install-Module -Name $($mod.Name)"
            if ($mod.Version -ine "") {
                $installcmd = $installcmd + " -RequiredVersion $($mod.Version)"
            }
            if ($mod.Flags -ine "") {
                $installcmd = $installcmd + " $($mod.Flags)"
            }
            Invoke-Expression -Command $installcmd
            $errCnt -= 1
        }
    }
    return ($errCnt -eq 0)
}

function Connect-AideArcKubernetes {
    $usrCfg = Get-AideUserConfig
    $json = ($usrCfg.AksEdgeConfig | ConvertTo-Json )
    $retVal = Connect-AksEdgeArc -JsonConfigString $json
    if ($retVal -eq "OK") {
        $serverinfo = Get-AideArcServerInfo
        if ($serverinfo.Status -eq "Connected") {
            #Arc for server is already connected. So try updating tags
            $serverid = "/subscriptions/$($serverinfo.SubscriptionId)/resourceGroups/$($serverinfo.ResourceGroupName)/providers/Microsoft.HybridCompute/machines/$($serverinfo.Name)"
            $clustername = Get-AideArcClusterName
            $tag = @{ AKSEE="$clustername" }
            $result = Update-AzTag -ResourceId $serverid -Tag $tag -Operation Merge
            Write-Verbose $result
        }
    }
    return ($retVal -eq "OK")
}
function Disconnect-AideArcKubernetes {
    $usrCfg = Get-AideUserConfig
    $json = ($usrCfg.AksEdgeConfig | ConvertTo-Json )
    $retVal = Disconnect-AksEdgeArc -JsonConfigString $json
    if ($retVal -eq "OK") {
        #patch to remove azure-arc-release namespace
        $namespaces = (kubectl get namespaces -o custom-columns=NAME:.metadata.name --no-headers)
        if ($namespaces.Contains("azure-arc-release")) {
            kubectl delete namespace azure-arc-release
        }
    }
    return ($retVal -eq "OK")
}