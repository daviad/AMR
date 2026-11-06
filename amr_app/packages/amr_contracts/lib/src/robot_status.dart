/// MQTT 状态消息数据模型（仿真 → App），契约见 docs/architecture.md 5.2 节。
library;

/// amr/status/battery —— {"level": 85, "voltage": 12.1, "charging": false}
class BatteryStatus {
  const BatteryStatus({
    required this.level,
    required this.voltage,
    required this.charging,
  });

  final int level;
  final double voltage;
  final bool charging;

  factory BatteryStatus.fromJson(Map<String, dynamic> json) => BatteryStatus(
        level: (json['level'] as num?)?.toInt() ?? 0,
        voltage: (json['voltage'] as num?)?.toDouble() ?? 0,
        charging: json['charging'] as bool? ?? false,
      );
}

/// amr/status/inspection ——
/// {"state": "running", "progress": 2, "total": 5, "current_point": "p3"}
class InspectionProgress {
  const InspectionProgress({
    required this.state,
    required this.progress,
    required this.total,
    required this.currentPoint,
  });

  /// idle / running / paused / done ...
  final String state;
  final int progress;
  final int total;
  final String currentPoint;

  bool get isRunning => state == 'running';

  factory InspectionProgress.fromJson(Map<String, dynamic> json) =>
      InspectionProgress(
        state: json['state'] as String? ?? 'idle',
        progress: (json['progress'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
        currentPoint: json['current_point'] as String? ?? '',
      );
}

/// amr/alert —— {"level": "warn", "code": "LOW_BATTERY", "message": "..."}
class AlertMessage {
  const AlertMessage({
    required this.level,
    required this.code,
    required this.message,
  });

  /// info / warn / error
  final String level;
  final String code;
  final String message;

  bool get isError => level == 'error' || level == 'critical';

  factory AlertMessage.fromJson(Map<String, dynamic> json) => AlertMessage(
        level: json['level'] as String? ?? 'info',
        code: json['code'] as String? ?? '',
        message: json['message'] as String? ?? '',
      );
}
