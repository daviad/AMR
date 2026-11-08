import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../comm/gateway_client.dart';
import '../../core/constants.dart';
import '../../models/command.dart';
import '../comm/gateway_provider.dart';

/// 业务指令控制面：HTTP 下发 + WS 回执 + 网关侧状态机。
///
/// 与旧实现的关键区别（见 docs/架构-网关收口.md §8）：
///  - cmd_id / trace_id 由网关生成，App 不再自己拼时间戳；
///  - 超时、重试、取消的权威状态在网关，本类只做 UI 映射与 trace 日志；
///  - 重试走 `POST /tasks/{id}/retry`，网关会重新生成 timestamp_ms，
///    不再出现“复用旧时间戳 → 必然 EXPIRED”的缺陷；
///  - WS 断线重连后调用 resync() 用 HTTP 对齐任务状态。
class MissionCommandCenter extends ChangeNotifier {
  MissionCommandCenter(this._ref);

  final Ref _ref;
  CommandStateMachine? _machine;

  CommandStateMachine? get machine => _machine;
  bool get hasCommand => _machine != null;

  /// 最近一次下发失败的原因（供 UI 提示，可忽略）。
  String? lastError;

  GatewayClient get _gateway => _ref.read(gatewayClientProvider);

  /// 下发导航指令。上一指令未终态时拒绝并返回 false（提示先取消）。
  Future<bool> sendNavigate(
    double x,
    double y,
    double theta, {
    int ttlMs = 8000,
  }) async {
    final current = _machine;
    if (current != null && current.phase.isActive) {
      lastError = '当前还有未完成的任务（${current.phase.label}）';
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final resp = await _gateway.createNavigate(
        x: x,
        y: y,
        theta: theta,
        ttlMs: ttlMs,
        holder: AppConstants.controlHolder,
      );
      final cmdId = '${resp['cmd_id'] ?? ''}';
      final traceId = '${resp['trace_id'] ?? ''}';
      if (cmdId.isEmpty) {
        lastError = '网关未返回 cmd_id';
        return false;
      }
      final m = CommandStateMachine(
        cmdId: cmdId,
        traceId: traceId,
        createdAtMs: now,
        ttlMs: ttlMs,
      );
      _machine = m;
      m.onPublished(now);
      lastError = null;
      _log(m, 'gateway_accepted', extra: {'x': x, 'y': y, 'theta': theta});
      _emit();
      return true;
    } on GatewayException catch (e) {
      lastError = _humanize(e);
      debugPrint('[CMD_TRACE] create_failed ${e.code} ${e.message}');
      return false;
    } catch (e) {
      lastError = '网关不可达：$e';
      debugPrint('[CMD_TRACE] create_error $e');
      return false;
    }
  }

  /// 取消（网关发布独立 cancel cmd_id，终态由 Result 回传）。
  Future<bool> cancel() async {
    final m = _machine;
    if (m == null || m.phase.isTerminal) return false;
    try {
      await _gateway.cancelTask(m.cmdId);
      m.onCancelRequested(DateTime.now().millisecondsSinceEpoch);
      _log(m, 'cancel_requested');
      _emit();
      return true;
    } on GatewayException catch (e) {
      lastError = _humanize(e);
      debugPrint('[CMD_TRACE] cancel_failed ${e.code} ${e.message}');
      return false;
    }
  }

  /// 重试：同 cmd_id，网关重新生成时间戳（修复旧版 EXPIRED 缺陷）。
  Future<bool> retry() async {
    final m = _machine;
    if (m == null || m.phase.isTerminal) return false;
    try {
      await _gateway.retryTask(m.cmdId);
      m.onRepublished(DateTime.now().millisecondsSinceEpoch);
      _log(m, 'command_retried');
      _emit();
      return true;
    } on GatewayException catch (e) {
      lastError = _humanize(e);
      debugPrint('[CMD_TRACE] retry_failed ${e.code} ${e.message}');
      return false;
    }
  }

  void clear() {
    if (_machine != null && _machine!.phase.isActive) return;
    _machine = null;
    notifyListeners();
  }

  // ───────────────── WS 推送入口 ─────────────────
  void onGatewayMessage(Map<String, dynamic> msg) {
    if (msg['type'] != 'task') return;
    final m = _machine;
    if (m == null || msg['cmd_id'] != m.cmdId) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final event = '${msg['event'] ?? ''}';
    final data = msg['data'] is Map
        ? Map<String, dynamic>.from(msg['data'] as Map)
        : <String, dynamic>{};
    switch (event) {
      case 'ack':
        m.onAck(CommandAck.fromJson(data), now);
        break;
      case 'feedback':
        m.onFeedback(CommandFeedback.fromJson(data), now);
        break;
      case 'result':
        m.onResult(_resultFrom(event, data, msg['task']), now);
        break;
      case 'retry':
      case 'publish':
        m.onRepublished(now);
        break;
      case 'state':
        _applyServerPhase(m, '${msg['phase'] ?? ''}', msg, now);
        break;
      default:
        break;
    }
    _log(m, '${event}_received', extra: {
      'phase': msg['phase'],
    });
    _emit();
  }

  /// WS 重连后调用：用 HTTP 把任务状态补齐（WS 不做消息回放）。
  Future<void> resync() async {
    final m = _machine;
    if (m == null) return;
    try {
      final task = await _gateway.getTask(m.cmdId);
      final now = DateTime.now().millisecondsSinceEpoch;
      _applyServerPhase(m, '${task['phase'] ?? ''}', task, now);
      _emit();
    } on GatewayException catch (e) {
      debugPrint('[CMD_TRACE] resync_failed ${e.code}');
    }
  }

  void _applyServerPhase(
    CommandStateMachine m,
    String phase,
    Map<String, dynamic> source,
    int now,
  ) {
    switch (phase) {
      case 'SUCCEEDED':
      case 'CANCELLED':
      case 'FAILED':
      case 'TIMEOUT':
        m.onResult(
          CommandResult(
            cmdId: m.cmdId,
            traceId: m.traceId,
            status: phase == 'TIMEOUT' ? 'FAILED' : phase,
            errorCode: source['error_code'] as String?,
            errorMessage: source['error_msg'] as String?,
          ),
          now,
        );
        break;
      case 'STALE':
        m.onFeedbackTimeout(now);
        break;
      case 'UNKNOWN':
        m.onAckTimeout(now);
        break;
      case 'ACCEPTED':
      case 'EXECUTING':
      case 'PUBLISHED':
      case 'CANCEL_REQUESTED':
        if (m.phase == CommandPhase.unknown || m.phase == CommandPhase.stale) {
          m.onRepublished(now);
        }
        break;
      default:
        break;
    }
  }

  CommandResult _resultFrom(
    String event,
    Map<String, dynamic> data,
    Object? taskSnapshot,
  ) {
    if (data.isNotEmpty) return CommandResult.fromJson(data);
    final task = taskSnapshot is Map ? taskSnapshot : const <String, dynamic>{};
    final result = task['result'] is Map ? task['result'] as Map : null;
    final status = '${result?['status'] ?? task['phase'] ?? 'FAILED'}';
    return CommandResult(
      cmdId: '${task['cmd_id'] ?? ''}',
      traceId: task['trace_id'] as String?,
      status: status,
      errorCode: task['error_code'] as String?,
      errorMessage: task['error_msg'] as String?,
    );
  }

  String _humanize(GatewayException e) {
    switch (e.code) {
      case 'LOCKED':
        return '设备正被其他端控制（Web 大屏或另一台手机）';
      case 'TASK_ACTIVE':
        return '已有任务在执行，请先取消';
      case 'MQTT_UNAVAILABLE':
        return '控制通道断开，指令没有发出';
      case 'RETRY_EXHAUSTED':
        return '重试次数已用尽';
      default:
        return '${e.code}: ${e.message}';
    }
  }

  void _log(CommandStateMachine m, String event, {Map<String, dynamic>? extra}) {
    final record = <String, dynamic>{
      'component': 'app',
      'event': event,
      'cmd_id': m.cmdId,
      'trace_id': m.traceId,
      'phase': m.phase.name,
      'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
    };
    if (extra != null) record.addAll(extra);
    debugPrint('[CMD_TRACE] ${jsonEncode(record)}');
  }

  void _emit() {
    notifyListeners();
  }
}

final missionCommandProvider =
    ChangeNotifierProvider<MissionCommandCenter>((ref) {
  final center = MissionCommandCenter(ref);
  // WS 推送 → 状态机
  ref.listen<AsyncValue<Map<String, dynamic>>>(gatewayMessageProvider,
      (previous, next) {
    final msg = next.valueOrNull;
    if (msg != null) center.onGatewayMessage(msg);
  });
  // WS 重连 → HTTP 对齐状态
  ref.listen<AsyncValue<bool>>(gatewayConnectedProvider, (previous, next) {
    if (next.valueOrNull == true) center.resync();
  });
  ref.onDispose(center.dispose);
  return center;
});
