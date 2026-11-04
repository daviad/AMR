import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/topic_mapping.dart';
import '../../models/robot_status.dart';
import '../comm/mqtt_provider.dart';

/// 巡检进度（amr/status/inspection，QoS0）。
final inspectionStatusProvider = StreamProvider<InspectionProgress>((ref) {
  return ref
      .watch(mqttClientProvider)
      .subscribe(TopicMapping.statusInspection)
      .map(InspectionProgress.fromJson);
});
