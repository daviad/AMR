import 'dart:math';

/// rosbridge 协议消息序列化（JSON op 码封装）。

Map<String, dynamic> rosSubscribe(
  String topic, {
  String? type,
  int queueLength = 1,
  int? throttleRate,
}) =>
    {
      'op': 'subscribe',
      'topic': topic,
      if (type != null) 'type': type,
      'queue_length': queueLength,
      if (throttleRate != null) 'throttle_rate': throttleRate,
    };

Map<String, dynamic> rosUnsubscribe(String topic) =>
    {'op': 'unsubscribe', 'topic': topic};

Map<String, dynamic> rosAdvertise(String topic, String type) =>
    {'op': 'advertise', 'topic': topic, 'type': type};

Map<String, dynamic> rosPublish(String topic, Map<String, dynamic> msg) =>
    {'op': 'publish', 'topic': topic, 'msg': msg};

Map<String, dynamic> rosPing() => {'op': 'ping'};

/// 构造 geometry_msgs/PoseStamped（map 帧），theta 为偏航角（弧度）。
Map<String, dynamic> buildPoseStampedMsg(double x, double y, double theta) {
  final ms = DateTime.now().millisecondsSinceEpoch;
  final half = theta / 2;
  return {
    'header': {
      'frame_id': 'map',
      'stamp': {'sec': ms ~/ 1000, 'nanosec': (ms % 1000) * 1000000},
    },
    'pose': {
      'position': {'x': x, 'y': y, 'z': 0.0},
      'orientation': {'x': 0.0, 'y': 0.0, 'z': sin(half), 'w': cos(half)},
    },
  };
}
