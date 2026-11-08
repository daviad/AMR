import 'dart:async';
import 'dart:typed_data';

import '../comm/gateway_client.dart';

/// 拍照：`GET /api/v1/snapshot` 取网关缓存的最新 JPEG 帧。
///
/// 视频预览走 WebRTC / HLS 直连 MediaMTX，图片通道只负责拍照，两者互不复用。
/// 网关还没收到 `/camera/image_raw/compressed` 时返回 503 NO_FRAME → 抛异常。
class PhotoCaptureService {
  PhotoCaptureService(this._client);

  final GatewayClient _client;

  Future<Uint8List> captureJpeg({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final bytes = await _client.snapshot().timeout(timeout);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('网关还没有图像帧（NO_FRAME）');
    }
    return bytes;
  }
}
