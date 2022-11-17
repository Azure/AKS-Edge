<#
This script deploys Onvif with Akri
#>
Push-Location $PSScriptRoot
Write-Host "----Script to deploy Akri with Onvif sample----"
Write-Host "Checking cluster type"
$natswitch1 = Get-VMSwitch -Name aksiotsw-int -ErrorAction SilentlyContinue
$natswitch2 = Get-VMSwitch -Name aksiotnatvswitch -ErrorAction SilentlyContinue
if ($natswitch1 -or $natswitch2 ) {
    Write-Host "Error: ONVIF is not supported on SingleMachineCluster deployment. This requires an deployment with external switch." -ForegroundColor Red
    Pop-Location
    return
}

Write-Host "1. Enabling UDP traffic for the linux node."
Write-Host "Warning: All ports opened here. Need to restrict to required ports" -ForegroundColor Yellow
Write-Host ">> sudo iptables -I INPUT -p udp -j ACCEPT" -ForegroundColor Cyan
Invoke-AksLiteLinuxNodeCommand "sudo iptables -I INPUT -p udp -j ACCEPT"
Write-Host ">> sudo iptables-save | sudo tee /etc/systemd/scripts/ip4save" -ForegroundColor Cyan
Invoke-AksLiteLinuxNodeCommand "sudo iptables-save | sudo tee /etc/systemd/scripts/ip4save" | Out-Null


Write-Host "2. Deploying akri with onvif discovery handlers"
Write-Host ">> kubectl apply -f akri-crds.yaml" -ForegroundColor Cyan
kubectl apply -f akri-crds.yaml

$IsK3s = (kubectl get nodes) | Where-Object { $_ -match "k3s"}
if ($IsK3s) {
    Write-Host ">> kubectl apply -f akri-onvif-k3s.yaml" -ForegroundColor Cyan
    kubectl apply -f akri-onvif-k3s.yaml
} else {
    Write-Host ">> kubectl apply -f akri-onvif-k8s.yaml" -ForegroundColor Cyan
    kubectl apply -f akri-onvif-k8s.yaml
}

Write-Host "3. Checking status of the akri configuration and instance"
Write-Host ">> kubectl get akric,akrii" -ForegroundColor Cyan
kubectl get akric,akrii

Write-Host "4. Deploying video streaming service"
Write-Host ">> kubectl apply -f akri-streaming.yaml" -ForegroundColor Cyan
kubectl apply -f akri-streaming.yaml

Write-Host "5. Checking status of the services"
Write-Host ">> kubectl get services" -ForegroundColor Cyan
kubectl get services
$status = (kubectl get services) | Where-Object { $_ -match "akri-video-streaming-app" }
if ($status) {
    $portno = ($status | Select-String ":(\d+)/").Matches.Groups[1].Value
    $nodeip = (Get-AksLiteLinuxNodeAddr)[1]
    $url = "http:\\$($nodeip):$portno"
    Write-Host ">> Launching browser for url : $url"
    Start-Process $url
} else {
    Write-Host "Error: akri-video-streaming-app not found." -ForegroundColor Red
}
Pop-Location