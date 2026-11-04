import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/topic_mapping.dart';
import '../comm/rosbridge_provider.dart';

/// 订阅 /plan（nav_msgs/Path），输出世界坐标路径点列。
final planProvider = StreamProvider<List<Offset>>((ref) {
  final client = ref.watch(rosbridgeClientProvider);
  return client
      .subscribe(
        TopicMapping.plan,
        type: 'nav_msgs/Path',
        queueLength: 1,
        throttleRate: 200,
      )
      .map((msg) {
    final poses = msg['poses'];
    if (poses is! List) return <Offset>[];
    final points = <Offset>[];
    for (final p in poses) {
      if (p is! Map<String, dynamic>) continue;
      final pos = (p['pose'] as Map<String, dynamic>?)?['position'];
      if (pos is! Map<String, dynamic>) continue;
      points.add(Offset(
        (pos['x'] as num).toDouble(),
        (pos['y'] as num).toDouble(),
      ));
    }
    return points;
  });
});
