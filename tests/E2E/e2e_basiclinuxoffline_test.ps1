#Requires -RunAsAdministrator

$AksEdgeProductUrl = "https://aka.ms/aks-edge/k3s-msi"
function Setup-BasicLinuxNodeOffline {
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

    $AideUserConfigObject.AksEdgeProductUrl = $AksEdgeProductUrl

    $AideUserConfig = $AideUserConfigObject | ConvertTo-Json

    $retval = Start-AideWorkflow -jsonString $AideUserConfig

    if($retval) {
        Write-Host "Deployment Successful"
    } else {
        throw "Deployment Failed"
    }
}

function Cleanup-BasicLinuxNodeOffline {
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

    $retval = Remove-AideDeployment

    if($retval) {
        Write-Host "Cleanup Successful"
    } else {
        throw "Cleanup Failed"
    }
}

function E2etest-BasicLinuxNodeOffline-TestOfflineClusterScenario {

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

    $output = & 'c:\program files\AksEdge\kubectl\kubectl.exe' get nodes
    Assert-Equal $LastExitCode 0
    Write-Host "kubectl output:`n$output"

    $result = $($output -split '\r?\n' -replace '\s+', ';' | ConvertFrom-Csv -Delimiter ';')
    
    Write-Host "Kubernetes nodes STATUS:"
    foreach ( $NODE in $result )
    {
        Write-Host "NAME: $($NODE.NAME) STATUS: $($NODE.STATUS)"
    }
    foreach ( $NODE in $result )
    {
        Assert-Equal $NODE.STATUS 'Ready'
    }
}
