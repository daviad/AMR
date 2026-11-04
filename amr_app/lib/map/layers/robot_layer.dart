import 'dart:math';

import 'package:flutter/material.dart';

import '../../models/robot_pose.dart';
import '../map_layer.dart';
import '../map_viewport.dart';

/// 机器人图层（zIndex 50）：位姿圆 + 朝向箭头。
class RobotLayer extends MapLayer {
  RobotLayer([RobotPose? pose]) : _pose = pose;

  @override
  String get id => 'robot';

  @override
  int get zIndex => 50;

  @override
  bool get visible => true;

  RobotPose? _pose;

  void updatePose(RobotPose? pose) {
    _pose = pose;
  }

  @override
  void paint(Canvas canvas, MapViewport viewport) {
    final pose = _pose;
    if (pose == null) return;
    final center = viewport.worldToScreen(Offset(pose.x, pose.y));
    // 机器人半径 0.18m 换算到屏幕：屏幕 px/米 = scale / resolution，限制在可读范围
    final t = viewport.transform;
    final pxPerMeter = t == null ? viewport.scale : viewport.scale / t.resolution;
    final radius = (0.18 * pxPerMeter).clamp(8.0, 48.0);

    final bodyPaint = Paint()..color = Colors.green;
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, radius, bodyPaint);
    canvas.drawCircle(center, radius, borderPaint);

    // 朝向箭头
    final dir = Offset(cos(pose.theta), -sin(pose.theta)); // 屏幕 y 向下
    final tip = center + dir * (radius + 10);
    final arrowPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, tip, arrowPaint);
  }
}
