import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../comm/rosbridge_client.dart';
import '../core/topic_mapping.dart';

/// 拍照：按需订阅一次 CompressedImage，取第一帧 JPEG 后立即退订。
/// 视频预览走 WebRTC，图片通道只负责拍照，两者互不复用。
class PhotoCaptureService {
  PhotoCaptureService(this._client);

  final RosbridgeClient _client;

  Future<Uint8List> captureJpeg({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final msg = await _client
        .subscribe(
          TopicMapping.cameraCompressed,
          type: 'sensor_msgs/CompressedImage',
          queueLength: 1,
        )
        .first
        .timeout(timeout);
    final data = msg['data'];
    if (data is! String) {
      throw StateError('CompressedImage 缺少 data');
    }
    return base64Decode(data);
  }
}
