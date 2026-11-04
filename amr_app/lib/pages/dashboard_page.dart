import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/topic_mapping.dart';
import '../map/layers/base_map_layer.dart';
import '../map/layers/inspection_points_layer.dart';
import '../map/layers/path_layer.dart';
import '../map/layers/robot_layer.dart';
import '../map/map_view.dart';
import '../models/occupancy_grid.dart';
import '../models/robot_status.dart';
import '../providers/comm/mqtt_provider.dart';
import '../providers/comm/rosbridge_provider.dart';
import '../providers/data/battery_provider.dart';
import '../providers/data/inspection_provider.dart';
import '../providers/data/map_provider.dart';
import '../providers/data/mode_provider.dart';
import '../providers/data/plan_provider.dart';
import '../providers/data/tf_provider.dart';
import '../providers/inspection/points_controller.dart';
import '../services/dashboard_video_io.dart'
    if (dart.library.html) '../services/dashboard_video_web.dart';

/// Web 后台大屏：地图 + 视频 + 状态 + 巡检控制。
class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  late final BaseMapLayer _baseLayer = BaseMapLayer();
  late final PathLayer _pathLayer = PathLayer();
  late final InspectionPointsLayer _pointsLayer = InspectionPointsLayer();
  late final RobotLayer _robotLayer = RobotLayer();

  String get _videoUrl =>
      'http://${AppConstants.host}:${AppConstants.hlsPort}/camera/index.m3u8';

  @override
  Widget build(BuildContext context) {
    final grid = ref.watch(mapProvider).valueOrNull;
    final batteryAsync = ref.watch(batteryProvider);
    final modeAsync = ref.watch(modeProvider);
    final inspectionAsync = ref.watch(inspectionStatusProvider);
    final points = ref.watch(pointsControllerProvider);

    // 与 map_page 一致：命令式更新各图层
    _baseLayer.updateGrid(grid);
    _pathLayer.updatePath(ref.watch(planProvider).valueOrNull ?? const []);
    _robotLayer.updatePose(ref.watch(robotPoseProvider).valueOrNull);
    _pointsLayer.updatePoints(points);

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('AMR 后台大屏'),
        backgroundColor: Colors.grey[850],
        actions: [
          _ConnIndicator(),
          const SizedBox(width: 16),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左侧：地图（60%）
            Expanded(
              flex: 6,
              child: _buildMapCard(grid),
            ),
            const SizedBox(width: 12),
            // 右侧：视频 + 状态 + 控制（40%）
            Expanded(
              flex: 4,
              child: Column(
                children: [
                  // 视频卡需用 Expanded 约束高度，否则其内部 Expanded 会占满整列
                  Expanded(child: _buildVideoCard()),
                  const SizedBox(height: 12),
                  _buildStatusCard(batteryAsync, modeAsync, inspectionAsync),
                  const SizedBox(height: 12),
                  _buildInspectionCard(points, inspectionAsync),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapCard(OccupancyGridData? grid) {
    return Card(
      color: Colors.grey[850],
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            const Text('地图', style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 8),
            Expanded(
              child: grid == null
                  ? const Center(child: CircularProgressIndicator())
                  : MapView(
                      layers: [_baseLayer, _pathLayer, _pointsLayer, _robotLayer],
                      transform: grid.transform,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoCard() {
    return Card(
      color: Colors.grey[850],
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            const Text('视频', style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 8),
            Expanded(
              child: DashboardVideoPlayer(url: _videoUrl),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(
    AsyncValue<BatteryStatus> batteryAsync,
    AsyncValue<String> modeAsync,
    AsyncValue<InspectionProgress> inspectionAsync,
  ) {
    return Card(
      color: Colors.grey[850],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('状态', style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 8),
            _StatusRow('电量', batteryAsync.when(
              data: (b) => '${b.level}% ${b.charging ? "⚡充电中" : ""}',
              loading: () => '…',
              error: (_, __) => '错误',
            )),
            _StatusRow('模式', modeAsync.when(
              data: (m) => m,
              loading: () => '…',
              error: (_, __) => '错误',
            )),
            _StatusRow('巡检', inspectionAsync.when(
              data: (i) => '${i.state} ${i.progress}/${i.total}',
              loading: () => '…',
              error: (_, __) => '错误',
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildInspectionCard(List points, AsyncValue<InspectionProgress> inspectionAsync) {
    return Card(
      color: Colors.grey[850],
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('巡检控制', style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 8),
            Text('巡检点: ${points.length} 个', style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _publishCommand(TopicMapping.cmdInspectionStart, {}),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('开始'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green[700]),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _publishCommand(TopicMapping.cmdInspectionStop, {}),
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('停止'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red[700]),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _publishCommand(String topic, Map<String, dynamic> payload) {
    ref.read(mqttClientProvider).publishCommand(topic, payload);
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 48, child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13))),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }
}

class _ConnIndicator extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mqttState = ref.watch(mqttConnectionProvider);
    final rosState = ref.watch(rosConnectionProvider);
    final mqttOk = mqttState.value ?? false;
    final rosOk = rosState.value ?? false;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 10, color: mqttOk ? Colors.green : Colors.red),
        const SizedBox(width: 4),
        const Text('MQTT', style: TextStyle(fontSize: 11, color: Colors.white54)),
        const SizedBox(width: 12),
        Icon(Icons.circle, size: 10, color: rosOk ? Colors.green : Colors.red),
        const SizedBox(width: 4),
        const Text('ROS', style: TextStyle(fontSize: 11, color: Colors.white54)),
      ],
    );
  }
}
