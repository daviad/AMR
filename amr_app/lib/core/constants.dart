/// 全局常量与连接配置。
class AppConstants {
  AppConstants._();

  /// 仿真端主机地址。
  /// 真机调试时必须为 WSL IP（WSL 内执行 `hostname -I` 查看），
  /// 可通过 `--dart-define=AMR_HOST=192.168.x.x` 注入，避免改代码。
  static const String host =
      String.fromEnvironment('AMR_HOST', defaultValue: '127.0.0.1');

  // ───────────────── 业务网关（App 唯一业务出口）─────────────────
  // 收口后 App 不再直连 rosbridge / MQTT：业务走 HTTP，推送走 WS，视频仍走 MediaMTX。
  // 见 docs/架构-网关收口.md。
  static const int gatewayHttpPort = 8080;
  static const int gatewayWsPort = 8081;
  static const String gatewayToken = String.fromEnvironment(
    'AMR_GATEWAY_TOKEN',
    defaultValue: 'amr-dev-token',
  );

  /// 控制权 holder：一台设备一个标记，用于 device_lock 区分 App 与 Web 大屏。
  static const String controlHolder = String.fromEnvironment(
    'AMR_CONTROL_HOLDER',
    defaultValue: 'app-flutter',
  );

  static const String gatewayHttpBase = 'http://$host:$gatewayHttpPort';

  static String get gatewayWsUrl =>
      'ws://$host:$gatewayWsPort/ws?token=$gatewayToken';

  // ───────────────── 以下仅用于调试 / 视频链路 ─────────────────
  // `/rosbridge` 已降级为调试工具：网关独占它，App 运行路径不再连接。
  // `/mqtt` 仅网关与仿真端使用；App 没有账号，也不应连接。

  /// rosbridge 调试端口（网关内部使用；App 不连接）。
  static const int rosbridgeWsPort = 9090;
  /// mosquitto TCP：网关与仿真端 mqtt_client 使用（ACL 收口，App 无账号）。
  static const int mqttTcpPort = 1884;
  // 同一个 broker 的 WebSocket 监听，仅调试用（App 不再走 MQTT）。
  static const int mqttWsPort = 9002;
  // `MediaMTX` RTSP，视频兜底链路：Gazebo 相机 → `gst_video_source` → RTSP 推流。
  // WebRTC 不通时需在相机页手动切换，不会自动降级。配置：`amr_gazebo/config/mediamtx.yml:6-7`
  static const int rtspPort = 18554;
  // `MediaMTX` WHEP 信令端点（`webrtcAddress`），App 视频主链路。只放通信令端口不够，
  // 媒体走 ICE（8189 UDP/TCP），否则「信令通了但画面不出」。配置：`mediamtx.yml:28-29`
  static const int whepPort = 8889;
  // `MediaMTX` HLS，切片式 HTTP 流，供 Web 大屏用 `<video>` 直接播放；延迟高于 WebRTC。
  // 配置：`mediamtx.yml:12-13`
  static const int hlsPort = 18888;

  static const String rosbridgeWsUrl = 'ws://$host:$rosbridgeWsPort';

  static const String videoMainPath = 'camera';
  static const String videoLowPath = 'camera_low';

  static String whepUrl([String path = videoMainPath]) =>
      'http://$host:$whepPort/$path/whep';

  static String rtspUrl([String path = videoMainPath]) =>
      'rtsp://$host:$rtspPort/$path';
}
