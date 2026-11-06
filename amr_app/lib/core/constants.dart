/// 全局常量与连接配置。
class AppConstants {
  AppConstants._();

  /// 仿真端主机地址。
  /// 真机调试时必须为 WSL IP（WSL 内执行 `hostname -I` 查看），
  /// 可通过 `--dart-define=AMR_HOST=192.168.x.x` 注入，避免改代码。
  static const String host =
      String.fromEnvironment('AMR_HOST', defaultValue: '127.0.0.1');

  // `rosbridge_websocket`。机器人 → App 的遥测直通，只订阅不发命令：
  // `/map`（`TRANSIENT_LOCAL` 整图）、`/scan`、`/tf`、`/odom`、`/amcl_pose`、`/plan`、
  // `/camera/image_raw/compressed`（拍照单帧，不是视频流）。App 与 Web 大屏共用；
  // 无鉴权，禁止直接暴露公网。服务端：`amr_comm/launch/rosbridge.launch.py`
  static const int rosbridgeWsPort = 9090;
  // `mosquitto` TCP 监听。`amr/cmd/*`（App → 机器人，QoS 1）；`amr/cmd/ack|feedback|result`、
  // `amr/status/*`、`amr/alert`、`amr/trace`（机器人 → App，QoS 0）。移动端走此口；配置：`amr_comm/config/mosquitto.conf:3`
  static const int mqttTcpPort = 1884;
  // 同一个 broker 的 WebSocket 监听（不是第二个 broker），供浏览器（Web 大屏）使用，
  // 因为浏览器不能开原生 TCP。配置：`mosquitto.conf:6-7`
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
