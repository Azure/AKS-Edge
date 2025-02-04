# Copyright (c) Microsoft Corporation. All rights reserved.

<#
 This script updates the AKS Edge Essential K3s configuration to set the lifespan of a Service Account token to 24 hours. 
 This only needs to be run once prior to install the KeyManaget extension for the first time.
#>


<#
A wrapper around Invoke-AksEdgeNodeCommand to throw an exception if an error occurs. 
#>
function Invoke-AksEdgeNodeCmd
{
    param(
        [ValidateNotNullOrEmpty()]        
        [string] $command,
        [switch] $ignoreError = $false,
        [string] $NodeType = "Linux"
    )
    
    $response = Invoke-AksEdgeNodeCommand $command -ignoreError:$ignoreError -NodeType $NodeType
    if ($LASTEXITCODE -eq 0)
    {
        return $response
    }
    throw "Invoke-AksEdgeNodeCommand `"$command`" failed."

}


$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$VerbosePreference = [System.Management.Automation.ActionPreference]::Continue


Write-Verbose "Updating k3s-config.yml"
Invoke-AksEdgeNodeCmd -command "sudo sed -i '/kube-apiserver-arg:/a\  - service-account-max-token-expiration=24h00m0s\' /home/aksedge-user/k3s-config.yml"   
Invoke-AksEdgeNodeCmd -command "sudo sed -i '/kube-apiserver-arg:/a\  - service-account-extend-token-expiration=false\' /home/aksedge-user/k3s-config.yml"   
Invoke-AksEdgeNodeCmd -command "sudo cp /home/aksedge-user/k3s-config.yml /var/.eflow/config/k3s/k3s-config.yml"   

Write-Verbose "Restarting k3 service with updated configuration"
Invoke-AksEdgeNodeCmd -command "sudo systemctl daemon-reload" 
Invoke-AksEdgeNodeCmd -command "sudo systemctl restart k3s.service" 

Write-Verbose "Successfully restarted k3 service with updated configuration"

