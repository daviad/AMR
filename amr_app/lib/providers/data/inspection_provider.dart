import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/robot_status.dart';
import '../comm/gateway_provider.dart';

/// 巡检进度：网关订阅 `amr/status/inspection` 后 WS 推送。
final inspectionStatusProvider = StreamProvider<InspectionProgress>((ref) {
  return ref
      .watch(gatewayWsProvider)
      .messages
      .where((msg) => msg['type'] == 'inspection')
      .map((msg) => InspectionProgress.fromJson(
            Map<String, dynamic>.from(msg['data'] as Map? ?? const {}),
          ));
});
