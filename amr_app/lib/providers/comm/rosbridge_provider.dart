import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../comm/rosbridge_client.dart';
import '../../core/constants.dart';

/// rosbridge 客户端单例，常驻，自动重连。
final rosbridgeClientProvider = Provider<RosbridgeClient>((ref) {
  final client = RosbridgeClient(url: AppConstants.rosbridgeWsUrl);
  client.connect();
  ref.onDispose(client.dispose);
  return client;
});

/// rosbridge 连接状态流。
final rosConnectionProvider = StreamProvider<bool>((ref) {
  return ref.watch(rosbridgeClientProvider).connectionState;
});
