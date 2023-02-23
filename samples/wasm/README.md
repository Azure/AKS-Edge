# Orchestrate WASM workloads using AKS Edge Essentials

## Introduction

This sample demonstrates how to run a WebAssembly (WASM) payload using [containerd-wasm-shim](https://github.com/deislabs/containerd-wasm-shims) inside an AKS Edge Essentials cluster.
**containerd-wasm-shim** only supports Linux nodes; Winodws nodes support is under development.

 _:warning: **WARNING**_: _This sample is experimental only and is not intended for production deployments. **containerd-wasm-shim** is currently in **alpha** version._

## Prerequisites

Check [AKS Edge Essentials requirements and support matrix](https://learn.microsoft.com/azure/aks/hybrid/aks-edge-system-requirements).

## Instructions

1. Setup AKS Edge Essentials - Follow [Set up machine](https://aka.ms/aks-edge/quickstart)
1. Deploy a [Single Machine cluster](https://learn.microsoft.com/azure/aks/hybrid/aks-edge-howto-single-node-deployment) or a [Scalable Cluster](https://learn.microsoft.com/azure/aks/hybrid/aks-edge-howto-multi-node-deployment).
1. Open an elevated PowerShell session
1. Move to an appropriate working directory
1. Download [Set-AksEdgeWasmRuntime.ps1](./Set-AksEdgeWasmRuntimes.ps1)
    ```powershell
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Azure/AKS-Edge/preview/samples/wasm/Set-AksEdgeWasmRuntimes.ps1" -OutFile ".\Set-AksEdgeWasmRuntimes.ps1"
    Unblock-File -Path ".\Set-AksEdgeWasmRuntimes.ps1"
    ```
4. Run the `Set-AksEdgeWasmRuntime` cmdlet to enable the *containerd-wasm-shim*. By default, version **v0.3.3** is used.

    ```powershell
    .\Set-AksEdgeWasmRuntime.ps1 -enable
    ```

   | Parameter | Options | Description | 
   | --------- | ------- | ----------- |
   | enable | None | If this flag is present, the command enables the feature.|
   | shimOption | spin, slight, both | containerd-wasm-shim version. For more information, see https://github.com/deislabs/containerd-wasm-shims |
   | shimVersion | None | containerd-wasm-shim version. For more information, see https://github.com/deislabs/containerd-wasm-shims |
    

5. Apply the *runtime.yaml* to create the *wasmtime-slight* and *wasmtime-spin* rumtime classes.

    ```powershell
    kubectl apply -f https://github.com/deislabs/containerd-wasm-shims/releases/download/v0.3.3/runtime.yaml
    ```
    
    If everything was correctly created, you should see the two runtime classes.

    ```bash
    NAME              HANDLER   AGE
    wasmtime-slight   slight    5s
    wasmtime-spin     spin      5s
    ```

6. Deploy Wasm workloads to your cluster using the *wasmtime-spin* and *wasmtime-slight* runtime classes deployed in the previous step.

    ```powershell
    kubectl apply -f https://raw.githubusercontent.com/Azure/AKS-Edge/preview/samples/wasm/workload.yaml
    ```

7. Check that the pods are deployed and running

    ```powershell
    kubectl get pods -n wasm
    ```

    If everything was correctly configured, you should see four wasm pods running. If pods are not running, use kubectl describe pods <name-of-pod> to get further troubleshooting information.

    ```bash
    NAME                           READY   STATUS    RESTARTS   AGE
    wasm-slight-66849b8575-5l2zv   1/1     Running   0          12s
    wasm-spin-bd6d84876-4bcs5      1/1     Running   0          12s
    wasm-spin-bd6d84876-fpmh2      1/1     Running   0          12s
    wasm-spin-bd6d84876-v8r9j      1/1     Running   0          12s
    ```

8. Get the wasm-spin service IP address and port

    ```powershell
    kubectl get services -n wasm
    ```

    You should see something similar to the following. Check the line "wasm-spin" and get the IP address and port.

    ```bash
    NAME          TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)   AGE
    kubernetes    ClusterIP   10.96.0.1        <none>        443/TCP   7m34s
    wasm-slight   ClusterIP   10.106.231.151   <none>        80/TCP    36s
    wasm-spin     ClusterIP   10.111.233.120   <none>        80/TCP    36s
    ```

9. Finally, check that the wasm Hello World sample is running correctly

    ```powershell
    Invoke-AksEdgeNodeCommand -NodeType Linux -command "curl -v http://<wasm-spin/slight-ip-address>:<wasm-spin/slight-port>/hello"
    ```

    If everything runs correctly, you should see the following output when using Slight.

    ```bash
    hello
    ```

    Or the following when using Spin

    ```bash
    Hello world from Spin!
    ```

## Clean up deployment

Once you're finished with WASM workloads, clean up your workspace by running the following commands.

1. Open an elevated PowerShell session  
1. Delete all resources
    ```powershell
    kubectl delete -f https://raw.githubusercontent.com/Azure/AKS-Edge/preview/samples/wasm/workload.yaml
    kubectl delete -f https://github.com/deislabs/containerd-wasm-shims/releases/download/v0.3.3/runtime.yaml
    .\Set-AksEdgeWasmRuntime.ps1
    ```

## Feedback

If you have problems with this sample, please post an issue in this repository.