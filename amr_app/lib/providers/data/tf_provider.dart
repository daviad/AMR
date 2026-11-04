import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/topic_mapping.dart';
import '../../models/robot_pose.dart';
import '../comm/rosbridge_provider.dart';

/// 机器人位姿（map 帧）。
/// 主源 /amcl_pose（AMCL 直接输出 map 帧位姿），/tf 兜底，节流至 20Hz。
final robotPoseProvider = StreamProvider<RobotPose?>((ref) {
  final client = ref.watch(rosbridgeClientProvider);
  final amcl = client
      .subscribe(
        TopicMapping.amclPose,
        type: 'geometry_msgs/PoseWithCovarianceStamped',
        queueLength: 1,
        throttleRate: 50,
      )
      .map((m) =>
          RobotPose.fromPoseMsg(m['pose']['pose'] as Map<String, dynamic>));
  final tf = client
      .subscribe(
        TopicMapping.tf,
        type: 'tf2_msgs/TFMessage',
        queueLength: 1,
        throttleRate: 100,
      )
      .map(RobotPose.fromTfMessage)
      .where((p) => p != null)
      .cast<RobotPose>();
  return _throttle(_merge([amcl, tf]), const Duration(milliseconds: 50));
});

/// 合并多个流。
Stream<T> _merge<T>(List<Stream<T>> streams) {
  late StreamController<T> controller;
  final subs = <StreamSubscription<T>>[];
  controller = StreamController<T>(
    onListen: () {
      for (final s in streams) {
        subs.add(s.listen(controller.add, onError: controller.addError));
      }
    },
    onCancel: () async {
      for (final sub in subs) {
        await sub.cancel();
      }
    },
  );
  return controller.stream;
}

/// 时间间隔采样：interval 内只放行第一条。
Stream<T> _throttle<T>(Stream<T> source, Duration interval) {
  var last = DateTime.fromMillisecondsSinceEpoch(0);
  return source.where((_) {
    final now = DateTime.now();
    if (now.difference(last) >= interval) {
      last = now;
      return true;
    }
    return false;
  });
}
