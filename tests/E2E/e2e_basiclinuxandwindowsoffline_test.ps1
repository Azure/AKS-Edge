
Import-Module "$PSScriptRoot\utils.ps1"

function Setup-BasicLinuxAndWindowsNodeOffline {
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

function Cleanup-BasicLinuxAndWindowsNodeOffline {
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

function E2etest-BasicLinuxAndWindowsNodeOffline-TestOfflineClusterNodesReady {
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

function E2etest-BasicLinuxAndWindowsNodeOffline-TestOfflineClusterPodsReady
{
    param
    (
        [String]
        # Test Parameter
        $JsonTestParameters,

        [HashTable]
        # Optional parameters from the commandline
        $TestVar
    )

    Write-Host "Running kubectl"

    Get-AksEdgeKubeConfig -Confirm:$false
    $kubectloutput = & 'c:\program files\AksEdge\kubectl\kubectl.exe' get pods --all-namespaces
    $result = $($kubectloutput -split '\r?\n' -replace '\s+', ';' | ConvertFrom-Csv -Delimiter ';')
    Write-Host "`n Kube pods output: $kubectloutput"

    Write-Host "Kubernetes pods STATUS:"
    foreach ( $POD in $result )
    {
        Write-Host "NAME: $($POD.NAME) READY: $($POD.READY) STATUS: $($POD.STATUS)"
    }

    # Verify if we get any pods output from kubectl
    $condition = [string]::IsNullOrEmpty($result.NAME)
    Assert-Equal $condition $false

    foreach ( $POD in $result )
    {
        # Verify if all the pods are Ready
        $ReadyValues = $POD.READY.Split("/")
        Assert-Equal $ReadyValues[0] $ReadyValues[1]
    }
}

function E2eTest-BasicLinuxAndWindowsNodeOffline-WindowsVmIp4Address
{
    param
    (
        [String]
        # Test Parameter
        $JsonTestParameters,

        [HashTable]
        # Optional parameters from the commandline
        $TestVar
    )
    $windowsVmIp = Get-WindowsVmIpAddress

    $output = Invoke-WindowsSSH "powershell.exe -command `"(Get-NetIPAddress).IpAddress`""
    $result = $output.Contains($windowsVmIp)
    Assert-Equal $result $True
    Write-Host "VM IPV4 ip address is: `n$windowsVmIp"
}


