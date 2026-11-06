import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/topic_mapping.dart';
import '../../models/occupancy_grid.dart';
import '../comm/rosbridge_provider.dart';

/// 订阅 /map（nav_msgs/OccupancyGrid），低频，节流 500ms。
///
/// /map 由 map_server 以 RELIABLE + TRANSIENT_LOCAL（latched）发布，且只在
/// 加载地图时发一帧。rosbridge 默认推断出的订阅是 VOLATILE，晚订阅就拿不到
/// 这唯一一帧，页面会一直停在「等待地图数据…」。这里显式声明 latched QoS
/// （必须在 topic 的首个订阅上生效，rosbridge 后续客户端会复用同一 DDS 订阅）。
const _latchedQos = {
  'durability': 'transient_local',
  'reliability': 'reliable',
  'history': 'keep_last',
  'depth': 1,
};

final mapProvider = StreamProvider<OccupancyGridData>((ref) {
  final client = ref.watch(rosbridgeClientProvider);
  return client
      .subscribe(
        TopicMapping.map,
        type: 'nav_msgs/OccupancyGrid',
        queueLength: 1,
        throttleRate: 500,
        qos: _latchedQos,
      )
      .map(OccupancyGridData.fromMsg);
});
