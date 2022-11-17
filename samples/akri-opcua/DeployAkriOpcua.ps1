<#
This script deploys OpcUA with Akri
#>
Push-Location $PSScriptRoot
Write-Host "----Script to deploy Akri with OpcUA sample----"
$ipv4 = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.AddressState -eq "Preferred" -and $_.ValidLifetime -lt "24:00:00"}).IPAddress | Select-Object -First 1
Write-Host "1. Run the OPC UA Server simulator"
$opcuaconfigXml = "$PSScriptRoot\..\opcua-server\Quickstarts.ReferenceServer.config.xml"
#patch the ip address
(Get-Content -Path $opcuaconfigXml) -replace "0.0.0.0",$ipv4 | Out-File $opcuaconfigXml -Encoding utf8

Push-Location "$PSScriptRoot\..\opcua-server"
Start-Process -FilePath ".\ConsoleReferenceServer.exe"
Pop-Location

Write-Host "2. Deploying akri with OpcUA discovery handlers"
Write-Host ">> kubectl apply -f $PSScriptRoot\..\akri-onvif\akri-crds.yaml" -ForegroundColor Cyan
kubectl apply -f "$PSScriptRoot\..\akri-onvif\akri-crds.yaml"
$IsK3s = (kubectl get nodes) | Where-Object { $_ -match "k3s"}
if ($IsK3s) {
    $akriconfigXml = "$PSScriptRoot\akri-opcua-config-k3s.yaml"
} else {
    $akriconfigXml = "$PSScriptRoot\akri-opcua-config-k8s.yaml"
}
#patch the ip address
(Get-Content -Path $akriconfigXml) -replace "0.0.0.0",$ipv4 | Out-File $akriconfigXml -Encoding utf8
Write-Host ">> kubectl apply -f $akriconfigXml" -ForegroundColor Cyan
kubectl apply -f $akriconfigXml

Write-Host "3. Deploying anomaly detection service"
Write-Host ">> kubectl apply -f akri-anomaly-detection-app.yml" -ForegroundColor Cyan
kubectl apply -f akri-anomaly-detection-app.yml

Write-Host "4. Checking status of the services"
Write-Host ">> kubectl get services" -ForegroundColor Cyan
kubectl get services
$status = (kubectl get services) | Where-Object { $_ -match "akri-anomaly-detection-app" }
if ($status) {
    $portno = ($status | Select-String ":(\d+)/").Matches.Groups[1].Value
    $nodeip = (Get-AksEdgeLinuxNodeAddr)[1]
    $url = "http:\\$($nodeip):$portno"
    Write-Host ">> Launching browser for url : $url"
    Start-Process $url
} else {
    Write-Host "Error: akri-anomaly-detection-app not found." -ForegroundColor Red
}
Pop-Location