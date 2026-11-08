import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../comm/gateway_client.dart';
import '../core/message_models.dart';
import '../map/layers/base_map_layer.dart';
import '../map/layers/inspection_points_layer.dart';
import '../map/layers/path_layer.dart';
import '../map/layers/robot_layer.dart';
import '../map/layers/target_point_layer.dart';
import '../map/map_view.dart';
import '../models/command.dart';
import '../models/robot_status.dart';
import '../providers/comm/gateway_provider.dart';
import '../providers/data/alert_provider.dart';
import '../providers/data/battery_provider.dart';
import '../providers/data/map_provider.dart';
import '../providers/data/mode_provider.dart';
import '../providers/data/plan_provider.dart';
import '../providers/data/tf_provider.dart';
import '../providers/inspection/points_controller.dart';
import '../providers/navigation/mission_command_controller.dart';
import '../providers/navigation/navigation_controller.dart';
import '../widgets/point_editor_dialog.dart';

/// 地图交互模式。
enum _MapEditMode { navigate, addPoint, editPoints }

/// 主页：地图 + 点击导航 + 控制按钮 + 状态栏 + 告警监听。
class MapPage extends ConsumerStatefulWidget {
  const MapPage({super.key});

  @override
  ConsumerState<MapPage> createState() => _MapPageState();
}

class _MapPageState extends ConsumerState<MapPage> {
  _MapEditMode _editMode = _MapEditMode.navigate;

  // 图层对象持久持有（位图缓存、拖拽状态在图层内部）
  late final BaseMapLayer _baseLayer = BaseMapLayer();
  late final PathLayer _pathLayer = PathLayer();
  late final InspectionPointsLayer _pointsLayer = InspectionPointsLayer(
    onPointMoved: (id, world) =>
        ref.read(pointsControllerProvider.notifier).movePoint(id, world),
    onPointTap: _onPointTap,
  );
  late final RobotLayer _robotLayer = RobotLayer();
  late final TargetPointLayer _targetLayer = TargetPointLayer();

  @override
  Widget build(BuildContext context) {
    // 告警弹窗监听（error 弹窗，warn/info 用 SnackBar）
    ref.listen(alertProvider, (_, next) {
      final alert = next.valueOrNull;
      if (alert != null) _showAlert(alert);
    });

    final grid = ref.watch(mapProvider).valueOrNull;
    _baseLayer.updateGrid(grid);
    _pathLayer.updatePath(ref.watch(planProvider).valueOrNull ?? const []);
    _robotLayer.updatePose(ref.watch(robotPoseProvider).valueOrNull);
    _pointsLayer.updatePoints(ref.watch(pointsControllerProvider));
    _pointsLayer.draggablePoints = _editMode == _MapEditMode.editPoints;
    final nav = ref.watch(navigationControllerProvider);
    _targetLayer.updateGoal(nav.pendingWorld, nav.theta);
    final mission = ref.watch(missionCommandProvider);

    final battery = ref.watch(batteryProvider).valueOrNull;
    final mode = ref.watch(modeProvider).valueOrNull ?? '--';
    final health = ref.watch(gatewayHealthProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AMR 巡检'),
        actions: [
          _connDot(health?.http ?? false, 'GW'),
          _connDot(health?.ws ?? false, 'WS'),
          _connDot(health?.mqtt ?? false, 'MQTT'),
          const SizedBox(width: 8),
          _batteryIndicator(battery),
          const SizedBox(width: 8),
          _modeMenu(mode),
          IconButton(
            icon: const Icon(Icons.route),
            tooltip: '巡检管理',
            onPressed: () => Navigator.of(context).pushNamed('/inspection'),
          ),
          IconButton(
            icon: const Icon(Icons.videocam),
            tooltip: '摄像头',
            onPressed: () => Navigator.of(context).pushNamed('/camera'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: grid == null
                ? const Center(child: Text('等待地图数据…'))
                : MapView(
                    layers: [
                      _baseLayer,
                      _pathLayer,
                      _pointsLayer,
                      _robotLayer,
                      _targetLayer,
                    ],
                    transform: grid.transform,
                    onMapTap: _onMapTap,
                  ),
          ),
          // 地图交互模式切换
          Positioned(
            top: 8,
            left: 8,
            child: SegmentedButton<_MapEditMode>(
              segments: const [
                ButtonSegment(
                    value: _MapEditMode.navigate,
                    icon: Icon(Icons.near_me),
                    label: Text('导航')),
                ButtonSegment(
                    value: _MapEditMode.addPoint,
                    icon: Icon(Icons.add_location_alt),
                    label: Text('加点')),
                ButtonSegment(
                    value: _MapEditMode.editPoints,
                    icon: Icon(Icons.edit_location_alt),
                    label: Text('编辑点')),
              ],
              selected: {_editMode},
              onSelectionChanged: (s) =>
                  setState(() => _editMode = s.first),
            ),
          ),
          // 目标确认浮层
          if (nav.pendingWorld != null)
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Center(child: _goalConfirmCard(nav)),
            ),
          // 指令生命周期状态（ACK/Feedback/Result/UNKNOWN/STALE）
          if (mission.machine != null)
            Positioned(
              top: 64,
              left: 8,
              child: _missionCard(mission),
            ),
          // 急停 / 回充
          Positioned(
            right: 12,
            bottom: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'charge',
                  tooltip: '回充',
                  onPressed: _returnCharge,
                  child: const Icon(Icons.ev_station),
                ),
                const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'estop',
                  tooltip: '急停',
                  backgroundColor: Colors.red,
                  onPressed: _estop,
                  child: const Icon(Icons.stop),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _connDot(bool connected, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle,
              size: 10, color: connected ? Colors.green : Colors.grey),
          const SizedBox(width: 2),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  Widget _batteryIndicator(BatteryStatus? battery) {
    if (battery == null) {
      return const Text('--%', style: TextStyle(fontSize: 13));
    }
    final level = battery.level;
    final color =
        level > 50 ? Colors.green : (level > 20 ? Colors.orange : Colors.red);
    final icon = battery.charging
        ? Icons.battery_charging_full
        : level > 80
            ? Icons.battery_full
            : level > 50
                ? Icons.battery_5_bar
                : level > 20
                    ? Icons.battery_3_bar
                    : Icons.battery_alert;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        Text('$level%',
            style: TextStyle(fontSize: 13, color: color)),
      ],
    );
  }

  Widget _modeMenu(String currentMode) {
    return PopupMenuButton<String>(
      tooltip: '模式切换',
      onSelected: (mode) => _sendCommand('mode', buildModePayload(mode)),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'manual', child: Text('手动')),
        PopupMenuItem(value: 'auto', child: Text('自动')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Chip(
          label: Text('模式: $currentMode',
              style: const TextStyle(fontSize: 12)),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  Widget _missionCard(MissionCommandCenter center) {
    final m = center.machine!;
    final color = m.phase.isTerminal
        ? (m.phase == CommandPhase.succeeded ? Colors.green : Colors.red)
        : (m.phase == CommandPhase.stale ||
                m.phase == CommandPhase.unknown
            ? Colors.orange
            : Colors.blue);
    final distance = m.distanceRemaining;
    final eta = m.etaSec;
    return Card(
      elevation: 4,
      child: Container(
        width: 300,
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: color, width: 4)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.memory, size: 16, color: color),
                const SizedBox(width: 6),
                Text('指令 ${m.phase.label}',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: color)),
                const Spacer(),
                if (m.phase.isActive && m.phase != CommandPhase.canceling)
                  InkWell(
                    onTap: center.cancel,
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Text('取消', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                if (m.phase == CommandPhase.unknown ||
                    m.phase == CommandPhase.stale)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    onPressed: center.retry,
                    child: const Text('重发', style: TextStyle(fontSize: 12)),
                  ),
                if (m.phase.isTerminal)
                  InkWell(
                    onTap: center.clear,
                    child: const Icon(Icons.close, size: 16),
                  ),
              ],
            ),
            if (m.navState != null)
              Text(
                'Nav2: ${m.navState} · 恢复 ${m.recoveries} 次'
                '${distance != null ? ' · 剩余 ${distance.toStringAsFixed(1)} m' : ''}'
                '${eta != null ? ' · ETA ${eta.toStringAsFixed(0)} s' : ''}',
                style: const TextStyle(fontSize: 11),
              )
            else if (!m.phase.isTerminal)
              const Text('等待机器人 ACK / Feedback…',
                  style: TextStyle(fontSize: 11)),
            if (m.errorCode != null)
              Text('${m.errorCode}: ${m.errorMessage ?? ''}',
                  style: const TextStyle(fontSize: 11, color: Colors.red)),
            if (m.recoveredFromStale)
              const Text('已从 STALE 恢复（迟到 Feedback）',
                  style: TextStyle(fontSize: 11, color: Colors.orange)),
            const SizedBox(height: 2),
            Text('trace ${m.traceId.substring(0, 18)}…',
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
            if (m.phase.isActive)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        ),
      ),
    );
  }

  Widget _goalConfirmCard(NavGoalState nav) {
    final world = nav.pendingWorld!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('目标点: (${world.dx.toStringAsFixed(2)}, '
                  '${world.dy.toStringAsFixed(2)})'),
              Row(
                children: [
                  const Text('朝向'),
                  Expanded(
                    child: Slider(
                      value: nav.theta,
                      min: -pi,
                      max: pi,
                      onChanged: (v) => ref
                          .read(navigationControllerProvider.notifier)
                          .updateTheta(v),
                    ),
                  ),
                  Text('${(nav.theta * 180 / pi).round()}°'),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => ref
                        .read(navigationControllerProvider.notifier)
                        .cancel(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.navigation),
                    onPressed: () => ref
                        .read(navigationControllerProvider.notifier)
                        .confirm(),
                    label: const Text('确认导航'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onMapTap(Offset world) {
    switch (_editMode) {
      case _MapEditMode.navigate:
        ref.read(navigationControllerProvider.notifier).setPending(world);
      case _MapEditMode.addPoint:
        _addPointAt(world);
      case _MapEditMode.editPoints:
        break; // 编辑模式下空白处点击无操作
    }
  }

  Future<void> _addPointAt(Offset world) async {
    final point = await showPointEditorDialog(context, world: world);
    if (point != null) {
      await ref.read(pointsControllerProvider.notifier).addPoint(point);
    }
  }

  void _onPointTap(String id) {
    if (_editMode != _MapEditMode.editPoints) return;
    final matches =
        ref.read(pointsControllerProvider).where((p) => p.id == id);
    if (matches.isEmpty) return;
    final point = matches.first;
    showPointEditorDialog(context, initial: point).then((updated) {
      if (updated != null) {
        ref.read(pointsControllerProvider.notifier).updatePoint(updated);
      }
    });
  }

  void _estop() => _sendCommand('estop', buildEstopPayload(true), ok: '已发送急停');

  void _returnCharge() =>
      _sendCommand('return_charge', buildEmptyPayload(), ok: '已发送回充命令');

  /// 非任务指令走网关 HTTP（网关是唯一的 MQTT 发布者）。
  Future<void> _sendCommand(
    String name,
    Map<String, dynamic> payload, {
    String ok = '指令已发送',
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(gatewayClientProvider).sendCommand(name, payload);
      messenger.showSnackBar(SnackBar(content: Text(ok)));
    } on GatewayException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('发送失败 ${e.code}: ${e.message}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('网关不可达: $e')));
    }
  }

  void _showAlert(AlertMessage alert) {
    if (alert.isError) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.warning_amber, color: Colors.red),
          title: Text('告警 ${alert.code}'),
          content: Text(alert.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${alert.code}: ${alert.message}')),
      );
    }
  }
}
