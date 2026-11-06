# 开发任务计划 — 仿真巡检 AMR + Flutter 上位机

> 本文件是跨 session 协作的进度看板。每个 session 结束时必须更新本文件的勾选状态和交接备注。
> 详细设计见 `architecture.md`，需求见 `requirements.md`。

---

## 进度总览

| 阶段 | 状态 | 负责 session |
|---|---|---|
| P0 环境准备 | ✅ 完成 | 2026-10-27 |
| P1 底盘+传感器仿真 | ✅ 运行验证通过 | 2026-10-27 |
| P2 遥控验证 | ✅ 通过 | 2026-10-27 |
| P3 Cartographer 建图 | ✅ 完成（indoor.pgm 已产出） | 2026-10-27 |
| P4 Nav2 导航 | ✅ 运行验证通过 | 2026-10-27 |
| P5 通信桥 | ✅ MQTT 链路验证通过 | 2026-10-27 |
| P6 Flutter 地图+点击导航 | ✅ 控制命令改 MQTT 单通道 + 指令状态机，analyze/test 通过 | 2026-11-03 |
| P7 巡检业务 | ✅ 仿真端链路验证通过（App 侧待联调） | 2026-10-27 |
| P8 回充+告警 | ✅ 仿真端全链路验证通过 | 2026-10-27 |
| P9 视频流 | ✅ GStreamer 双码流 → MediaMTX → WebRTC，RTSP/WHEP 实测通过 | 2026-11-03 |
| P10 全链路联调 | 🔶 仿真端与静态检查通过，待 Windows 模拟器按 CHECK.md 联调 | 2026-11-03 |

---

## P0 环境准备 ⚠️

**目标**：确认并安装所有依赖

- [x] 确认 Ubuntu 24.04 + ROS2 Jazzy + Gazebo Sim 8.15.0 已装
- [x] 确认 ros_gz_bridge、ros_gz_sim、teleop_twist_keyboard 已装
- [x] 确认 WSLg 可用
- [x] 安装 nav2：`sudo apt install ros-jazzy-nav2-bringup`
- [x] 安装 cartographer：`sudo apt install ros-jazzy-cartographer-ros`
- [x] 安装 rosbridge：`sudo apt install ros-jazzy-rosbridge-suite`
- [x] 安装 mosquitto：`sudo apt install mosquitto mosquitto-clients`
- [x] 安装 mqtt-client：`sudo apt install ros-jazzy-mqtt-client`
- [x] 验证：`source /opt/ros/jazzy/setup.bash && ros2 pkg list | grep -E "nav2|cartographer|rosbridge|mqtt"`

**交接备注**：✅ 2026-10-27 全部依赖已由用户安装完成并实际运行验证（nav2 / cartographer / rosbridge / mqtt-client / mosquitto 均在全链路中工作）。gz GUI 经 WSLg 可正常显示。

---

## P1 底盘+传感器仿真 🔶

**目标**：Gazebo 中加载 AMR 模型，传感器话题有数据输出

**关联文档**：`architecture.md` 第 3.1、3.2 节

### 任务清单

**1. 创建 amr_description 包（URDF/xacro）**
- [x] `ros2 pkg create --build-type ament_cmake amr_description`
- [x] urdf/amr_base.xacro：差速底盘（底盘 link + 左右轮 + 脚轮），含碰撞和惯性
- [x] urdf/amr_lidar.xacro：2D 激光雷达（gpu_lidar sensor）
- [x] urdf/amr_imu.xacro：IMU sensor
- [x] urdf/amr_camera.xacro：camera sensor
- [x] urdf/amr_robot.xacro：include 以上，组装完整机器人
- [x] CMakeLists.txt：仅 install(DIRECTORY urdf) + ament_package()
- [x] 验证：`xacro amr_robot.xacro` 能正常输出 URDF

**2. 创建 amr_gazebo 包**
- [x] worlds/indoor.world：室内场景（墙、房间、障碍物、充电桩标记）
- [x] config/bridge_topics.yaml：ros_gz_bridge 话题映射
- [x] launch/sim_bringup.launch.py：gz sim + robot_state_publisher + spawn + ros_gz_bridge
- [x] package.xml + CMakeLists.txt

**3. 关键配置点**
- [x] 差速驱动用 `gz::sim::systems::DiffDrive` system 插件
- [x] 传感器用 `gz::sim::systems::Sensors` + 对应 sensor 标签
- [x] URDF 中不嵌 `<ros>` 标签，通信全靠 ros_gz_bridge
- [x] xacro 不用 `$(find pkg)`，launch 里用 ament_index 拼路径

**验收标准**（待运行环境验证）：
- [ ] Gazebo GUI 正常显示 AMR 模型和室内场景
- [ ] `ros2 topic list` 能看到 /scan /odom /imu/data /tf /camera/image_raw
- [ ] `ros2 topic echo /scan` 有激光数据输出
- [ ] `ros2 topic echo /odom` 有里程计数据

**交接备注**：代码与 colcon build（7 包全过）已完成。验收项需 GUI 运行环境：先修复 gz GUI 库缺失（见 P0 备注），再 `ros2 launch amr_gazebo sim_bringup.launch.py` 验证。camera compressed 桥接依赖 gz 端 image transport 插件，运行时需确认。

---

## P2 遥控验证 ⬜

**目标**：通过键盘控制 AMR 在 Gazebo 中移动

**关联文档**：`architecture.md` 第 3.3 节

### 任务清单
- [ ] 终端1：`ros2 launch amr_gazebo sim_bringup.launch.py`
- [ ] 终端2：`ros2 run teleop_twist_keyboard teleop_twist_keyboard --ros-args -r cmd_vel:=/cmd_vel`
- [ ] 验证键盘控制 AMR 移动
- [ ] 验证移动时 /odom 和 /tf 数据变化
- [ ] 验证 /scan 数据随位置变化

**验收标准**：
- [ ] 键盘 I/J/K/L 能控制 AMR 前后左右移动
- [ ] 移动过程中 /odom 的位置坐标实时变化

**交接备注**：（P2 完成后填写）

---

## P3 Cartographer 建图 🔶

**目标**：遥控 AMR 走一圈，生成可保存的地图

**关联文档**：`architecture.md` 第 3.1 节 amr_slam 包

### 任务清单
- [x] 创建 amr_slam 包
- [x] config/cartographer_2d.lua：2D SLAM 配置（tracking_frame=imu_link, published_frame=odom, num_laser_scans=1, use_imu_data=true）
- [x] launch/cartographer.launch.py：启动 cartographer_node + occupancy_grid_node
- [ ] 建图：遥控 AMR 遍历场景
- [ ] 保存地图：`ros2 run nav2_map_server map_saver_cli -f maps/indoor`
- [ ] maps/indoor.pgm + indoor.yaml 提交到 amr_nav/maps/

**验收标准**：
- [ ] `/map` 话题有 OccupancyGrid 数据
- [ ] 保存的 pgm 文件能在图像查看器中看到清晰的室内轮廓
- [ ] map.yaml 中 resolution/origin 正确

**交接备注**：代码完成。运行前置：安装 cartographer（见 P0）+ P1 运行验证通过。

---

## P4 Nav2 导航 🔶

**目标**：AMR 能自主导航到指定目标点并避障

**关联文档**：`architecture.md` 第 3.1 节 amr_nav 包

### 任务清单
- [x] 创建 amr_nav 包
- [x] config/nav2_params.yaml：Nav2 全栈参数（amcl, controller_server, planner_server, bt_navigator, costmap）
- [x] maps/indoor.pgm + indoor.yaml（来自 P3）
- [x] launch/nav_bringup.launch.py：复用 nav2_bringup，传入 map + params_file + use_sim_time:=true
- [x] 启动顺序：gz sim → amcl → nav2（full_bringup 一键启动）
- [x] 发布 /goal_pose 或 action 目标，验证 AMR 规划路径并到达（目标点 (2,1) 成功）

**关键配置**：
- [x] global_planner: NavfnPlanner
- [x] local_planner: DWB
- [x] costmap：static_layer(indoor map) + obstacle_layer(/scan) + inflation_layer
- [x] amcl：use_sim_time=true，laser_topic=/scan

**验收标准**：
- [x] 下发目标点后，AMR 能规划出路径（/plan 有 Path 数据）
- [x] AMR 沿路径行驶，避开障碍物，到达目标点（(2,1) 导航成功）

**交接备注**：✅ 2026-10-27 运行验证通过。注意：生命周期节点须在 /initialpose 发布后才能全部 activate（顺序颠倒会激活超时 abort，需 `ros2 lifecycle set /<node> activate` 手动补齐 8 节点）。AMCL 收敛后定位误差 ~12cm 内可正常导航。

---

## P5 通信桥 🔶

**目标**：rosbridge + MQTT 双路通信打通

**关联文档**：`architecture.md` 第 3.5、4.4 节

### 任务清单
- [x] 创建 amr_comm 包
- [x] launch/rosbridge.launch.py：启动 rosbridge_websocket（端口 9090）
- [ ] 安装并启动 mosquitto（端口 1883）
- [x] config/mosquitto.conf
- [x] config/mqtt_client.yaml：mqtt_client 话题映射（按契约 5.2，命令 QoS1 / 状态 QoS0，battery/mode retain）
- [x] launch/mqtt_bridge.launch.py：启动 mqtt_client 节点
- [x] 验证：用 mosquitto_pub 发命令，ROS 端能收到
- [x] 验证：ROS 端发状态，mosquitto_sub 能收到

**验收标准**：
- [ ] rosbridge ws://<WSL_IP>:9090 可连接（待 App 真机联调验证）
- [ ] 通过 rosbridge 能订阅到 /odom 数据（待 App 真机联调验证）
- [x] `mosquitto_pub -t amr/cmd/mode -m '{"mode":"auto"}'` 后 ROS 端收到对应 topic
- [x] ROS 端发布电池状态后，`mosquitto_sub -t amr/status/battery` 能收到（retained，1Hz）

**交接备注**：✅ 2026-10-27 MQTT 双向链路验证通过（命令 App → 机器人 + battery/mode 状态 机器人 → App retained）。⚠️ **关键修复**：MQTT 状态上报一度无消息，根因是 /clock 未桥接——所有节点 use_sim_time=true 但 /clock 无发布者，inspection_node 的 1Hz 定时器（sim time）从不触发，/battery/state 从不发布。已在 bridge_topics.yaml 增加 /clock 桥（rosgraph_msgs/Clock ← gz.msgs.Clock, GZ_TO_ROS）。mosquitto 当前绑 localhost，App 真机联调前需 `sudo` 改绑 0.0.0.0。

---

## P6 Flutter 地图+点击导航 🔶

**目标**：App 显示地图，点击地图下发目标点，AMR 自动导航

**关联文档**：`architecture.md` 第 4 节全章

### 任务清单
- [x] 创建 Flutter 工程 amr_app（手写 pubspec + lib/，平台目录待 `flutter create .` 生成）
- [x] 配置依赖：flutter_riverpod, riverpod_generator, hive, web_socket_channel, mqtt_client
- [x] core/topic_mapping.dart：所有 topic 常量
- [x] comm/rosbridge_client.dart：WebSocket 封装（订阅引用计数、2s 重连、心跳检测）
- [x] comm/mqtt_client.dart：MQTT 封装（QoS1 命令 / QoS0 状态 / LWT）
- [x] providers/data/map_provider.dart：订阅 /map → OccupancyGrid
- [x] providers/data/tf_provider.dart：订阅 /tf + /amcl_pose → 机器人位姿
- [x] providers/data/plan_provider.dart：订阅 /plan → 路径
- [x] map/ 目录：MapLayer 接口、MapViewport、BaseMapLayer、PathLayer、RobotLayer、MapView、MapPainter
- [x] pages/map_page.dart：主页面，集成 MapView + 控制按钮
- [x] providers/navigation/navigation_controller.dart：点击导航逻辑（双发 rosbridge + MQTT）
- [x] 点击 → 世界坐标转换 → 确认浮层 → 下发目标

**验收标准**：
- [ ] App 连接 rosbridge 后能显示地图
- [ ] 点击地图后 AMR 在 Gazebo 中开始导航
- [ ] App 实时显示规划路径和机器人位姿
- [ ] AMR 到达目标后 App 有提示

**交接备注**：40 个 dart 文件手写完成（Riverpod 手写风格，未用 .g.dart 代码生成）。✅ 2026-10-27 WSL 内已装 Linux Flutter SDK 3.47.8（~/.local/flutter），`flutter create --platforms=android .` 已生成平台目录，`flutter pub get` 通过，`flutter analyze` **0 issues**，`flutter test` 通过。修复点：5 个图层类 `implements MapLayer` → `extends MapLayer`（接口默认实现不继承）、mqtt_client 10.x 需 `mqtt_server_client.dart` 导入、`constraints.biggest()` → `biggest` getter、widget_test 模板重写。WSL 无 Android SDK，真机/模拟器运行需在 Windows 侧：`flutter run --dart-define=AMR_HOST=<WSL_IP>`。

---

## P7 巡检业务 🔶

**目标**：App 管理巡检点/路线，一键执行巡检

**关联文档**：`architecture.md` 第 3.4 节（状态机）、第 4.8 节（Hive）

### 任务清单

**仿真端（amr_inspection 包）**：
- [x] inspection_manager.py：巡检点/路线数据管理
- [x] mode_state_machine.py：四态状态机（MANUAL/AUTO/INSPECTING/CHARGING）
- [x] route_executor.py：依次调用 Nav2 NavigateToPose Action
- [x] charge_manager.py：低电量检测 + 回充
- [x] inspection_node.py：ROS2 节点入口，整合以上模块
- [x] 发布 /inspection/status，订阅 amr/cmd/inspection/*

**Flutter 端**：
- [x] models/inspection_point.dart, inspection_route.dart（HiveType 0/1，手写 adapter）
- [x] providers/inspection/points_controller.dart：Hive 持久化 + CRUD
- [x] providers/inspection/route_controller.dart：路线编排
- [x] map/layers/inspection_points_layer.dart：巡检点图层（可拖拽）
- [x] pages/inspection_page.dart：巡检点/路线管理界面
- [x] 点击地图创建巡检点 → 配置名称/停留时间/拍照
- [x] 编排路线 → 一键启动 → 显示进度

**验收标准**：
- [ ] App 可创建/编辑/删除巡检点（待真机联调）
- [ ] 可将巡检点编排为路线（待真机联调）
- [x] 启动路线后 AMR 依次到达各巡检点并停留（仿真端 2 点巡检验证通过）
- [x] MQTT 下发巡检命令 + /inspection/status 进度上报链路通（App 侧 UI 待联调）

**交接备注**：契约已扩展（architecture.md 5.2）：`amr/cmd/inspection/start` 携带完整路线数据（route_id + loop + points[]），App Hive 为单一事实来源，仿真端收到后登记覆盖再执行；不带 points 时回退仿真端内置演示路线。双端代码 + 文档三处已同步。✅ 2026-10-27 仿真端链路验证：MQTT 下发 2 点巡检路线，AMCL 导航依次到达并上报进度，状态机 INSPECTING→AUTO 正确流转。

---

## P8 回充+告警 🔶

**目标**：低电量自动回充，App 显示告警

**关联文档**：`architecture.md` 第 3.4 节

### 任务清单
- [x] Gazebo 场景含充电桩标记区（indoor.world 充电桩区域 + 节点内 dock 坐标参数）
- [x] charge_manager.py：电量低于阈值 → 状态切到 CHARGING → 导航到充电桩
- [x] 到达充电桩后开始充电，充满后回 AUTO
- [x] 发布 /battery/state（节点内电池仿真，未用 gz Battery 插件）
- [x] Flutter 端：battery_provider + 低电量告警弹窗
- [x] alert_provider：告警展示

**验收标准**：
- [x] 电量低于 20% 时 AMR 自动驶向充电桩（initial_level=21 验证，静止放电触发）
- [x] 到达充电桩后电量开始上升（charging:true，约 2 分钟充满模型）
- [ ] App 弹出低电量告警（待真机联调，/amr/alert 上报链路已验证）
- [x] 充电完成后 AMR 恢复自动模式（95% 阈值，日志"充电完成，恢复 AUTO"）

**交接备注**：电池为 inspection_node 内软件仿真（非 gz 插件），dock 坐标用 ROS 参数 dock_x/dock_y 配置。✅ 2026-10-27 全链路验证通过：21% 初始电量 → 20% 触发 LOW_BATTERY 告警（MQTT）→ 自动切 CHARGING → NavigateToPose 至 dock → 到达充电 → 95% 自动回 AUTO，MQTT 状态全程 1Hz 上报。修复记录：① dock 默认点 (-4.4,-3.4) 距充电桩立柱 (-4.7,-3.4) 仅 0.3m < inflation_radius 0.4 导致 NavFn 恒失败，已改 (-4.1,-3.4)（仍在标记区内）；② 新增 initial_level 参数（默认 100）便于低电量场景测试；③ _on_tick dt 钳位 ≤5s，防 use_sim_time 启动跳变瞬间放电误触发。如后续要更真实的电量物理，可换 gz Battery 插件。

---

## P9 视频流 ✅（2026-11-03 重构）

**目标**：视频预览走真正的视频流，拍照仍走单帧

**关联文档**：`architecture.md` 第 4.7 节、[CHECK.md](../CHECK.md)

### 任务清单
- [x] `amr_gazebo/scripts/gst_video_source.py`：GStreamer `appsrc → tee → x264enc ×2 → rtspclientsink`，主/低双码流 + 编码延迟 P50/P95/P99
- [x] `amr_gazebo/config/mediamtx.yml`：RTSP 18554（TCP）+ WHEP 8889 + ICE 8189 + HLS 18888
- [x] `services/video_stream_service.dart`：`WebRtcWhepPlayer`（WHEP + `getStats` 健康判定）、`RtspVideoPlayer`、`RosbridgeCompressedPlayer` fallback、自动主/低码流切换
- [x] `pages/camera_page.dart`：WebRTC 渲染 + 健康条 + LOST 横幅 + 画质/源菜单
- [x] `services/photo_capture_service.dart`：拍照按需取 `/camera/image_raw/compressed` 单帧，与预览解耦
- [x] `image_transport republish` 仅保留给拍照

**验收标准**：
- [x] RTSP 双路可解码（主 640×480@15 / 低 320×240@15，test source 实测）
- [x] WHEP `POST application/sdp` 返回 201 且 SDP 含 H.264
- [ ] App 端 HEALTHY/DEGRADED/LOST 与自动降级（Windows 模拟器按 CHECK.md 验证）
- [ ] 端到端 P50/P95/P99 延迟数字（CHECK.md 第 7 节）

**交接备注**：✅ 2026-11-03 重构完成。放弃“逐帧 JPEG 预览”，改为 GStreamer 虚拟摄像头双码流推 MediaMTX，App 用 `flutter_webrtc` WHEP。ROS 端实测：`ffprobe` 双路 H.264 正常；WHEP 协商 `201 Created`。App 侧 `flutter analyze` 0 issue，状态机单测 16 条全绿。Android 模拟器注意：用 WSL mirrored IP（如 192.168.0.103）访问 8889/8189，`adb reverse` 只能通 TCP，WebRTC UDP 需直连；主 Manifest 已加 `usesCleartextTraffic` 与 INTERNET 权限。

---

## P10 全链路联调 ⬜

**目标**：完整巡检流程跑通，优化性能

### 任务清单
- [x] 一键启动：amr_bringup/full_bringup.launch.py（TimerAction 延时：sim → rosbridge/mqtt(5s) → mission_bridge(6s) → gst_video(8s) → nav2(10s) → inspection(12s)）
- [x] 仿真端完整流程：建图 → 导航 → MQTT 巡检 → 低电量回充（P3/P4/P7/P8 均通过）
- [x] 验收检查单：[CHECK.md](../CHECK.md)（构建、视频、控制、故障注入、延迟、Windows 模拟器）
- [ ] App 真机全流程：连接 → 地图 → 点击导航 → 巡检 → 回充告警
- [ ] 性能优化：地图渲染帧率、位姿延迟、视频流畅度
- [ ] 断线重连测试
- [ ] Bug 修复

**验收标准**：
- [x] 一键启动所有节点无报错（full_bringup 起全栈 + AMCL 定位 + 8 生命周期节点 active）
- [ ] 完整巡检流程无中断跑通（仿真端分段已通，App 端待联调）
- [ ] 地图渲染 ≥30fps，位姿延迟 <200ms（App 侧指标，待真机测）

**交接备注**：✅ 2026-10-27 仿真端全链路已通。剩余：① P9 视频桥接方案落地；② mosquitto 绑 0.0.0.0（需 sudo）；③ Windows 侧 `flutter run --dart-define=AMR_HOST=<WSL_IP>` 真机联调。启动注意：launch 前 `export ROS_LOG_DIR=/tmp/ros_log`；启动后需发 /initialpose，若 lifecycle 激活超时按 planner_server→behavior_server→bt_navigator→waypoint_follower→velocity_smoother→collision_monitor→route_server→docking_server 顺序手动 activate。

---

## 阶段交接备注汇总

> 每个 session 结束时在此追加备注。格式：**阶段名 - 日期 - 备注内容**

**P0~P10 运行验证与全链路排障 - 2026-10-27**：
- 做了什么：P0 依赖全部安装；P1~P8 逐一运行验证通过（P3 产出 indoor.pgm 地图，P4 导航 (2,1) 成功，P5 MQTT 双向链路通，P7 两点巡检，P8 低电量回充全链路）。仿真端全链路（建图→导航→巡检→回充）已通。
- 关键修复：① **/clock 未桥接导致 MQTT 状态上报无消息**——use_sim_time 节点定时器不触发，bridge_topics.yaml 增加 /clock 桥解决；② dock 点 (-4.4,-3.4) 陷入充电桩立柱膨胀区导致 NavFn 恒失败，改 (-4.1,-3.4)；③ inspection_node 新增 initial_level 参数 + dt 钳位 ≤5s 防启动跳变误放电。
- 遇到的坑：① Nav2 lifecycle 须在 /initialpose 后激活，顺序错了需手动 activate 8 节点；② costmap clear 服务名是 `/global_costmap/clear_entirely_global_costmap`（单层），写错两层路径会报 "rcl node's context is invalid"（不是服务挂死）；③ ROS launch 需 `export ROS_LOG_DIR=/tmp/ros_log`；④ gz 真值经 /gz_truth（TFMessage，frame 名丢失，取 transforms[0]）。
- 遗留：~~P9 compressed 图桥~~ 已解决（image_transport republish 方案，见 P9 备注）；mosquitto 需 sudo 绑 0.0.0.0；Flutter 真机联调在 Windows 侧进行。

**P1~P9 代码全量开发 - 2026-10-26**：
- 做了什么：一次性完成全部 7 个 ROS2 包（amr_description / amr_gazebo / amr_slam / amr_nav / amr_inspection / amr_comm / amr_bringup）与 Flutter App（40 个 dart 文件）的代码编写；`colcon build --symlink-install` 7 包全过，xacro / py_compile / launch 加载验证通过。
- 契约变更：`amr/cmd/inspection/start` payload 由 `{"route_id"}` 扩展为携带完整路线数据（`route_id + loop + points[]`），App 端 Hive 为单一事实来源，仿真端收到后登记覆盖再执行。已同步 architecture.md 5.2 节 + 双端代码。
- 遇到的坑：① 环境无 sudo，P0 剩余 5 个 apt 依赖（nav2/cartographer/rosbridge/mqtt-client/mosquitto-clients）确认未安装，用户需手动装；② gz GUI 库 libgz-sim8-gui.so.8 缺失，需修复后才能做 P1 运行验证；③ WSL 内无可用 Flutter SDK，App 未跑 pub get/analyze，平台目录待生成；④ rclpy Node 属性名不能与自定义成员 executor 冲突（已改为 route_executor）。
- 下一阶段注意：先完成 P0 依赖安装 + gz GUI 修复 → P1 运行验证 → P2 遥控 → P3 建图（产出地图后 P4 才能跑）；App 侧先在 Windows 侧 `flutter create .` + `flutter pub get` + `flutter analyze`，真机运行加 `--dart-define=AMR_HOST=<WSL_IP>`。
