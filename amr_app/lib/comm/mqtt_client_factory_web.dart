import 'package:mqtt_client/mqtt_browser_client.dart';
import 'package:mqtt_client/mqtt_client.dart';

/// Web 端：WebSocket 协议。
MqttClient createMqttClient(
    String host, String clientId, int tcpPort, int wsPort) {
  final client = MqttBrowserClient.withPort('ws://$host', clientId, wsPort);
  client.websocketProtocols = ['mqtt'];
  return client;
}
