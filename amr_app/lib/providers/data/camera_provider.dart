import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/video_stream_service.dart';

/// 摄像头 JPEG 帧流（仅 rosbridge 模式）。
/// autoDispose：离开相机页无监听时自动停止订阅，节省带宽。
final cameraFrameProvider = Provider.autoDispose<Stream<Uint8List>?>((ref) {
  final manager = ref.watch(videoStreamManagerProvider);
  final player = manager.player;
  if (player == null || player.source != VideoSource.rosbridge) {
    return null;
  }
  return player.frameStream;
});

/// 确保 manager 已初始化（在 App 启动或进入相机页时调用）。
final videoManagerInitProvider = FutureProvider<void>((ref) async {
  final manager = ref.read(videoStreamManagerProvider.notifier);
  await manager.init();
});
