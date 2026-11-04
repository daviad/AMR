import 'package:flutter/material.dart';

import '../map_layer.dart';
import '../map_viewport.dart';

/// 路径图层（zIndex 10）：绘制 /plan 规划路径。
class PathLayer extends MapLayer {
  PathLayer([List<Offset>? path]) : _path = path ?? const [];

  @override
  String get id => 'path';

  @override
  int get zIndex => 10;

  @override
  bool get visible => true;

  List<Offset> _path;

  void updatePath(List<Offset> path) {
    _path = path;
  }

  @override
  void paint(Canvas canvas, MapViewport viewport) {
    if (_path.length < 2) return;
    final paint = Paint()
      ..color = Colors.blueAccent
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(
        viewport.worldToScreen(_path.first).dx,
        viewport.worldToScreen(_path.first).dy,
      );
    for (final p in _path.skip(1)) {
      final s = viewport.worldToScreen(p);
      path.lineTo(s.dx, s.dy);
    }
    canvas.drawPath(path, paint);
  }
}
