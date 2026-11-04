import 'package:flutter/material.dart';

import '../models/occupancy_grid.dart';
import 'map_layer.dart';
import 'map_painter.dart';
import 'map_viewport.dart';

/// 核心地图视图：视口变换 + 手势处理 + 图层调度。
/// 不含业务逻辑，图层可插拔。
class MapView extends StatefulWidget {
  const MapView({
    super.key,
    required this.layers,
    this.transform,
    this.onMapTap,
  });

  /// 图层列表（内部按 zIndex 排序绘制）
  final List<MapLayer> layers;

  /// 世界 ↔ 位图像素换算器（来自地图数据），为 null 时 world 按像素处理
  final MapTransform? transform;

  /// 点击地图空白处回调（世界坐标）
  final void Function(Offset world)? onMapTap;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  final MapViewport _viewport = MapViewport();
  MapLayer? _dragLayer;
  String? _dragHitId;
  Size? _viewSize;
  bool _fitted = false;

  @override
  Widget build(BuildContext context) {
    _viewport.transform = widget.transform;
    final layers = widget.layers.where((l) => l.visible).toList()
      ..sort((a, b) => a.zIndex.compareTo(b.zIndex));
    final listenables = layers
        .map((l) => l.repaintListenable)
        .whereType<Listenable>()
        .toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewSize = constraints.biggest;
        // 首次拿到地图数据时自动适配视野
        if (!_fitted && widget.transform != null && _viewSize != null) {
          _fitted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _viewport.fitToContent(_viewSize!));
          });
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          onTapUp: _onTapUp,
          child: CustomPaint(
            size: Size.infinite,
            painter: MapPainter(
              layers: layers,
              viewport: _viewport,
              repaint: listenables.isEmpty ? null : Listenable.merge(listenables),
            ),
          ),
        );
      },
    );
  }

  /// 从上层到下层命中测试，命中即停止。
  ({MapLayer layer, String hitId})? _hitTest(Offset screenPos) {
    final topDown = widget.layers.where((l) => l.visible).toList()
      ..sort((a, b) => b.zIndex.compareTo(a.zIndex));
    for (final layer in topDown) {
      final hitId = layer.hitTest(screenPos, _viewport);
      if (hitId != null) return (layer: layer, hitId: hitId);
    }
    return null;
  }

  void _onScaleStart(ScaleStartDetails details) {
    final hit = _hitTest(details.localFocalPoint);
    if (hit != null && hit.layer.draggable) {
      _dragLayer = hit.layer;
      _dragHitId = hit.hitId;
      hit.layer.onDragStart(hit.hitId, details.localFocalPoint, _viewport);
    } else {
      _dragLayer = null;
      _dragHitId = null;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final dragLayer = _dragLayer;
    if (dragLayer != null) {
      dragLayer.onDragUpdate(
          _dragHitId!, details.localFocalPoint, _viewport);
      return;
    }
    setState(() {
      _viewport.panBy(details.focalPointDelta);
      _viewport.zoomAt(details.localFocalPoint, details.scale);
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final dragLayer = _dragLayer;
    if (dragLayer != null && _dragHitId != null) {
      dragLayer.onDragEnd(_dragHitId!, Offset.zero, _viewport);
    }
    _dragLayer = null;
    _dragHitId = null;
  }

  void _onTapUp(TapUpDetails details) {
    final hit = _hitTest(details.localPosition);
    if (hit != null) {
      hit.layer.onTap(hit.hitId, details.localPosition, _viewport);
      return;
    }
    widget.onMapTap?.call(_viewport.screenToWorld(details.localPosition));
  }
}
