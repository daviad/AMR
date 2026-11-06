# amr_sim_ws/AGENTS.md — ROS 2 仿真端边界

只改 `src/`。`build/`、`install/`、`log/` 是 colcon 产物，不手改、不提交。
colcon 必须在工作空间根执行：`cd /home/dxw/amr/amr_sim_ws`。

## 包与入口
| 包 | 干什么 | 入口 |
|---|---|---|
| `amr_bringup` | 全链路编排 | `launch/full_bringup.launch.py:26-193`；TimerAction 时序在 70/80/89/96/103/117/144/170 行 |
| `amr_gazebo` | 仿真、桥、视频源 | `launch/sim_bringup.launch.py:40-81`；`config/bridge_topics.yaml`；`scripts/gst_video_source.py`(429) |
| `amr_description` | URDF/xacro | `urdf/amr_robot.xacro` → `amr_base/lidar/camera/imu.xacro` |
| `amr_nav` | Nav2 + 地图 | `config/nav2_params.yaml`(312)；`launch/nav_bringup.launch.py`；`maps/indoor.yaml` |
| `amr_slam` | Cartographer | `config/cartographer_2d.lua`；`launch/mapping.launch.py`；`scripts/save_map` |
| `amr_comm` | 通信桥 | `scripts/mission_bridge.py`(434)；`config/{mqtt_client.yaml,mosquitto.conf}` |
| `amr_inspection` | 巡检业务 | `amr_inspection/inspection_node.py`(281)、`charge_manager.py`、`cmd_vel_watchdog.py`(79) |

## 易踩
1. 是 gz-sim8 不是 Classic：只用 `gz::sim::systems::*` + `ros_gz_bridge`，禁止 `libgazebo_ros_*`。
2. `/cmd_vel` 链：controller → cmd_vel_nav → velocity_smoother → collision_monitor → bridge → DiffDrive；另有 `cmd_vel_watchdog` 补零速。
3. 每条命令前加 `env -u LD_LIBRARY_PATH`，否则 Python 扩展报 `GLIBCXX_3.4.29 not found`。
4. 改 `maps/` 或 `config/` 后：`colcon build --symlink-install --packages-select amr_nav`（symlink 下即时生效）。
5. 视频四件套：`mediamtx.yml`（18554/8889/18888/8189）、`gst_video_source.py`、launch 里的 `LD_LIBRARY_PATH` 注入（142-150）、`camera`/`camera_low` 两个 path。
6. launch 一次起 7 组组件；排障先看 `~/arm_logs/<ts>/full_bringup.log`，不要逐个节点读源码。
7. 地图是唯一产物：覆盖前 `cp maps/indoor.{pgm,yaml} /tmp/`；建图阶段不要同时启 Nav2。

## 验证
```bash
cd /home/dxw/amr && ./amr_start.sh --build      # 编译 + 启动 + 自检
cd /home/dxw/amr && ./amr_start.sh --video test # 视频源换 videotestsrc（仍启动全链路）
ros2 pkg executables amr_inspection             # 新增节点后确认已安装
```
