import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/robot_status.dart';
import '../comm/gateway_provider.dart';

/// 告警流：网关订阅 `amr/alert` 后通过 WS 推送 `{"type":"alert","data":{...}}`。
final alertProvider = StreamProvider<AlertMessage>((ref) {
  return ref
      .watch(gatewayWsProvider)
      .messages
      .where((msg) => msg['type'] == 'alert')
      .map((msg) => AlertMessage.fromJson(
            Map<String, dynamic>.from(msg['data'] as Map? ?? const {}),
          ));
});
