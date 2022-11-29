# Akri

[Akri](https://docs.akri.sh/) is a CNCF open-source project that allows heterogeneous leaf devices (such as IP cameras, OPCUA devices ) to be exposed as a Kubernetes resource.

It currently supports udev, OPC UA, and ONVIF protocols, but you can also write your own protocol handlers to have your devices be discovered by Akri.

---

## OPC UA Demo

In this demo, you will run an OPC UA server that outputs temperature values from a simulated thermometer. You will then deploy an Akri OPC UA broker to view the server as a Kubernetes resource and deploy an anomaly detection app to monitor the values of the temperature in your browser.

> [!NOTE]
> The following steps are scripted in [DeployAkriOpcua.ps1](./DeployAkriOpcua.ps1) and [RemoveAkriOpcua.ps1](./RemoveAkriOpcua.ps1).

### Step 1: Run the OPC UA Server

In the samples folder, go to the OPC UA Server folder. From there, open `QuickstartsReferenceServer.Config.xml`.

Navigate to lines `77-78`. In the base addresses, replace the `0.0.0.0` with your local host IP. You can find this IP if you go to Powershell and run `ipconfig`. Save and close the file.

Now double click on `ConsoleReferenceServer.exe` to run the OPC UA server.

![opcua-server](/docs/images/opcua-server.png)

### Step 2: Configure Akri

Now navigate to the `akri-opcua` folder in the samples. Open `akri-opcua-config.yaml`.

Go to line 219 and replace the `0.0.0.0` address with the same local host IP addresses from the step above. Save and close.

### Step 3: Deploy Akri

In your powershell, go to the samples directory by entering `cd <path to samples folder>`. Once you are in the samples directory, run the following commands based on your distribution,  :

```bash
kubectl apply -f akri-onvif\akri-crds.yaml
kubectl apply -f akri-opcua\akri-opcua-kXs.yaml 
kubectl apply -f akri-opcua\akri-anomaly-detection-app.yml
```

(or) just keep the yaml file corresponding to the kubernetes distribution (remove the other distro file) and apply config at folder level

```bash
kubectl apply -f akri-onvif\akri-crds.yaml
kubectl apply -f akri-opcua
```

This should apply all the YAMLs in the folder, including the akri configurations and the anomaly detection app.

![akri-opcua-pods](/docs/images/akri-pods.png)

### Step 4: Confirm deployment and view application

Run the following command to view the OPC UA server being discovered. Each entity represents one server. If you have two servers running, you should see two resources.

```bash
kubectl get akric
kubectl get akrii
```

![akri-resources](/docs/images/akri-resources.png)

Once you've confirmed that Akri is discovering your server(s), you can view monitor the OPC UA outputs by going to `<Node IP>:<Port>` in your browser. You can find the node IP by running `Get-AksEdgeNodeAddr`, and you can find the service port by running `kubectl get services`.

![akri-svc-node](/docs/images/akri-svc-port.png)

![akri-app](/docs/images/akri-app.png)

Once you've confirmed that Akri is discovering your server(s), you can view monitor the OPC UA outputs by going to `<Node IP>:<Port>` in your browser. You can find the node IP by running `Get-AksEdgeNodeAddr`, and you can find the service port by running `kubectl get services`.

### Step 5: Clean up deployments

Once you're finished with the demo, you can clean up your workspace by running:

```bash
kubectl delete -f akri-opcua
```

(or)

```bash
kubectl delete -f akri-opcua\akri-opcua-kXs.yaml 
kubectl delete -f akri-opcua\akri-anomaly-detection-app.yml
```

Return to the [deployment guidance homepage](/docs/AKS-Lite-Deployment-Guidance.md) or the [samples page](/samples/README.md).
