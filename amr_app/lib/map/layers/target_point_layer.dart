import 'dart:math';

import 'package:flutter/material.dart';

import '../map_layer.dart';
import '../map_viewport.dart';

/// 目标点图层（zIndex 60）：点击导航待确认目标（圆环 + 十字 + 朝向箭头）。
class TargetPointLayer extends MapLayer {
  @override
  String get id => 'target_point';

  @override
  int get zIndex => 60;

  @override
  bool get visible => true;

  Offset? _world;
  double _theta = 0;

  void updateGoal(Offset? world, double theta) {
    _world = world;
    _theta = theta;
  }

  @override
  void paint(Canvas canvas, MapViewport viewport) {
    final world = _world;
    if (world == null) return;
    final center = viewport.worldToScreen(world);
    const radius = 14.0;

    final ringPaint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, ringPaint);
    canvas.drawLine(center - const Offset(radius, 0),
        center + const Offset(radius, 0), ringPaint);
    canvas.drawLine(center - const Offset(0, radius),
        center + const Offset(0, radius), ringPaint);

    // 朝向箭头
    final dir = Offset(cos(_theta), -sin(_theta));
    final tip = center + dir * (radius + 16);
    canvas.drawLine(
        center, tip, ringPaint..strokeWidth = 3);
    canvas.drawCircle(tip, 4, Paint()..color = Colors.redAccent);
  }
}
