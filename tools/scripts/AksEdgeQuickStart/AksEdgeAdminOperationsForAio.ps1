<#
  Script for setting up Admin operations for AIO-AKSEE
#>
param(
    [ValidateNotNullOrEmpty()]
    [String] $SubscriptionId,
    [ValidateNotNullOrEmpty()]
    [String] $Location,
    [ValidateNotNullOrEmpty()]
    [String] $ResourceGroupName
)
#Requires -RunAsAdministrator
New-Variable -Name gAksEdgeAdminOperationsForAioVersion -Value "1.0.241118.1500" -Option Constant -ErrorAction SilentlyContinue

# Validate az cli version.
try {
    $azRequiredMinVersion = "2.64.0"
    $azVersion = (az version)[1].Split(":")[1].Split('"')[1]
    if ($azVersion -lt $azRequiredMinVersion){
        Write-Host "Installed Azure CLI version $azVersion is older than $azRequiredMinVersion. Please upgrade Azure CLI and retry." -ForegroundColor Red
        exit -1
    }
}
catch {
    Write-Host "Please install Azure CLI version $azRequiredMinVersion or newer and retry." -ForegroundColor Red
    exit -1
}

# Ensure logged into Azure
$azureLogin = az account show
if ( $null -eq $azureLogin){
    Write-Host "Please login to azure via `az login` and retry." -ForegroundColor Red
    exit -1
}

# Set the azure subscription
Write-Host "Set subscription to $SubscriptionId"
$errOut = $($retVal = & {az account set -s $SubscriptionId}) 2>&1
if ($LASTEXITCODE -ne 0)
{
    throw "Error setting Subscription ($SubscriptionId): $errOut"
}

# Create resource group if needed
Write-Host "Verify/Create resource group $ResourceGroupName"
$errOut = $($rgExists = & {az group show --resource-group $ResourceGroupName}) 2>&1
if ($null -eq $rgExists) {
    Write-Host "Creating resource group: $ResourceGroupName" -ForegroundColor Cyan
    $errOut = $($retVal = & {az group create --location $Location --resource-group $ResourceGroupName --subscription $SubscriptionId}) 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Error creating ResourceGroup ($ResourceGroupName): $errOut"
    }
}

# Register the required resource providers 
Write-Host "Verify/Register the required resource providers" -ForegroundColor Cyan
$resourceProviders = 
@(
    "Microsoft.ExtendedLocation",
    "Microsoft.Kubernetes",
    "Microsoft.KubernetesConfiguration"
)
foreach($rp in $resourceProviders)
{
    $errOut = $($obj = & {az provider show -n $rp | ConvertFrom-Json}) 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Error querying provider $rp : $errOut"
    }

    if ($obj.registrationState -eq "Registered")
    {
        continue
    }

    $errOut = $($retVal = & {az provider register -n $rp}) 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Error registering provider $rp : $errOut"
    }
}

# Get CustomLocationOid
Write-Host "Query CustomLocationOid"
$customLocationsAppId = "bc313c14-388c-4e7d-a58e-70017303ee3b"
$errOut = $($objectId = & {az ad sp show --id $customLocationsAppId --query id -o tsv}) 2>&1
if ($null -eq $objectId)
{
    throw "Error querying ObjectId for CustomLocationsAppId : $errOut"
}
Write-Host "CustomLocationOid - $objectId"