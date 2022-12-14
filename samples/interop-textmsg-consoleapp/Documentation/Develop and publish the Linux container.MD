# Interop Windows Console App with AKS Edge Linux container

## Progress
- [x] [Step 1 - Setup Azure Kubernetes Service Edge Essentials (AKS edge)](/docs/AKS-Lite-Deployment-Guidance.md)
- [ ] **Step 2 - Develop and publish the Linux container**
- [ ] [Step 3 - Deploy the containers onto the AKS edge Edge Device](./DeployContainersOnAKSLiteEdgedevice.md)
- [ ] [Step 4 - Build and run the Companion Application](./Run%20the%20Console%20Application.MD)
---
# Step 2: Develop and publish the Linux container
This section will explain how to develop and publish the Linux containers in the development VM using Visual Studio Code.

1. [Download and build the container project](#ContainerProject)  
1. [Login to container registry](#LoginRegistry)  
1. [Push your container](#PushContainer)   

    > **Note** 
    > The C# solution created in the following steps is included in our sample repo. We recommned downloading the sample code and run it, however, you can create your own edge container based on this sample code. 

---  
<a name="ContainerProject"></a>  

## Download and build the container project

1. Open Visual Studio Code

1. In Visual Studio Code, select **File** > **Open Folder** to open the **EdgeInterop** project folder. 

1. In the command palette, enter and run the command **Azure: Sign in** and follow the instructions to sign in your Azure account. If you're already signed in, you can skip this step.  

1. Open the VS Code integrated terminal by selecting **View** > **Terminal**.

1. Build the container using docker build command. For example `docker build -t aksedgeessentials.azuecr.io/edgeinterop:latest .`

    ```bash
    docker build -t  <ACR server>/<name-of-container>:<tag-name> .
    ```
    
    Docker building should take ~1-2 minutes. If everything was successful, you the docker should be ready to push to your container registry. 

---
<a name="LoginRegistry"></a>  

## Login to container registry

1. Open the VS Code integrated terminal by selecting **View** > **Terminal**.

1. Sign in to Docker by entering the following command in the terminal. Sign in with the username, password, and login server from your Azure container registry. You can retrieve these values from the **Access keys** section of your registry in the Azure portal.

   ```bash
   docker login -u <ACR username> -p <ACR password> <ACR server>
   ```
   You may receive a security warning recommending the use of `--password-stdin`. While that best practice is recommended for production scenarios, it's outside the scope of this tutorial. For more information, see the [docker login reference](https://docs.docker.com/engine/reference/commandline/login/).

---

<a name="PushContainer"></a>

## **Push the container**  
In the previous section, you created and build the Linux container image. Now you need to push it to your Azure container registry.

1. Open the VS Code integrated terminal by selecting **View** > **Terminal**.

1. Push the container image to the Azure container registry

    ```bash
    docker push <ACR server>/<name-of-container>:<tag-name>
    ```

Go to [Next Step](./DeployContainersOnAKSLiteEdgedevice.md)