# 仿真巡检 AMR + Flutter 上位机 — 需求文档

| 项 | 内容 |
|---|---|
| 项目名称 | 仿真巡检 AMR + Flutter 上位机 + Web大屏监控 |
| 版本 | v1.0 |
| 日期 | 2026-10-26 |
| 状态 | 已确认 |

---

## 0. 开发环境

- **宿主**：Windows 11
- **子系统**：WSL2 + Ubuntu 24.04.5 LTS
- **ROS**：ROS2 Jazzy
- **仿真器**：Gazebo Sim 8.15.0（gz-sim8，非 Classic）
- **GUI**：WSLg 支持 Gazebo/RViz 图形界面
- **手机端**：Flutter App（Android/iOS）

**关键约束**：
- 仿真端运行于 WSL 内，App 连接用 WSL IP（非 localhost）
- 终端需 `source /opt/ros/jazzy/setup.bash`
- 不涉及真实硬件，纯仿真

---

## 1. 项目概述

本项目构建一套**完整的仿真巡检 AMR（自主移动机器人）系统 + Flutter 手机上位机**。系统在仿真环境中模拟一台差速 AMR，具备建图、定位、导航、避障、巡检任务执行、自动回充等能力；上位机以手机 App 形式提供地图可视化、点击导航、巡检点/路线管理、实时状态监控、视频预览等功能。

本项目**不涉及真实硬件**，全部运行在 Gazebo Sim 仿真环境中，上位机通过 rosbridge（WebSocket）和 MQTT 与仿真端通信。

---

## 2. 项目目标

1. 验证 ROS2 Jazzy + Gazebo Sim + Cartographer + Nav2 全链路在仿真环境中的可行性
2. 提供一套可在手机上操作的 AMR 巡检上位机，核心交互为**地图点击导航**
3. 建立可扩展的软件架构，为后续接入真实机器人和功能扩展预留接口

---

## 3. 用户角色

| 角色 | 描述 | 主要操作 |
|---|---|---|
| 操作员 | 使用手机 App 操控机器人 | 查看地图、点击导航、配置巡检点/路线、启动巡检、监控状态 |
| 管理员 | 配置系统参数 | 配置通信参数、地图管理、巡检策略 |

---

## 4. 功能需求

### 4.1 仿真端（ROS2 Jazzy + Gazebo Sim）

#### FR-SIM-01 机器人底盘仿真
- 在 Gazebo Sim 中加载差速 AMR 的 URDF/SDF 模型
- 支持通过 `/cmd_vel`（geometry_msgs/Twist）控制移动
- 底盘参数（轮距、轮径、最大速度、最大加速度）可配置

#### FR-SIM-02 传感器仿真
- **2D 激光雷达**：发布 `/scan`（sensor_msgs/LaserScan），参数（范围、角度、线束、噪声）可配置
- **IMU**：发布 `/imu/data`（sensor_msgs/Imu），含加速度计、陀螺仪
- **轮式编码器**：发布 `/odom`（nav_msgs/Odometry），提供里程计
- **摄像头**：发布 `/camera/image_raw`（sensor_msgs/Image）和 `/camera/image_raw/compressed`（sensor_msgs/CompressedImage）

#### FR-SIM-03 SLAM 建图
- 使用 Cartographer 进行 2D SLAM 建图
- 输入：`/scan`、`/imu/data`、`/odom`
- 输出：`/map`（nav_msgs/OccupancyGrid）、TF（map → odom → base_link）
- 支持保存地图为 pgm/yaml 格式
- 导航阶段切换为定位模式（AMCL 或 Cartographer 纯定位）

#### FR-SIM-04 导航与避障
- 使用 Nav2 导航栈
- 全局规划：A*（NavFn 或 Smac Planner）
- 局部规划：DWB 或 TEB
- 代价地图：静态层（来自 /map）+ 障碍层（来自 /scan）+ 膨胀层
- 接收 `/goal_pose`（geometry_msgs/PoseStamped）作为导航目标
- 发布 `/plan`（nav_msgs/Path）规划路径
- 支持动态避障

#### FR-SIM-05 巡检任务执行
- 巡检点管理：存储点位坐标（x, y, theta）、名称、停留时间、是否拍照
- 巡检路线：有序巡检点序列，支持循环执行
- 路线执行器：按顺序依次导航到各巡检点，到达后停留指定时间，可拍照
- 执行状态发布：`/inspection/status`，含当前状态、进度、当前点位

#### FR-SIM-06 自动回充
- 电池仿真：电量随时间消耗，到达充电桩后充电
- 低电量阈值触发自动回充：导航到充电桩位置并对接
- 充电完成后恢复自动模式

#### FR-SIM-07 模式状态机
- 四种模式：手动（MANUAL）、自动（AUTO）、巡检（INSPECTING）、回充（CHARGING）
- 所有模式切换由仿真端状态机统一处理，拒绝非法流转
- 模式状态发布：`/amr/status/mode`

#### FR-SIM-08 通信桥接
- **rosbridge-suite**：通过 WebSocket（端口 9090）暴露 ROS2 topic/service/action 给上位机
- **MQTT**：mosquitto broker（端口 1883）+ ros2-mqtt-bridge，实现 ROS2 与 MQTT 双向转发
- 目标点双发：同时通过 rosbridge（低延迟）和 MQTT（可靠 QoS 1）下发

### 4.2 上位机端（Flutter 手机 App）

#### FR-APP-01 地图可视化
- 渲染 `/map`（OccupancyGrid）为 2D 灰度图
- 支持手势缩放、平移
- 叠加显示：机器人位姿、规划路径、历史轨迹、巡检点、充电桩
- 图层化架构，支持可插拔扩展

#### FR-APP-02 点击导航（核心交互）
- 点击地图任意位置 → 计算世界坐标 → 弹出确认浮层（可拖拽微调）
- 确认后下发导航目标（rosbridge + MQTT 双发）
- 实时显示规划路径和机器人移动轨迹
- 支持取消导航
- 到达目标后提示

#### FR-APP-03 巡检点管理
- 在地图上点击创建巡检点
- 配置巡检点属性：名称、停留时间、是否拍照
- 拖拽调整巡检点位置
- 编辑、删除巡检点
- 本地持久化存储（Hive）

#### FR-APP-04 巡检路线管理
- 将巡检点编排为有序路线
- 配置路线名称、是否循环
- 一键启动/停止路线巡检
- 实时显示巡检进度（当前点位、已完成数、总数）

#### FR-APP-05 实时状态监控
- 电池电量、电压、充电状态
- 线速度、角速度
- 当前模式
- 里程计位姿
- 告警信息弹窗（低电量、避障、通信中断、任务异常）

#### FR-APP-06 视频预览
- 显示仿真摄像头画面（CompressedImage over rosbridge）
- 支持截图
- 预留 RTSP 升级接口

#### FR-APP-07 控制按钮
- 紧急停止（常驻、醒目）
- 模式切换（手动/自动/巡检/回充）
- 一键回充
- 速度档位（慢/中/快）

#### FR-APP-08 通信
- rosbridge WebSocket 客户端：订阅数据流、发布目标点
- MQTT 客户端：发布命令（QoS 1）、订阅状态（QoS 0）
- 自动重连 + 心跳检测
- 断线状态提示

---

## 5. 非功能需求

| 类别 | 要求 |
|---|---|
| 性能 | 地图渲染 ≥ 30fps；位姿更新延迟 < 200ms；视频预览 640×480@10fps 流畅 |
| 可用性 | 横屏优先，竖屏适配；单手可操作核心功能；紧急停止一键可达 |
| 可靠性 | MQTT 命令 QoS 1 保证送达；rosbridge 自动重连；模式状态机拒绝非法操作 |
| 可扩展性 | 地图图层可插拔；通信桥可替换；视频流可升级 RTSP；持久化可替换 |
| 兼容性 | Flutter 支持 Android 8+、iOS 12+；仿真端 Ubuntu 22.04+ / ROS2 Jazzy |
| 可维护性 | 模块化分层架构；统一 TopicMapping；消息契约独立定义 |

---

## 6. 验收标准

### 6.1 仿真端
- [ ] Gazebo 中 AMR 可通过 `/cmd_vel` 控制移动
- [ ] `/scan`、`/odom`、`/imu/data` 话题有正确数据输出
- [ ] Cartographer 可建图并保存地图
- [ ] Nav2 可在 RViz 中点击目标点完成导航
- [ ] 配置巡检点后可一键执行巡检路线
- [ ] 低电量时自动回充
- [ ] rosbridge 和 MQTT 桥接正常工作

### 6.2 上位机
- [ ] App 可连接 rosbridge 和 MQTT，显示地图
- [ ] 点击地图可下发目标点，机器人自动导航到达
- [ ] 可创建、编辑、删除巡检点
- [ ] 可编排巡检路线并启动执行
- [ ] 实时显示电量、速度、模式、告警
- [ ] 显示摄像头画面
- [ ] 紧急停止、模式切换、回充按钮功能正常
- [ ] 断线后自动重连并提示

---

## 7. 不在范围内（v1 不做）

- 真实硬件对接
- 桌面端/Web 端上位机
- 3D 点云地图渲染
- AR 叠加
- 语音控制、陀螺仪体感控制
- 多机器人协同
- 传感器故障注入
- 天气/光照仿真
