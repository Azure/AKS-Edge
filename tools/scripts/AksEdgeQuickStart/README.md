# AksEdge Quick Start

AksEdgeQuickStart enables you to quickly bootstrap your machine with installation and deployment of AKS Edge Essentials, setup your Azure portal with the required configurations and use the credentials created in the setup to connect your machine to Arc for Servers and the cluster to Arc for Connected Kubernetes.

## Prerequisites

- See the [Microsoft Software License Terms](https://learn.microsoft.com/azure/aks/hybrid/aks-edge-software-license-terms) as they apply to your use of the software. By using the AksEdgeQuickStart script, you accept the Microsoft Software License Terms and the `AcceptEULA` flag is set to `true` indicating acceptance
- Check your machine for this default system requirements
  - Free Memory : 4.5GB (as the Linux VM is configured for 4GB)
  - Free Storage : 20GB
  - vCPUs Available : 4 vCPUs
  - The above are defined in the json file as defaults. You can change them to your desired values. See [System requirements](https://learn.microsoft.com/azure/aks/hybrid/aks-edge-system-requirements) for the minimum requirements.

- Get the following information ready:
  - Your Subscription ID `<subscription-id>`: In the Azure portal, select the subscription you're using and look for the subscription ID (GUID)
  - Your Tenant ID `<tenant-id>`: In the Azure portal, search Azure Active Directory, which should take you to the Default Directory page. Look for the tenant ID (GUID).
  - The Location (Azure region) `<location>`:  where you want your resources to be created, see [Azure Arc by Region](https://azure.microsoft.com/explore/global-infrastructure/products-by-region/?products=azure-arc) for the Locations supported by `Azure Arc enabled servers` and `Azure Arc enabled Kubernetes` services. Choose a region where both are supported.

## Run the script

- Download the [AksEdgeQuickStart.ps1](https://raw.githubusercontent.com/Azure/AKS-Edge/main/tools/scripts/AksEdgeQuickStart/AksEdgeQuickStart.ps1), **right-click** and **save link as** to a working folder.
- Open an elevated powershell prompt and change directory to your working folder.
- Depending on the policy setup on your machine, you may require to unblock the file before running.

    ```powershell
    Unblock-File .\AksEdgeQuickStart.ps1
    ```

- Run the script with required parameters

    ```powershell
    .\AksEdgeQuickStart.ps1 -SubscriptionId "<subscription-id>" -TenantId "<tenant-id>" -Location "<location>"
    ```

    For installing the K8s version, use

    ```powershell
    .\AksEdgeQuickStart.ps1 -SubscriptionId "<subscription-id>" -TenantId "<tenant-id>" -Location "<location>" -UseK8s
    ```

    By default, the main branch of the Azure/AKS-Edge repo is used. However, if you need to specify a specific release tag, you can do so

    ```powershell
    .\AksEdgeQuickStart.ps1 -SubscriptionId "<subscription-id>" -TenantId "<tenant-id>" -Location "<location>" -Tag "1.0.406.0"
    ```

    Alternate format of invocation

    ```powershell
    $parameters = @{
        SubscriptionId = "<subscription-id>"
        TenantId = "<tenant-id>"
        Location = "<location>"
        UseK8s = $false
        Tag = ""
    }
    .\AksEdgeQuickStart.ps1 @parameters
    ```

## What does this script do?

1. In the working folder, the script downloads the Github archive [Azure/AKS-Edge](https://github.com/Azure/AKS-Edge) and unzips to a folder `AKS-Edge-main` (or `AKS-Edge-<tag>`). By default this downloads the current main branch.
2. Populates the aide-userconfig.json and aksedge-config.json with the contents present in the script.( `herestrings $aideuserConfig and $aksedgeConfig` ) and invokes the `AksEdgeShell` prompt.
3. Invokes `AksEdgeAzureSetup.ps1` script to configure the Azure subscription and create the required service principal. See [AksEdgeAzureSetup](../AksEdgeAzureSetup/README.md) for more details on the Azure setup.

    ```powershell
    .\AksEdgeAzureSetup.ps1 -jsonFile $aidejson -spContributorRole -spCredReset
    ```

   - Note that this will prompt for an interactive login session to create the required resource group, service principal account in the azure subscription.

4. Downloads the AKS Edge Essentials MSI, installs it and deploys `SingleMachineCluster` using the `Start-AideWorkflow` function.
   - This function invokes `Install-AksEdgeHostFeatures` that installs all the required OS features and policy settings on the host machine. A restart will be triggered when the Hyper-V feature is enabled and when this occurs, the script needs to be re-run to continue further.
5. Finally, using the Azure credentials created in step 2, the host machine and the cluster are connected to Arc using `Connect-AideArc` function.
   - Note that the required Az Powershell modules and the required `helm` binary are installed using `Initialise-AideArc` function.
