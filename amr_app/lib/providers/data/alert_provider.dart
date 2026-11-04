import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/topic_mapping.dart';
import '../../models/robot_status.dart';
import '../comm/mqtt_provider.dart';

/// 告警流（amr/alert，QoS0）。UI 侧用 ref.listen 消费。
final alertProvider = StreamProvider<AlertMessage>((ref) {
  return ref
      .watch(mqttClientProvider)
      .subscribe(TopicMapping.alert)
      .map(AlertMessage.fromJson);
});
