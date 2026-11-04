import 'package:hive/hive.dart';

/// 巡检路线（Hive typeId 1），手写 TypeAdapter。
class InspectionRoute {
  const InspectionRoute({
    required this.id,
    required this.name,
    required this.pointIds,
    this.loop = false,
  });

  final String id;
  final String name;

  /// 巡检点 id 列表，按执行顺序
  final List<String> pointIds;

  /// 是否循环执行
  final bool loop;

  InspectionRoute copyWith({
    String? name,
    List<String>? pointIds,
    bool? loop,
  }) =>
      InspectionRoute(
        id: id,
        name: name ?? this.name,
        pointIds: pointIds ?? this.pointIds,
        loop: loop ?? this.loop,
      );
}

class InspectionRouteAdapter extends TypeAdapter<InspectionRoute> {
  @override
  final int typeId = 1;

  @override
  InspectionRoute read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return InspectionRoute(
      id: fields[0] as String,
      name: fields[1] as String,
      pointIds:
          (fields[2] as List?)?.cast<String>() ?? const <String>[],
      loop: fields[3] as bool? ?? false,
    );
  }

  @override
  void write(BinaryWriter writer, InspectionRoute obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.pointIds)
      ..writeByte(3)
      ..write(obj.loop);
  }
}
