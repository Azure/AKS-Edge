# Orchestrate WASM workloads using AKS Edge

## Introduction

This sample demonstrates how to run a WebAssembly (WASM) payload using [spin-containerd-wasm-shim](https://github.com/deislabs/containerd-wasm-shims) inside the AKS Edge cluster. **containerd-wasm-shim** is currently in _alpha_ version and is not intended for production deployments.

## Prerequisites

Check [AKS Edge Essentials requirements and support matrix](https://learn.microsoft.com/en-us/azure/aks/hybrid/aks-edge-system-requirements).

## Instructions

1. Setup AKS Edge Essentials - Follow [Set up machine](https://aka.ms/aks-edge/quickstart)
2. Open an elevated PowerShell session
3. Download and load [Enable-AksEdgeWasmWorkload.ps1](./Enable-AksEdgeWasmWorkloads.ps1)
4. Run the `Enable-AksEdgeWasmWorkload` cmdlet to enable the *containerd-wasm-shim*. By default version **v0.3.3** is used.

    ```powershell
    .\Enable-AksEdgeWasmWorkloads.ps1
    ```

5. Apply a runtime class that contains a handler that matches the "spin" config runtime name from previous step.

    ```powershell
    kubectl apply -f https://github.com/deislabs/containerd-wasm-shims/releases/download/v0.3.3/runtime.yaml
    ```

6. Deploy a Wasm workload to your cluster with the specified runtime class name matching the "wasmtime-spin" runtime class from previous step.

    ```powershell
    kubectl apply -f https://raw.githubusercontent.com/fcabrera23/AKS-Edge/wasm-enablement/samples/wasm/workload.yaml
    ```

7. Check that the pods are deployed and running

    ```powershell
    kubectl get pods
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
    kubectl get services
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

    If everything is running correctly, you should see the following output when using Slight

    ```bash
    hello
    ```

    Or the following when using Spin

    ```bash
    Hello world from Spin!
    ```

## Feedback

If you have problems with this sample, please post an issue in this repository.