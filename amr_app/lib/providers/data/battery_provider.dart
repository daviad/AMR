import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/robot_status.dart';
import '../comm/gateway_provider.dart';

/// 电池状态：网关订阅 `amr/status/battery`（保留消息）后 WS 推送。
final batteryProvider = StreamProvider<BatteryStatus>((ref) {
  return ref
      .watch(gatewayWsProvider)
      .messages
      .where((msg) => msg['type'] == 'battery')
      .map((msg) => BatteryStatus.fromJson(
            Map<String, dynamic>.from(msg['data'] as Map? ?? const {}),
          ));
});
