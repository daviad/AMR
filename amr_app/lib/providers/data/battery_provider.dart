import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/topic_mapping.dart';
import '../../models/robot_status.dart';
import '../comm/mqtt_provider.dart';

/// 电池状态（amr/status/battery，QoS0 retain）。
final batteryProvider = StreamProvider<BatteryStatus>((ref) {
  return ref
      .watch(mqttClientProvider)
      .subscribe(TopicMapping.statusBattery)
      .map(BatteryStatus.fromJson);
});
