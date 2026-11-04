import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mission_command_controller.dart';

/// 点击导航状态。
class NavGoalState {
  const NavGoalState({this.pendingWorld, this.theta = 0.0});

  /// 待确认的目标点（世界坐标），null 表示无待确认目标
  final Offset? pendingWorld;

  /// 目标朝向（弧度）
  final double theta;
}

/// 点击导航控制器。
/// 流程：点击地图 → setPending → 确认浮层 → confirm() 只走 MQTT 单一权威通道，
/// 由 MissionCommandCenter 承担 cmd_id 幂等、ACK/Feedback/Result 与非终态兜底。
/// 不再通过 rosbridge /goal_pose 双发，避免同一物理动作被执行两次。
final navigationControllerProvider =
    NotifierProvider<NavigationController, NavGoalState>(
        NavigationController.new);

class NavigationController extends Notifier<NavGoalState> {
  @override
  NavGoalState build() => const NavGoalState();

  /// 设置待确认目标点（世界坐标）。
  void setPending(Offset world) {
    state = NavGoalState(pendingWorld: world);
  }

  /// 调整目标朝向。
  void updateTheta(double theta) {
    if (state.pendingWorld == null) return;
    state = NavGoalState(pendingWorld: state.pendingWorld, theta: theta);
  }

  /// 取消待确认目标。
  void cancel() {
    state = const NavGoalState();
  }

  /// 确认并下发目标点（MQTT QoS1 + 应用层状态机）。
  void confirm() {
    final world = state.pendingWorld;
    if (world == null) return;
    final sent = ref
        .read(missionCommandProvider)
        .sendNavigate(world.dx, world.dy, state.theta);
    if (sent) {
      state = const NavGoalState();
    }
  }
}

