#Requires -RunAsAdministrator

$AksEdgeProductUrl = "https://aka.ms/aks-edge/k3s-msi"
function Setup-BasicLinuxNodeOnline {
    param(
        [string]
        $AideUserConfigPath,

        # Test Parameters
        [String]
        $JsonTestParameters,

        [HashTable]
        # Optional parameters from the commandline
        $TestVar
    )

    # Get Aide UserConfig
    $AideUserConfigObject = Get-Content $AideUserConfigPath | ConvertFrom-Json

    # $AideUserConfigObject.AksEdgeProductUrl = $AksEdgeProductUrl

    $AideUserConfigObject.AksEdgeConfigFile = ".\\..\\tools\\aksedge-config.json"

    $AideUserConfigObject.Azure.SubscriptionID = ""
    $AideUserConfigObject.Azure.TenantId = ""
    $AideUserConfigObject.Azure.ResourceGroupName = ""
    $AideUserConfigObject.Azure.ServicePrincipalName = ""
    $AideUserConfigObject.Azure.Auth.ServicePrincipalId = ""
    $AideUserConfigObject.Azure.Auth.Password = ""
    $AideUserConfig = $AideUserConfigObject | ConvertTo-Json
    # Get AksEdge UserConfig
    # $AksEdgeConfig = Get-Content $AideUserConfig.AksEdgeConfigFile | ConvertFrom-Json
    $retval = Start-AideWorkflow -jsonString $AideUserConfig

    if($retval) {
        Write-Host "Deployment Successful"
    } else {
        throw "Deployment Failed"
    }

    $azureConfig = $(Get-AideUserConfig).Azure
    Write-Host $azureConfig

    if ($azureConfig.Auth.ServicePrincipalId -and $azureConfig.Auth.Password -and $azureConfig.TenantId){
        $arcstatus = Initialize-AideArc
        if ($arcstatus) {
            Write-Host ">Connecting to Azure Arc"
            if (Connect-AideArc) {
                Write-Host "Azure Arc connections successful."
            } else {
                throw "Error: Azure Arc connections failed" 
            }
        } else {
            throw "Initializing Azure Arc failed"
        }
    } else { 
        throw "No Auth info available. Skipping Arc Connection" 
    }
}

function Cleanup-BasicLinuxNodeOnline {
    param(
        [string]
        $AideUserConfigPath,

        # Test Parameters
        [String]
        $JsonTestParameters,

        [HashTable]
        # Optional parameters from the commandline
        $TestVar
    )

    $AideUserConfigObject = Get-Content $AideUserConfigPath | ConvertFrom-Json

    $AideUserConfigObject.AksEdgeConfigFile = "\\..\\..\\tools\\aksedge-config.json"
    $AideUserConfigObject.Azure.SubscriptionID = ""
    $AideUserConfigObject.Azure.TenantId = ""
    $AideUserConfigObject.Azure.ResourceGroupName = ""
    $AideUserConfigObject.Azure.ServicePrincipalName = ""
    $AideUserConfigObject.Azure.Auth.ServicePrincipalId = ""
    $AideUserConfigObject.Azure.Auth.Password = ""

    $AideUserConfig = $AideUserConfigObject | ConvertTo-Json
    Set-AideUserConfig -jsonString $AideUserConfig

    Write-Host "Disconnecting from Arc"
    $retval = Disconnect-AideArcServer
    if($retval) {
        Write-Host "Arc Server disconnection successful"
    } else {
        throw "Arc server disconnection failed"
    }

    $retval = Disconnect-AideArcKubernetes
    if($retval) {
        Write-Host "Arc Server disconnection successful"
    } else {
        throw "Arc server disconnection failed"
    }

    $retval = Remove-AideDeployment

    if($retval) {
        Write-Host "Cleanup Successful"
    } else {
        throw "Cleanup Failed"
    }
}

function E2etest-BasicLinuxNodeOnline-TestOnlineClusterScenario {

    param(

        # Test Parameters
        [String]
        $JsonTestParameters,

        [HashTable]
        # Optional parameters from the commandline
        $TestVar
    )

    Write-Host "Running kubectl on node"

    # Assuming the cluster is ready after this is done, let's prove whether it's good or not
    Get-AksEdgeKubeConfig -Confirm:$false

    $output = & 'c:\program files\AksEdge\kubectl\kubectl.exe' get pods -n azure-arc
    Assert-Equal $LastExitCode 0
    Write-Host "kubectl output:`n$output"

    $result = $($output -split '\r?\n' -replace '\s+', ';' | ConvertFrom-Csv -Delimiter ';')
    
    Write-Host "Status of azure-arc related pods"
    foreach ( $POD in $result )
    {
        Write-Host "NAME: $($POD.NAME) STATUS: $($POD.STATUS)"
    }
    foreach ( $POD in $result )
    {
        Assert-Equal $POD.STATUS 'Running'
    }
}
