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
/// 流程：点击地图 → setPending → 确认浮层 → confirm() 经网关 HTTP 下发，
/// 由 MissionCommandCenter 消费 WS 回执（ACK/Feedback/Result 与超时全在网关侧）。
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

  /// 确认并下发目标点（网关 HTTP + WS 回执）。
  Future<void> confirm() async {
    final world = state.pendingWorld;
    if (world == null) return;
    final sent = await ref
        .read(missionCommandProvider)
        .sendNavigate(world.dx, world.dy, state.theta);
    if (sent) {
      state = const NavGoalState();
    }
  }
}
