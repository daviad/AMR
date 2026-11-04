/// 全局常量与连接配置。
class AppConstants {
  AppConstants._();

  /// 仿真端主机地址。
  /// 真机调试时必须为 WSL IP（WSL 内执行 `hostname -I` 查看），
  /// 可通过 `--dart-define=AMR_HOST=192.168.x.x` 注入，避免改代码。
  static const String host =
      String.fromEnvironment('AMR_HOST', defaultValue: '127.0.0.1');

  static const int rosbridgePort = 9090;
  static const int mqttPort = 1884;      // TCP（App/仿真端）
  static const int mqttWsPort = 9002;    // WebSocket（Web 大屏）
  static const int rtspPort = 18554;     // RTSP（App 视频 fallback）
  static const int webrtcPort = 8889;    // WebRTC WHEP 信令（TCP）
  static const int hlsPort = 18888;      // HLS（Web 视频）

  static const String rosbridgeUrl = 'ws://$host:$rosbridgePort';

  static const String videoMainPath = 'camera';
  static const String videoLowPath = 'camera_low';

  static String whepUrl([String path = videoMainPath]) =>
      'http://$host:$webrtcPort/$path/whep';

  static String rtspUrl([String path = videoMainPath]) =>
      'rtsp://$host:$rtspPort/$path';
}
