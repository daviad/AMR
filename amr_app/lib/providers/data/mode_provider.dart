import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/topic_mapping.dart';
import '../comm/mqtt_provider.dart';

/// 机器人当前模式（amr/status/mode，QoS0 retain）。
/// 值：manual / auto / inspect / charge，由仿真端状态机唯一决策。
final modeProvider = StreamProvider<String>((ref) {
  return ref
      .watch(mqttClientProvider)
      .subscribe(TopicMapping.statusMode)
      .map((json) => json['mode'] as String? ?? 'unknown');
});
