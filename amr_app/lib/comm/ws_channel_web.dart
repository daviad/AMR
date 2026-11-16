import 'package:web_socket_channel/web_socket_channel.dart';

/// Web 端：浏览器 WebSocket（心跳由浏览器管理，无法注入 pingInterval）。
WebSocketChannel connectRosbridge(Uri uri) =>
    WebSocketChannel.connect(uri);
