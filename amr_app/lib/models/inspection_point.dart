import 'package:amr_contracts/amr_contracts.dart';
import 'package:hive/hive.dart';

export 'package:amr_contracts/amr_contracts.dart' show InspectionPoint;

/// 巡检点（Hive typeId 0），手写 TypeAdapter。
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
