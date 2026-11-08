import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../comm/gateway_provider.dart';

/// 全局路径：由网关 WS 推送 `plan`（网关订阅 /plan 后转成世界坐标点列）。
final planProvider = StreamProvider<List<Offset>>((ref) {
  return ref
      .watch(gatewayWsProvider)
      .messages
      .where((msg) => msg['type'] == 'plan')
      .map((msg) {
    final raw = msg['points'];
    if (raw is! List) return <Offset>[];
    final points = <Offset>[];
    for (final p in raw) {
      if (p is! List || p.length < 2) continue;
      final x = p[0];
      final y = p[1];
      if (x is! num || y is! num) continue;
      points.add(Offset(x.toDouble(), y.toDouble()));
    }
    return points;
  });
});
