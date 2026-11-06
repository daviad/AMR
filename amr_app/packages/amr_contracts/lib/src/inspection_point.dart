/// 巡检点数据模型（纯 Dart，不含持久化实现）。
class InspectionPoint {
  const InspectionPoint({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    required this.theta,
    this.dwellTime = 3,
    this.capturePhoto = false,
  });

  final String id;
  final String name;
  final double x;
  final double y;
  final double theta;

  /// 停留时间（秒）
  final int dwellTime;

  /// 到达后是否拍照
  final bool capturePhoto;

  InspectionPoint copyWith({
    String? name,
    double? x,
    double? y,
    double? theta,
    int? dwellTime,
    bool? capturePhoto,
  }) =>
      InspectionPoint(
        id: id,
        name: name ?? this.name,
        x: x ?? this.x,
        y: y ?? this.y,
        theta: theta ?? this.theta,
        dwellTime: dwellTime ?? this.dwellTime,
        capturePhoto: capturePhoto ?? this.capturePhoto,
      );
}
