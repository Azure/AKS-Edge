<#
This script removes Onvif with Akri
#>
Push-Location $PSScriptRoot
Write-Host "----Script to remove Akri with Onvif sample----"
Write-Host "Checking cluster type"
$natswitch1 = Get-VMSwitch -Name aksiotsw-int -ErrorAction SilentlyContinue
$natswitch2 = Get-VMSwitch -Name aksiotnatvswitch -ErrorAction SilentlyContinue
if ($natswitch1 -or $natswitch2 ) {
    Write-Host "Error: ONVIF is not supported on SingleMachineCluster deployment. This requires an deployment with external switch." -ForegroundColor Red
    Pop-Location
    return
}

Write-Host "1. Disabling UDP traffic for the linux node."
Write-Host "Warning: All ports of UDP closed here. Need to restrict to required ports" -ForegroundColor Yellow
Write-Host ">> sudo iptables -D INPUT -p udp -j ACCEPT" -ForegroundColor Cyan
Invoke-AksEdgeLinuxNodeCommand "sudo iptables -D INPUT -p udp -j ACCEPT"
Write-Host ">> sudo iptables-save | sudo tee /etc/systemd/scripts/ip4save" -ForegroundColor Cyan
Invoke-AksEdgeLinuxNodeCommand "sudo iptables-save | sudo tee /etc/systemd/scripts/ip4save" | Out-Null

Write-Host "2. Delete deployment of akri with onvif discovery handlers"
$IsK3s = (kubectl get nodes) | Where-Object { $_ -match "k3s"}
if ($IsK3s) {
    Write-Host ">> kubectl delete -f akri-onvif-k3s.yaml" -ForegroundColor Cyan
    kubectl delete -f akri-onvif-k3s.yaml
} else {
    Write-Host ">> kubectl delete -f akri-onvif-k8s.yaml" -ForegroundColor Cyan
    kubectl delete -f akri-onvif-k8s.yaml
}

Write-Host "3. Delete deployment of video streaming service"
Write-Host ">> kubectl delete -f akri-streaming.yaml" -ForegroundColor Cyan
kubectl delete -f akri-streaming.yaml
Pop-Location