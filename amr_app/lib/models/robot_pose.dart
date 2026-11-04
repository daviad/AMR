import 'dart:math';

/// 机器人位姿（map 帧，theta 为偏航角弧度）。
class RobotPose {
  const RobotPose({required this.x, required this.y, required this.theta});

  final double x;
  final double y;
  final double theta;

  /// 从 geometry_msgs/Pose JSON 解析（position + orientation 四元数）。
  factory RobotPose.fromPoseMsg(Map<String, dynamic> pose) {
    final pos = pose['position'] as Map<String, dynamic>;
    final ori = pose['orientation'] as Map<String, dynamic>;
    return RobotPose(
      x: (pos['x'] as num).toDouble(),
      y: (pos['y'] as num).toDouble(),
      theta: yawFromQuaternion(
        (ori['x'] as num).toDouble(),
        (ori['y'] as num).toDouble(),
        (ori['z'] as num).toDouble(),
        (ori['w'] as num).toDouble(),
      ),
    );
  }

  /// 从 tf2_msgs/TFMessage 解析 map 帧下的机器人位姿。
  /// 优先取 header.frame_id == 'map' 且 child 为 base 系的变换；
  /// 无则返回 null（实际主要依赖 /amcl_pose，tf 为兜底）。
  static RobotPose? fromTfMessage(Map<String, dynamic> msg) {
    final transforms = msg['transforms'];
    if (transforms is! List) return null;
    RobotPose? fallback;
    for (final t in transforms) {
      if (t is! Map<String, dynamic>) continue;
      final child = t['child_frame_id'] as String? ?? '';
      if (!child.contains('base')) continue;
      final transform = t['transform'] as Map<String, dynamic>?;
      if (transform == null) continue;
      final pose = RobotPose.fromPoseMsg({
        'position': transform['translation'],
        'orientation': transform['rotation'],
      });
      final frame = (t['header'] as Map<String, dynamic>?)?['frame_id'];
      if (frame == 'map') return pose;
      fallback ??= pose;
    }
    return fallback;
  }

  static double yawFromQuaternion(double x, double y, double z, double w) =>
      atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z));
}
