import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'map_viewport.dart';

/// 地图图层抽象接口（可插拔扩展核心）。
///
/// 新增叠加元素只需实现本接口并加入 MapView 的 layers 列表，
/// MapView 核心代码零修改。
abstract class MapLayer {
  /// 唯一标识
  String get id;

  /// 绘制顺序，越大越上层
  int get zIndex;

  bool get visible;

  /// 图层内部数据变化时触发重绘（可选）。
  /// MapView 会将其合并进 CustomPainter 的 repaint。
  Listenable? get repaintListenable => null;

  void paint(Canvas canvas, MapViewport viewport);

  /// 命中测试（屏幕坐标），返回命中元素 id，未命中返回 null。
  /// MapView 从上层到下层依次询问，命中即停止。
  String? hitTest(Offset screenPos, MapViewport viewport) => null;

  /// 图层元素是否可拖拽
  bool get draggable => false;

  void onDragStart(String hitId, Offset screenPos, MapViewport viewport) {}

  void onDragUpdate(String hitId, Offset screenPos, MapViewport viewport) {}

  void onDragEnd(String hitId, Offset screenPos, MapViewport viewport) {}

  void onTap(String hitId, Offset screenPos, MapViewport viewport) {}
}
