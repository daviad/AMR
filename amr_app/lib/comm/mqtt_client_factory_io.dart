import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

/// 非 Web 端：TCP 直连。
MqttClient createMqttClient(
        String host, String clientId, int tcpPort, int wsPort) =>
    MqttServerClient.withPort(host, clientId, tcpPort);
