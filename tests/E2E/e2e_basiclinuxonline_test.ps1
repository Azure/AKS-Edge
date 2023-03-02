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

    $AideUserConfigObject.Azure.SubscriptionID = "cd80ddb4-f99c-479e-9db2-bc519645d595"
    $AideUserConfigObject.Azure.TenantId = "bb71f4b3-c8c4-47ff-8df8-763e2fdb9ccd"
    $AideUserConfigObject.Azure.ResourceGroupName = "aksedgepreview-rg"
    $AideUserConfigObject.Azure.ServicePrincipalName = "aide-script-testing-sp"
    $AideUserConfigObject.Azure.Auth.ServicePrincipalId = "5421e59d-d027-4d28-a6a6-2d904576c997"
    $AideUserConfigObject.Azure.Auth.Password = "8LO8Q~iWSTgI.rZnfoII.C2mHg4EQuxoqhZY7bE7"
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
    $AideUserConfigObject.Azure.SubscriptionID = "cd80ddb4-f99c-479e-9db2-bc519645d595"
    $AideUserConfigObject.Azure.TenantId = "bb71f4b3-c8c4-47ff-8df8-763e2fdb9ccd"
    $AideUserConfigObject.Azure.ResourceGroupName = "aksedgepreview-rg"
    $AideUserConfigObject.Azure.ServicePrincipalName = "aksedge-test-sp"
    $AideUserConfigObject.Azure.Auth.ServicePrincipalId = "b7a2833e-10e9-4757-9b34-2b672b33dee2"
    $AideUserConfigObject.Azure.Auth.Password = "G0-8Q~0g8eDRteTjmGUVrI_hLdNEiV2BtnAcJaSy"

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