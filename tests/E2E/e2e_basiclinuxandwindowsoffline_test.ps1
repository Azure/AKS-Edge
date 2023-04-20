function Setup-BasicLinuxAndWindowsNode {
    param(
        # Test Parameters
        [String]
        $JsonTestParameters,

        [HashTable]
        # Optional parameters from the commandline
        $TestVar
    )

    # Get Aide UserConfig

    $retval = Start-AideWorkflow -jsonString $JsonTestParameters

    if($retval) {
        Write-Host "Deployment Successful"
    } else {
        throw "Deployment Failed"
    }
}

function Cleanup-BasicLinuxAndWindowsNode {
    param(
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
