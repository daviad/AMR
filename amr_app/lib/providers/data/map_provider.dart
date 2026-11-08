import 'dart:async';
import 'dart:typed_data';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/occupancy_grid.dart';
import '../comm/gateway_provider.dart';

/// 地图：HTTP 下载 + 本地版本缓存（不再是 rosbridge 流）。
///
/// 流程（架构文档 §9）：
///   1. 先读 Hive 缓存立即出图（冷启动不等网络）；
///   2. 取 /api/v1/map/meta，version 不同才下载 /api/v1/map/pgm；
///   3. 15s 轮询一次 meta，建图/换图时自动刷新。
///
/// 这样做的原因：`/map` 是 latched 话题，网关独占订阅并落盘成 PGM，
/// App 只按 version 拉取，顺便修掉“晚订阅拿不到唯一一帧”的结构性问题。
final mapProvider = StreamProvider<OccupancyGridData>((ref) async* {
  final gateway = ref.watch(gatewayClientProvider);
  final box = await Hive.openBox('gateway_map');

  final cached = _readCache(box);
  if (cached != null) yield cached;

  while (true) {
    try {
      final meta = await gateway.mapMeta();
      if (meta != null) {
        final version = '${meta['version']}';
        if (cached == null || box.get('version') != version) {
          final pgm = await gateway.mapPgm(version);
          if (pgm != null) {
            final grid = parsePgm(pgm, meta);
            await box.put('version', version);
            await box.put('meta', meta);
            await box.put('pgm', pgm);
            yield grid;
          }
        }
      }
    } catch (_) {
      // 网关暂不可用：保留上一张图（缓存或最后一次成功下载）
    }
    await Future<void>.delayed(const Duration(seconds: 15));
  }
});

OccupancyGridData? _readCache(Box box) {
  final pgm = box.get('pgm');
  final meta = box.get('meta');
  if (pgm is! List || meta is! Map) return null;
  try {
    return parsePgm(
      Uint8List.fromList(pgm.cast<int>()),
      Map<String, dynamic>.from(meta),
    );
  } catch (_) {
    return null;
  }
}

/// 解析 PGM(P5) + meta → OccupancyGridData。
///
/// 网关落盘时行序是“上→下（图片习惯）”，而 OccupancyGrid 的行 0 在世界坐标底部，
/// 所以这里要翻转一次；像素映射：0→占用(100)、254→空闲(0)、205→未知(-1)。
OccupancyGridData parsePgm(Uint8List bytes, Map<String, dynamic> meta) {
  var pos = 0;
  final tokens = <String>[];
  while (tokens.length < 4 && pos < bytes.length) {
    // 跳过空白
    while (pos < bytes.length && _isWhitespace(bytes[pos])) {
      pos++;
    }
    // 跳过注释行（PGM 允许 # 注释）
    if (pos < bytes.length && bytes[pos] == 0x23) {
      while (pos < bytes.length && bytes[pos] != 0x0A) {
        pos++;
      }
      continue;
    }
    final start = pos;
    while (pos < bytes.length && !_isWhitespace(bytes[pos])) {
      pos++;
    }
    if (pos > start) tokens.add(String.fromCharCodes(bytes.sublist(start, pos)));
  }
  pos++; // 跳过分隔 magic/width/height/maxval 与像素数据的最后一个空白
  if (tokens.length < 4 || tokens[0] != 'P5') {
    throw const FormatException('不是 P5 PGM');
  }
  final width = int.parse(tokens[1]);
  final height = int.parse(tokens[2]);
  if (bytes.length < pos + width * height) {
    throw const FormatException('PGM 像素数据不完整');
  }

  final flipped = meta['row_order'] == 'top_down';
  final data = Int8List(width * height);
  for (var row = 0; row < height; row++) {
    final srcRow = flipped ? row : height - 1 - row;
    final srcBase = pos + srcRow * width;
    final dstBase = (height - 1 - row) * width;
    for (var col = 0; col < width; col++) {
      final p = bytes[srcBase + col];
      data[dstBase + col] = p <= 5 ? 100 : (p >= 250 ? 0 : -1);
    }
  }

  final origin = (meta['origin'] as Map?) ?? const {};
  return OccupancyGridData(
    width: width,
    height: height,
    resolution: (meta['resolution'] as num?)?.toDouble() ?? 0.05,
    originX: (origin['x'] as num?)?.toDouble() ?? 0.0,
    originY: (origin['y'] as num?)?.toDouble() ?? 0.0,
    data: data,
  );
}

bool _isWhitespace(int c) => c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09;
