/// 所有 rosbridge / MQTT topic 常量，单一事实来源。
/// 与 docs/architecture.md 第 5 节通信契约严格一致，改动需同步文档。
class TopicMapping {
  TopicMapping._();

  // ── 数据下行（rosbridge 订阅）──
  static const String map = '/map';
  static const String scan = '/scan';
  static const String tf = '/tf';
  static const String odom = '/odom';
  static const String plan = '/plan';
  static const String cameraCompressed = '/camera/image_raw/compressed';
  static const String amclPose = '/amcl_pose';

  // ── 命令上行（MQTT publish，QoS 1）──
  static const String cmdGoal = 'amr/cmd/goal';
  static const String cmdCancel = 'amr/cmd/cancel';
  static const String cmdInspectionStart = 'amr/cmd/inspection/start';
  static const String cmdInspectionStop = 'amr/cmd/inspection/stop';
  static const String cmdMode = 'amr/cmd/mode';
  static const String cmdEStop = 'amr/cmd/estop';
  static const String cmdReturnCharge = 'amr/cmd/return_charge';

  // ── 指令生命周期上行（mission_bridge 回传）──
  static const String cmdAck = 'amr/cmd/ack';
  static const String cmdFeedback = 'amr/cmd/feedback';
  static const String cmdResult = 'amr/cmd/result';
  static const String trace = 'amr/trace';

  // ── 状态上行（MQTT subscribe，QoS 0）──
  static const String statusBattery = 'amr/status/battery';
  static const String statusInspection = 'amr/status/inspection';
  static const String statusMode = 'amr/status/mode';
  static const String statusVideo = 'amr/status/video';
  static const String statusVideoMetrics = 'amr/status/video_metrics';
  static const String alert = 'amr/alert';

  // ── App 遗嘱消息（MQTT LWT）──
  static const String statusAppOffline = 'amr/status/app_offline';
}
