using McMaster.Extensions.CommandLineUtils;
using MQTTnet.Client;
using MQTTnet;
using System.Net;
using MQTTnet.Extensions.ManagedClient;
using MQTTnet.Server;
using System.Text;

var app = new CommandLineApplication();

app.Name = "WindowCompanion App";
app.Description = "Companion Windows app to communicate with edge AKS-IoT MQTT broker.";
app.HelpOption();

var connectionServer = app.Option("-x|--connectionServer <connServer>", "Connection server to MQTT broker", CommandOptionType.SingleValue);
var connectionPort = app.Option("-p|--connectionPort <connPort>", "Connection server to MQTT broker", CommandOptionType.SingleValue);
var pubTopic = app.Option("-t|--pubTopic <topic>", "Publishing topic", CommandOptionType.SingleValue);
var subTopic = app.Option("-s|--subTopic <topic>", "Subscribe topic", CommandOptionType.SingleValue);

IManagedMqttClient _mqttClient = new MqttFactory().CreateManagedMqttClient();

app.OnExecuteAsync(async cancellationToken =>
{
    // Get the MQTT connection string
    string bootstrapServers = GetConnectionString();

    // Get the MQTT connection port
    int bootstrapPort = GetConnectionPort();

    // Get the subscribing topic
    string subscribeTopic = GetSubTopic();

    // Get the publishing topic
    string publishTopic = GetPubTopic();

    // Create client options object
    MqttClientOptionsBuilder builder = new MqttClientOptionsBuilder()
                                            .WithTcpServer(bootstrapServers, bootstrapPort);

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

    await Task.Delay(3000);

    while (true)
    {
        Console.WriteLine("------------------");
        Console.WriteLine("(1) Publish");
        Console.WriteLine("(2) Subscribe");
        Console.WriteLine("(3) Exit");
        Console.WriteLine("------------------");
        Console.WriteLine("Please enter mode:");
        string mode = Console.ReadLine() ?? "";

        switch (mode)
        {
            case "1":
                await PublishMessage(publishTopic, subscribeTopic);
                break;
            case "2":
                SubscribeMessage(subscribeTopic, 0);
                break;
            case "3":
                return;
            default:
                Console.WriteLine("Error - Incorrect mode:");
                break;
        }
    }
});

return app.Execute(args);

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

Task _mqttClient_ReceivedMessageAsync(MqttApplicationMessageReceivedEventArgs arg)
{
    string incomingMessage = Encoding.UTF8.GetString(arg.ApplicationMessage.Payload);
    if (!string.IsNullOrEmpty(incomingMessage))
    {
        Console.WriteLine($"Incoming message - {incomingMessage}");
    }

    return Task.CompletedTask;
}

/// <summary>
/// Retrieves the value of the connection string from the connectionStringOption. 
/// If the connection string wasn't passed method prompts for the connection string.
/// </summary>
/// <returns></returns>
string GetConnectionString()
{
    string connString;

    if (!connectionServer.HasValue())
    {
        connString = Environment.GetEnvironmentVariable("DEVICE_CONNECTION_STRING") ?? "";
    }
    else
    {
        connString = connectionServer.Value() ?? "";
    }

    while (string.IsNullOrEmpty(connString))
    {
        Console.WriteLine("Please enter MQTT Connection String:");
        connString = Console.ReadLine() ?? "";
    }

    Console.WriteLine($"Using connection string: {connString}");
    return connString;
}

/// <summary>
/// Retrieves the value of the connection port from the connectionPortOption. 
/// If the connection string wasn't passed method prompts for the connection port.
/// </summary>
/// <returns></returns>
int GetConnectionPort()
{
    string connPort;

    if (!connectionPort.HasValue())
    {
        connPort = Environment.GetEnvironmentVariable("DEVICE_CONNECTION_PORT") ?? "";
    }
    else
    {
        connPort = connectionPort.Value() ?? "";
    }

    while (string.IsNullOrEmpty(connPort))
    {
        Console.WriteLine("Please enter MQTT Connection port:");
        connPort = Console.ReadLine() ?? "";
    }

    Console.WriteLine($"Using connection port: {connPort}");
    return int.Parse(connPort);
}

/// <summary>
/// Retrieves the value of the Subscribe Topic. 
/// If the subTopic wasn't passed method prompts for the topic string.
/// </summary>
/// <returns></returns>
string GetSubTopic()
{
    string subTopicString;

    if (!subTopic.HasValue())
    {
        subTopicString = Environment.GetEnvironmentVariable("SUBSCRIBE_TOPIC") ?? "";
    }
    else
    {
        subTopicString = subTopic.Value() ?? "";
    }

    while (string.IsNullOrEmpty(subTopicString))
    {
        Console.WriteLine("Please enter Subscribe topic:");
        subTopicString = Console.ReadLine() ?? "";
    }

    Console.WriteLine($"Using Subscribe topic: {subTopicString}");
    return subTopicString;
}

/// <summary>
/// Retrieves the value of the Publish Topic. 
/// If the pubTopic wasn't passed method prompts for the topic string.
/// </summary>
/// <returns></returns>
string GetPubTopic()
{
    string pubTopicString;

    if (!pubTopic.HasValue())
    {
        pubTopicString = Environment.GetEnvironmentVariable("PUBLISH_TOPIC") ?? "";
    }
    else
    {
        pubTopicString = pubTopic.Value() ?? "";
    }

    while (string.IsNullOrEmpty(pubTopicString))
    {
        Console.WriteLine("Please enter Publish topic:");
        pubTopicString = Console.ReadLine() ?? "";
    }

    Console.WriteLine($"Using Publish topic: {pubTopicString}");
    return pubTopicString;
}

/// <summary>
/// This method will send message to edge MQTT to the defined topic
/// </summary>
async Task PublishMessage(string pubTop, string subTop)
{
    string publishMessage = "";
    while (string.IsNullOrEmpty(publishMessage))
    {
        Console.WriteLine("Please enter mesage to send:");
        publishMessage = Console.ReadLine() ?? "";
    }

    await _mqttClient.EnqueueAsync(pubTop, publishMessage);
    Console.WriteLine($"Published message - Topic: {pubTop} - Message: {publishMessage}");

    // Subscribe for 5 seconds to see if we get a response to this message
    SubscribeMessage(subTop, 5000);
}

/// <summary>
/// This method will consume messages from edge MQTT topic
/// </summary>
void SubscribeMessage(string subTopic, int timeout)
{
    CancellationTokenSource cts = new CancellationTokenSource();
    Console.CancelKeyPress += (_, e) => {
        e.Cancel = true; // prevent the process from terminating.
        cts.Cancel();
    };

    // If there's a timeout, cancel after timeout is finished
    if (timeout > 0)
        cts.CancelAfter(timeout);

   _mqttClient.SubscribeAsync(subTopic);

    // Wait for cancelation
    while (!cts.IsCancellationRequested) ;

    _mqttClient.UnsubscribeAsync(subTopic);
}
