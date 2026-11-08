import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../comm/gateway_client.dart';
import '../../comm/gateway_ws_client.dart';

/// 网关 + 两条依赖通道的聚合健康状态（驱动 UI 的连接指示灯与降级提示）。
class GatewayHealth {
  const GatewayHealth({
    required this.http,
    required this.ws,
    required this.mqtt,
    required this.rosbridge,
    this.mapVersion,
  });

  final bool http;
  final bool ws;
  final bool mqtt;
  final bool rosbridge;
  final String? mapVersion;

  static const GatewayHealth offline = GatewayHealth(
    http: false,
    ws: false,
    mqtt: false,
    rosbridge: false,
  );

  bool get canSendCommands => http && ws && mqtt;
  bool get hasPose => http && ws && rosbridge;

  factory GatewayHealth.fromJson(Map<String, dynamic> json, bool ws) {
    return GatewayHealth(
      http: json['ok'] == true,
      ws: ws,
      mqtt: json['mqtt'] == true,
      rosbridge: json['rosbridge'] == true,
      mapVersion: json['map_version'] as String?,
    );
  }
}

/// HTTP 客户端（业务：地图/任务/锁/快照）。
final gatewayClientProvider = Provider<GatewayClient>((ref) {
  final client = GatewayClient();
  ref.onDispose(client.dispose);
  return client;
});

/// WebSocket 客户端（推送：位姿/路径/扫描/任务/状态）。
final gatewayWsProvider = Provider<GatewayWsClient>((ref) {
  final client = GatewayWsClient();
  unawaited(client.connect());
  ref.onDispose(client.dispose);
  return client;
});

/// 推送消息流（页面/控制器通过 `ref.listen` 或 `.where` 消费）。
final gatewayMessageProvider = StreamProvider<Map<String, dynamic>>(
  (ref) => ref.watch(gatewayWsProvider).messages,
);

/// WS 连接状态。
final gatewayConnectedProvider = StreamProvider<bool>(
  (ref) => ref.watch(gatewayWsProvider).connectionState,
);

/// 每 5s 轮询 `/healthz`，失败视为整条网关链路离线。
final gatewayHealthProvider = StreamProvider<GatewayHealth>((ref) async* {
  final http = ref.watch(gatewayClientProvider);
  final ws = ref.watch(gatewayWsProvider);
  while (true) {
    try {
      final json = await http.healthz();
      yield GatewayHealth.fromJson(json, ws.isConnected);
    } catch (_) {
      yield GatewayHealth.offline;
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});
