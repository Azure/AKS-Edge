# AKS Edge Essentials Arc Connection

The following functions enables you to install and use `Arc enabled Servers` and `Arc enabled Kubernetes` easily on a windows IoT device.

## Usage

1. Populate the *aide-userconfig.json* with the desired values.
2. Run the script `AksEdgeAzureSetup.ps1` in the `tools\scripts` directory to setup your Azure subscription, create the resource group, setup the required extensions and also create the service principal with minimal privileges(`Azure Connected Machine Onboarding`,`Kubernetes Cluster - Azure Arc Onboarding`). You will need to login for Azure CLI interactively for the first time to create the service principal. This step is required to be run only once per subscription.

   ```powershell
   # prompts for interactive login for serviceprincipal creation with minimal privileges
   ..\tools\scripts\AksEdgeAzureSetup.ps1 .\aide-userconfig.json
   ```

    If you require to create the service principal with `Contributor` role at the resource group level, you can add the `-spContributorRole` switch. You will require the Contributor role if you need to disconnect your kubernetes cluster using `Disconnect-ArcEdgeK8s`.
    To, reset an already existing service principal, use `-spCredReset`. Reset should be used cautiously.

   ```powershell
   # creates service principal with Contributor role at resource group level
   ..\tools\scripts\AksEdgeAzureSetup.ps1 .\aide-userconfig.json -spContributorRole
   ```

   ```powershell
   # resets the existing service principal
   ..\tools\scripts\AksEdgeAzureSetup.ps1 .\aide-userconfig.json -spCredReset
   ```

    ```powershell
   # you can test the creds with 
   ..\tools\scripts\AksEdgeAzureSetup-Test.ps1 .\aide-userconfig.json
   ```

3. Import the AksEdgeDeploy module and set the user config.
4. Run `Initialize-ArcEdge` to install the required software (Azure CLI) and validates that Azure setup is good.
5. `Connect-ArcEdgeCmAgent` to connect your machine to Arc for Servers.
6. After installing AKS edge or any kuberenetes cluster in your Linux VM, verify with `kubectl get nodes` and then call `Connect-ArcEdgeK8s`

```powershell
# installs AzCLI 
Initialize-ArcEdge
# Connects the Win IoT machine to Arc for Servers
Connect-ArcEdgeCmAgent
# Prereq: install AKS edge and deploy cluster
# test the cluster is good
kubectl get nodes
# Connect the cluster to Arc for Kubernetes
Connect-ArcEdgeK8s
```

## Supported Functions

| Functions |   Description |
|:------------ |:-----------|
|`Initialize-ArcEdge`| Main funtion that checks and installs required software, validates if the Auth parameters are good for Azure login  |
|`Install-ArcEdgeAzCLI` | Installs Azure CLI |
|`Enter-ArcEdgeSession`| Logs in to Azure using the service principal credentials|
|`Exit-ArcEdgeSession`| Logs out from the Azure CLI session|
| **Arc for Server Functions** |  |
|`Install-ArcEdgeCmAgent`| Installs Azure Connected Machine Agent |
|`Test-ArcEdgeCmAgent`| Tests ConnectedMachine Agent status (returns true if connected) |
|`Connect-ArcEdgeCmAgent`| Connects the machine to Arc for Servers |
|`Disconnect-ArcEdgeCmAgent`| Removes the Arc for Servers connection |
|`Get-ArcEdgeCmInfo`| Returns the HIMDS info (name,subscriptionid,resourcegroupname and location) from Connected machine agent |
|`Get-ArcEdgeMIAccessToken`| Retrieves the system assigned managed identity for Arc for Server|
|**Arc for Kubernetes Functions** ||
|`Test-ArcEdgeK8sConnection`| Tests if the K8s cluster is connected to Arc |
|`Connect-ArcEdgeK8s`| Connects the K8s cluster to Arc using the default kubeconfig files |
|`Disconnect-ArcEdgeK8s`| Deletes the K8s cluster resource in Arc |
|`Get-ArcEdgeK8sServiceToken`| Retrieves the service token for admin-user in the K8s cluster |
|`Get-ArcEdgeClusterName`| Retrieves the cluster name used for Arc connection |
