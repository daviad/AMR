# AI 开发上下文 — 仿真巡检 AMR + Flutter 上位机

> 本文件为 AI 辅助开发的入口上下文。详细需求见 `docs/requirements.md`，详细架构见 `docs/architecture.md`。开发前先读本文件，需要细节时再查对应文档章节。

## 1. 项目一句话

在 Gazebo Sim 中仿真一台差速巡检 AMR（建图/导航/巡检/回充），Flutter 手机 App 通过 rosbridge(WS) + MQTT 控制，核心交互是**地图点击导航**。纯仿真，无真机。

## 2. 技术栈（锁定）

| 层 | 选型 |
|---|---|
| 系统 | Win11 + WSL2 + Ubuntu 24.04 |
| ROS | Jazzy |
| 仿真 | Gazebo Sim 8.15.0（**gz-sim8，非 Classic**） |
| SLAM | Cartographer 2D |
| 导航 | Nav2（AMCL + 规划器 + 行为树） |
| 通信 A | rosbridge-suite（WebSocket，数据下行） |
| 通信 B | mosquitto + ros-jazzy-mqtt-client（命令/状态，QoS） |
| 上位机 | Flutter（手机 App，横屏优先） |
| 状态 | Riverpod（代码生成） |
| 持久化 | Hive |
| 地图 | CustomPaint + 缓存位图 + 可插拔图层 |
| 视频 | GStreamer 双码流 → MediaMTX → WebRTC(WHEP)；拍照走 CompressedImage 单帧 |

## 3. 目录结构

```
/home/dxw/amr/
├── docs/
│   ├── requirements.md      # 需求文档
│   ├── architecture.md      # 架构文档
│   └── DEVELOPMENT_PLAN.md  # 开发任务计划（阶段进度+交接备注）
├── amr_sim_ws/              # ROS2 工作空间（仿真端）
│   └── src/
│       ├── amr_description/ # URDF/xacro
│       ├── amr_gazebo/      # 仿真启动 + world + ros_gz_bridge
│       ├── amr_slam/        # Cartographer
│       ├── amr_nav/         # Nav2
│       ├── amr_inspection/  # 巡检业务节点(Python)
│       ├── amr_comm/        # rosbridge + MQTT
│       └── amr_bringup/     # 一键启动
└── amr_app/                 # Flutter 工程（上位机）
```

## 4. ⚠️ 易错点（AI 必看）

1. **Gazebo Sim ≠ Classic**：禁用 `libgazebo_ros_diff_drive.so` 等 Classic 插件。用 gz system 插件（`gz::sim::systems::DiffDrive`）+ `ros_gz_bridge` 桥接话题。URDF 不嵌 `<ros>` 标签。
2. **ROS2 xacro 路径**：不用 `$(find pkg)`，用 launch 里 `ament_index_python.get_package_share_directory()` 拼绝对路径。
3. **robot_state_publisher 参数**：`robot_description` 走 `parameters=[...]`，不是 `arguments`。
4. **MQTT 桥**：Jazzy 用 `ros-jazzy-mqtt-client`（非 mqtt_bridge）。配置 topic 映射用 YAML。
5. **通信分工**：rosbridge=高频数据下行（地图/雷达/TF/位姿）+ 拍照单帧；MQTT=命令上行(QoS1)+回执/状态上行。目标点**只走 MQTT 单通道**，禁止 rosbridge 双发（会重复执行物理动作）。
6. **模式状态机**：仿真端单一入口，App 只展示不决策。非法流转拒绝。
7. **WSL 网络**：App 连仿真端用 WSL IP（`hostname -I`），非 localhost。
8. **Riverpod**：不依赖 BuildContext。流数据用 `StreamProvider`，命令用 `Notifier`。

## 5. 通信契约速查

**rosbridge topics**：`/map` `/scan` `/tf` `/odom` `/plan` `/amcl_pose`（下行）；`/camera/image_raw/compressed`（仅拍照按需）

**MQTT topics**：
- 命令(QoS1)：`amr/cmd/goal`（信封含 cmd_id/trace_id/timestamp_ms/ttl_ms）`amr/cmd/cancel` `amr/cmd/inspection/start` `amr/cmd/inspection/stop` `amr/cmd/mode` `amr/cmd/estop` `amr/cmd/return_charge`
- 回执(QoS1/0)：`amr/cmd/ack` `amr/cmd/feedback` `amr/cmd/result` `amr/trace`
- 状态(QoS0)：`amr/status/battery` `amr/status/inspection` `amr/status/mode` `amr/status/video` `amr/status/video_metrics` `amr/alert`

指令状态机：PENDING→SENT→ACKED→EXECUTING→终态；ACK 1.2s 超时→UNKNOWN，Feedback 3s 超时→STALE，Result 120s 超时→UNKNOWN；`cmd_id` 幂等，重发只回放不重复执行。
视频：`camera`（主）/`camera_low`（低）双路，App 健康状态 HEALTHY→DEGRADED→LOST 自动降级。
验收步骤见 [CHECK.md](CHECK.md)。消息格式见 `docs/architecture.md` 第 5 节。

## 6. 开发顺序（阶段）

P0 环境确认(✅已完成) → P1 底盘+传感器 → P2 遥控验证 → P3 建图 → P4 Nav2 导航 → P5 通信桥 → P6 Flutter 地图+点击导航 → P7 巡检业务 → P8 回充+告警 → P9 视频 → P10 联调

## 7. 开发规范

- 先看 `docs/architecture.md` 对应章节再动手
- 新建文件遵循架构文档的目录结构
- 话题/消息格式必须符合第 5 节契约，改契约需同时更新文档
- 地图新叠加层实现 `MapLayer` 接口，不改 MapView 核心
- 提交前确保 `colcon build` / `flutter analyze` 通过

## 8. Session 工作流（多对话协作必读）

本项目按阶段拆分到多个对话 session。每个 session 必须遵守以下流程：

**启动时**：
1. 读本文件（AI_CONTEXT.md）
2. 读 `docs/DEVELOPMENT_PLAN.md`，找到当前阶段任务
3. 读 `docs/architecture.md` 对应章节
4. 确认上一阶段已完成（看 DEVELOPMENT_PLAN 的勾选状态）

**开发中**：
- 严格按阶段边界工作，不跨阶段做未规划的事
- 遇到契约变更（topic 名、消息格式、接口签名），必须同步更新：
  - `docs/architecture.md` 对应章节
  - 本文件第 5 节（通信契约速查）

**结束时**（session 收尾必做）：
1. 更新 `docs/DEVELOPMENT_PLAN.md` 中本阶段的勾选状态和备注
2. 如有契约/架构变更，确认文档已同步
3. 在 DEVELOPMENT_PLAN 末尾追加「阶段交接备注」，说明：做了什么、遇到什么坑、下一阶段注意什么

## 9. ⚠️ 文档-代码同步协议（强制）

任何 session 修改代码后，必须检查以下项是否需要同步更新文档：

| 代码变更 | 需同步的文档 |
|---|---|
| 新增/修改 ROS topic 名或消息格式 | AI_CONTEXT.md 第5节 + architecture.md 第5节 |
| 新增/修改 MQTT topic 或 payload | AI_CONTEXT.md 第5节 + architecture.md 第5.2节 |
| 新增 ROS2 包或目录 | AI_CONTEXT.md 第3节 + architecture.md 第3.1节 |
| 修改模式状态机 | architecture.md 第3.4节 |
| 修改 Flutter 目录结构 | architecture.md 第4.2节 |
| 新增地图图层 | architecture.md 第4.6节 |
| 阶段完成 | docs/DEVELOPMENT_PLAN.md |

**原则**：文档是单一事实来源。代码可以超前于文档，但不允许文档描述的契约与实际代码矛盾。发现矛盾时，以代码为准修正文档。

## 10. 环境命令备忘

```bash
source /opt/ros/jazzy/setup.bash
colcon build --symlink-install && source install/setup.bash
hostname -I   # 获取 WSL IP 供 App 连接
```
