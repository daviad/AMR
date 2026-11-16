import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 非 Web 端：dart:io WebSocket。
///
/// - `pingInterval`：10s 发一次 WS 控制帧 ping，对端（rosbridge/tornado）
///   不回 pong 就自动断开，用来发现半开连接；
/// - `connectTimeout`：5s 内握手不成功直接失败，避免 SYN 超时把重连拖到分钟级。
WebSocketChannel connectRosbridge(Uri uri) => IOWebSocketChannel.connect(
      uri,
      pingInterval: const Duration(seconds: 10),
      connectTimeout: const Duration(seconds: 5),
    );
