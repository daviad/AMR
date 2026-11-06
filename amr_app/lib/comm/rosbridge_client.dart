import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'rosbridge_protocol.dart';

/// rosbridge WebSocket 客户端封装。
/// - subscribe/publish/unsubscribe，订阅数据以广播 Stream 分发
/// - 断线自动重连（2s 退避）+ 5s 应用层心跳，10s 无消息判定僵死
/// - 同一 topic 引用计数，重连后自动恢复所有订阅
class RosbridgeClient {
  RosbridgeClient({required this.url});

  final String url;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  bool _disposed = false;
  bool _connected = false;
  DateTime _lastMsgTime = DateTime.now();

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

  void _doConnect() {
    if (_disposed) return;
    _channelSub?.cancel();
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _lastMsgTime = DateTime.now();
    _channelSub = _channel!.stream.listen(
      _onData,
      onError: (_) => _onDisconnected(),
      onDone: _onDisconnected,
      cancelOnError: true,
    );
    // 连接建立无显式事件，先乐观置位；失败会立即走 onError/onDone
    _connected = true;
    _connController.add(true);
    _advertised.clear();
    _resubscribeAll();
    _startPing();
  }

  void _onData(dynamic raw) {
    _lastMsgTime = DateTime.now();
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

  void _onDisconnected() {
    if (_disposed) return;
    if (_connected) {
      _connected = false;
      _connController.add(false);
    }
    _pingTimer?.cancel();
    _channelSub?.cancel();
    _channel = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer =
        Timer(const Duration(seconds: 2), _doConnect);
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // 10s 无任何消息视为僵死，主动断开重连
      if (DateTime.now().difference(_lastMsgTime) >
          const Duration(seconds: 10)) {
        _onDisconnected();
        return;
      }
      _send(rosPing());
    });
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
    _pingTimer?.cancel();
    _channelSub?.cancel();
    _channel?.sink.close();
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
