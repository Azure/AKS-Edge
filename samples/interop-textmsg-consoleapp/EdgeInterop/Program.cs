using MQTTnet;
using MQTTnet.Client;
using MQTTnet.Extensions.ManagedClient;
using System.Text;

Console.WriteLine("Starting EdgeInterop module");

string bootstrapServers = Environment.GetEnvironmentVariable("BOOTSTRAP_SERVERS") ?? "";
if(string.IsNullOrEmpty(bootstrapServers))
{
    Console.WriteLine("bootstrapServers cannot be empty or null");
    return;
}
else
{
    Console.WriteLine($"Using boostrapServers = {bootstrapServers}");
}

string bootstrapPort = Environment.GetEnvironmentVariable("BOOTSTRAP_PORT") ?? "1883";
if (string.IsNullOrEmpty(bootstrapPort))
{
    Console.WriteLine("bootstrapPort cannot be empty or null");
    return;
}
else
{
    Console.WriteLine($"Using boostrapPort = {bootstrapPort}");
}

string clientId = Environment.GetEnvironmentVariable("CLIENT_ID") ?? "";
if (string.IsNullOrEmpty(clientId))
{
    Console.WriteLine("clientId cannot be empty or null");
    return;
}
else
{
    Console.WriteLine($"Using clientId = {clientId}");
}

string subscribeTopic = Environment.GetEnvironmentVariable("SUBSCRIBE_TOPIC") ?? "";
if (string.IsNullOrEmpty(subscribeTopic))
{
    Console.WriteLine("subscribeTopic cannot be empty or null");
    return;
}
else
{
    Console.WriteLine($"Using subscribeTopic = {subscribeTopic}");
}

string publishTopic = Environment.GetEnvironmentVariable("PUBLISH_TOPIC") ?? "";
if (string.IsNullOrEmpty(subscribeTopic))
{
    Console.WriteLine("publishTopic cannot be empty or null");
    return;
}
else
{
    Console.WriteLine($"Using publishTopic = {publishTopic}");
}

IManagedMqttClient _mqttClient = new MqttFactory().CreateManagedMqttClient();

// Create client options object
MqttClientOptionsBuilder builder = new MqttClientOptionsBuilder()
                                        .WithClientId(clientId)
                                        .WithTcpServer(bootstrapServers, int.Parse(bootstrapPort));

ManagedMqttClientOptions options = new ManagedMqttClientOptionsBuilder()
                        .WithAutoReconnectDelay(TimeSpan.FromSeconds(60))
                        .WithClientOptions(builder.Build())
                        .Build();

// Set up MQTT handlers
_mqttClient.ConnectedAsync += _mqttClient_ConnectedAsync;
_mqttClient.DisconnectedAsync += _mqttClient_DisconnectedAsync;
_mqttClient.ConnectingFailedAsync += _mqttClient_ConnectingFailedAsync;
_mqttClient.ApplicationMessageReceivedAsync += _mqttClient_ReceivedMessageAsync;

// Connect to the MQTT broker
await _mqttClient.StartAsync(options);
await _mqttClient.SubscribeAsync(subscribeTopic);

while (true)
{
    await Task.Delay(TimeSpan.FromSeconds(1));
}


Task _mqttClient_ConnectedAsync(MqttClientConnectedEventArgs arg)
{
    Console.WriteLine("MQTT Broker connected");
    return Task.CompletedTask;
};

Task _mqttClient_DisconnectedAsync(MqttClientDisconnectedEventArgs arg)
{
    Console.WriteLine("MQTT Broker disconnected");
    return Task.CompletedTask;
};

Task _mqttClient_ConnectingFailedAsync(ConnectingFailedEventArgs arg)
{
    Console.WriteLine("MQTT Broker connection failed check network or broker!");
    return Task.CompletedTask;
}

async Task _mqttClient_ReceivedMessageAsync(MqttApplicationMessageReceivedEventArgs arg)
{
    string incomingMessage = Encoding.UTF8.GetString(arg.ApplicationMessage.Payload);
    if (!string.IsNullOrEmpty(incomingMessage))
    {
        Console.WriteLine($"Incoming message - {incomingMessage}");
        await _mqttClient_PublishMessageAsync(incomingMessage);
    }
}

async Task _mqttClient_PublishMessageAsync(string incomingMessage)
{
    await _mqttClient.EnqueueAsync(publishTopic, $"{incomingMessage} - Received Ok");
    Console.WriteLine("MQTT application message is published.");
}