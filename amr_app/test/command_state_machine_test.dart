import 'package:flutter_test/flutter_test.dart';

import 'package:amr_app/models/command.dart';

CommandStateMachine _machine({int now = 1000}) => CommandStateMachine(
      cmdId: 'cmd-1',
      traceId: 'trace-1',
      createdAtMs: now,
      ackTimeoutMs: 1200,
      feedbackTimeoutMs: 3000,
    );

CommandAck _ack({String status = 'ACCEPTED', String? errorCode}) =>
    CommandAck(
      cmdId: 'cmd-1',
      traceId: 'trace-1',
      status: status,
      errorCode: errorCode,
    );

CommandFeedback _feedback({
  String state = 'EXECUTING',
  String navState = 'CONTROLLING',
  int recoveries = 0,
  double? distance,
  double? eta,
  bool heartbeat = false,
}) =>
    CommandFeedback(
      cmdId: 'cmd-1',
      traceId: 'trace-1',
      state: state,
      navState: navState,
      recoveries: recoveries,
      distanceRemaining: distance,
      etaSec: eta,
      heartbeat: heartbeat,
    );

CommandResult _result(String status, {String? errorCode}) => CommandResult(
      cmdId: 'cmd-1',
      traceId: 'trace-1',
      status: status,
      errorCode: errorCode,
    );

void main() {
  group('正常路径', () {
    test('PENDING → SENT → ACKED → EXECUTING → SUCCEEDED', () {
      final m = _machine();
      m.onPublished(1100);
      expect(m.phase, CommandPhase.sent);
      m.onAck(_ack(), 1200);
      expect(m.phase, CommandPhase.acked);
      m.onFeedback(_feedback(distance: 4.2, eta: 6.0, recoveries: 1), 1300);
      expect(m.phase, CommandPhase.executing);
      expect(m.navState, 'CONTROLLING');
      expect(m.recoveries, 1);
      expect(m.distanceRemaining, 4.2);
      m.onResult(_result('SUCCEEDED'), 5000);
      expect(m.phase, CommandPhase.succeeded);
      expect(m.phase.isTerminal, isTrue);

      final path = m.transitions.map((t) => t.to).toList();
      expect(path, [
        CommandPhase.pending,
        CommandPhase.sent,
        CommandPhase.acked,
        CommandPhase.executing,
        CommandPhase.succeeded,
      ]);
    });

    test('Nav2 恢复中途不拍平：Feedback 保留 RECOVERING 与恢复次数', () {
      final m = _machine();
      m.onPublished(1100);
      m.onAck(_ack(), 1200);
      m.onFeedback(
          _feedback(navState: 'RECOVERING', recoveries: 3, distance: 2.0), 2000);
      expect(m.phase, CommandPhase.executing);
      expect(m.navState, 'RECOVERING');
      expect(m.recoveries, 3);
    });

    test('心跳 Feedback 不改变 phase，仅刷新 lastUpdateMs', () {
      final m = _machine();
      m.onPublished(1100);
      m.onAck(_ack(), 1200);
      m.onFeedback(_feedback(), 1400);
      expect(m.lastUpdateMs, 1400);
      m.onFeedback(_feedback(heartbeat: true), 2400);
      expect(m.phase, CommandPhase.executing);
      expect(m.lastUpdateMs, 2400);
    });
  });

  group('异常与降级', () {
    test('ACK 超时：SENT → UNKNOWN（不永久悬挂）', () {
      final m = _machine();
      m.onPublished(1100);
      m.onAckTimeout(1100 + 1200 + 1);
      expect(m.phase, CommandPhase.unknown);
      expect(m.errorCode, 'ACK_TIMEOUT');
    });

    test('迟到 ACK 可从 UNKNOWN 恢复为 ACKED', () {
      final m = _machine();
      m.onPublished(1100);
      m.onAckTimeout(2301);
      expect(m.phase, CommandPhase.unknown);
      m.onAck(_ack(), 2500);
      expect(m.phase, CommandPhase.acked);
    });

    test('ACK 被拒绝直接失败，并透传 error_code', () {
      final m = _machine();
      m.onPublished(1100);
      m.onAck(_ack(status: 'REJECTED', errorCode: 'TTL_EXPIRED'), 1200);
      expect(m.phase, CommandPhase.failed);
      expect(m.errorCode, 'TTL_EXPIRED');
    });

    test('Feedback 超时：ACKED → STALE，迟到 Feedback 恢复 EXECUTING', () {
      final m = _machine();
      m.onPublished(1100);
      m.onAck(_ack(), 1200);
      m.onFeedbackTimeout(1200 + 3000 + 1);
      expect(m.phase, CommandPhase.stale);
      m.onFeedback(_feedback(), 4300);
      expect(m.phase, CommandPhase.executing);
      expect(m.recoveredFromStale, isTrue);
    });

    test('Result 超时进入 UNKNOWN，重复 Result 仍可收敛终态', () {
      final m = _machine();
      m.onPublished(1100);
      m.onAck(_ack(), 1200);
      m.onFeedback(_feedback(), 1300);
      m.onResultTimeout(1300 + 120000);
      expect(m.phase, CommandPhase.unknown);
      expect(m.errorCode, 'RESULT_TIMEOUT');
      m.onResult(_result('SUCCEEDED'), 1300 + 121000);
      expect(m.phase, CommandPhase.succeeded);
    });

    test('未连接 MQTT 发布失败：直接 FAILED，不假装已发送', () {
      final m = _machine();
      m.onPublishFailed(1100, 'mqtt offline');
      expect(m.phase, CommandPhase.failed);
      expect(m.errorCode, 'NOT_PUBLISHED');
      expect(m.phase.isTerminal, isTrue);
    });

    test('重复 Result 不再迁移（终态幂等）', () {
      final m = _machine();
      m.onPublished(1100);
      m.onAck(_ack(), 1200);
      m.onResult(_result('SUCCEEDED'), 3000);
      final before = m.transitions.length;
      m.onResult(_result('SUCCEEDED'), 3100);
      expect(m.transitions.length, before);
      expect(m.phase, CommandPhase.succeeded);
    });
  });

  group('取消', () {
    test('EXECUTING → CANCELING → CANCELLED', () {
      final m = _machine();
      m.onPublished(1100);
      m.onAck(_ack(), 1200);
      m.onFeedback(_feedback(), 1300);
      m.onCancelRequested(2000);
      expect(m.phase, CommandPhase.canceling);
      m.onResult(_result('CANCELLED'), 2600);
      expect(m.phase, CommandPhase.cancelled);
      expect(m.phase.isTerminal, isTrue);
    });

    test('取消超时进入 UNKNOWN，不永久停在 CANCELING', () {
      final m = _machine();
      m.onPublished(1100);
      m.onAck(_ack(), 1200);
      m.onCancelRequested(2000);
      m.onCancelTimeout(7001);
      expect(m.phase, CommandPhase.unknown);
      expect(m.errorCode, 'CANCEL_TIMEOUT');
    });
  });

  group('幂等重发', () {
    test('同一 cmd_id 从 UNKNOWN 重发 → SENT，id 不变', () {
      final m = _machine();
      m.onPublished(1100);
      m.onAckTimeout(2301);
      expect(m.phase, CommandPhase.unknown);
      m.onRepublished(3000);
      expect(m.phase, CommandPhase.sent);
      expect(m.cmdId, 'cmd-1');
    });

    test('终态后重发不改变状态', () {
      final m = _machine();
      m.onPublishFailed(1100, 'offline');
      m.onRepublished(1200);
      expect(m.phase, CommandPhase.failed);
    });
  });

  test('newCommandId 每次唯一', () {
    final ids = {for (var i = 0; i < 1000; i++) newCommandId()};
    expect(ids.length, 1000);
  });
}
