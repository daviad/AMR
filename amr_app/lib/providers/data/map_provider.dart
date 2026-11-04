import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/topic_mapping.dart';
import '../../models/occupancy_grid.dart';
import '../comm/rosbridge_provider.dart';

/// 订阅 /map（nav_msgs/OccupancyGrid），低频，节流 500ms。
final mapProvider = StreamProvider<OccupancyGridData>((ref) {
  final client = ref.watch(rosbridgeClientProvider);
  return client
      .subscribe(
        TopicMapping.map,
        type: 'nav_msgs/OccupancyGrid',
        queueLength: 1,
        throttleRate: 500,
      )
      .map(OccupancyGridData.fromMsg);
});
