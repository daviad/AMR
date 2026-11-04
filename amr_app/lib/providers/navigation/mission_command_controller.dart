import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mqtt_client/mqtt_client.dart';

import '../../comm/mqtt_client.dart';
import '../../core/message_models.dart';
import '../../core/topic_mapping.dart';
import '../../models/command.dart';
import '../comm/mqtt_provider.dart';

/// 业务指令控制面：MQTT 单一权威通道 + 应用层状态机。
///
/// 职责：
///  - 生成 cmd_id / trace_id，发布 amr/cmd/goal；
///  - 订阅 amr/cmd/ack、amr/cmd/feedback、amr/cmd/result，驱动状态机；
///  - ACK / Feedback / Result 超时，不永久悬挂；
///  - 取消、重发（同 cmd_id）与结构化 trace 日志。
class MissionCommandCenter extends ChangeNotifier {
  MissionCommandCenter(this._ref) {
    _subscribe();
  }

  final Ref _ref;
  CommandStateMachine? _machine;
  Map<String, dynamic>? _lastEnvelope;

  StreamSubscription<Map<String, dynamic>>? _ackSub;
  StreamSubscription<Map<String, dynamic>>? _feedbackSub;
  StreamSubscription<Map<String, dynamic>>? _resultSub;

  Timer? _ackTimer;
  Timer? _feedbackTimer;
  Timer? _resultTimer;
  Timer? _cancelTimer;
  bool _disposed = false;

  CommandStateMachine? get machine => _machine;
  bool get hasCommand => _machine != null;

  AppMqttClient get _mqtt => _ref.read(mqttClientProvider);

  void _subscribe() {
    _ackSub = _mqtt
        .subscribe(TopicMapping.cmdAck, qos: MqttQos.atLeastOnce)
        .listen(_onAckMessage);
    _feedbackSub = _mqtt
        .subscribe(TopicMapping.cmdFeedback, qos: MqttQos.atMostOnce)
        .listen(_onFeedbackMessage);
    _resultSub = _mqtt
        .subscribe(TopicMapping.cmdResult, qos: MqttQos.atLeastOnce)
        .listen(_onResultMessage);
  }

  /// 下发导航指令。上一指令未终态时拒绝并返回 false（由 UI 提示先取消）。
  bool sendNavigate(double x, double y, double theta, {int ttlMs = 8000}) {
    final current = _machine;
    if (current != null && current.phase.isActive) {
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final cmdId = newCommandId();
    final traceId = newCommandId('trace');
    final m = CommandStateMachine(
      cmdId: cmdId,
      traceId: traceId,
      createdAtMs: now,
      ttlMs: ttlMs,
    );
    _machine = m;
    _lastEnvelope = buildGoalCommand(
      cmdId: cmdId,
      traceId: traceId,
      timestampMs: now,
      ttlMs: ttlMs,
      x: x,
      y: y,
      theta: theta,
    );
    _log(m, 'command_created', extra: {'x': x, 'y': y, 'theta': theta});
    if (!_mqtt.publishCommand(TopicMapping.cmdGoal, _lastEnvelope!)) {
      m.onPublishFailed(now, 'MQTT 未连接');
      _log(m, 'publish_failed');
      _emit();
      return false;
    }
    m.onPublished(now);
    _log(m, 'command_published');
    _startTimers(m);
    _emit();
    return true;
  }

  /// 取消当前指令（取消自身也带 cmd_id，终态由 Result 回传）。
  bool cancel() {
    final m = _machine;
    if (m == null || m.phase.isTerminal) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final cancelId = newCommandId('cancel');
    final payload = buildCancelCommand(
      cmdId: cancelId,
      traceId: m.traceId,
      targetCmdId: m.cmdId,
    );
    if (!_mqtt.publishCommand(TopicMapping.cmdCancel, payload)) {
      return false;
    }
    m.onCancelRequested(now);
    _log(m, 'cancel_published');
    _cancelTimer?.cancel();
    _cancelTimer = Timer(const Duration(seconds: 5), () {
      if (_machine != m || m.phase.isTerminal) return;
      m.onCancelTimeout(DateTime.now().millisecondsSinceEpoch);
      _log(m, 'cancel_timeout');
      _emit();
    });
    _emit();
    return true;
  }

  /// 重发同一 cmd_id。服务端按 cmd_id 幂等：不重复执行物理动作，只回放结果。
  bool retry() {
    final m = _machine;
    final envelope = _lastEnvelope;
    if (m == null || envelope == null || m.phase.isTerminal) return false;
    if (!_mqtt.publishCommand(TopicMapping.cmdGoal, envelope)) return false;
    m.onRepublished(DateTime.now().millisecondsSinceEpoch);
    _log(m, 'command_republished');
    _startTimers(m);
    _emit();
    return true;
  }

  void clear() {
    if (_machine != null && _machine!.phase.isActive) return;
    _cancelTimers();
    _machine = null;
    _lastEnvelope = null;
    notifyListeners();
  }

  void _startTimers(CommandStateMachine m) {
    _ackTimer?.cancel();
    _feedbackTimer?.cancel();
    _resultTimer?.cancel();
    _ackTimer = Timer(Duration(milliseconds: m.ackTimeoutMs), () {
      if (_machine != m || m.phase.isTerminal) return;
      m.onAckTimeout(DateTime.now().millisecondsSinceEpoch);
      _log(m, 'ack_timeout');
      _emit();
    });
    _feedbackTimer = Timer(Duration(milliseconds: m.feedbackTimeoutMs), () {
      if (_machine != m || m.phase.isTerminal) return;
      m.onFeedbackTimeout(DateTime.now().millisecondsSinceEpoch);
      _log(m, 'feedback_timeout');
      _emit();
    });
    _resultTimer = Timer(const Duration(seconds: 120), () {
      if (_machine != m || m.phase.isTerminal) return;
      m.onResultTimeout(DateTime.now().millisecondsSinceEpoch);
      _log(m, 'result_timeout');
      _emit();
    });
  }

  void _cancelTimers() {
    _ackTimer?.cancel();
    _feedbackTimer?.cancel();
    _resultTimer?.cancel();
    _cancelTimer?.cancel();
    _ackTimer = null;
    _feedbackTimer = null;
    _resultTimer = null;
    _cancelTimer = null;
  }

  void _onAckMessage(Map<String, dynamic> json) {
    final m = _machine;
    final ack = CommandAck.fromJson(json);
    if (m == null || ack.cmdId != m.cmdId || m.phase.isTerminal) return;
    m.onAck(ack, DateTime.now().millisecondsSinceEpoch);
    _log(m, 'ack_received',
        extra: {'status': ack.status, 'latency_ms': ack.latencyMs});
    if (m.phase == CommandPhase.failed) {
      _cancelTimers();
    } else {
      _ackTimer?.cancel();
      _ackTimer = null;
      _startFeedbackTimer(m);
    }
    _emit();
  }

  void _onFeedbackMessage(Map<String, dynamic> json) {
    final m = _machine;
    final fb = CommandFeedback.fromJson(json);
    if (m == null || fb.cmdId != m.cmdId || m.phase.isTerminal) return;
    m.onFeedback(fb, DateTime.now().millisecondsSinceEpoch);
    _log(m, 'feedback_received', extra: {
      'nav_state': fb.navState,
      'recoveries': fb.recoveries,
      'distance_remaining': fb.distanceRemaining,
    });
    _startFeedbackTimer(m);
    _emit();
  }

  void _onResultMessage(Map<String, dynamic> json) {
    final m = _machine;
    final result = CommandResult.fromJson(json);
    if (m == null || result.cmdId != m.cmdId) return;
    if (m.phase.isTerminal) {
      _log(m, 'duplicate_result_ignored', extra: {'status': result.status});
      return;
    }
    m.onResult(result, DateTime.now().millisecondsSinceEpoch);
    _log(m, 'result_received', extra: {
      'status': result.status,
      'error_code': result.errorCode,
      'latency_ms': result.latencyMs,
    });
    _cancelTimers();
    _emit();
  }

  void _startFeedbackTimer(CommandStateMachine m) {
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(Duration(milliseconds: m.feedbackTimeoutMs), () {
      if (_machine != m || m.phase.isTerminal) return;
      m.onFeedbackTimeout(DateTime.now().millisecondsSinceEpoch);
      _log(m, 'feedback_timeout');
      _emit();
    });
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
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    _ackSub?.cancel();
    _feedbackSub?.cancel();
    _resultSub?.cancel();
    super.dispose();
  }
}

final missionCommandProvider =
    ChangeNotifierProvider<MissionCommandCenter>((ref) {
  final center = MissionCommandCenter(ref);
  ref.onDispose(center.dispose);
  return center;
});
