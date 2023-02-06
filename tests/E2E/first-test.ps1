#Requires -RunAsAdministrator

function CreateAksEdgeCluster {

    param (
        [string]$AideModulePath,
        [string]$AideUserConfigPath
    )

    $modulePath = Split-Path -Path $((Get-ChildItem $AideModulePath -recurse -Filter AksEdgeDeploy).FullName) -Parent
    if (!(($env:PSModulePath).Contains($modulePath))) {
        $env:PSModulePath = "$modulePath;$env:PSModulePath"
    }

    Write-Host "Loading AksEdgeDeploy module from $modulePath.." -ForegroundColor Cyan
    Import-Module AksEdgeDeploy.psd1 -Force

    $retval = Start-AideWorkflow -jsonFile $AideUserConfigPath

    if($retval) {
        Write-Host "Deployment Successful"
    } else {
        throw ("Deployment Failed")
    }


    $azureConfig = Get-AideUserConfig.Azure

    if ($azureConfig.Auth.ServicePrincipalId -and $azureConfig.Auth.Password -and $azureConfig.TenantId){
        # we have ServicePrincipalId, Password and TenantId
        $retval = Enter-AideArcSession
        if (!$retval) {
            throw ("Azure login failed.")
        }
        # Arc for Servers
        Write-Host "Connecting to Azure Arc"
        $retval = Connect-AideArc
        Exit-AideArcSession
        if ($retval) {
            Write-Host "Arc connection successful. "
        } else {
            throw ("Arc connection failed")
        }
    } else { 
        throw ("No Auth info available. Skipping Arc Connection") 
    }

}

CreateAksEdgeCluster -AideModulePath $PSScriptRoot\..\.. -AideUserConfigPath $PSScriptRoot\..\..\tools\aide-userconfig.json

