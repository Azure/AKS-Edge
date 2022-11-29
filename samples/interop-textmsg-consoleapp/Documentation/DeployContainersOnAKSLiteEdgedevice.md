# Interop Windows Console App with AKS edge Linux container

## Progress
- [x] [Step 1 - Setup Azure Kubernetes Service Edge Essentials (AKS edge)](/docs/AKS-Lite-Deployment-Guidance.md)
- [x] [Step 2 - Develop and publish the Linux container](./Documentation/Develop%20and%20publish%20the%20Linux%20container.MD)
- [x] [Step 3 - Deploy the containers onto the AKS edge Edge Device](../DeployContainersOnAKSLiteEdgedevice.md)
- [ ] [Step 4 - Build and run the Companion Application](./Run%20the%20Console%20Application.MD)
---

# Step 3: Deploy the containers onto the AKS edge Edge Device

## Deploy Mosquitto MQTT Broker
1. First create a namespace for your demo artifacts:
    ```powershell
    kubectl create namespace edgeinterop
    ```
2. In your PowerShell, navigate to the directory of the samples and run:
    ```powershell
    kubectl apply -f mosquitto -n edgeinterop
    ```
This will deploy your Mosquitto MQTT broker to your `edgeinterop` namespace.

3. Now you'll need the internal IP of the service. Run:
    ```powershell
    kubectl get svc -n edgeinterop 
    ```
And retrieve the Cluster-IP and port of the Mosquitto service.

## Deploy the Edge Interop Module 

1. Once your modules are created, open the `edgeinterop.yaml` file.

2. In line 38, edit the `image` with the tag name you used in Step 2 of this demo.

3. In line 41, replace the value of `BOOTSTRAP_SERVERS` with the internal IP of the Mosquitto service you retrieved earlier.

4. Save and close the file.

5. In your PowerShell, run:
    ```powershell
    kubectl apply -f edgeinterop.yaml
    ```

6. Make sure your pods are running:
    ```powershell
    kubectl get pods -n edgeinterop
    ```

8. Check that the connection was successful by running the command below, replacing the pod name with your own:
    ```powershell
    kubectl logs <edgeinterop-pod-name> -n edgeinterop
    ```

It should state that the MQTT broker connected.

Go to [Next Step](./Run%20the%20Console%20Application.MD)  