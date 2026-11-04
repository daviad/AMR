import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/occupancy_grid.dart';
import '../map_layer.dart';
import '../map_viewport.dart';

/// 底图图层（zIndex 0）：OccupancyGrid → 缓存位图。
/// grid 实例不变时复用位图，变化时异步重建并触发重绘。
class BaseMapLayer extends MapLayer with ChangeNotifier {
  BaseMapLayer([OccupancyGridData? grid]) {
    updateGrid(grid);
  }

  @override
  String get id => 'base_map';

  @override
  int get zIndex => 0;

  @override
  bool get visible => true;

  @override
  Listenable? get repaintListenable => this;

  OccupancyGridData? _grid;
  ui.Image? _image;
  bool _building = false;

  OccupancyGridData? get grid => _grid;

  void updateGrid(OccupancyGridData? grid) {
    if (identical(grid, _grid)) return;
    _grid = grid;
    _image = null;
    if (grid != null) {
      _buildImage(grid);
    }
    notifyListeners();
  }

  Future<void> _buildImage(OccupancyGridData grid) async {
    if (_building) return;
    _building = true;
    try {
      final w = grid.width;
      final h = grid.height;
      final rgba = Uint8List(w * h * 4);
      for (var py = 0; py < h; py++) {
        // 位图第 0 行在顶部 ↔ 栅格第 (h-1-py) 行
        final rowBase = (h - 1 - py) * w;
        for (var px = 0; px < w; px++) {
          final v = grid.data[rowBase + px];
          final i = (py * w + px) * 4;
          if (v < 0) {
            // 未知：灰
            rgba[i] = 0x60;
            rgba[i + 1] = 0x60;
            rgba[i + 2] = 0x68;
          } else if (v == 0) {
            // 空闲：浅
            rgba[i] = 0xE8;
            rgba[i + 1] = 0xE8;
            rgba[i + 2] = 0xE8;
          } else {
            // 占用：按概率由浅到深
            final shade = 0xE8 - (v * 0xE8 ~/ 100);
            rgba[i] = shade;
            rgba[i + 1] = shade;
            rgba[i + 2] = shade;
          }
          rgba[i + 3] = 0xFF;
        }
      }
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba,
        w,
        h,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      // 构建期间 grid 可能又变了，丢弃旧结果
      final image = await completer.future;
      if (identical(grid, _grid)) {
        _image = image;
        notifyListeners();
      }
    } finally {
      _building = false;
    }
  }

  @override
  void paint(Canvas canvas, MapViewport viewport) {
    final grid = _grid;
    if (grid == null) return;
    final image = _image;
    final topLeft = viewport.pixelToScreen(Offset.zero);
    final bottomRight = viewport.pixelToScreen(
        Offset(grid.width.toDouble(), grid.height.toDouble()));
    final dst = ui.Rect.fromPoints(topLeft, bottomRight);
    if (image == null) {
      // 位图构建中：先画占位底
      canvas.drawRect(dst, Paint()..color = const Color(0xFF606068));
      return;
    }
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(
          0, 0, grid.width.toDouble(), grid.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.none,
    );
  }
}
