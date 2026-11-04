import 'dart:async';
import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
// Web 端用 WebSocket，非 Web 端用 TCP（工厂条件导入）
import 'mqtt_client_factory_io.dart' if (dart.library.html) 'mqtt_client_factory_web.dart';

import '../core/constants.dart';
import '../core/topic_mapping.dart';

/// MQTT 客户端封装。
/// - Web 端自动使用 WebSocket 连接（MqttBrowserClient）
/// - 非 Web 端使用 TCP 连接（MqttServerClient）
/// - 命令消息 QoS 1 发布，状态消息 QoS 0 订阅
/// - 断线自动重连（包内 autoReconnect + 手动兜底）
/// - 遗嘱消息：App 异常断开时发布 amr/status/app_offline
class AppMqttClient {
  AppMqttClient({required this.host, this.port = 1883});

  final String host;
  final int port;

  MqttClient? _client;
  Timer? _retryTimer;
  bool _disposed = false;
  final Map<String, List<StreamController<Map<String, dynamic>>>> _listeners =
      {};
  final StreamController<bool> _connController =
      StreamController<bool>.broadcast();

  Stream<bool> get connectionState async* {
    yield isConnected;
    yield* _connController.stream;
  }

  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  Future<void> connect() async {
    if (_client != null) return;
    final clientId = 'amr_app_${DateTime.now().millisecondsSinceEpoch}';
    final client =
        createMqttClient(host, clientId, port, AppConstants.mqttWsPort);
    _client = client;
    client.logging(on: false);
    client.keepAlivePeriod = 30;
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = true;
    client.onConnected = () {
      _connController.add(true);
      _resubscribeAll();
    };
    client.onDisconnected = () => _connController.add(false);
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .withWillTopic(TopicMapping.statusAppOffline)
        .withWillMessage('{"offline": true}')
        .withWillQos(MqttQos.atMostOnce)
        .startClean();
    try {
      await client.connect();
    } catch (_) {
      client.disconnect();
    }
    client.updates?.listen(_dispatch);

    // 首次连接失败时 autoReconnect 不生效，手动兜底重试
    _retryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed) return;
      final state = _client?.connectionStatus?.state;
      if (state == MqttConnectionState.disconnected ||
          state == MqttConnectionState.faulted) {
        _client?.connect().catchError((_) {
          _client?.disconnect();
          return null;
        });
      }
    });
  }

  final Map<String, MqttQos> _subQos = {};

  void _resubscribeAll() {
    for (final topic in _listeners.keys) {
      _client?.subscribe(topic, _subQos[topic] ?? MqttQos.atMostOnce);
    }
  }

  void _dispatch(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final event in events) {
      final msg = event.payload as MqttPublishMessage;
      final raw =
          MqttPublishPayload.bytesToStringAsString(msg.payload.message);
      Map<String, dynamic> json;
      try {
        json = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final list = _listeners[event.topic];
      if (list == null) continue;
      for (final c in List.of(list)) {
        if (!c.isClosed) c.add(json);
      }
    }
  }

  /// 订阅 topic，返回解析后的 JSON 流。
  /// 指令 ACK/Result 使用 QoS 1；状态类默认 QoS 0。
  Stream<Map<String, dynamic>> subscribe(
    String topic, {
    MqttQos qos = MqttQos.atMostOnce,
  }) {
    _subQos[topic] = qos;
    late StreamController<Map<String, dynamic>> controller;
    controller = StreamController<Map<String, dynamic>>.broadcast(
      onListen: () {
        _listeners.putIfAbsent(topic, () => []).add(controller);
        if (isConnected) _client?.subscribe(topic, qos);
      },
      onCancel: () {
        _listeners[topic]?.remove(controller);
        if (_listeners[topic]?.isEmpty ?? true) {
          _listeners.remove(topic);
          _subQos.remove(topic);
          if (isConnected) _client?.unsubscribe(topic);
        }
      },
    );
    return controller.stream;
  }

  /// 发布命令（QoS 1）。返回是否真正写入连接，供状态机判定 SENT/UNKNOWN。
  bool publishCommand(String topic, Map<String, dynamic> payload) {
    final client = _client;
    if (!isConnected || client == null) return false;
    try {
      final builder = MqttClientPayloadBuilder()
        ..addString(jsonEncode(payload));
      client.publishMessage(
        topic,
        MqttQos.atLeastOnce,
        builder.payload!,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _client?.disconnect();
    _connController.close();
  }
}
