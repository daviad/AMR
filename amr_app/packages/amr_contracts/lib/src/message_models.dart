/// MQTT 命令 payload 构造器。
/// 格式严格遵循 docs/architecture.md 第 5.2 节契约。
library;

import 'inspection_point.dart';
import 'inspection_route.dart';

/// amr/cmd/goal —— 业务指令信封（cmd_id 幂等 + trace_id 全链路追踪）。
/// 格式严格遵循 docs/architecture.md 第 5.2 节契约。
Map<String, dynamic> buildGoalCommand({
  required String cmdId,
  required String traceId,
  required int timestampMs,
  required int ttlMs,
  required double x,
  required double y,
  required double theta,
}) =>
    {
      'cmd_id': cmdId,
      'trace_id': traceId,
      'type': 'NAVIGATE_TO_POSE',
      'timestamp_ms': timestampMs,
      'ttl_ms': ttlMs,
      'payload': {
        'frame_id': 'map',
        'x': x,
        'y': y,
        'theta': theta,
      },
    };

/// amr/cmd/cancel —— 取消也需要独立 cmd_id 与终态。
Map<String, dynamic> buildCancelCommand({
  required String cmdId,
  required String traceId,
  required String targetCmdId,
}) =>
    {
      'cmd_id': cmdId,
      'trace_id': traceId,
      'type': 'CANCEL',
      'target_cmd_id': targetCmdId,
      'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
    };

/// amr/cmd/mode —— {"mode": "auto"} (manual/auto/inspect/charge)
Map<String, dynamic> buildModePayload(String mode) => {'mode': mode};

/// amr/cmd/estop —— {"stop": true}
Map<String, dynamic> buildEstopPayload(bool stop) => {'stop': stop};

/// amr/cmd/inspection/start —— 携带完整路线数据（App 端 Hive 为单一事实来源，
/// 仿真端收到后登记路线再执行）。
Map<String, dynamic> buildInspectionStartPayload(
  InspectionRoute route,
  List<InspectionPoint> points,
) =>
    {
      'route_id': route.id,
      'loop': route.loop,
      'points': [
        for (final p in points)
          {
            'id': p.id,
            'name': p.name,
            'x': p.x,
            'y': p.y,
            'theta': p.theta,
            'dwell_time': p.dwellTime,
            'capture_photo': p.capturePhoto,
          },
      ],
    };

/// amr/cmd/inspection/stop、amr/cmd/return_charge —— {}
Map<String, dynamic> buildEmptyPayload() => <String, dynamic>{};
