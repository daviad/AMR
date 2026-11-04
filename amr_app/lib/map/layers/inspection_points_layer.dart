import 'dart:math';

import 'package:flutter/material.dart';

import '../../models/inspection_point.dart';
import '../map_layer.dart';
import '../map_viewport.dart';

/// 巡检点图层（zIndex 40）：编号圆点 + 朝向线，支持命中测试与拖拽编辑。
class InspectionPointsLayer extends MapLayer with ChangeNotifier {
  InspectionPointsLayer({
    List<InspectionPoint> points = const [],
    this.draggablePoints = false,
    this.onPointMoved,
    this.onPointTap,
  }) : _points = points;

  @override
  String get id => 'inspection_points';

  @override
  int get zIndex => 40;

  @override
  bool get visible => true;

  @override
  Listenable? get repaintListenable => this;

  List<InspectionPoint> _points;

  /// 是否允许拖拽编辑（由页面编辑模式控制）
  bool draggablePoints;

  /// 拖拽结束回调（pointId, 新世界坐标）
  final void Function(String id, Offset world)? onPointMoved;

  /// 点击巡检点回调
  final void Function(String id)? onPointTap;

  /// 拖拽中的临时位置（提交前预览）
  final Map<String, Offset> _dragOverrides = {};

  @override
  bool get draggable => draggablePoints;

  void updatePoints(List<InspectionPoint> points) {
    _points = points;
  }

  Offset _pointWorld(InspectionPoint p) =>
      _dragOverrides[p.id] ?? Offset(p.x, p.y);

  @override
  String? hitTest(Offset screenPos, MapViewport viewport) {
    for (final p in _points.reversed) {
      final s = viewport.worldToScreen(_pointWorld(p));
      if ((s - screenPos).distance <= 20) return p.id;
    }
    return null;
  }

  @override
  void onDragUpdate(String hitId, Offset screenPos, MapViewport viewport) {
    _dragOverrides[hitId] = viewport.screenToWorld(screenPos);
    notifyListeners();
  }

  @override
  void onDragEnd(String hitId, Offset screenPos, MapViewport viewport) {
    final world = _dragOverrides.remove(hitId);
    if (world != null) {
      onPointMoved?.call(hitId, world);
    }
    notifyListeners();
  }

  @override
  void onTap(String hitId, Offset screenPos, MapViewport viewport) {
    onPointTap?.call(hitId);
  }

  @override
  void paint(Canvas canvas, MapViewport viewport) {
    for (var i = 0; i < _points.length; i++) {
      final p = _points[i];
      final world = _pointWorld(p);
      final center = viewport.worldToScreen(world);
      const radius = 11.0;

      final bodyPaint = Paint()..color = Colors.orange;
      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(center, radius, bodyPaint);
      canvas.drawCircle(center, radius, borderPaint);

      // 朝向线
      final dir = Offset(cos(p.theta), -sin(p.theta));
      canvas.drawLine(
          center,
          center + dir * (radius + 8),
          Paint()
            ..color = Colors.orange
            ..strokeWidth = 2);

      // 序号
      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(
              color: Colors.black,
              fontSize: 11,
              fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
          canvas, center - Offset(tp.width / 2, tp.height / 2));
    }
  }
}
