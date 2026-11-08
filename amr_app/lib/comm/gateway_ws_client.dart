import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/constants.dart';

/// 网关 WebSocket 推送客户端（位姿 / 路径 / 扫描 / 任务 / 状态 / 告警）。
///
/// - 断线自动重连（2s 起，指数退避到 10s）；
/// - 连接后自动 `{"op":"subscribe"}` 订阅全量主题；
/// - 不做消息回放：重连后由业务层 `GET /tasks` 对齐状态（见架构文档 §6）。
class GatewayWsClient {
  GatewayWsClient({String? url, this.autoReconnect = true})
      : url = url ?? AppConstants.gatewayWsUrl;

  final String url;
  final bool autoReconnect;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retryTimer;
  Timer? _pingTimer;
  int _attempt = 0;
  bool _disposed = false;
  bool _connected = false;

  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<bool> _connectedCtrl =
      StreamController<bool>.broadcast();

  /// 服务端推送消息（已 JSON 解码）。
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// 连接状态：先发当前值，再跟随变化。
  Stream<bool> get connectionState async* {
    yield _connected;
    yield* _connectedCtrl.stream;
  }

  bool get isConnected => _connected;

  Future<void> connect() async {
    if (_disposed) return;
    _retryTimer?.cancel();
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      await channel.ready;
      if (_disposed) {
        await channel.sink.close();
        return;
      }
      _channel = channel;
      _attempt = 0;
      _setConnected(true);
      _sub = channel.stream.listen(
        _onRaw,
        onError: (_) => _onClosed(),
        onDone: _onClosed,
        cancelOnError: true,
      );
      _send({'op': 'subscribe'});
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        _send({'op': 'ping'});
      });
    } catch (_) {
      _setConnected(false);
      _scheduleReconnect();
    }
  }

  void _onRaw(dynamic raw) {
    if (raw is! String) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _messages.add(decoded);
      }
    } catch (_) {
      // 非法帧直接丢弃，不影响连接
    }
  }

  void _send(Map<String, dynamic> payload) {
    try {
      _channel?.sink.add(jsonEncode(payload));
    } catch (_) {
      // sink 已关闭时由 onDone 触发重连
    }
  }

  void _onClosed() {
    _pingTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _setConnected(false);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || !autoReconnect) return;
    _retryTimer?.cancel();
    final delaySeconds = (2 << (_attempt.clamp(0, 2))).clamp(2, 10);
    _attempt++;
    _retryTimer = Timer(Duration(seconds: delaySeconds), connect);
  }

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    if (!_connectedCtrl.isClosed) _connectedCtrl.add(value);
  }

  Future<void> dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    _pingTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    await _messages.close();
    await _connectedCtrl.close();
  }
}
