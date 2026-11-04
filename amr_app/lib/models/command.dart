import 'dart:math';

/// 指令生命周期状态（与 docs/architecture.md 5.2 一致）。
///
/// IDLE → PENDING → SENT → ACKED → EXECUTING → SUCCEEDED / FAILED / CANCELLED
/// 异常分支：SENT --ACK 超时--> UNKNOWN；ACKED/EXECUTING --Feedback 超时--> STALE。
enum CommandPhase {
  idle,
  pending,
  sent,
  acked,
  executing,
  canceling,
  succeeded,
  failed,
  cancelled,
  unknown,
  stale,
}

extension CommandPhaseX on CommandPhase {
  bool get isTerminal =>
      this == CommandPhase.succeeded ||
      this == CommandPhase.failed ||
      this == CommandPhase.cancelled;

  bool get isActive => this != CommandPhase.idle && !isTerminal;

  String get label {
    switch (this) {
      case CommandPhase.idle:
        return '空闲';
      case CommandPhase.pending:
        return '待发送';
      case CommandPhase.sent:
        return '已发送';
      case CommandPhase.acked:
        return '已确认';
      case CommandPhase.executing:
        return '执行中';
      case CommandPhase.canceling:
        return '取消中';
      case CommandPhase.succeeded:
        return '已完成';
      case CommandPhase.failed:
        return '失败';
      case CommandPhase.cancelled:
        return '已取消';
      case CommandPhase.unknown:
        return '送达未知';
      case CommandPhase.stale:
        return '状态陈旧';
    }
  }
}

class CommandTransition {
  CommandTransition({
    required this.from,
    required this.to,
    required this.atMs,
    this.reason,
  });

  final CommandPhase from;
  final CommandPhase to;
  final int atMs;
  final String? reason;

  Map<String, dynamic> toJson() => {
        'from': from.name,
        'to': to.name,
        'at_ms': atMs,
        'reason': reason,
      };
}

class CommandAck {
  CommandAck({
    required this.cmdId,
    this.traceId,
    this.status,
    this.errorCode,
    this.latencyMs,
  });

  factory CommandAck.fromJson(Map<String, dynamic> json) => CommandAck(
        cmdId: json['cmd_id'] as String? ?? '',
        traceId: json['trace_id'] as String?,
        status: json['status'] as String?,
        errorCode: json['error_code'] as String?,
        latencyMs: (json['latency_ms'] as num?)?.toDouble(),
      );

  final String cmdId;
  final String? traceId;
  final String? status;
  final String? errorCode;
  final double? latencyMs;

  bool get accepted => status == 'ACCEPTED';
}

class CommandFeedback {
  CommandFeedback({
    required this.cmdId,
    this.traceId,
    this.state,
    this.navState,
    this.recoveries = 0,
    this.distanceRemaining,
    this.etaSec,
    this.heartbeat = false,
  });

  factory CommandFeedback.fromJson(Map<String, dynamic> json) =>
      CommandFeedback(
        cmdId: json['cmd_id'] as String? ?? '',
        traceId: json['trace_id'] as String?,
        state: json['state'] as String?,
        navState: json['nav_state'] as String?,
        recoveries: (json['number_of_recoveries'] as num?)?.toInt() ?? 0,
        distanceRemaining:
            (json['distance_remaining'] as num?)?.toDouble(),
        etaSec: (json['eta_sec'] as num?)?.toDouble(),
        heartbeat: json['heartbeat'] == true,
      );

  final String cmdId;
  final String? traceId;
  final String? state;
  final String? navState;
  final int recoveries;
  final double? distanceRemaining;
  final double? etaSec;
  final bool heartbeat;
}

class CommandResult {
  CommandResult({
    required this.cmdId,
    this.traceId,
    this.status,
    this.errorCode,
    this.errorMessage,
    this.latencyMs,
  });

  factory CommandResult.fromJson(Map<String, dynamic> json) => CommandResult(
        cmdId: json['cmd_id'] as String? ?? '',
        traceId: json['trace_id'] as String?,
        status: json['status'] as String?,
        errorCode: json['error_code'] as String?,
        errorMessage: json['error_msg'] as String?,
        latencyMs: (json['latency_ms'] as num?)?.toDouble(),
      );

  final String cmdId;
  final String? traceId;
  final String? status;
  final String? errorCode;
  final String? errorMessage;
  final double? latencyMs;

  CommandPhase get phase {
    switch (status) {
      case 'SUCCEEDED':
        return CommandPhase.succeeded;
      case 'CANCELLED':
        return CommandPhase.cancelled;
      default:
        return CommandPhase.failed;
    }
  }
}

/// 纯状态机：不依赖 Flutter / 定时器 / 网络，便于单测与故障注入。
class CommandStateMachine {
  CommandStateMachine({
    required this.cmdId,
    required this.traceId,
    required this.createdAtMs,
    this.ttlMs = 8000,
    this.ackTimeoutMs = 1200,
    this.feedbackTimeoutMs = 3000,
  }) {
    lastUpdateMs = createdAtMs;
    transitions.add(CommandTransition(
      from: CommandPhase.idle,
      to: CommandPhase.pending,
      atMs: createdAtMs,
      reason: 'created',
    ));
  }

  final String cmdId;
  final String traceId;
  final int createdAtMs;
  final int ttlMs;
  final int ackTimeoutMs;
  final int feedbackTimeoutMs;

  CommandPhase phase = CommandPhase.pending;
  late int lastUpdateMs;
  CommandAck? ack;
  CommandFeedback? feedback;
  CommandResult? result;
  String? errorCode;
  String? errorMessage;
  bool recoveredFromStale = false;
  final List<CommandTransition> transitions = [];

  String? get navState => feedback?.navState;
  int get recoveries => feedback?.recoveries ?? 0;
  double? get distanceRemaining => feedback?.distanceRemaining;
  double? get etaSec => feedback?.etaSec;

  void _move(CommandPhase next, int nowMs, {String? reason}) {
    if (phase == next) {
      lastUpdateMs = nowMs;
      return;
    }
    transitions.add(CommandTransition(
      from: phase,
      to: next,
      atMs: nowMs,
      reason: reason,
    ));
    phase = next;
    lastUpdateMs = nowMs;
  }

  /// MQTT 发布成功：PENDING → SENT。
  void onPublished(int nowMs) {
    if (phase != CommandPhase.pending) return;
    _move(CommandPhase.sent, nowMs, reason: 'published');
  }

  /// MQTT 未连接/发布异常：直接进入失败终态，不假装指令已生效。
  void onPublishFailed(int nowMs, String reason) {
    if (phase.isTerminal) return;
    errorCode = 'NOT_PUBLISHED';
    errorMessage = reason;
    _move(CommandPhase.failed, nowMs, reason: 'publish_failed');
  }

  void onAck(CommandAck value, int nowMs) {
    if (phase.isTerminal) return;
    ack = value;
    if (!value.accepted) {
      errorCode = value.errorCode ?? 'ACK_REJECTED';
      errorMessage = '机器人拒绝了指令';
      _move(CommandPhase.failed, nowMs, reason: 'ack_rejected');
      return;
    }
    // 迟到 ACK：从 UNKNOWN 恢复，说明链路抖动而非指令丢失。
    _move(CommandPhase.acked, nowMs, reason: 'ack');
  }

  void onFeedback(CommandFeedback value, int nowMs) {
    if (phase.isTerminal) return;
    feedback = value;
    if (phase == CommandPhase.stale) {
      recoveredFromStale = true;
    }
    if (value.heartbeat) {
      lastUpdateMs = nowMs;
      return;
    }
    _move(CommandPhase.executing, nowMs, reason: 'feedback');
  }

  void onResult(CommandResult value, int nowMs) {
    if (phase.isTerminal) return; // 重复 Result 不重复迁移
    result = value;
    if (value.phase != CommandPhase.succeeded) {
      errorCode = value.errorCode;
      errorMessage = value.errorMessage;
    }
    _move(value.phase, nowMs, reason: 'result');
  }

  /// ACK 超时：不永久等待，进入 UNKNOWN。
  void onAckTimeout(int nowMs) {
    if (phase.isTerminal || phase == CommandPhase.acked ||
        phase == CommandPhase.executing || phase == CommandPhase.canceling) {
      return;
    }
    errorCode = 'ACK_TIMEOUT';
    errorMessage = '指令送达未知，最后已知状态为 ${phase.label}';
    _move(CommandPhase.unknown, nowMs, reason: 'ack_timeout');
  }

  /// Feedback 超时：进入 STALE，但保留取消/结果监听。
  void onFeedbackTimeout(int nowMs) {
    if (phase.isTerminal) return;
    if (phase == CommandPhase.acked ||
        phase == CommandPhase.executing ||
        phase == CommandPhase.unknown) {
      _move(CommandPhase.stale, nowMs, reason: 'feedback_timeout');
    }
  }

  /// 整条指令的结果超时：进入 UNKNOWN，等待迟到 Result 回放。
  void onResultTimeout(int nowMs) {
    if (phase.isTerminal) return;
    errorCode = 'RESULT_TIMEOUT';
    errorMessage = '超过预期时间未收到终态，最后已知状态为 ${phase.label}';
    _move(CommandPhase.unknown, nowMs, reason: 'result_timeout');
  }

  void onCancelRequested(int nowMs) {
    if (phase.isTerminal) return;
    _move(CommandPhase.canceling, nowMs, reason: 'cancel_requested');
  }

  void onCancelTimeout(int nowMs) {
    if (phase.isTerminal || phase != CommandPhase.canceling) return;
    errorCode = 'CANCEL_TIMEOUT';
    errorMessage = '取消指令未收到终态';
    _move(CommandPhase.unknown, nowMs, reason: 'cancel_timeout');
  }

  /// 重发同一 cmd_id（不是新指令），用于验证服务端幂等回放。
  void onRepublished(int nowMs) {
    if (phase.isTerminal) return;
    lastUpdateMs = nowMs;
    if (phase == CommandPhase.unknown || phase == CommandPhase.stale) {
      _move(CommandPhase.sent, nowMs, reason: 'republished');
    }
  }
}

final Random _random = Random.secure();

/// 生成跨设备唯一 ID：时间戳 + 32 位随机数，避免引入 uuid 依赖。
String newCommandId([String prefix = 'cmd']) {
  final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final rand = _random.nextInt(1 << 32).toRadixString(16);
  return '$prefix-$micros-$rand';
}
