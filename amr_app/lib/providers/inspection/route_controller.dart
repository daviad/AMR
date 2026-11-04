import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../core/message_models.dart';
import '../../core/topic_mapping.dart';
import '../../models/inspection_point.dart';
import '../../models/inspection_route.dart';
import '../comm/mqtt_provider.dart';
import 'points_controller.dart';

/// 巡检路线 Hive Box，在 main.dart 中 override 注入已打开的 Box。
final inspectionRoutesBoxProvider = Provider<Box<InspectionRoute>>(
  (ref) => throw UnimplementedError('需在 main.dart 中 override'),
);

/// 巡检路线列表（Hive 持久化 CRUD）+ 巡检启动/停止命令。
final routeControllerProvider =
    NotifierProvider<RouteController, List<InspectionRoute>>(
        RouteController.new);

class RouteController extends Notifier<List<InspectionRoute>> {
  Box<InspectionRoute> get _box => ref.read(inspectionRoutesBoxProvider);

  @override
  List<InspectionRoute> build() => _box.values.toList(growable: false);

  Future<void> addRoute(InspectionRoute route) async {
    await _box.put(route.id, route);
    _refresh();
  }

  Future<void> removeRoute(String id) async {
    await _box.delete(id);
    _refresh();
  }

  /// 启动巡检：amr/cmd/inspection/start 携带完整路线点数据（QoS1）。
  /// 路线/巡检点存于 App 端 Hive，启动时随命令全量下发给仿真端。
  void startRoute(String routeId) {
    final route = _box.get(routeId);
    if (route == null) return;
    final pointsBox = ref.read(inspectionPointsBoxProvider);
    final points = route.pointIds
        .map((pid) => pointsBox.get(pid))
        .whereType<InspectionPoint>()
        .toList();
    if (points.isEmpty) return;
    ref.read(mqttClientProvider).publishCommand(
          TopicMapping.cmdInspectionStart,
          buildInspectionStartPayload(route, points),
        );
  }

  /// 停止巡检：amr/cmd/inspection/stop {}（QoS1）。
  void stopInspection() {
    ref.read(mqttClientProvider).publishCommand(
          TopicMapping.cmdInspectionStop,
          buildEmptyPayload(),
        );
  }

  void _refresh() {
    state = _box.values.toList(growable: false);
  }
}
