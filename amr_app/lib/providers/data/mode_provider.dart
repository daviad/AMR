import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../comm/gateway_provider.dart';

/// 机器人当前模式（manual / auto / inspect / charge）：网关 WS 推送 `mode`。
final modeProvider = StreamProvider<String>((ref) {
  return ref
      .watch(gatewayWsProvider)
      .messages
      .where((msg) => msg['type'] == 'mode')
      .map((msg) => (msg['data'] as Map?)?['mode'] as String? ?? 'unknown');
});
