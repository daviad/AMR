import 'package:flutter/material.dart';

import 'map_layer.dart';
import 'map_viewport.dart';

/// 地图绘制器：按 zIndex 顺序调度各图层 paint。
class MapPainter extends CustomPainter {
  MapPainter({
    required this.layers,
    required this.viewport,
    super.repaint,
  });

  /// 已按 zIndex 升序排序的可见图层
  final List<MapLayer> layers;
  final MapViewport viewport;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final layer in layers) {
      layer.paint(canvas, viewport);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MapPainter oldDelegate) => true;
}
