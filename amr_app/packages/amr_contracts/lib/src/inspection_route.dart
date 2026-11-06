/// 巡检路线数据模型（纯 Dart，不含持久化实现）。
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
