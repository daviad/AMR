# 仿真巡检 AMR + Flutter 上位机 — 架构文档

| 项 | 内容 |
|---|---|
| 项目名称 | 仿真巡检 AMR + Flutter 上位机 |
| 版本 | v1.0 |
| 日期 | 2026-10-26 |
| 状态 | 已确认 |

---

## 0. 开发环境

| 项 | 内容 |
|---|---|
| 宿主系统 | Windows 11 |
| 子系统 | WSL2 + Ubuntu 24.04.5 LTS |
| ROS | ROS2 Jazzy（/opt/ros/jazzy） |
| 仿真器 | Gazebo Sim 8.15.0（gz-sim8，随 ros-jazzy-gz-sim-vendor 安装） |
| GUI | WSLg（$DISPLAY=:0），Gazebo GUI 可直接显示 |
| 已装包 | ros_gz_bridge, ros_gz_sim, teleop_twist_keyboard |
| 待装包 | nav2-bringup, cartographer-ros, rosbridge-suite, mosquitto, mqtt-client |

**WSL 注意事项**：
- 每次开终端需 `source /opt/ros/jazzy/setup.bash`（或写入 ~/.bashrc）
- Gazebo GUI 库在 `/opt/ros/jazzy/opt/gz_sim_vendor/lib/`，必须 source ROS 环境才能找到
- 仿真端跑在 WSL 内，Flutter 开发可在 Windows 侧（Android Studio / VS Code）或 WSL 内
- 手机 App 连接仿真端时，用 WSL 的 IP 地址（`hostname -I`），不是 localhost

**待装依赖安装命令**：
```bash
sudo apt update
sudo apt install -y \
  ros-jazzy-nav2-bringup \
  ros-jazzy-cartographer-ros \
  ros-jazzy-rosbridge-suite \
  ros-jazzy-mqtt-client \
  mosquitto mosquitto-clients
```

---

## 1. 技术选型总览

| 层 | 选型 | 说明 |
|---|---|---|
| ROS 版本 | ROS2 Jazzy | 与系统已装环境一致 |
| 仿真器 | Gazebo Sim 8.15.0（gz-sim8） | 非 Gazebo Classic，插件体系不同；通过 WSLg 显示 GUI |
| SLAM | Cartographer 2D | 激光 + IMU + 里程计 |
| 导航 | Nav2 | AMCL + 全局/局部规划 + 行为树 |
| 通信桥 A | rosbridge-suite | WebSocket，ROS2 ↔ Flutter 实时数据流 |
| 通信桥 B | MQTT（mosquitto + ros-jazzy-mqtt-client） | 命令/状态双向转发，QoS 保证；Jazzy 无 mqtt_bridge apt 包，用官方 mqtt_client |
| 上位机 | Flutter | 手机 App，横屏优先 |
| 状态管理 | Riverpod（代码生成） | 不依赖 BuildContext，StreamProvider 适配实时流 |
| 本地持久化 | Hive | 纯 Dart，存巡检点/路线 |
| 地图渲染 | CustomPaint + 缓存位图 | 可插拔图层架构 |
| 视频流 | MediaMTX（Gazebo 相机 → gst → RTSP 18554 → WHEP 8889 / HLS 18888） | 主链路；rosbridge JPEG 仅备选/退路 |

---

## 2. 系统总体架构

```
┌──────────────────────────────────────────────────────────────────────┐
│                        仿真端 (Linux PC)                              │
│                                                                      │
│  ┌─────────────┐   ┌──────────────┐   ┌──────────────────────────┐  │
│  │ Gazebo Sim  │──▶│ Cartographer │──▶│           Nav2           │  │
│  │ (AMR+传感器) │   │   SLAM建图    │   │  AMCL + 规划 + 避障 + BT  │  │
│  └──────┬──────┘   └──────────────┘   └────────────┬─────────────┘  │
│         │                                          │                │
│         │   ┌──────────────────────────────┐       │                │
│         └──▶│   amr_inspection (业务节点)    │◀──────┘                │
│             │  巡检点/路线/回充/模式状态机    │                        │
│             └──────────┬───────────┬───────┘                        │
│                        │           │                                 │
│             ┌──────────▼───┐  ┌────▼────────────┐                   │
│             │  rosbridge   │  │ ros2-mqtt-bridge │                   │
│             │  websocket   │  │   (mqtt_bridge)  │                   │
│             │   :9090      │  │                  │                   │
│             └──────┬───────┘  └────┬─────────────┘                   │
└────────────────────┼───────────────┼─────────────────────────────────┘
                     │ WebSocket     │ MQTT
                     ▼               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                     Flutter 手机 App                                  │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                        UI Layer                              │   │
│  │  MapPage / InspectionPage / StatusPage / CameraPage / ControlHUD │
│  └──────────────────────────────┬───────────────────────────────┘   │
│                                 │                                    │
│  ┌──────────────────────────────▼───────────────────────────────┐   │
│  │                    Service / Riverpod Layer                   │   │
│  │  NavigationService  InspectionService  RobotStatusService      │   │
│  │  VideoStreamService  PointsController  RouteController         │   │
│  └──────────────────────────────┬───────────────────────────────┘   │
│                                 │                                    │
│  ┌──────────────────────────────▼───────────────────────────────┐   │
│  │                    Communication Layer                        │   │
│  │  ┌─────────────────┐  ┌────────────────┐  ┌───────────────┐  │   │
│  │  │ RosbridgeWSClient│  │   MqttClient   │  │  TopicMapping │  │   │
│  │  │  机器人→App      │  │  App→机器人     │  │  (统一路由)    │  │   │
│  │  │                  │  │  机器人→App     │  │               │  │   │
│  │  └─────────────────┘  └────────────────┘  └───────────────┘  │   │
│  └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. 仿真端架构

### 3.1 ROS2 工作空间结构

```
amr_sim_ws/
├── src/
│   ├── amr_description/           # 纯资源包：URDF/xacro
│   │   ├── urdf/
│   │   │   ├── amr_base.xacro     # 底盘几何+碰撞+惯性
│   │   │   ├── amr_lidar.xacro    # 激光雷达
│   │   │   ├── amr_imu.xacro
│   │   │   ├── amr_camera.xacro
│   │   │   └── amr_robot.xacro    # 主文件
│   │   ├── CMakeLists.txt         # 仅 install(DIRECTORY)
│   │   └── package.xml
│   │
│   ├── amr_gazebo/                # 仿真启动 + world + bridge
│   │   ├── launch/
│   │   │   ├── sim_bringup.launch.py
│   │   │   └── ros_gz_bridge.launch.py
│   │   ├── worlds/
│   │   │   └── indoor.world
│   │   ├── config/
│   │   │   └── bridge_topics.yaml
│   │   └── package.xml
│   │
│   ├── amr_slam/                  # Cartographer
│   │   ├── config/cartographer_2d.lua
│   │   ├── launch/cartographer.launch.py
│   │   └── package.xml
│   │
│   ├── amr_nav/                   # Nav2
│   │   ├── config/
│   │   │   ├── nav2_params.yaml
│   │   │   └── amcl_params.yaml
│   │   ├── maps/indoor.pgm + indoor.yaml
│   │   ├── launch/nav_bringup.launch.py
│   │   └── package.xml
│   │
│   ├── amr_inspection/            # 自定义巡检业务（Python）
│   │   ├── amr_inspection/
│   │   │   ├── inspection_manager.py   # 巡检点/路线数据管理
│   │   │   ├── route_executor.py       # 路线执行
│   │   │   ├── charge_manager.py       # 回充逻辑
│   │   │   ├── mode_state_machine.py   # 模式状态机
│   │   │   └── inspection_node.py      # ROS2 节点入口
│   │   ├── setup.py
│   │   └── package.xml
│   │
│   ├── amr_comm/                     # 通信桥
│   │   ├── launch/
│   │   │   ├── rosbridge.launch.py
│   │   │   └── mqtt_bridge.launch.py # 启动 mqtt_client 节点
│   │   ├── config/
│   │   │   ├── mqtt_client.yaml      # mqtt_client 的 topic 映射配置
│   │   │   └── mosquitto.conf
│   │   └── package.xml
│   │
│   └── amr_bringup/               # 一键启动聚合
│       └── launch/full_bringup.launch.py
```

### 3.2 Gazebo Sim 插件配置（关键：gz 非 Classic）

**禁止使用** Gazebo Classic 插件（`libgazebo_ros_diff_drive.so` 等），必须使用 gz-sim 的 system 插件 + ros_gz_bridge。

| 功能 | gz System 插件 | ROS2 话题 | 桥接方式 |
|---|---|---|---|
| 差速驱动 | `gz::sim::systems::DiffDrive` | `/cmd_vel` ← gz `/cmd_vel` | ros_gz_bridge 双向 |
| 激光雷达 | `gz::sim::systems::Sensors` + `gpu_lidar` | `/scan` ← gz lidar | ros_gz_bridge |
| IMU | `gz::sim::systems::Imu` | `/imu/data` | ros_gz_bridge |
| 摄像头 | `gz::sim::systems::Sensors` + camera | `/camera/image_raw`, `/camera/image_raw/compressed` | ros_gz_bridge |
| 电池 | `gz::sim::systems::Battery` | `/battery/state` | ros_gz_bridge |
| TF | `gz::sim::systems::PosePublisher` | `/tf` | ros_gz_bridge |

**桥接配置**（`bridge_topics.yaml`）集中管理 ROS ↔ gz topic 映射，URDF 保持纯模型描述。

### 3.3 数据流（仿真端内部）

```
Gazebo Sim
  ├─ DiffDrive        ◀── /cmd_vel ──┐
  ├─ gpu_lidar        ──▶ /scan ─────┼──▶ Cartographer
  ├─ imu              ──▶ /imu/data ─┤      │
  ├─ camera           ──▶ /camera/* ─┤      ▼
  └─ PosePublisher    ──▶ /tf ───────┤  /map (OccupancyGrid)
                                     │      │
                                     ▼      ▼
                                   Nav2 (AMCL + Planner + Controller)
                                     ▲      │
                                     │      ├─▶ /plan
                                     │      └─▶ /cmd_vel (回 DiffDrive)
                                     │
  amr_inspection node ◀──────────────┘
    ├─ 订阅: /battery/state, /amcl_pose, Nav2 action result
    ├─ 发布: /inspection/status, /inspection/progress
    └─ 调用: Nav2 NavigateToPose Action
```

### 3.4 模式状态机

```
         ┌──────────┐
         │  MANUAL  │◀──── 紧急停止 / 手动接管
         └────┬─────┘
              │ 进入自动
         ┌────▼─────┐
    ┌───▶│   AUTO   │◀───┐
    │    └────┬─────┘    │
    │         │ 启动巡检  │ 巡检结束/取消
    │    ┌────▼─────┐    │
    │    │INSPECTING│────┘
    │    └────┬─────┘
    │         │ 电量低
    │    ┌────▼─────┐
    └────│ CHARGING │ (充满回 AUTO)
         └──────────┘
```

**规则**：所有模式切换请求经 `mode_state_machine.py` 单一入口处理，非法流转返回错误码。App 侧只做展示，不做决策。

### 3.5 通信桥分工

| 数据类型 | 通道 | QoS | 理由 |
|---|---|---|---|
| `/map`、`/scan`、`/tf`、`/odom`、`/plan`、摄像头 | rosbridge (WS) | 尽力而为 | 高频流式数据，低延迟 |
| 导航目标 `amr/cmd/goal` | MQTT 单通道 | MQTT QoS 1 | 唯一权威通道，cmd_id 幂等，避免双通道重复执行 |
| 巡检启动/停止、急停、模式切换、回充 | MQTT | QoS 1 | 控制命令，必须送达 |
| 电量、巡检进度、模式、告警 | MQTT | QoS 0 | 状态通知，允许丢失 |

---

## 4. Flutter 端架构

### 4.1 分层架构

```
UI Layer (Pages)
    │  Consumer / ref.watch
    ▼
Service / Riverpod Layer
    │  Stream / Notifier
    ▼
Communication Layer
  ┌─────────────┐  ┌──────────────┐
  │ RosbridgeWS │  │  MqttClient  │
  └──────┬──────┘  └──────┬───────┘
         └────────┬────────┘
                  ▼
           TopicMapping (统一路由)
```

### 4.2 目录结构

```
lib/
├── main.dart
├── app.dart                      # ProviderScope + 路由
├── core/
│   ├── topic_mapping.dart        # 所有 topic 常量，单一事实来源
│   ├── message_models.dart       # MQTT 消息契约
│   └── constants.dart
├── comm/
│   ├── rosbridge_client.dart     # WebSocket 封装
│   ├── mqtt_client.dart          # MQTT 封装
│   └── rosbridge_protocol.dart   # rosbridge 协议序列化
├── models/
│   ├── robot_pose.dart
│   ├── inspection_point.dart
│   ├── inspection_route.dart
│   ├── robot_status.dart
│   └── occupancy_grid.dart
├── providers/
│   ├── comm/
│   │   ├── rosbridge_provider.dart
│   │   └── mqtt_provider.dart
│   ├── data/
│   │   ├── map_provider.dart
│   │   ├── scan_provider.dart
│   │   ├── tf_provider.dart
│   │   ├── plan_provider.dart
│   │   └── camera_provider.dart
│   ├── status/
│   │   ├── battery_provider.dart
│   │   ├── mode_provider.dart
│   │   ├── inspection_provider.dart
│   │   └── alert_provider.dart
│   ├── navigation/
│   │   └── navigation_controller.dart
│   └── inspection/
│       ├── points_controller.dart
│       └── route_controller.dart
├── services/
│   ├── navigation_service.dart
│   ├── inspection_service.dart
│   ├── robot_status_service.dart
│   └── video_stream_service.dart
├── map/
│   ├── map_viewport.dart         # 坐标变换
│   ├── map_layer.dart            # 图层接口（扩展核心）
│   ├── map_data_source.dart      # 地图源接口
│   ├── layers/
│   │   ├── base_map_layer.dart
│   │   ├── path_layer.dart
│   │   ├── robot_layer.dart
│   │   ├── inspection_points_layer.dart
│   │   └── target_point_layer.dart
│   ├── map_view.dart             # 核心 MapView（手势+调度）
│   └── map_painter.dart
├── pages/
│   ├── map_page.dart
│   ├── inspection_page.dart
│   ├── status_page.dart
│   └── camera_page.dart
└── widgets/
    ├── control_hud.dart
    ├── battery_indicator.dart
    └── ...
```

### 4.3 状态管理（Riverpod）

| 数据来源 | Provider 类型 | 说明 |
|---|---|---|
| rosbridge 流数据（map/scan/tf/plan/camera） | `StreamProvider` | 纯数据流，UI 被动响应 |
| MQTT 状态（battery/mode/inspection/alert） | `StreamProvider` 或 `Notifier` | 低频状态用 Notifier 缓存 |
| 用户操作（导航、急停、模式切换） | `Notifier` | 有副作用，命令式 |
| 巡检点/路线本地数据 | `Notifier` + Hive | CRUD + 持久化 |
| 派生计算状态 | `Provider` | 纯函数组合 |

**核心优势**：不依赖 BuildContext，Service 层可直接 `ref.read` 状态；StreamProvider 天生适配 rosbridge/MQTT 的实时流。

### 4.4 通信层设计

**TopicMapping（单一事实来源）**：

```dart
class TopicMapping {
  // ── 机器人 → App（rosbridge 订阅）──
  static const map = '/map';
  static const scan = '/scan';
  static const tf = '/tf';
  static const odom = '/odom';
  static const plan = '/plan';
  static const cameraCompressed = '/camera/image_raw/compressed';
  static const amclPose = '/amcl_pose';

  // ── App → 机器人（MQTT publish，QoS 1）──
  static const cmdGoal = 'amr/cmd/goal';
  static const cmdInspectionStart = 'amr/cmd/inspection/start';
  static const cmdInspectionStop = 'amr/cmd/inspection/stop';
  static const cmdMode = 'amr/cmd/mode';
  static const cmdEStop = 'amr/cmd/estop';
  static const cmdReturnCharge = 'amr/cmd/return_charge';

  // ── 机器人 → App（MQTT subscribe，QoS 0）──
  static const statusBattery = 'amr/status/battery';
  static const statusInspection = 'amr/status/inspection';
  static const statusMode = 'amr/status/mode';
  static const alert = 'amr/alert';
}
```

**RosbridgeWSClient**：
- 基于 `web_socket_channel`，实现 rosbridge 协议（subscribe/publish/call_service）
- JSON 消息反序列化为 Dart model，通过 `Stream` 推给 Service 层
- 自动重连 + 心跳（5s ping）
- 大消息（map、image）节流处理

**MqttClient**：
- 基于 `mqtt_client` Dart 包
- 命令消息 QoS 1，状态消息 QoS 0
- 保留消息（retain）用于模式/电量，App 重连后立即获取最新值
- 遗嘱消息（LWT）：App 异常断开时发布 `amr/status/app_offline`

### 4.5 地图点击导航流程

```
用户点击 MapView
  │
  ▼
屏幕坐标 (px, py)
  │  MapViewport.screenToWorld(px, py)
  ▼
世界坐标 (x, y)  [map frame]
  │
  ▼
目标确认浮层（可拖拽微调圆点）
  │ 用户确认
  ▼
NavigationService.navigateTo(x, y, theta)
  └─ mqtt.publish('amr/cmd/goal', {x,y,theta}, QoS 1) ← 唯一权威通道（App → 机器人，cmd_id 幂等）
  │
  ▼
仿真端 mqtt_client → /amr/cmd/goal → mission_bridge → NavigateToPose Action → Nav2
  │
  ▼
rosbridge 推送 /plan → MapView 绘制路径
rosbridge 推送 /tf → MapView 更新机器人位姿
Nav2 action result → MQTT status → App 提示到达
```

### 4.6 地图渲染架构（可扩展图层）

**核心接口**：

```dart
abstract class MapLayer {
  String get id;           // 唯一标识
  int get zIndex;          // 绘制顺序，越大越上层
  bool get visible;
  void paint(Canvas canvas, MapViewport viewport);
  String? hitTest(Offset screenPos, MapViewport viewport);  // 返回命中元素 id
  void onDragStart/Update/End(...);  // 可选
  void onTap(...);                   // 可选
}

abstract class MapDataSource {
  Future<ui.Image?> buildImage();
  MapInfo get info;
  Stream<void> get onChange;
}

class MapViewport {
  Offset offset;
  double scale;
  Offset worldToScreen(Offset world);
  Offset screenToWorld(Offset screen);
}
```

**MapView 职责**：
- 管理视口变换（offset/scale）
- 手势处理（缩放、平移、点击、拖拽）
- 按 zIndex 顺序调度各 Layer 的 paint
- 命中测试从上层到下层，命中即停止

**扩展方式**：新增叠加元素只需实现 `MapLayer` 接口，在使用 MapView 时传入 layers 列表，**核心代码零修改**。

**内置图层**：BaseMapLayer（zIndex=0）、PathLayer（10）、InspectionPointsLayer（40）、RobotLayer（50）、TargetPointLayer（60）

### 4.7 视频流抽象（已升级为主线）

视频预览不再走逐帧 JPEG（rosbridge），改为 **GStreamer → MediaMTX → WebRTC(WHEP)**；
拍照仍走 `/camera/image_raw/compressed` 单帧，两条链路彻底解耦。

```dart
abstract class VideoStreamPlayer {
  RTCVideoRenderer? get renderer;              // WebRTC 渲染
  VideoPlayerController? get controller;       // RTSP fallback
  Stream<Uint8List>? get frameStream;          // rosbridge JPEG fallback
  Stream<VideoHealthSnapshot>? get healthStream;
  VideoHealthSnapshot get health;
  Future<void> start();
  Future<void> stop();
}
```

服务端管线：

```
Gazebo /camera/image_raw
  → gst_video_source (tee)
      → x264enc(主码流) → rtspclientsink → MediaMTX camera
      → x264enc(低码流) → rtspclientsink → MediaMTX camera_low
  → MediaMTX → WebRTC WHEP :8889 / ICE :8189 → App
```

健康状态机：`HEALTHY → DEGRADED → LOST`，依据 `inbound-rtp` 的
`framesDecoded / freezeCount / packetsLost / jitter / totalDecodeTime` 与
`candidate-pair.currentRoundTripTime` 判定。auto 模式在连续 2 次 DEGRADED/LOST
切低码流，连续 4 次 HEALTHY 升回主码流（10s 冷却）。
视频 LOST 只影响预览，MQTT 控制面保持可用。

### 4.8 本地持久化（Hive）

**数据模型**：
- `InspectionPoint`（HiveType 0）：id, name, x, y, theta, dwellTime, capturePhoto
- `InspectionRoute`（HiveType 1）：id, name, pointIds[], loop

**Provider 对接**：`inspectionBoxProvider` 提供 Hive Box，`PointsController` / `RouteController` 读写 Box 并同步 Riverpod 状态。

### 4.9 多端形态（Android / iOS / Web）

> 核对日期：2026-11-05。后端只有一套（ROS 2 Jazzy + Gazebo Sim 8.15 + Nav2 + Cartographer + MediaMTX）；Android / iOS / Web 三端全部由 `amr_app` 同一份 Flutter 工程产出。本节只写当前代码与已实测事实，未验证项直接标注，不把计划当成果。

```
Android APK ─┐
iOS Runner  ─┼──▶ rosbridge :9090 / MQTT :1884·:9002 / MediaMTX :18554·:8889·:8189·:18888
Web build/web ┘
```

#### 4.9.1 每端的运行形态

| 端 | 构建产物 | 运行位置 | 如何连后端 | 验证状态 |
|---|---|---|---|---|
| Android | APK（`flutter build apk` / `flutter run`），`applicationId = com.amr.amr_app` | Android 模拟器或真机 | 默认 `AMR_HOST=127.0.0.1` + `adb reverse`；或 `--dart-define=AMR_HOST=<可达 IP>` 直连 | 模拟器已实测 |
| iOS | `Runner.app`（需要 macOS + Xcode） | iPhone 真机 / iOS 模拟器（iOS 模拟器也只能在 macOS 上运行） | 设计为直连局域网：`--dart-define=AMR_HOST=<WSL 可达 IP>`；iOS 没有 `adb reverse` | **未验证**：无 macOS 环境、未 `pod install`、未编译、未真机/模拟器运行 |
| Web | `build/web` 静态产物 | Chrome / Edge，由任意静态服务器托管（开发期常用 `python3 -m http.server 8081`） | `ws://<host>:9090`、`ws://<host>:9002`、`http://<host>:8889`、`http://<host>:18888`；入口 `http://localhost:8081/#/dashboard` | 地图已可用（2026-11-05）；大屏视频为已知缺口（见 4.9.6） |

补充事实：

- Android 的 `AndroidManifest.xml` 已声明 `INTERNET`、`ACCESS_NETWORK_STATE`，并设置 `android:usesCleartextTraffic="true"`，否则 rosbridge/MQTT/WHEP/HLS 的明文 http/ws 都会被系统拦截。
- iOS 的 `ios/Podfile` 为 `platform :ios, '15.0'`；`ios/Runner/Info.plist` 已加 `NSAllowsLocalNetworking` 与 `NSLocalNetworkUsageDescription`；Bundle ID 为 `com.amr.amr_app`（`project.pbxproj` 中三处 `IPHONEOS_DEPLOYMENT_TARGET = 15.0`）。这些只是工程配置，**不代表 iOS 可编译或可运行**。
- Web 端不加载 `fvp` 等原生插件；`main.dart` 里只有 `if (!kIsWeb)` 时才注册 fvp，Web 端视频只能走浏览器原生能力（WebRTC/HLS/`<video>`）。
- Web 工程使用普通 `routes`（`app.dart` 的 `'/dashboard'`），Flutter Web 默认走 hash 路由，所以地址必须带 `#/dashboard`，否则落到默认地图页。
- `AMR_HOST` 是编译期常量（`constants.dart` 的 `String.fromEnvironment('AMR_HOST', defaultValue: '127.0.0.1')`），只能写裸主机名/IP，不能带 `http://` 或端口；改了必须重新 `flutter run` / 重新 build，热重载不生效。

#### 4.9.2 连接方式差异与端口清单

| 用途 | 后端监听 | 协议 | Android | iOS | Web |
|---|---|---|---|---|---|
| rosbridge（地图/位姿/路径） | 9090 | WebSocket | `adb reverse tcp:9090`，或直连 | 直连 `AMR_HOST` | `ws://<host>:9090` |
| MQTT（遥控/遥测） | 1884 / 9002 | TCP / WebSocket | 1884 + `adb reverse tcp:1884` | 直连 1884 | 只能 `ws://<host>:9002`（浏览器不能裸 TCP） |
| RTSP（视频兜底） | 18554 | TCP | 18554 + `adb reverse`（fvp 强制 TCP interleaved） | 直连（依赖 fvp，未验证） | **不可用**（浏览器没有 RTSP 播放器） |
| WHEP 信令 | 8889 | HTTP/TCP | 8889 + `adb reverse` | 直连 | `http://<host>:8889` |
| ICE 媒体面 | 8189 | UDP + ICE-TCP | `adb reverse` 只能转 TCP，UDP 8189 过不去 | 直连（需防火墙放行 UDP 8189） | 直连（需防火墙放行 UDP 8189） |
| HLS（大屏视频） | 18888 | HTTP | 可选，需额外 `adb reverse tcp:18888` | 可选 | `http://<host>:18888` |
| Web 静态站点 | 8081 | HTTP | — | — | 浏览器入口 |

**Android 的两种连法**：

1. **直达（推荐）**：WSL 使用 mirrored 模式时 `--dart-define=AMR_HOST=localhost`；NAT 模式则用 WSL 的 LAN IP，并在 Windows 防火墙放行 TCP 9090/1884/8889/18554 与 UDP 8189。此时 WebRTC 媒体面可直连。
2. **`adb reverse`（退化）**：默认 `AMR_HOST=127.0.0.1`，在 Windows 侧执行：

```powershell
& $adb reverse tcp:9090  tcp:9090    # rosbridge
& $adb reverse tcp:1884  tcp:1884    # MQTT
& $adb reverse tcp:8889  tcp:8889    # WHEP 信令
& $adb reverse tcp:18554 tcp:18554   # RTSP fallback
& $adb reverse --list
```

`adb reverse` **只转发 TCP**：9090/1884/8889/18554 都能通，但 WebRTC 的媒体面（UDP 8189）不能通，ICE 协商通常失败。App 不会自动切源，需要在相机页手动选「RTSP（TCP 兼容）」；RTSP 已在 `main.dart` 通过 fvp 注册强制 `avformat.rtsp_transport=tcp`。模拟器每次重启或 `adb kill-server` 后规则都会丢失，需要重做。

**iOS**：没有 `adb reverse` 这一套，设计上就是直连局域网 IP。真机若用 `iproxy`（libimobiledevice）也只能转 TCP，不能替代 UDP 8189，且本项目未使用。Info.plist 里已配置本地网络权限；iOS 14+ 首次弹窗若被拒绝，表现为所有视频通路都失败。以上全部**未验证**。

**Web**：两条 WebSocket（9090/9002）加两条 HTTP（8889/18888）即可，不涉及 `adb reverse`。MediaMTX 已配置 `webrtcAllowOrigins: ["*"]` 与 `hlsAllowOrigins: ["*"]`，但浏览器侧仍受 CORS/混合内容/自动播放策略约束。

#### 4.9.3 视频通路的选择与差异

| 端 | 相机页默认 | 相机页可选兜底 | 大屏页 | 依据与状态 |
|---|---|---|---|---|
| Android | WebRTC（WHEP `:8889`，媒体 ICE `:8189`） | RTSP（`video_player` + fvp，TCP）；rosbridge JPEG（`:9090`） | HLS（`video_player` 播 `:18888`） | WebRTC 直连已实测；`adb reverse` 下 WebRTC 失败、需手动切 RTSP |
| iOS | 同一份 Dart 代码，默认同样是 WebRTC | 同一份代码：RTSP（fvp）/ rosbridge JPEG | HLS（`video_player`） | **未验证**；fvp 的 iOS 编译与 RTSP 硬解均未验证 |
| Web | WebRTC（WHEP `:8889`） | rosbridge JPEG（`:9090`） | HLS（`hls.min.js` + `<video>`，`:18888`） | 相机页 WHEP **未实测**；大屏 HLS 为已知缺口 |

**为什么 Web 端必须单独处理**：

1. **浏览器不能播 RTSP**。`video_stream_service.dart` 的 `RtspVideoPlayer` 依赖 `video_player`，Web 端的 `video_player` 后端是 HTML5 `<video>`，没有 `rtsp://` 支持。但 UI 的视频源菜单并未按平台裁剪，Web 端仍能看到「RTSP」选项；选中后不会工作。这是当前代码的已知限制，不是网络问题。
2. **Chrome/Edge 没有原生 HLS**。大屏页固定使用 `http://<host>:18888/camera/index.m3u8`（`dashboard_page.dart` 的 `_videoUrl`）。Web 端通过 `dashboard_video_web.dart` 用 `HtmlElementView` 注册一个 `<video data-hls=...>`，由 `web/index.html` 里的 `hls.min.js` 胶水脚本扫描并绑定；非 Web 端则由 `dashboard_video_io.dart` 用 `video_player` 播放同一 URL。
3. **WebRTC 必须有 transceiver**。`WebRtcWhepPlayer` 在 `createOffer()` 之前显式执行 `addTransceiver(kind: video, direction: RecvOnly)`。没有这条时，unified-plan 生成的 SDP 没有 `m=video`，也就没有 `a=ice-ufrag`，MediaMTX 会返回 400 `SetRemoteDescription called with no ice-ufrag`。这段代码是跨端共享的；Android 侧同样需要，因为 `flutter_webrtc` 的 Android 实现会忽略 `offerToReceiveVideo` 这类 constraints。
4. **WebRTC 媒体面不走 `adb reverse`**。Web 端是直连网络，媒体仍是 UDP/TCP 8189；只要局域网和防火墙允许即可。Android 走 `adb reverse` 时这条不成立，所以两端表现不同。
5. **HLS 的兜底播放尚未实现**。当前 `web/index.html` 只做 `loadSource + attachMedia`（Safari 走原生 `v.src`），没有在 `MANIFEST_PARSED` 后显式 `play()`，也没有错误恢复/重试。这正是大屏视频停在 `0:00` 的已知现象之一；根因尚未定论，本节按已知缺口记录。

**健康与降级**：`VideoHealthSnapshot`（`HEALTHY / DEGRADED / LOST`）与自动主/低码流切换只对 WebRTC 路径生效；RTSP 与 rosbridge JPEG 没有 `healthStream`，返回固定 `HEALTHY`。因此“视频健康条/自动降码流”能力在 Web 端也只对 WHEP 有意义。

#### 4.9.4 能力矩阵

| 能力 | Android | iOS | Web | 证据/说明 |
|---|---|---|---|---|
| 视频（相机页） | **已实测** | **未实测** | **未实测** | Android：WebRTC 直连已实测；`adb reverse` 下需手动切 RTSP。Web：WHEP/JPEG 未在浏览器实测 |
| 视频（大屏 HLS） | **未实测** | **未实测** | **已知缺口** | Web 大屏停在 `0:00`，hls.js 未推进（见 4.9.6） |
| 地图 | **已实测** | **未实测** | **已实测** | Web 地图 2026-11-05 用户确认可用；数据链路见下方说明 |
| 定位（机器人位姿） | **已实测** | **未实测** | **未实测** | 共用 `/amcl_pose` + `/tf` 链路；Web 未单独复测 |
| 遥控（导航/巡检/急停） | **已实测** | **未实测** | **未实测** | Web 大屏有开始/停止按钮、MQTT 走 9002，但未单独复测 |
| 遥测（电量/模式/告警） | **已实测** | **未实测** | **未实测** | 共用 MQTT 状态 topic；Web 未单独复测 |

**Web 地图数据链路的核对结论（2026-11-05）**：

- Web 与 Android 共用 `mapProvider`，最终都走 `rosbridge_client.dart` 的 `subscribe()` 订阅 `/map`，`throttleRate: 500`。
- **订阅端没有声明 QoS**：`rosbridge_client.dart` 的 `subscribe()` 发出的是 `op/id/topic/type/queue_length/throttle_rate`，没有 `qos` 字段；`rosbridge_protocol.dart` 的 `rosSubscribe()` 也没有 `qos` 字段。
- 运行时核对 `ros2 topic info -v /map`：发布端 `map_server` 的 Durability 为 `TRANSIENT_LOCAL`；订阅端 `amcl`、`global_costmap`、`rosbridge_websocket` 也都是 `TRANSIENT_LOCAL`。
- 原因是 rosbridge 服务端的默认 QoS 推断：`rosbridge_library/internal/subscribers.py` 的 `_get_default_qos_profile()` 会在“该 topic 所有发布端都是 `TRANSIENT_LOCAL`”时，把订阅端默认 QoS 升级为 `TRANSIENT_LOCAL`。所以 Web 端能收到 latched 的 `/map`。
- 结论：**Web 地图可用不是“Dart 订阅端补了 `transient_local`”，代码里也没有这个字段**；它是 rosbridge 服务端自动匹配的结果。潜在风险：如果 `/map` 后续出现非 `TRANSIENT_LOCAL` 的发布端，自动推断可能不再升级，而客户端又没有显式 QoS 兜底。

#### 4.9.5 代码分层与条件导入分叉

**跨端共享（无平台分支）**：

| 路径 | 作用 |
|---|---|
| `lib/core/constants.dart` | 主机、端口、WHEP/RTSP URL |
| `lib/core/topic_mapping.dart` | rosbridge/MQTT topic 常量 |
| `lib/core/message_models.dart` | MQTT 消息契约 |
| `lib/comm/rosbridge_client.dart` | WebSocket 连接、订阅/发布、重连、心跳 |
| `lib/comm/rosbridge_protocol.dart` | rosbridge JSON 协议封装 |
| `lib/models/*` | 位姿、地图、巡检点/路线、状态等模型 |
| `lib/providers/*` | Riverpod provider（comm/data/navigation/inspection） |
| `lib/map/*` | 视口、图层、绘制 |
| `lib/services/photo_capture_service.dart` | 拍照（单帧 CompressedImage） |
| `lib/services/video_stream_service.dart` | 视频源枚举、WebRTC/RTSP/JPEG 播放器、健康与降码流 |
| `lib/pages/*` | 页面逻辑（仅条件导入处有平台差异） |

**现有条件导入/平台分叉点**：

| 入口 | 写法 | 非 Web 实现 | Web 实现 | 差异 |
|---|---|---|---|---|
| `lib/comm/mqtt_client.dart` L6 | `import 'mqtt_client_factory_io.dart' if (dart.library.html) 'mqtt_client_factory_web.dart';` | `MqttServerClient.withPort(...)` → TCP 1884 | `MqttBrowserClient` → `ws://<host>:9002` | 浏览器不能裸 TCP |
| `lib/pages/camera_page.dart` L11-L12 | `import '../services/capture_saver_io.dart' if (dart.library.html) '../services/capture_saver_web.dart';` | 写临时目录并返回路径 | Blob + `<a download>` 触发浏览器下载 | 文件落地方式不同 |
| `lib/pages/dashboard_page.dart` L22-L23 | `import '../services/dashboard_video_io.dart' if (dart.library.html) '../services/dashboard_video_web.dart';` | `video_player` 播 HLS | `HtmlElementView` + `hls.min.js` | 浏览器 HLS 需要 JS 解码 |
| `lib/main.dart` L19 | `if (!kIsWeb) { fvp.registerWith(...) }` | Android/iOS 注册 fvp（RTSP、硬解） | 不注册 | Web 无原生插件 |
| `web/index.html` + `web/hls.min.js` | 静态资源 | — | hls.js 胶水脚本 | 仅 Web |

关键说明：

- **`video_stream_service.dart` 本身没有 `dart.library.html` 条件导入**，也没有 `Platform.isIOS/isAndroid` 分支；三端共用同一份播放器代码。Web 端的实际差异来自“可用后端”：WebRTC 与 rosbridge JPEG 可用，RTSP 分支不可用。
- 全仓 `lib/` 的平台判断只有 `main.dart` 的 `kIsWeb`；iOS 工程与 Android 工程共享全部业务代码。
- Web 构建**不能加 `--wasm`**：上述三处条件导入按 `dart.library.html` 分叉，wasm 下会退回 `dart:io`，直接编译失败。

#### 4.9.6 未验证项与已知缺口

**未验证**：

- iOS 全链路：`pod install` 未执行、无 macOS/Xcode 构建、无模拟器/真机运行；`flutter_webrtc` 的 iOS 实现、fvp（libmdk）能否编译并硬解 H.264 RTSP，均未验证。
- iOS Bundle ID `com.amr.amr_app` 含下划线，属非 Apple 规范字符；本地调试签名一般可用，但 Provisioning / App Store 提交可能被拒。
- 浏览器相机页 WHEP：CORS + UDP 8189 + transceiver 的组合未实测。
- Android 真机不走 `adb reverse`、直接连局域网 IP 的 WebRTC 场景未实测；已验证的是模拟器 + `adb reverse` / mirrored 路径。
- Web 的定位、遥控、遥测未单独复测（地图已确认）。

**已知缺口**：

- **Web 大屏视频停在 `0:00`，hls.js 未推进**。当前 `web/index.html` 只绑定 `loadSource/attachMedia`，没有兜底 `play()` 与错误恢复；根因未定论，状态仍为未解决。
- Web 相机页视频源菜单未按平台隐藏 RTSP；选中 RTSP 在浏览器中不可用。
- 客户端未显式声明 rosbridge QoS；`/map` 依赖 rosbridge 服务端的 `TRANSIENT_LOCAL` 自动推断（见 4.9.4），发布端 QoS 变化时存在回归风险。

---

## 5. 通信协议契约

### 5.1 rosbridge topic 映射

| ROS Topic | 类型 | 方向 | 频率 |
|---|---|---|---|
| `/map` | nav_msgs/OccupancyGrid | 机器人 → App | 地图更新时 |
| `/scan` | sensor_msgs/LaserScan | 机器人 → App | 10-40Hz |
| `/tf` | tf2_msgs/TFMessage | 机器人 → App | 50-100Hz |
| `/odom` | nav_msgs/Odometry | 机器人 → App | 50Hz |
| `/plan` | nav_msgs/Path | 机器人 → App | 规划更新时 |
| `/camera/image_raw/compressed` | sensor_msgs/CompressedImage | 机器人 → App | **仅拍照按需** |
| `/amcl_pose` | geometry_msgs/PoseWithCovarianceStamped | 机器人 → App | 10Hz |

> 导航不再使用 rosbridge `/goal_pose`；控制命令统一走 MQTT（见 5.2），避免双通道重复执行。

### 5.2 MQTT topic 契约

**命令信封（App → 仿真，`std_msgs/String` 透传 JSON）**：

```json
{
  "cmd_id": "cmd-<micros>-<rand>",
  "trace_id": "trace-<micros>-<rand>",
  "type": "NAVIGATE_TO_POSE",
  "timestamp_ms": 1793670000000,
  "ttl_ms": 8000,
  "payload": {"frame_id": "map", "x": 1.0, "y": 2.0, "theta": 0.0}
}
```

**命令（QoS 1）**：

| Topic | 说明 |
|---|---|
| `amr/cmd/goal` | 导航目标（含 cmd_id / trace_id / timestamp_ms / ttl_ms） |
| `amr/cmd/cancel` | `{"cmd_id": "cancel-...", "trace_id": "...", "target_cmd_id": "<目标>"}` |
| `amr/cmd/inspection/start` | `{"route_id": "route_1", "loop": false, "points": [...]}` |
| `amr/cmd/inspection/stop` | `{}` |
| `amr/cmd/mode` | `{"mode": "auto"}`（manual/auto/inspect/charge） |
| `amr/cmd/estop` | `{"stop": true}` |
| `amr/cmd/return_charge` | `{}` |

> **巡检数据单一事实来源**：巡检点/路线存于 App 端 Hive，`inspection/start` 命令携带完整路线数据全量下发，仿真端收到后登记（覆盖同 id）再执行；不带 `points` 字段时回退使用仿真端内置演示路线。

**指令生命周期回执（仿真 → App）**：

| Topic | QoS | Payload 要点 |
|---|---|---|
| `amr/cmd/ack` | 1 | `cmd_id / trace_id / status(ACCEPTED\|REJECTED) / error_code / latency_ms` |
| `amr/cmd/feedback` | 0 | `state=EXECUTING / nav_state / number_of_recoveries / distance_remaining / eta_sec / heartbeat` |
| `amr/cmd/result` | 1 | `cmd_id / status(SUCCEEDED\|FAILED\|CANCELLED) / error_code / latency_ms / total_recoveries` |
| `amr/trace` | 0 | 结构化 trace：`component / event / trace_id / cmd_id / latency_ms` |

**应用层状态机**（App 与 bridge 共同遵守，`cmd_id` 幂等）：

```
IDLE → PENDING → SENT → ACKED → EXECUTING → SUCCEEDED / FAILED / CANCELLED
                 └ ACK 超时(1.2s) → UNKNOWN
                          ACKED/EXECUTING ─ Feedback 超时(3s) → STALE
                          终态超时(120s) → UNKNOWN
取消：CANCELING → CANCELLED；5s 未终态 → UNKNOWN
```

MQTT QoS 只保证逐跳投递；业务语义（是否真的执行、是否完成、失败原因）全部由以上回执与状态机补足。

**状态（仿真 → App）**：

| Topic | QoS | Retain | Payload |
|---|---|---|---|
| `amr/status/battery` | 0 | true | `{"level": 85, "voltage": 12.1, "charging": false}` |
| `amr/status/inspection` | 0 | false | `{"state": "running", "progress": 2, "total": 5, "current_point": "p3"}` |
| `amr/status/mode` | 0 | true | `{"mode": "auto"}` |
| `amr/status/video` | 0 | true | `{"state": "ONLINE|DEGRADED|OFFLINE", "main_fps": 5.0, "last_error": null}` |
| `amr/status/video_metrics` | 0 | true | `{"main": {"encode_latency_ms": {"p50":..., "p95":..., "p99":...}}}` |
| `amr/alert` | 0 | false | `{"level": "warn", "code": "LOW_BATTERY", "message": "电量低于 20%"}` |

---

## 6. 扩展点设计

| 扩展点 | 接口 | 说明 |
|---|---|---|
| 地图叠加层 | `MapLayer` | 加任何地图元素，核心代码不变 |
| 地图数据源 | `MapDataSource` | 支持栅格/点云/瓦片等不同底图 |
| 视口变换 | `MapViewport` | 可加旋转等变换 |
| 视频流 | `VideoStreamPlayer` | WebRTC(主) / RTSP / rosbridge JPEG 切换 + 健康状态驱动降级 |
| 通信桥 | TopicMapping + 消息契约 | 换 MQTT/rosbridge 实现不改业务 |
| 持久化 | Box Provider 抽象 | Hive → SQLite/Isar 切换 |

---

## 7. 实施阶段规划

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| P0 | 确认系统已装 ROS2 Jazzy / Gazebo / Nav2 / Cartographer / rosbridge / mosquitto | 输出已装包清单 |
| P1 | URDF 底盘 + gz DiffDrive + 传感器 + ros_gz_bridge | `/scan` `/odom` `/imu/data` 有数据 |
| P2 | 键盘遥控验证 | 键盘控制 AMR 移动 |
| P3 | Cartographer 建图 + 保存地图 | `/map` 有数据，可保存 |
| P4 | Nav2 导航（AMCL + 规划 + 避障） | RViz 点目标可达 |
| P5 | rosbridge + MQTT 桥接 | rosbridge 能订阅，MQTT 能发命令 |
| P6 | Flutter 地图渲染 + 点击导航 | App 显示地图，点击 AMR 移动 |
| P7 | 巡检点/路线 + 状态机 | App 配置巡检点，一键巡检 |
| P8 | 回充 + 告警 | 低电量自动回充，App 弹告警 |
| P9 | 视频流预览 | App 显示摄像头画面 |
| P10 | 全链路联调优化 | 完整巡检流程跑通 |

---

## 8. 关键风险与对策

| 风险 | 对策 |
|---|---|
| Gazebo Classic vs Sim 插件混淆 | 明确使用 gz system 插件 + ros_gz_bridge，URDF 不嵌 `<ros>` |
| 大消息性能（map/image） | 缓存位图、节流重绘、CompressedImage |
| MQTT 回调线程安全 | 回调线程只解析分发，不做重活，异步 loop 负责广播 |
| 状态机一致性 | 仿真端单一状态机入口，拒绝非法流转 |
| 跨机通信 | 手机不直接连 DDS，通过 rosbridge/MQTT，避开 FastDDS 跨机发现问题 |
| rosbridge 与 MQTT 双发一致性 | rosbridge 低延迟，MQTT QoS 1 可靠，仿真端去重 |

---

## 9. 开发环境依赖清单

### 仿真端（已装 ✅ / 待装 ⬜）
- ✅ ROS2 Jazzy
- ✅ Gazebo Sim 8.15.0（gz-sim8，含 ros_gz_bridge、ros_gz_sim）
- ✅ teleop_twist_keyboard
- ⬜ ros-jazzy-nav2-bringup
- ⬜ ros-jazzy-cartographer-ros
- ⬜ ros-jazzy-rosbridge-suite
- ⬜ mosquitto + mosquitto-clients
- ⬜ ros-jazzy-mqtt-client（官方 ROS2 MQTT 桥接，Jazzy 无 mqtt_bridge apt 包）

### 上位机
- Flutter SDK（3.x）
- flutter_riverpod, riverpod_annotation, riverpod_generator
- hive, hive_flutter
- web_socket_channel
- mqtt_client
- build_runner
