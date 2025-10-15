<#
    .DESCRIPTION
        This module contains the Arc functions to use on Edge Essentials platforms (AksEdgeDeploy-Arc)
#>
#Requires -RunAsAdministrator
if (! [Environment]::Is64BitProcess) {
    Write-Host "Error: Run this in 64bit Powershell session" -ForegroundColor Red
    exit -1
}
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name azcmagentexe -Value "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"
New-Variable -Option Constant -ErrorAction SilentlyContinue -Name arciotEnvConfig -Value @{
    "ArcIotSchema"  = @("SubscriptionName", "SubscriptionId", "TenantId", "ResourceGroupName", "Location", "Auth")
}
New-Variable -option Constant -ErrorAction SilentlyContinue -Name arcLocations -Value @(
    "westeurope", "eastus", "westcentralus", "southcentralus", "southeastasia", "uksouth",
    "eastus2", "westus2", "australiaeast", "northeurope", "francecentral", "centralus",
    "westus", "northcentralus", "koreacentral", "japaneast", "eastasia", "westus3",
    "canadacentral", "eastus2euap"
)
function Get-AideArcUserConfig {
    return (Get-AideUserConfig).Azure
}
function Test-AideArcUserConfig {
    $retval = $true
    $aicfg = Get-AideArcUserConfig
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
    if ($arcLocations -inotcontains $($aicfg.Location)){
        Write-Host "Error: Location $($aicfg.Location) is not supported for Azure Arc" -ForegroundColor Red
        Write-Host "Supported Locations : $arcLocations"
        $retval = $false
    }
    return $retval
}

function Get-AideArcAzureCreds {
    $cred = $null
    $aicfg = Get-AideArcUserConfig
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

function Install-AideArcServer {
    <#
    .SYNOPSIS
        Checks and installs connected machine agent.

    .DESCRIPTION
        This command tests if the connected machine agent is installed and installs using script from "https://aka.ms/azcmagent-windows".
        This also sets up for auto update via Microsoft Update.

    .OUTPUTS
        Boolean
        True when the install is successful

    .EXAMPLE
        Install-AideArcServer
    #>
    if (Test-IsAzureVM) { return $false }
    if (Test-Path -Path $azcmagentexe -PathType Leaf) {
        Write-Host "> ACMA is already installed" -ForegroundColor Green
        & $azcmagentexe version
        return $true
    }
    Write-Host "> Installing ACMA..."

    $tempPath = Join-Path $env:SystemRoot "AkseeTemp"
    if (-Not (Test-Path -Path $tempPath)) {
        New-Item -Path $tempPath -ItemType Directory
        Write-Output "Directory '$tempPath' created."
    }

    Push-Location $tempPath
    try {
        # Download the installation package

        Invoke-WebRequest -Uri "https://aka.ms/azcmagent-windows" -TimeoutSec 300 -OutFile ".\install_windows_azcmagent.ps1" -UseBasicParsing
        # Install the hybrid agent
        & ".\install_windows_azcmagent.ps1"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error: Failed to install the ACMA agent : $LASTEXITCODE" -ForegroundColor Red
        } else {
            Write-Host "Setting up auto update via Microsoft Update"
            $ServiceManager = (New-Object -com "Microsoft.Update.ServiceManager")
            $ServiceID = "7971f918-a847-4430-9279-4a52d1efe18d"
            $ServiceManager.AddService2($ServiceId, 7, "") | Out-Null
        }
        Remove-Item .\AzureConnectedMachineAgent.msi
        if (Test-Path -Path $azcmagentexe -PathType Leaf) {
            Write-Host "> ACMA is installed successfully" -ForegroundColor Green
            & $azcmagentexe version
            $retval = $true
        } else { 
            Write-Host "Error: Install failed." -ForegroundColor Red 
            $retval = $false
        }
    } catch {
        Write-Host "Error: Install failed." -ForegroundColor Red
        $retval = $false
    }
    Pop-Location
    return $retval
}

function Get-AideACMAStatus {
    [cmdletbinding()]
    param()
    <#
    .SYNOPSIS
        Returns the status of the Azure Connected Machine Agent (acma).

    .DESCRIPTION
        This command tests if the connected machine agent is installed and connected to Azure Arc-enabled server.

    .OUTPUTS
        String
        [Connected/Disconnected/NotInstalled]

    .EXAMPLE
        Get-AideACMAStatus
    #>
    $retval = "Disconnected"
    if (!(Test-Path -Path $azcmagentexe -PathType Leaf)) {
        Write-Verbose "ACMA is not installed"
        $retval = "NotInstalled"
    } else{
        # Check if the machine is already connected
        $agentstatus = (& $azcmagentexe show -j) | ConvertFrom-Json
        $retval = $agentstatus.status
        Write-Verbose "ACMA is $retval"
    }
    return $retval
}
function Test-AideArcServer {
    [cmdletbinding()]
    param()
    <#
    .SYNOPSIS
        Tests if the connected machine agent is installed and connected to Azure Arc-enabled server.

    .DESCRIPTION
        This command tests if the connected machine agent is installed and connected to Azure Arc-enabled server.
        The inputs required are consumed from the aide-userconfig.json file.

    .OUTPUTS
        Boolean
        True when connected.

    .EXAMPLE
        Test-AideArcServer
    #>
    $retval = $false
    $status = Get-AideACMAStatus
    if ($status -eq "Connected") {
        $retval = $true
    }
    return $retval

}

function Get-AideArcServerInfo {
    <#
    .SYNOPSIS
        Returns Arc connection information for Arc-enabled server instance.

    .DESCRIPTION
        This command returns Arc connection information for Arc-enabled server instance from the local IMDS endpoint.

    .OUTPUTS
        Hashtable
        Hashtable with the following keys :Status, Name,ResourceGroupName,SubscriptionId,Location. 

    .EXAMPLE
        Get-AideArcServerInfo

    #>
    $vmInfo = @{}
    $status = Get-AideACMAStatus
    $vmInfo.Add("Status", $status)
    if ($status -eq "Connected") {
        $apiVersion = "2020-06-01"
        $imdsEndpoint = [System.Environment]::GetEnvironmentVariable("IMDS_ENDPOINT","Machine")
        $InstanceUri = $imdsEndpoint + "/metadata/instance?api-version=$apiVersion"
        $Proxy = New-Object System.Net.WebProxy
        $WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $WebSession.Proxy = $Proxy
        $response = (Invoke-RestMethod -Headers @{"Metadata" = "true"} -Method GET -Uri $InstanceUri -WebSession $WebSession) 
        $vmInfo.Add("Name", $response.compute.name)
        $vmInfo.Add("ResourceGroupName", $response.compute.resourceGroupName)
        $vmInfo.Add("SubscriptionId", $response.compute.subscriptionId)
        $vmInfo.Add("Location", $response.compute.location)
    }
    return $vmInfo
}
function Connect-AideArcServer {
    <#
    .SYNOPSIS
        Connects the machine to Azure Arc.

    .DESCRIPTION
        This command installs and connects Azure Arc Connected machine agent to Arc-enabled Server. 
        The inputs required are consumed from the aide-userconfig.json file.

    .OUTPUTS
        Boolean
        True if the connection is successful.

    .EXAMPLE
        Connect-AideArcServer

    #>
    if (Test-IsAzureVM) {
        Write-Host "Disabling WindowsAzureGuestAgent"
        Disable-WindowsAzureGuestAgent
    }
    $status = Get-AideACMAStatus
    if ($status -eq "Connected") {
        Write-Host "ACMA is already connected." -ForegroundColor Green
        return $true
    }
    if ($status -eq "NotInstalled" ) {
        $retval = Install-AideArcServer
        if (!$retval) { return $retval }
    }
    Write-Host "Connecting ConnectedMachine Agent now..."
    $aicfg = Get-AideArcUserConfig
    $creds = Get-AideArcAzureCreds
    if (!$creds) {
        Write-Host "Error: No valid credentials found. Connect not attempted." -ForegroundColor Red
        return $false
    }
    $connectargs = @( "--resource-group", "$($aicfg.ResourceGroupName)",
        "--tenant-id", "$($aicfg.TenantId)",
        "--location", "$($aicfg.Location)",
        "--subscription-id", "$($aicfg.SubscriptionId)",
        "--cloud", "AzureCloud",
        "--service-principal-id", "$($creds.Username)",
        "--service-principal-secret", "$($creds.Password)"
    )
    $tags = @("--tags","SKU=AksEdgeEssentials")
    if (Test-AksEdgeArcConnection) {
        $clustername = Get-AideArcClusterName
        $tags += @("--tags","AKSEE=$clustername")
    }
    $connectargs += $tags
    if ($aicfg.ConnectedMachineName) {
        $connectargs += @("--resource-name","$($aicfg.ConnectedMachineName)")
    }
    $hostSettings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyServer, ProxyEnable
    if ($hostSettings.ProxyEnable) {
        & $azcmagentexe config set proxy.url $($hostSettings.ProxyServer)
    }
    & $azcmagentexe connect @connectargs
    if ($LastExitCode -eq 0) {
        Write-Host "ACMA connected."
    } else {
        Write-Host "Error in connecting to Azure: $LastExitCode" -ForegroundColor Red
        return $false
    }
    return $true
}

function Disconnect-AideArcServer {
    <#
    .SYNOPSIS
        Disconnects the machine from Azure Arc.

    .DESCRIPTION
        This command disconnects from Arc-enabled Server, if connected.
        The inputs required are consumed from the aide-userconfig.json file.

    .OUTPUTS
        Boolean
        True if the disconnection is successful.

    .EXAMPLE
        Disconnect-AideArcServer

    #>
    $status = Get-AideACMAStatus
    if ($status -ne "Connected") {
        Write-Host "ACMA is $status. Nothing to disconnect." -ForegroundColor Green
        return $true
    }
    #check and unregister extensions
    Remove-AideArcServerExtension
    # disconnect
    Write-Host "ACMA state is connected. Disconnecting now..."
    # Get creds
    $creds = Get-AideArcAzureCreds
    if ($creds) {
        $disconnectargs = @(
            "--service-principal-id", "$($creds.Username)",
            "--service-principal-secret", "$($creds.Password)"
        )
        & $azcmagentexe disconnect @disconnectargs
        if ($LastExitCode -eq 0) {
            Write-Host "ACMA disconnected."
            return $true
        } else {
            Write-Host -ForegroundColor red "Error in disconnecting from Azure: $LastExitCode"
        }

    } else {
        Write-Host "Error: No valid credentials found. Disconnect not attempted." -ForegroundColor Red
    }
    return $false
}
function Set-AideArcCmProxy {
    <#
    .SYNOPSIS
        Sets the proxy server settings for the connected machine agent.

    .DESCRIPTION
        Sets the proxy server settings for the connected machine agent, if the agent is installed.

    .OUTPUTS
        None

    .PARAMETER proxyUrl
        This proxy url to set.

    .EXAMPLE
        Set-AideArcCmProxy -proxyUrl "https://myproxy:8080"
    #>
    Param(
        [Parameter(Position = 0, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$proxyUrl
    )
    if (!(Test-Path -Path $azcmagentexe -PathType Leaf)) {
        Write-Host "ACMA is not installed" -ForegroundColor Gray
        return
    }
    & $azcmagentexe config set proxy.url $proxyUrl
}
function Get-AideArcServerSMI {
    <#
    .SYNOPSIS
        Returns the System Managed Identity access token for the Arc-enabled Server instance.

    .DESCRIPTION
        This command the System Managed Identity access token for the Arc-enabled Server instance, queried from the local IMDS end point.

    .OUTPUTS
        String

    .EXAMPLE
        Get-AideArcServerSMI
    #>
    if (!(Test-AideArcServer)) { return $null }
    $token = $null
    $apiVersion = "2020-06-01"
    $resource = "https://management.azure.com/"
    $idEndpoint = [System.Environment]::GetEnvironmentVariable("IDENTITY_ENDPOINT","Machine")
    $endpoint = "{0}?resource={1}&api-version={2}" -f $idEndpoint, $resource, $apiVersion
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
function New-AideArcServerExtension {
    if (!(Test-AideArcServer)) { return }
    $aicfg = Get-AideArcUserConfig
    $protectedsettings = @'
    {
        "fileUris": [ filename.ps1 ]
        "commandToExecute":"powershell.exe -ExecutionPolicy Unrestricted -File filename.ps1 "
    }
'@
    $arciotMachineName = hostname
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

function Remove-AideArcServerExtension {

    if (!(Test-AideArcServer)) { return }
    $aicfg = Get-AideArcUserConfig
    $arciotMachineName = hostname
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
