import 'dart:typed_data';
import 'dart:ui';

/// nav_msgs/OccupancyGrid 解析结果。
class OccupancyGridData {
  const OccupancyGridData({
    required this.width,
    required this.height,
    required this.resolution,
    required this.originX,
    required this.originY,
    required this.data,
  });

  final int width;
  final int height;

  /// 米/像素
  final double resolution;

  /// 地图左下角（data[0] 对应格）在世界坐标系中的位置
  final double originX;
  final double originY;

  /// 行优先栅格数据，-1 未知，0 空闲，100 占用。
  /// data[row * width + col]，row 0 在 origin.y（世界坐标底部）。
  final Int8List data;

  factory OccupancyGridData.fromMsg(Map<String, dynamic> msg) {
    final info = msg['info'] as Map<String, dynamic>;
    final origin = info['origin'] as Map<String, dynamic>;
    final position = origin['position'] as Map<String, dynamic>;
    final raw = msg['data'] as List<dynamic>;
    final data = Int8List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      data[i] = (raw[i] as num).toInt();
    }
    return OccupancyGridData(
      width: (info['width'] as num).toInt(),
      height: (info['height'] as num).toInt(),
      resolution: (info['resolution'] as num).toDouble(),
      originX: (position['x'] as num).toDouble(),
      originY: (position['y'] as num).toDouble(),
      data: data,
    );
  }

  MapTransform get transform => MapTransform(
        resolution: resolution,
        origin: Offset(originX, originY),
        width: width,
        height: height,
      );
}

/// 世界坐标（米） ↔ 地图位图像素坐标 换算器。
///
/// 位图像素系：原点在图像左上角，x 向右，y 向下。
/// 世界系：原点在地图 origin（左下角），x 向右，y 向上。
class MapTransform {
  const MapTransform({
    required this.resolution,
    required this.origin,
    required this.width,
    required this.height,
  });

  final double resolution;
  final Offset origin;
  final int width;
  final int height;

  Offset worldToPixel(Offset world) => Offset(
        (world.dx - origin.dx) / resolution,
        height - (world.dy - origin.dy) / resolution,
      );

  Offset pixelToWorld(Offset pixel) => Offset(
        origin.dx + pixel.dx * resolution,
        origin.dy + (height - pixel.dy) * resolution,
      );
}
