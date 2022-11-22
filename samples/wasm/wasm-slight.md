# Interop Windows Console App with AKS edge Linux container

## Introduction
This sample demonstrates how to run a WebAssembly (WASM) payload using [slight-containerd-wasm-shim](https://github.com/deislabs/containerd-wasm-shims) inside the AKS edge cluster. **slight-containerd-wasm-shim** is currently in _alpha_ version and is not intended for production deployments. 

## Prerequisites
A Windows device with the following minimum requirements:
* System Requirements
   * Windows 10¹/11 (Pro, Enterprise, IoT Enterprise)
   * Windows Server 2019¹/2022  
   <sub>¹ Windows 10 and Windows Server 2019 minimum build 17763 with all current cumulative updates installed.</sub>
* Hardware requirements
  * Memory: 4 GB at least 2 GB free (cluster-only), 8 GB at least 4 GB free (Arc and GitOps)
  * CPU: Two logical processors, clock speed at least 1.8 GHz
  * Storage: At least 17 GB free after installing MSI

## Instructions
1. Setup Azure Kubernetes Service Edge Essentials (AKS edge) - Follow [this guide](/docs/AKS-Lite-Deployment-Guidance.md) 
1. Open an elevated PowerShell session
1. Download and load [Enable-AksLiteWasmWorkload.ps1](./Enable-AksLiteWasmWorkloads.ps1)
1. Run the `Enable-AksLiteWasmWorkload` cmdlet for **slight** shim. For a specific shim version, use the `-shimVersion` parameter. By default version **v0.3.0** is used.
    ```powershell
    .\Enable-AksLiteWasmWorkloads.ps1 -shimOption "slight"
    ```
1. Apply a runtime class that contains a handler that matches the "slight" config runtime name from previous step.
    ```powershell
    kubectl apply -f https://github.com/deislabs/containerd-wasm-shims/releases/download/v0.3.0/slight_runtime.yaml
    ```
1. Deploy a Wasm workload to your cluster with the specified runtime class name matching the "wasmtime-slight" runtime class from previous step.
    ```powershell
    kubectl apply -f https://github.com/deislabs/containerd-wasm-shims/releases/download/v0.3.0/slight_workload.yaml
    ```
1. Check that the pods are deployed and running
    ```powershell
    kubectl get pods
    ```
    If everything was correctly configured, you should see three wasm pods running. If pods are not running, use kubectl describe pods <name-of-pod> to get further troubleshooting information.

    ```bash
    NAME                        READY   STATUS    RESTARTS   AGE
    wasm-slight-cf6589674-l66pm   1/1     Running   0          6s
    wasm-slight-cf6589674-mmlgf   1/1     Running   0          6s
    wasm-slight-cf6589674-zm6pf   1/1     Running   0          6s
    ```
1. Get the wasm-slight service IP address and port
    ```powershell
    kubectl get services
    ```
    You should see something similar to the following. Check the line "wasm-slight" and get the IP address and port.

    ```bash
    NAME         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
    kubernetes   ClusterIP   10.43.0.1       <none>        443/TCP   13h
    wasm-slight    ClusterIP   10.43.176.163   <none>        80/TCP    12h
    ```
1. Finally, check that the wasm Hello World sample is running correctly
    ```powershell
    Invoke-AksLiteLinuxNodeCommand "curl -v http://<wasm-slight-ip-address>:<wasm-slight-port>/hello"
    ```
    If everything is running correctly, you should see the following output
    ```bash
    hello
    ```

## Feedback
If you have problems with this sample, please post an issue in this repository.