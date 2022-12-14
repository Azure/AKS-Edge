# Interop Windows Console App with AKS Edge Linux container

## Introduction
This sample demonstrates bidirectional communication between a Windows console application and a Linux container running inside the AKS edge cluster. 

The underlying communication between the Windows console application and the Linux container is based on [Mosquitto Broker](https://mosquitto.org/), an open-source message broker that implements the MQTT protocol. 

### Mosquitto Broker
To establish a bi-directional communication between the Windows companion app and a Linux container, this sample code uses Mosquitto broker running as a container inside the AKS edge cluster. All communication is done using MQTT pub/sub protocol. There are different Mosquitto container options already packaged and published. For this tutorial, we'll use the [Mosquitto broker packaged by Eclipse](https://hub.docker.com/_/eclipse-mosquitto). However, the user can build and package their own version.

### Windows Companion Application
The Windows console application in this sample uses the [MQTTNet]https://github.com/dotnet/MQTTnet) package and [.NET](https://docs.microsoft.com/en-us/dotnet/core/whats-new/dotnet-6) to publish and subscribe to messages using the MQTT broker. In this scenario, the Windows console application is being implemented as a *companion app* that runs side-by-side with a Linux container. 

The Windows console application, doesn't require to authenticate with the Mosquitto broker instance, running as a container inside the AKS edge cluster. If needed, authentication using certificates or username/password can also be configured. For more information about certificates usage, see [Mosquitto - Authentication methods](https://mosquitto.org/documentation/authentication-methods/). 

### Linux container 
This sample also incorporates a Linux container, which processes messages sent by the *console app* then sends processed results back to the *console app* to be displayed on the console output.

### Message Routing
This sample employs concepts described in [MQTT Producer/Suscriber](https://mqtt.org/) to establish message flow between the *companion app* (Windows console application) and a custom AKS edge Linux container. 

The [topic table](https://kafka.apache.org/documentation/#topicconfigs) below defines a set of topic entries, where each entry defines a message routing between the two endpoints. 

To realize this communication model for the development of both the Windows application and Linux container, we use the below topics:  

<center>

| Companion app (Console App) | Message Direction | Linux container |
|-------------------|:-----------:|-------------|
| **(1) Produce** - This method will send a user defined message to the Kafka broker to the topic defined by the *PUBLISH_TOPIC* env variable. If variable isn't defined, the user will have to provide the publishing topic. | 🠊 🠊 🠊 | **ConsumeMessage** - This method receives a message from the companion app and trigger a response back to the companion app. Using the **ProduceMessage** method, the Linux container answers back a modified version of the original message. | 
| **(2) Consume** - This method will subscribe to Kafka topic defined by the *SUBSCRIBE_TOPIC* env variable. If variable isn't defined, the user will have to provide the subscribe topic. | 🠈 🠈 🠈 | If the **ProduceMessage** is invoked, it will send a message to the topic defined by the *PUBLISH_TOPIC* env variable. | 

</center>

## Prerequisites
To exercise this sample, you'll need the following
* An [Azure Subscription](https://azure.microsoft.com/free/) in which you have rights to deploy resources. 
* An [Azure Container Registry](https://docs.microsoft.com/en-us/azure/container-registry/container-registry-get-started-portal?tabs=azure-cli) in which you have right to push and pull containers.
* [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed to build and push the Linux container.

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

- [Step 1 - Setup AKS Edge Essentials](./Documentation/AKS-EE-Deployment-Guidance.md)
- [Step 2 - Develop and publish the Linux container](./Documentation/Develop%20and%20publish%20the%20Linux%20container.MD)
- [Step 3 - Deploy the containers onto the AKS edge Edge Device](./Documentation/DeployContainersOnAKSLiteEdgedevice.md)
- [Step 4 - Build and run the Companion Application](./Documentation/Run%20the%20Console%20Application.MD)

## Feedback
If you have problems with this sample, please post an issue in this repository.