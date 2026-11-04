import 'package:hive/hive.dart';

/// 巡检点（Hive typeId 0），手写 TypeAdapter。
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

class InspectionPointAdapter extends TypeAdapter<InspectionPoint> {
  @override
  final int typeId = 0;

  @override
  InspectionPoint read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return InspectionPoint(
      id: fields[0] as String,
      name: fields[1] as String,
      x: (fields[2] as num).toDouble(),
      y: (fields[3] as num).toDouble(),
      theta: (fields[4] as num).toDouble(),
      dwellTime: (fields[5] as num?)?.toInt() ?? 3,
      capturePhoto: fields[6] as bool? ?? false,
    );
  }

  @override
  void write(BinaryWriter writer, InspectionPoint obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.x)
      ..writeByte(3)
      ..write(obj.y)
      ..writeByte(4)
      ..write(obj.theta)
      ..writeByte(5)
      ..write(obj.dwellTime)
      ..writeByte(6)
      ..write(obj.capturePhoto);
  }
}
