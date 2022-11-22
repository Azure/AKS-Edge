<#
  Sample script to enable WASM workloads with AKS edge
#>
param(
    [string] $shimVersion = "v0.3.0"
    [ValidateSet("spin", "slight")]
    [string] $shimOption = "spin"
)

#Requires -RunAsAdministrator
$k8SOption = $false

$version = (Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' | Get-ItemProperty |  Where-Object {$_.DisplayName -like 'Azure Kubernetes Service Edge Essentials*'}).DisplayName
if ([string]::IsNullOrEmpty($version))
{
    throw $("AKS edge is not installed on this device")
}

if ($version.Contains("K8s"))
{ 
    Write-Host "K8S version being used" -ForegroundColor green
    $k8SOption = $true
}
elseif ($version.Contains("K3s"))
{ 
    Write-Host "K3S version being used" -ForegroundColor green
}
else
{
    throw $("AKS edge verison not supported")
}

Write-Host "Downloading shim verison $shimVersion" -ForegroundColor green
Invoke-AksEdgeNodeCommand "wget -O /home/iotedge-user/containerd-wasm-shim.tar.gz https://github.com/deislabs/containerd-wasm-shims/releases/download/$shimVersion/containerd-wasm-shims-v1-$shimVersion-linux-amd64.tar.gz"

Write-Host "Unpacking and moving shim to appropiate folder" -ForegroundColor green
Invoke-AksEdgeommand "tar -xvf /home/iotedge-user/containerd-wasm-shim.tar.gz && sudo mkdir /var/lib/bin" | Out-Null
Invoke-AksEdgeNodeCommand "sudo mv /home/iotedge-user/containerd-shim-$shimOption-v1 /var/lib/bin/ && sudo rm /home/iotedge-user/containerd-*"  | Out-Null

Write-Host "Configuring containerd to support runwasi runtime" -ForegroundColor green
$command = "echo -e '\n[plugins.cri.containerd.runtimes.$shimOption]\n  runtime_type = \`"io.containerd.$shimOption.v1\`"'  | sudo tee -a /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"
if($k8SOption)
{
    $command =  "echo -e '\n[plugins.\`"io.containerd.grpc.v1.cri\`".containerd.runtimes.$shimOption]\n  runtime_type = \`"io.containerd.$shimOption.v1\`"'  | sudo tee -a /etc/containerd/config.toml"
}
else
{
  Invoke-AksEdgeNodeCommand "sudo cp /var/lib/rancher/k3s/agent/etc/containerd/config.toml /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"  
}
Invoke-AksEdgeNodeCommand -command $command| Out-Null

Write-Host "Adding new runwasi directory to  PATH variable" -ForegroundColor green
$currentPath = Invoke-AksEdgeNodeCommand 'echo $PATH'
$newPath = "PATH=" + $currentPath + ":/var/lib/bin"
Write-Host "Current PATH=$currentPath - New $newPath" -ForegroundColor green

$kubeService = "k3s"
if($k8SOption)
{
    $kubeService = "containerd"
}
Write-Host "Configuring $kubeService service with new configuration" -ForegroundColor green

Invoke-AksEdgeNodeCommand "sudo mkdir /etc/systemd/system/$kubeService.service.d"
$command = "echo -e '[Service]\nEnvironment=\`"$newPath\`"'  | sudo tee -a /etc/systemd/system/$kubeService.service.d/override.conf"
Invoke-AksEdgeNodeCommand -command $command | Out-Null
Invoke-AksEdgeNodeCommand "sudo systemctl daemon-reload"
Invoke-AksEdgeNodeCommand "sudo systemctl restart $kubeService"

Write-Host "Configuration finished - You can now deploy WASM workloads using kubectl interface" -ForegroundColor green