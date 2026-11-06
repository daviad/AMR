# 仿真巡检 AMR + Flutter 上位机

一套跑通的端到端巡检系统：**Gazebo 仿真机器人 → ROS 2 导航栈 → Flutter App / Web 监控大屏**。地图、定位、导航、巡检、视频、告警五条链路都在同一个工程里闭环，不是零散 demo。

**环境**：WSL2 + Ubuntu 24.04 + ROS 2 Jazzy + Gazebo Sim 8.15（gz-sim8）+ MediaMTX；上位机为 Flutter（Android 模拟器与 Web 已实测，iOS 未验证）。**纯仿真，不涉及真实硬件**。

---

## 它能做什么

### 地图与定位

- Cartographer 2D 建图：激光 + IMU + 轮式里程计先验，产出 `pgm/yaml` 栅格地图。
- AMCL 在已有地图上定位，发布 `/amcl_pose` 与 `map → odom` 变换。
- App 自绘栅格地图：`CustomPainter` + 可插拔图层（底图 / 路径 / 机器人 / 巡检点 / 目标点），支持双指缩放与拖动。

### 导航与任务

- 地图上点一下即下发目标：App → MQTT `amr/cmd/goal` → `mission_bridge` → Nav2 `NavigateToPose`。
- Nav2 全栈：全局/局部规划、速度平滑、碰撞监控、生命周期管理。
- 巡检点与路线管理：增删改点、编排路线、循环执行；巡检 / 待机 / 充电三态状态机，支持一键回充。

### 视频

- Gazebo 相机原始帧 → GStreamer 编码 → MediaMTX，同时产出 `camera`（主）与 `camera_low`（低码率）两路。
- App 主链路走 **WHEP（WebRTC）**；不通时可在相机页**手动**切到 **RTSP（TCP）** 或 rosbridge JPEG，不是自动降级。
- Web 大屏固定走 **HLS**，避开浏览器 WebRTC 的端口与编解码差异。

### 监控大屏 / App

- 同一个 Flutter 工程，`/dashboard` 是 App 与 Web **共用路由**，不是 Web 专属。
- 大屏布局：地图占 60%，视频 + 状态 + 巡检控制占 40%；顶栏显示 MQTT / ROS 连接状态。

### 告警

- 统一告警通道 `amr/alert`：`ESTOP`、`ILLEGAL_MODE`、`ROUTE_EMPTY`、`LOW_BATTERY`、`DOCK_FAILED`。
- App 与机器人之间用 MQTT 遗嘱消息 `amr/status/app_offline` 感知对端掉线。

---

## 通信与端口

| 用途 | 协议 / 通道 | 端口 | 说明 |
|---|---|---|---|
| 遥测（机器人 → App） | rosbridge WebSocket | 9090 | `/map` `/scan` `/tf` `/odom` `/plan` `/amcl_pose` 等 |
| 指令（App → 机器人） | MQTT TCP | 1884 | `amr/cmd/*`，QoS 1 + `cmd_id` 幂等 |
| 指令（浏览器大屏） | MQTT WebSocket | 9002 | Web 端专用入口 |
| 视频主链路 | WHEP（HTTP 信令）+ ICE | 8889 / 8189(UDP) | App 默认；8189 不能 `adb reverse` |
| 视频兜底 | RTSP（强制 TCP） | 18554 | 相机页手动切换 |
| Web 视频 | HLS | 18888 | 大屏固定 |

话题与消息模型的**唯一真实定义**在 [`amr_app/packages/amr_contracts`](amr_app/packages/amr_contracts)，App 与仿真端共用。

---

## 快速开始

仿真端在 WSL 内：

```bash
cd /home/dxw/amr
./amr_start.sh           # 启动全链路（默认仅 install/ 缺失时才编译）
./amr_start.sh --build   # 源码改动后强制 colcon build
./amr_start.sh --video test   # 视频源换 videotestsrc，仍跑全链路
```

Windows 侧（与 WSL 脚本同目录）：

```powershell
.\amr_start_windows.ps1   # 同步 Windows 副本 + 构建/安装 Android App
.\amr_web_start.ps1       # flutter build web + 静态服务，打开 /#/dashboard
```

> **连接地址**：App / 模拟器连仿真端要用 WSL 的**局域网 IP**，不是 `localhost`。Windows 一键脚本 `-AmrHost auto` 默认取 WSL `eth0` IPv4。`adb reverse` 只能转发 TCP，UDP 8189 过不去，所以模拟器视频必须走 LAN IP。

完整步骤、排错与端口占用处理见 [docs/RUNBOOK.md](docs/RUNBOOK.md)（唯一权威运行手册），Windows 细则见 [docs/WINDOWS侧操作手册.md](docs/WINDOWS侧操作手册.md)，大屏见 [docs/WEB大屏操作手册.md](docs/WEB大屏操作手册.md)。

---

## 技术亮点（精简版）

完整版见 **[docs/技术亮点.md](docs/技术亮点.md)**（每条：短句 + 为什么这么做 + 代码/文档链接）。

- **端到端闭环**：鼠标点地图到机器人跑到位，中间是 MQTT 指令 + Nav2 Action + 反馈/结果回传，不是脚本串起来的假流程。
- **通信分工明确**：WebSocket 传遥测、MQTT 传指令、WebRTC 传视频，各用各的强项，而不是一条通道全塞。
- **弱网与兜底**：视频自动重连（1/2/4/8/10 s 退避）、健康度分级、主/低码流自动切换；源切换是手动兜底。
- **视频链路**：GStreamer 双路编码 → MediaMTX → App 用 `fvp` 替换 `video_player` 底层做硬解，失败回退软解。
- **ROS 2 工程化**：7 个功能包（description / gazebo / slam / nav / inspection / comm / bringup），SDF 场景 + URDF/Xacro 机器人，多个 bridge 处理 ROS ↔ Gazebo ↔ 上位机消息转换。
- **建图稳定性**：定位到里程计漂移与渲染队列时间戳滞后导致的穿墙/错位，逐项修掉，并留下 A/B 实验记录。

---

## 目录结构

```
amr/
├── amr_start.sh              # 仿真端一键启动（WSL）
├── amr_start_windows.ps1     # Windows 侧 App 构建/安装
├── amr_web_start.ps1         # Windows 侧 Web 大屏
├── amr_sim_ws/src/           # 7 个 ROS 2 包
├── amr_app/                  # Flutter App + Web（含 packages/amr_contracts 契约包）
├── docs/                     # 运行手册、架构、视频链路、技术亮点
└── learn/                    # 学习笔记
```

---

## 文档

| 文档 | 内容 |
|---|---|
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | 唯一权威运行手册：启动、验证、排错 |
| [docs/architecture.md](docs/architecture.md) | 分层架构、技术选型、模块边界 |
| [docs/视频流全链路.md](docs/视频流全链路.md) | 采集 → 编码 → MediaMTX → WHEP/RTSP/HLS → App |
| [docs/WebRTC排查与原理.md](docs/WebRTC排查与原理.md) | WHEP 握手、ICE、端口映射与常见故障 |
| [docs/技术亮点.md](docs/技术亮点.md) | 技术亮点完整版与实现依据 |
| [docs/WINDOWS侧操作手册.md](docs/WINDOWS侧操作手册.md) | Windows 侧构建、同步、模拟器联调 |
| [docs/WEB大屏操作手册.md](docs/WEB大屏操作手册.md) | Web 大屏构建与访问 |
