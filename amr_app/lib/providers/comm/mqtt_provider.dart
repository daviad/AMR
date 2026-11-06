import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../comm/mqtt_client.dart';
import '../../core/constants.dart';

/// MQTT 客户端单例，常驻，自动重连。
final mqttClientProvider = Provider<AppMqttClient>((ref) {
  final client =
      AppMqttClient(host: AppConstants.host, port: AppConstants.mqttTcpPort);
  client.connect();
  ref.onDispose(client.dispose);
  return client;
});

/// MQTT 连接状态流。
final mqttConnectionProvider = StreamProvider<bool>((ref) {
  return ref.watch(mqttClientProvider).connectionState;
});
