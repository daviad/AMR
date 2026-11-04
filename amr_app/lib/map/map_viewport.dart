import 'dart:math';
import 'dart:ui';

import '../models/occupancy_grid.dart';

/// 地图视口：管理 屏幕坐标 ↔ 世界坐标 的两级变换。
///
/// 变换链：world --(MapTransform)--> 地图位图像素 --(offset/scale)--> 屏幕。
/// 位图 → 屏幕：screen = pixel * scale + offset。
class MapViewport {
  MapViewport({
    this.offset = Offset.zero,
    this.scale = 20.0,
    this.transform,
  });

  /// 屏幕平移量（像素）
  Offset offset;

  /// 缩放（屏幕像素 / 地图位图像素）
  double scale;

  /// 世界 ↔ 位图像素 换算器，无地图时为 null（此时 world 直接按位图像素处理）
  MapTransform? transform;

  double minScale = 0.05;
  double maxScale = 50.0;

  Offset pixelToScreen(Offset pixel) => pixel * scale + offset;

  Offset screenToPixel(Offset screen) => (screen - offset) / scale;

  Offset worldToScreen(Offset world) {
    final t = transform;
    return pixelToScreen(t == null ? world : t.worldToPixel(world));
  }

  Offset screenToWorld(Offset screen) {
    final t = transform;
    final pixel = screenToPixel(screen);
    return t == null ? pixel : t.pixelToWorld(pixel);
  }

  /// 以屏幕点 focal 为中心缩放。
  void zoomAt(Offset focal, double factor) {
    final before = screenToPixel(focal);
    scale = (scale * factor).clamp(minScale, maxScale);
    // 保持 focal 处地图内容不动：offset = focal - pixel * scale
    offset = focal - before * scale;
  }

  void panBy(Offset delta) {
    offset += delta;
  }

  /// 将整张地图适配到视图大小并居中。
  void fitToContent(Size viewSize) {
    final t = transform;
    if (t == null || t.width <= 0 || t.height <= 0) return;
    final sx = viewSize.width / t.width;
    final sy = viewSize.height / t.height;
    scale = min(sx, sy) * 0.95;
    final centerPixel = Offset(t.width / 2, t.height / 2);
    offset = Offset(viewSize.width / 2, viewSize.height / 2) -
        centerPixel * scale;
  }
}
