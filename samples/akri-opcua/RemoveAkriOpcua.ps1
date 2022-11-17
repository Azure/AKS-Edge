<#
This script removes deployed OpcUA with Akri
#>
Push-Location $PSScriptRoot
Write-Host "----Script to Remove Akri with OpcUA sample----"
$ipv4 = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.AddressState -eq "Preferred" -and $_.ValidLifetime -lt "24:00:00"}).IPAddress | Select-Object -First 1
Write-Host "1. Reset config files"
$opcuaconfigXml = "$PSScriptRoot\..\opcua-server\Quickstarts.ReferenceServer.config.xml"
#patch the ip address
(Get-Content -Path $opcuaconfigXml) -replace $ipv4,"0.0.0.0" | Out-File $opcuaconfigXml -Encoding utf8

Write-Host "2. Delete deployments"
Stop-Process -Name "ConsoleReferenceServer" -ErrorAction SilentlyContinue
$IsK3s = (kubectl get nodes) | Where-Object { $_ -match "k3s"}
if ($IsK3s) {
    $akriconfigXml = "$PSScriptRoot\akri-opcua-config-k3s.yaml"
} else {
    $akriconfigXml = "$PSScriptRoot\akri-opcua-config-k8s.yaml"
}
#patch the ip address
(Get-Content -Path $akriconfigXml) -replace $ipv4,"0.0.0.0" | Out-File $akriconfigXml -Encoding utf8
Write-Host ">> kubectl delete -f $akriconfigXml" -ForegroundColor Cyan
kubectl delete -f $akriconfigXml

Write-Host "3. Delete anomaly detection service"
Write-Host ">> kubectl delete -f akri-anomaly-detection-app.yml" -ForegroundColor Cyan
kubectl delete -f akri-anomaly-detection-app.yml
Pop-Location