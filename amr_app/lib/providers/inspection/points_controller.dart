import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../models/inspection_point.dart';

/// 巡检点 Hive Box，在 main.dart 中 override 注入已打开的 Box。
final inspectionPointsBoxProvider = Provider<Box<InspectionPoint>>(
  (ref) => throw UnimplementedError('需在 main.dart 中 override'),
);

/// 巡检点列表（Hive 持久化 CRUD）。
final pointsControllerProvider =
    NotifierProvider<PointsController, List<InspectionPoint>>(
        PointsController.new);

class PointsController extends Notifier<List<InspectionPoint>> {
  Box<InspectionPoint> get _box => ref.read(inspectionPointsBoxProvider);

  @override
  List<InspectionPoint> build() => _box.values.toList(growable: false);

  Future<void> addPoint(InspectionPoint point) async {
    await _box.put(point.id, point);
    _refresh();
  }

  Future<void> updatePoint(InspectionPoint point) async {
    await _box.put(point.id, point);
    _refresh();
  }

  Future<void> removePoint(String id) async {
    await _box.delete(id);
    _refresh();
  }

  /// 地图拖拽后更新坐标。
  Future<void> movePoint(String id, Offset world) async {
    final point = _box.get(id);
    if (point == null) return;
    await _box.put(id, point.copyWith(x: world.dx, y: world.dy));
    _refresh();
  }

  void _refresh() {
    state = _box.values.toList(growable: false);
  }
}
