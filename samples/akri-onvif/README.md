# Akri

[Akri](https://docs.akri.sh/) is a CNCF open-source project that allows heterogeneous leaf devices (such as IP cameras, OPCUA devices ) to be exposed as a Kubernetes resource.

It currently supports udev, OPC UA, and ONVIF protocols, but you can also write your own protocol handlers to have your devices be discovered by Akri.

---

## ONVIF Demo

In this demo, you will need an ONVIF camera that is connected to the same network as your cluster. You will then deploy an Akri ONVIF broker to view the camera as a Kubernetes resource and deploy a video streaming app to view the live camera feed in your browser.

> [!IMPORTANT] ONVIF is not supported in the SingleMachineCluster as it is deployed with an internal switch. You will require a deployment with external switch to use this sample.

> [!NOTE]
> The following steps are scripted in [DeployAkriOnvif.ps1](./DeployAkriOnvif.ps1) and [RemoveAkriOnvif.ps1](./RemoveAkriOnvif.ps1).

### Step 1: Make Sure Camera is Running

Make sure your camera is connected to the same network as your cluster and confirm it is working correctly on an [ONVIF Device Manager](https://sourceforge.net/projects/onvifdm/). You should be able to see your camera and live feed there.

### Step 2: Deploy Akri

In your powershell, go to the samples directory by entering `cd <path to samples folder>`. Once you are in the samples directory, run the following commands based on your distribution,  :

```bash
kubectl apply -f akri-onvif\akri-crds.yaml
kubectl apply -f akri-onvif\akri-onvif-kXs.yaml 
kubectl apply -f akri-onvif\akri-streaming.yaml
```

(or) just keep the yaml file corresponding to the kubernetes distribution (remove the other distro file) and apply config at folder level

```bash
kubectl apply -f akri-onvif 
```

This should apply all the YAMLs in the folder, including the akri configurations and the video streaming app.

![akri-onvif-pods](/docs/images/akri-onvif-pods.png)

### Step 3: Allow Linux VM to Discover ONVIF Devices

Make sure you are using `AksEdgePrompt.cmd` located in the `tools` folder. Here, type in `mars` and enter to enter the bash shell of your node.
Once in the bash shell, run:

```bash
sudo iptables -I INPUT -p udp -j ACCEPT
```

Then type, `exit` to go back to your normal PowerShell commandline.

![onvif-discovery-linux](/docs/images/onvif-discovery-linux.png)

### Step 4: Confirm deployment and view ONVIF application

Run the following command to view the camera being discovered. Each entity represents one camera. If you have two cameras running, you should see two resources.

```bash
kubectl get akrii
```

![akri-resources](/docs/images/akri-onvif-resources.png)

Once you've confirmed that Akri is discovering your server(s), you can view monitor the ONVIF outputs by going to `<Node IP>:<Port>` in your browser. You can find the node IP by running `Get-AksEdgeLinuxNodeAddr`, and you can find the service port by running `kubectl get services`.

![akri-svc-node](/docs/images/akri-onvif-svc-port.png)

![akri-app](/docs/images/akri-onvif-app.png)

### Step 5: Clean up ONVIF deployments

Once you're finished with the demo, you can clean up your workspace by running:

```bash
kubectl delete -f akri-onvif
```

(or)

```bash
kubectl delete -f akri-onvif\akri-onvif-kXs.yaml 
kubectl delete -f akri-onvif\akri-streaming.yaml
```

Return to the [deployment guidance homepage](https://aka.ms/aks-edge/quickstart) or the [samples page](/samples/README.md).
