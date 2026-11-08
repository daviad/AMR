import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/robot_pose.dart';
import '../comm/gateway_provider.dart';

/// 机器人位姿（map 帧）：由网关 WS 推送 `pose`（网关内部合并 /amcl_pose 与 /tf）。
final robotPoseProvider = StreamProvider<RobotPose?>((ref) {
  return ref
      .watch(gatewayWsProvider)
      .messages
      .where((msg) => msg['type'] == 'pose')
      .map<RobotPose?>((msg) => RobotPose(
            x: (msg['x'] as num?)?.toDouble() ?? 0.0,
            y: (msg['y'] as num?)?.toDouble() ?? 0.0,
            theta: (msg['theta'] as num?)?.toDouble() ?? 0.0,
          ));
});
