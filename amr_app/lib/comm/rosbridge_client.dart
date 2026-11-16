import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'rosbridge_protocol.dart';
// IO 端带 WS 心跳与握手超时，Web 端用浏览器原生通道
import 'ws_channel_io.dart'
    if (dart.library.html) 'ws_channel_web.dart';

/// rosbridge WebSocket 客户端封装。
/// - subscribe/publish/unsubscribe，订阅数据以广播 Stream 分发
/// - 断线自动重连（2s 退避）；IO 端由 WS 层 ping/pong 判活，不依赖业务消息
/// - 同一 topic 引用计数，重连后自动恢复所有订阅
class RosbridgeClient {
  RosbridgeClient({required this.url});

  final String url;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _connected = false;

  /// topic -> 订阅参数（用于重连恢复）
  final Map<String, _SubParams> _subParams = {};

  /// topic -> 订阅者列表
  final Map<String, List<StreamController<Map<String, dynamic>>>> _listeners =
      {};
  final Set<String> _advertised = {};
  final StreamController<bool> _connController =
      StreamController<bool>.broadcast();

  Stream<bool> get connectionState async* {
    yield _connected;
    yield* _connController.stream;
  }
  bool get isConnected => _connected;

  void connect() => _doConnect();

  Future<void> _doConnect() async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _teardown();

    final WebSocketChannel channel;
    try {
      channel = connectRosbridge(Uri.parse(url));
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _channel = channel;
    try {
      // 等握手完成：失败会在 ready 上抛异常，从而被这里捕获，
      // 不会变成未捕获异常，也不会"没连上就报已连接"。
      await channel.ready;
    } catch (_) {
      if (!identical(_channel, channel)) return;
      _teardown();
      _scheduleReconnect();
      return;
    }
    if (_disposed || !identical(_channel, channel)) return;

    _channelSub = channel.stream.listen(
      _onData,
      onError: (_) => _onDisconnected(channel),
      onDone: () => _onDisconnected(channel),
      cancelOnError: true,
    );
    _connected = true;
    _connController.add(true);
    _advertised.clear();
    _resubscribeAll();
  }

  /// 关掉当前连接并清理订阅，但不安排重连。
  /// 必须显式 close：只 cancel 订阅会留下半开 socket，服务端 ESTAB 会持续累积。
  void _teardown() {
    _channelSub?.cancel();
    _channelSub = null;
    final channel = _channel;
    _channel = null;
    if (channel == null) return;
    channel.sink.close(ws_status.goingAway).catchError((_) {});
  }

  void _onData(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (json['op'] == 'publish') {
      final topic = json['topic'] as String?;
      final msg = json['msg'];
      if (topic == null || msg is! Map<String, dynamic>) return;
      final list = _listeners[topic];
      if (list == null) return;
      // 复制列表避免回调中增删导致并发修改
      for (final c in List.of(list)) {
        if (!c.isClosed) c.add(msg);
      }
    }
  }

  /// [from] 用于丢弃已被替换的旧连接迟到的 onDone/onError。
  void _onDisconnected([WebSocketChannel? from]) {
    if (_disposed) return;
    if (from != null && !identical(from, _channel)) return;
    if (_connected) {
      _connected = false;
      _connController.add(false);
    }
    _teardown();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer =
        Timer(const Duration(seconds: 2), _doConnect);
  }

  void _send(Map<String, dynamic> msg) {
    try {
      _channel?.sink.add(jsonEncode(msg));
    } catch (_) {
      // 发送失败由心跳/重连机制兜底
    }
  }

  /// 订阅 topic，返回广播流（msg 部分）。流取消监听时自动退订。
  /// [qos] 见 [rosSubscribe]：只在 topic 首个订阅创建 DDS 订阅时生效。
  Stream<Map<String, dynamic>> subscribe(
    String topic, {
    String? type,
    int queueLength = 1,
    int? throttleRate,
    Map<String, dynamic>? qos,
  }) {
    _subParams[topic] = _SubParams(
        type: type,
        queueLength: queueLength,
        throttleRate: throttleRate,
        qos: qos);
    late StreamController<Map<String, dynamic>> controller;
    controller = StreamController<Map<String, dynamic>>.broadcast(
      onListen: () {
        _listeners.putIfAbsent(topic, () => []).add(controller);
        _send(rosSubscribe(topic,
            type: type,
            queueLength: queueLength,
            throttleRate: throttleRate,
            qos: qos));
      },
      onCancel: () {
        _listeners[topic]?.remove(controller);
        if ((_listeners[topic]?.isEmpty ?? true)) {
          _listeners.remove(topic);
          _subParams.remove(topic);
          _send(rosUnsubscribe(topic));
        }
      },
    );
    return controller.stream;
  }

  /// 发布消息（首次自动 advertise）。
  void publish(String topic, Map<String, dynamic> msg, {String? type}) {
    if (type != null && _advertised.add(topic)) {
      _send(rosAdvertise(topic, type));
    }
    _send(rosPublish(topic, msg));
  }

  void _resubscribeAll() {
    _subParams.forEach((topic, p) {
      if ((_listeners[topic]?.isNotEmpty ?? false)) {
        _send(rosSubscribe(topic,
            type: p.type,
            queueLength: p.queueLength,
            throttleRate: p.throttleRate,
            qos: p.qos));
      }
    });
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _teardown();
    _connController.close();
  }
}

class _SubParams {
  const _SubParams(
      {this.type,
      this.queueLength = 1,
      this.throttleRate,
      this.qos});
  final String? type;
  final int queueLength;
  final int? throttleRate;
  final Map<String, dynamic>? qos;
}
