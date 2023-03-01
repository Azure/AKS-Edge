<#
    .SYNOPSIS
        Enables or disables WASM support on AKS Edge Essentials

    .DESCRIPTION
        The Set-AksEdgeWasmRuntime cmdlet enables or disables WASM support inside AKS Edge Essentials Linux node

    .PARAMETER enable
        If this flag is present, the WASM rutime is enabled, otherwise is disabled.
    
    .PARAMETER shimVersion
        containerd-wasm-shim version. For more information, see https://github.com/deislabs/containerd-wasm-shims

    .PARAMETER shimOption
        WASM Engine shim: Spin, Slight, or both. For more information, see https://github.com/deislabs/containerd-wasm-shims

    .EXAMPLE
        Set-AksEdgeWasmRuntime -enable

    .LINK
        https://github.com/Azure/AKS-Edge/tree/wasm-enablement/samples/wasm 
#>

param(
    [Switch] $enable,
    [string] $shimVersion = "v0.4.0",
    [ValidateSet("spin", "slight", "both")]
    [string] $shimOption = "both"
)

Write-Host "1. Checking AKS Edge Essentials dependencies" -ForegroundColor Green
$IsK8s = $false
$productName = (Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' | Get-ItemProperty |  Where-Object {$_.DisplayName -like 'AKS Edge Essentials*'}).DisplayName
if ([string]::IsNullOrEmpty($productName))
{
    Write-Host "AKS Edge Essentials is not installed on this device" -ForegroundColor Red
    exit -1
}

if ($productName.Contains("K8s"))
{ 
    Write-Host "    K8s version found" -ForegroundColor Cyan
    $IsK8s = $true
}
elseif ($productName.Contains("K3s"))
{ 
    Write-Host "    K3s version found" -ForegroundColor Cyan
}
else
{
    Write-Host "AKS Edge Essentials verison not supported" -ForegroundColor Red
    exit -1
}

if ($enable.IsPresent)
{
    Write-Host "2. Downloading shim verison $shimVersion" -ForegroundColor green
    Invoke-AksEdgeNodeCommand "wget -O /home/aksedge-user/containerd-wasm-shim.tar.gz https://github.com/deislabs/containerd-wasm-shims/releases/download/$shimVersion/containerd-wasm-shims-v1-linux-x86_64.tar.gz"

    Write-Host "3. Unpacking and moving shim to appropiate folder" -ForegroundColor green
    Invoke-AksEdgeNodeCommand "tar -xvf /home/aksedge-user/containerd-wasm-shim.tar.gz && sudo mkdir /var/lib/bin" -ignoreError | Out-Null

    if($shimOption -eq "both")
    {
        Invoke-AksEdgeNodeCommand "sudo mv /home/aksedge-user/containerd-shim-spin-v1 /var/lib/bin/ && sudo mv /home/aksedge-user/containerd-shim-slight-v1 /var/lib/bin/ && sudo rm /home/aksedge-user/containerd-*"  | Out-Null
    }
    else
    {
        Invoke-AksEdgeNodeCommand "sudo mv /home/aksedge-user/containerd-shim-$shimOption-v1 /var/lib/bin/ && sudo rm /home/aksedge-user/containerd-*"  | Out-Null
    }

    Write-Host "4. Copying required files" -ForegroundColor green
    if($IsK8s)
    {
        Invoke-AksEdgeNodeCommand -NodeType Linux "sudo cp /etc/containerd/config.toml /home/aksedge-user/config.toml"
    }
    else
    {
        Invoke-AksEdgeNodeCommand -NodeType Linux "sudo cp /var/lib/rancher/k3s/agent/etc/containerd/config.toml /home/aksedge-user/config.toml"
    }

    Invoke-AksEdgeNodeCommand -NodeType Linux "sudo chown -R aksedge-user /home/aksedge-user/config.toml"
    Copy-AksEdgeNodeFile -NodeType Linux -FromFile "/home/aksedge-user/config.toml" -ToFile ".\config.toml"

    Write-Host "5. Configuring containerd config files to support runwasi runtime" -ForegroundColor green
    if($shimOption -eq "both")
    {
        $command = "`n[plugins.cri.containerd.runtimes.spin]`n  runtime_type = ""io.containerd.spin.v1""`n[plugins.cri.containerd.runtimes.slight]`n  runtime_type = ""io.containerd.slight.v1"""
        if($IsK8s)
        {
            $command =  "`n[plugins.""io.containerd.grpc.v1.cri"".containerd.runtimes.slight]`n  runtime_type = ""io.containerd.slight.v1""`n[plugins.""io.containerd.grpc.v1.cri"".containerd.runtimes.spin]`n  runtime_type = ""io.containerd.spin.v1"""
        }
        Add-Content -Path ".\config.toml" $command     
    }
    else
    {
        $command = "`n[plugins.cri.containerd.runtimes.$shimOption]`n  runtime_type = ""io.containerd.$shimOption.v1"""
        if($IsK8s)
        {
            $command =  "`n[plugins.""io.containerd.grpc.v1.cri"".containerd.runtimes.$shimOption]`n  runtime_type = ""io.containerd.$shimOption.v1"""
        }
        Add-Content -Path ".\config.toml" $command  
    }

    Copy-AksEdgeNodeFile -NodeType Linux -FromFile ".\config.toml" -ToFile "/home/aksedge-user/config.toml" -PushFile
    if($IsK8s)
    {
        Invoke-AksEdgeNodeCommand -NodeType Linux "sudo cp /home/aksedge-user/config.toml /etc/containerd/config.toml"   
    }
    else
    {
        Invoke-AksEdgeNodeCommand -NodeType Linux "sudo cp /home/aksedge-user/config.toml /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"
    }

    Write-Host "6. Cleaning unnecessary files" -ForegroundColor green
    Invoke-AksEdgeNodeCommand -NodeType Linux "sudo rm /home/aksedge-user/config.toml"
    Remove-Item -Path ".\config.toml"

    Write-Host "7. Adding new runwasi directory to  PATH variable" -ForegroundColor green
    $currentPath = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    $newPath = "PATH=" + $currentPath + ":/var/lib/bin"
    Write-Host "    Current PATH=$currentPath - New $newPath" -ForegroundColor Cyan
    $kubeService = "k3s"
    if($IsK8s)
    {
        $kubeService = "containerd"
    }

    Write-Host "8. Configuring $kubeService service with new configuration" -ForegroundColor green
    Invoke-AksEdgeNodeCommand -NodeType Linux "sudo cp /etc/systemd/system/$kubeService.service.d/override.conf /home/aksedge-user/override.conf"
    Invoke-AksEdgeNodeCommand -NodeType Linux "sudo chown -R aksedge-user /home/aksedge-user/override.conf"
    Copy-AksEdgeNodeFile -NodeType Linux -FromFile "/home/aksedge-user/override.conf" -ToFile ".\override.conf"
    $command = "Environment=""$newPath"""
    Add-Content -Path ".\override.conf" $command  
    Copy-AksEdgeNodeFile -NodeType Linux -FromFile ".\override.conf" -ToFile "/home/aksedge-user/override.conf" -PushFile
    Invoke-AksEdgeNodeCommand -NodeType Linux "sudo cp /home/aksedge-user/override.conf /etc/systemd/system/$kubeService.service.d/override.conf"

    Write-Host "9. Cleaning unnecessary files" -ForegroundColor green
    Invoke-AksEdgeNodeCommand -NodeType Linux "sudo rm /home/aksedge-user/override.conf"
    Remove-Item -Path ".\override.conf"

    Write-Host "10. Reloading and restarting services" -ForegroundColor green
    Invoke-AksEdgeNodeCommand "sudo systemctl daemon-reload"
    Invoke-AksEdgeNodeCommand "sudo systemctl restart $kubeService"

    Write-Host "11. Configuration finished - You can now deploy WASM workloads using kubectl interface" -ForegroundColor green
}
else
{
    Write-Host "2. Remvoving shims from /var/lib/bin folder" -ForegroundColor green
    if($shimOption -eq "both")
    {
        Invoke-AksEdgeNodeCommand "sudo rm /var/lib/bin/containerd-shim-spin-v1 && sudo rm /var/lib/bin/containerd-shim-slight-v1" -ignoreError | Out-Null
    }
    else
    {
        Invoke-AksEdgeNodeCommand "sudo rm /var/lib/bin/containerd-shim-$shimOption-v1" -ignoreError  | Out-Null
    }

    Write-Host "3. Removing containerd config files to support runwasi runtime" -ForegroundColor green
    if($shimOption -eq "both")
    {
        if($IsK8s)
        {
            Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo sed -i -e '/spin/,+1d' /etc/containerd/config.toml" | Out-Null
            Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo sed -i -e '/slight/,+1d' /etc/containerd/config.toml" | Out-Null
        }
        else
        {
            Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo sed -i -e '/spin/,+1d' /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl" | Out-Null
            Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo sed -i -e '/slight/,+1d' /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl" | Out-Null
        }    
    }
    else
    {
        if($IsK8s)
        {
            Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo sed -i -e '/${shimOption}/,+1d' /etc/containerd/config.toml" | Out-Null
        }
        else
        {
            Invoke-AksEdgeNodeCommand -NodeType "Linux" -command "sudo sed -i -e '/${shimOption}/,+1d' /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl" | Out-Null
        }  
    }

    $kubeService = "k3s"
    if($IsK8s)
    {
        $kubeService = "containerd"
    }

    Write-Host "3. Cleaning PATH environment config file" -ForegroundColor green
    Invoke-AksEdgeNodeCommand -NodeType Linux "sudo sed -i -e '/PATH/d' /etc/systemd/system/$kubeService.service.d/override.conf"

    Write-Host "4. Reloading and restarting services" -ForegroundColor green
    Invoke-AksEdgeNodeCommand "sudo systemctl daemon-reload"
    Invoke-AksEdgeNodeCommand "sudo systemctl restart $kubeService"
}



