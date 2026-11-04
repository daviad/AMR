# AMR 巡检小车 URDF 改造 + Gazebo 仿真暂停根因诊断

> 版本：v1.0 | 日期：2026-11-02
> 环境：Ubuntu 24.04 + ROS 2 Jazzy + Gazebo Sim 8.15.0 + ros_gz_bridge
> 涉及包：`amr_description`、`amr_gazebo`、`amr_slam`

***

## 0. 一句话摘要

两轮差速改三轮（前万向轮 + 后双驱动）过程中，URDF 几何参数、物理仿真插件配置、上层 SLAM/导航启动链路全部打通；中途遭遇"tf2 帧大面积缺失、仿真时间戳显示巨大延迟"假象，根因是 **Gazebo GUI 左下角暂停按钮被误触导致世界被 pause**——但 `JointStatePublisher` 和 `SceneBroadcaster` 在暂停时会重复发送上一帧数据，制造了"数据流正常"的陷阱。

***

## 1. 背景与改造目标

项目原始 AMR 小车是**四轮布局**：左右驱动轮 + 前后两个脚轮（`front_caster` + `back_caster`）。运行中发现三个问题：

| # | 问题 | 影响 |
|---|------|------|
| 1 | 顶层 `top_link`（设备仓）悬空，与 `base_link` 之间没有物理支撑杆 | Gazebo 物理引擎可能出现穿透/抖动 |
| 2 | 驱动轮半径 0.075m 偏大，底盘视觉比例不协调；IMU 放在右前角、摄像头贴在设备仓顶面，位置不理想 | 视觉与物理仿真都不够精准 |
| 3 | 用户希望改成**前 1 后 2 三轮差速布局**（前万向轮负责导向，后双驱动轮负责动力），这是工业 AMR 最稳定的差速底盘形态 | 稳定性要求 |

**改造目标清单**：

1. 四轮改三轮 — 保留左/右驱动轮 + 前万向轮，删除后脚轮
2. 驱动轮半径从 0.075 → 0.06
3. `base_link` 顶面与 `top_link` 底面之间增加一根支撑杆（`pole_link`）
4. 驱动轮后移至 x=-0.10（原 x=0.0），形成"前万向轮 + 后双驱动"的理想差速布局
5. 激光雷达底面紧贴 `top_link` 顶面
6. 摄像头贴 `top_link` 前壁正面朝前
7. IMU 放在**两轮中点正上方**（差速旋转中心），减小加速度耦合
8. 所有修改**限定在 `urdf/` 文件夹内**

***

## 2. URDF 改造方案

### 2.1 统一高度基准（核心约束）

改造前先**冻结了一套不可违反的高度基准**，避免陷入"看起来不对就加减"的试探循环：

```
地面 z=0.0
  ├─ base_link 原点（底盘几何中心）  z = 0.08
  │  ├─ 底盘底面  z = 0.08 − 0.05 = 0.03  （离地 3cm 间隙）
  │  ├─ 底盘顶面  z = 0.08 + 0.05 = 0.13
  │  │  ├─ pole_joint origin (杆中心)  z = (0.13 + 0.19)/2 = 0.16 ← 原方案用了 0.12，需修正
  │  │  └─ pole_link：r=0.02, length=0.14, 中心 z=0.16，底端 z=0.09，顶端 z=0.23
  │  ├─ 驱动轮中心  z = 0.08 − 0.04 = 0.04  ← 轮半径 0.06，轮底触地 z=0.04−0.06=−0.02？
  │  │                                        ⚠️ 重新对齐：驱动轮 z 基准 = base_link − wheel_radius
  │  └─ 脚轮触地点  z = −0.055 − 0.025 = −0.08 ← 必须与驱动轮底共面（地面 z=0 → base_link.z=0.08 时 wheel bottom z=0.08−0.06=0.02？矛盾）
```

> ⚠️ **关键纠偏**：上述推导暴露了一个常见陷阱——base_link 的 z 原点到底是"地面"还是"底盘几何中心"？最终确认：**base_link 原点在底盘几何中心，z=0.08 时整个机器人底盘底面 z=0.03、轮底 z=0.02，都在空中离地面**。Gazebo 物理引擎会自动把整个模型放到地面，此时 base_link 的世界 z 坐标会变成 `wheel_radius + 0.03 = 0.09`。因此 **所有 joint origin 的 z 值都是 base_link 局部坐标系下的相对坐标**，**驱动轮 joint z 应该是 `-wheel_radius`** 让轮底触地。

**最终基准（确定版）**：

```
base_link（底盘几何中心，相对坐标系原点=0,0,0）
  ├─ 底盘尺寸：0.40(x) × 0.30(y) × 0.10(z)
  │   → 顶面 z_local = +0.05，底面 z_local = −0.05
  │
  ├─ 驱动轮 joint z = −0.02
  │   轮半径 0.06，轮中心 z_local = −0.02
  │   → 轮底 z_local = −0.02 − 0.06 = −0.08（相对底盘中心）
  │
  ├─ 前脚轮 joint z = −0.055
  │   球半径 0.025，球中心 z_local = −0.055
  │   → 球底 z_local = −0.055 − 0.025 = −0.08
  │
  ├─ pole_link（支撑杆）：r=0.02, length=0.14
  │   中心 z_local = 0.12，底端 0.05，顶端 0.19
  │
  └─ top_link（设备仓）：0.30 × 0.22 × 0.08
      中心 z_local = 0.23，底面 z_local = 0.19（恰好落在支撑杆顶上），顶面 z_local = 0.27
```

### 2.2 amr_base.xacro 完整重写

**文件**：`amr_sim_ws/src/amr_description/urdf/amr_base.xacro`

主要变更对比：

| 参数 | 旧值 | 新值 | 决策理由 |
|------|------|------|----------|
| 后轮 `back_caster` | 存在，x=−0.15 | **删除** | 三轮布局不再需要 |
| 驱动轮 `radius` | 0.075 | **0.06** | 视觉比例 + 与底盘厚度匹配 |
| 驱动轮 `length` | 0.03 | **0.04** | 与轮宽视觉一致 |
| 驱动轮 joint **x** | 0.0（居中） | **−0.10** | 差速车动力放后方，前方万向轮负责导向 |
| 驱动轮 joint **z** | −0.05 | **−0.02** | z = −wheel_radius，轮底触地对齐 |
| 前脚轮 joint x | 0.15 | 0.15（保留） | 前导向轮位置 |
| 前脚轮 joint z | −0.05 | **−0.055** | 球底 = 球心 − 半径 = −0.055 − 0.025 = −0.08 |
| `top_joint` origin z | 0.40（悬空） | **0.23** | 中心 0.23 → 底面 0.19 恰好落在支撑杆顶 |
| `pole_link`（新增） | — | 圆柱 r=0.02, length=0.14 | 连接底盘顶面(0.05)与设备仓底面(0.19) |
| 右轮材质 | 引用左轮 color（失效） | 统一 `wheel_black` | 消除 xacro 未展开的材质引用 |
| 底盘质量 | 旧值 | **10.0 kg** | 合理的仿真质量分配 |

### 2.3 amr_imu.xacro — 位置优化

**文件**：`amr_sim_ws/src/amr_description/urdf/amr_imu.xacro`

```xml
<!-- 旧：右前角 -->
<origin xyz="0.10 0.08 0.06" rpy="0 0 0"/>

<!-- 新：两轮中点正上方，差速旋转中心 -->
<origin xyz="-0.10 0.0 0.06" rpy="0 0 0"/>
```

**为什么选 (x=−0.10, y=0)？**

- 差速车转弯时，角速度中心在两轮轴中点（y=0 直线上），x 位置与驱动轮 x 相同即 −0.10
- 放在旋转中心，转弯时 **只有向心加速度（y 轴）**，几乎没有切向加速度（x 轴）耦合到 z 轴加速度计读数里 → 传感器融合最干净
- 避开了中心支撑杆（x=0, r=0.02），安全距离 > 0.08m
- z=0.06 让 IMU 底面刚好落在底盘顶面（z=0.05）之上 1mm，视觉贴合

### 2.4 amr_lidar.xacro — 精确落台

**文件**：`amr_sim_ws/src/amr_description/urdf/amr_lidar.xacro`

```xml
<!-- 旧 -->
<origin xyz="0.0 0.0 0.16" rpy="0 0 0"/>

<!-- 新 -->
<origin xyz="0.0 0.0 0.07" rpy="0 0 0"/>
```

**计算逻辑**（相对 `top_link` 自身坐标系）：

```
top_link 自身 z=0.04 是顶面
lidar_link 圆柱高 0.06 → 中心要落在 0.04 + 0.03 = 0.07
→ 底面正好 = 0.07 − 0.03 = 0.04（与 top_link 顶面齐平）
```

> 注意：这里的 parent 是 `top_link`，所以 origin 是 **相对于 top_link 局部坐标系**，不是 base_link 全局。

### 2.5 amr_camera.xacro — 贴前壁

**文件**：`amr_sim_ws/src/amr_description/urdf/amr_camera.xacro`

```xml
<!-- 旧：顶面靠前 -->
<origin xyz="0.14 0.0 0.02" rpy="0 0 0"/>

<!-- 新：前壁正面 -->
<origin xyz="0.165 0.0 0.0" rpy="0 0 0"/>
```

**计算逻辑**：

```
top_link 自身 x=0.15 是前壁
camera_link 箱体深 0.03（x 方向厚度）
→ 中心 x = 0.15 + 0.015 = 0.165，后壁恰好贴壁
z=0：居正面中部
```

### 2.6 amr_robot.xacro — 插件参数对齐

**文件**：`amr_sim_ws/src/amr_description/urdf/amr_robot.xacro`

```xml
<!-- diff_drive 插件 wheel_radius 必须与 xacro 几何一致 -->
<wheel_radius>0.06</wheel_radius>    <!-- 旧值 0.075 -->
```

**特别注意**：`amr_robot.xacro` 里的 `gz-sim-diff-drive-system` 插件在 **<gazebo> 扩展标签里**，不依赖 `<ros>` 标签生效。ROS 侧的 `/cmd_vel`、`/odom`、`/tf` 全部通过 `ros_gz_bridge` 桥接。这个 wheel_radius 必须**精确**等于 xacro 里 `<cylinder radius="...">` 的值，否则仿真会出现轮径不匹配导致的里程计误差。

### 2.7 改造验证

```bash
# 1. xacro 语法检查
ros2 run xacro xacro amr_robot.xacro -o /tmp/test.urdf
# 无错误输出

# 2. 生成 URDF 确认结构
head -1 /tmp/test.urdf
# 确认包含 10 links, 9 joints，base_link 为根

# 3. 重建工作空间
cd amr_sim_ws && source /opt/ros/jazzy/setup.bash
colcon build --symlink-install --packages-select amr_description
source install/setup.bash

# 4. RViz / Gazebo 视觉确认
ros2 launch amr_gazebo sim_bringup.launch.py headless:=false
```

***

## 3. 仿真暂停根因诊断

### 3.1 现象描述

URDF 改造完成后启动仿真，用户执行 `ros2 run tf2_ros tf2_monitor` 观察到异常：

- 所有已发布帧显示 **"Average Delay: 1.7936e+09"**（≈当前 Unix 时间戳，约 18 亿）
- 仅发现 7 个**静态帧**（robot_state_publisher 发布的固定 link 关系），**没有 `base_link`、驱动轮、`odom` 等动态帧**
- `/odom` 和 gz 侧 `/tf` 话题**均无数据**

### 3.2 分层排查方法论

诊断过程遵循 **"ROS 层 → Bridge 层 → Gazebo 插件层 → gz transport 底层"** 四层自顶向下的顺序。

#### Layer 1 — ROS 话题层：joint_states 正常，但 odom/tf/scan/imu 缺失

```bash
# ros_gz_bridge 进程存活
ros2 node list | grep bridge
# → /ros_gz_bridge

# joint_states 正常流动（由 JointStatePublisher 插件 → bridge → robot_state_publisher 链路）
ros2 topic hz /joint_states
# → average rate: 50.0
ros2 topic echo /joint_states --once
# → 有 left_wheel_joint 和 right_wheel_joint

# /odom 完全空
ros2 topic hz /odom
# → WARNING: no data received
# /tf 缺失 odom→base_link 变换
ros2 topic echo /tf --once
# → 只有 7 个 tf，全是静态变换（top_link→lidar_link、base_link→pole_link 等），无 odom→base_link

# /scan /imu/data 也空
ros2 topic hz /scan
ros2 topic hz /imu/data
# → 都是 WARNING
```

**这一层的结论**：`JointStatePublisher` 插件 → bridge 这条链路正常，但 `DiffDrive` 插件（负责 /odom 和 odom→base_link）、`IMU` 插件、`gpu_lidar` 插件（负责 /scan）**都没在工作**。

#### Layer 2 — Bridge 配置层：确认桥接关系正确

```bash
# 查看 bridge_topics.yaml，确认 /tf、/odom、/scan、/imu/data 都在桥接列表
cat src/amr_gazebo/config/bridge_topics.yaml
# → /tf (tf2_msgs/TFMessage ← gz.msgs.Pose_V) ✓
# → /odom (nav_msgs/Odometry ← gz.msgs.Odometry) ✓
# → /scan (sensor_msgs/LaserScan ← gz.msgs.LaserScan) ✓
# → /imu/data (sensor_msgs/Imu ← gz.msgs.IMU ← gz.msgs.IMU) ✓
```

Bridge 配置没有问题。那问题在 Gazebo 侧：插件根本没有往对应的 gz transport topic 发数据。

#### Layer 3 — Gazebo server 日志：插件加载成功

```bash
# gz sim server 日志路径（每次启动的 timestamp 子目录）
ls -lt ~/.gz/sim/log/
# → 取最新目录

grep -E "DiffDrive|JointStatePublisher|IMU|load.*plugin" ~/.gz/sim/log/<timestamp>/server_console.log
# → [INFO] Plugin loaded successfully: gz::sim::systems::DiffDrive
# → [INFO] Plugin loaded successfully: gz::sim::systems::JointStatePublisher
# → [INFO] Plugin loaded successfully: gz::sim::systems::IMU
# → entity id: 70 (amr_robot model)
```

插件都加载成功了，entity id 也正确。那为什么不工作？

#### Layer 4 — gz transport 底层：世界统计暴露真相

关键一步是**跳过 ros_gz_bridge，直接用 gz transport 订阅 Gazebo 原生话题**。这比 bridge 更底层，能区分"Gazebo 没发数据"还是"bridge 转发有问题"。

##### 准备 gz transport Python 环境

IDE 启动的 shell 会注入污染的 `LD_LIBRARY_PATH`（带了错误的 libstdc++），导致 Python `import gz.transport13` 报符号找不到。必须用干净环境：

```bash
# 启动干净 bash（清除 IDE 注入的环境变量）
env -u LD_LIBRARY_PATH -u LD_PRELOAD bash

# 设置 gz transport/math/utils 的库路径
export LD_LIBRARY_PATH=/opt/ros/jazzy/opt/gz_transport_vendor/lib:/opt/ros/jazzy/opt/gz_msgs_vendor/lib:/opt/ros/jazzy/opt/gz_utils_vendor/lib:/opt/ros/jazzy/opt/gz_math_vendor/lib

# 验证
python3 -c "import gz.transport13; print('OK')"
```

##### 用 Python gz transport API 检查原生话题

```python
import gz.transport13 as gzt

# 创建订阅器的辅助函数
class MsgCounter:
    def __init__(self):
        self.count = 0
    def cb(self, msg):
        self.count += 1

import time

# 检查世界统计 —— 这是关键！
counter = MsgCounter()
sub = gzt.Subscriber("/world/indoor/stats", lambda m: counter.cb(m))
# 等待一下让数据进来
time.sleep(2)
# 手动解析 WorldStatistics 消息
# gz.msgs10.WorldStatistics 字段：paused(bool), rtf(float), sim_time(Time)

# 同时检查 /tf、/odom、/scan 原生话题
for topic in ["/world/indoor/pose/info", "/world/indoor/joint_states", "/tf", "/odom", "/scan"]:
    c = MsgCounter()
    sub = gzt.Subscriber(topic, lambda m, c=c: c.cb(m))
    time.sleep(1)
    print(f"{topic}: {c.count} msgs")
    sub = None
```

**诊断结果**：

```
/world/indoor/stats:    有数据（关键！）
/world/indoor/pose/info:  232 msgs / 4s（SceneBroadcaster 在发）
/world/indoor/joint_states: 2827 msgs / 4s（⚠️ 频率极高）
/tf:                      0 msgs ← DiffDrive 没发
/odom:                    0 msgs ← DiffDrive 没发
/scan:                    0 msgs ← GPU Lidar 没发
/imu/data:                0 msgs ← IMU 没发
```

**决定性发现 — WorldStatistics 的内容**：

订阅 `/world/indoor/stats` 后解析消息体：

```
WorldStatistics:
  paused: True        ← 世界被暂停了！
  rtf: 0.0            ← 实时因子为 0
  sim_time: 1137.64   ← 仿真时间冻结在这个值，完全不推进
```

### 3.3 根因确认与修复

**根因**：Gazebo GUI 左下角的暂停按钮被误触（headless:=false 打开 GUI 时最容易发生），世界被 pause。

**为什么 `/joint_states` 还在全速发？**

这是 gz-sim 暂停行为的一个**反直觉特性**：

| 插件/组件 | 暂停时行为 | 原因 |
|-----------|-----------|------|
| **SceneBroadcaster** | 持续发送上一帧 pose | 每个 sim server tick 都重复广播 scene 状态 |
| **JointStatePublisher** | 持续发送上一帧 joint 状态 | 同上，但会在 update_rate 参数基础上按物理步重复 |
| **DiffDrive** | **不发** /odom /tf | 依赖物理步的 Update() → 暂停时物理步不执行 |
| **IMU / GPU Lidar** | **不发** /imu/data /scan | 依赖 PostUpdate() → 暂停时物理步不执行 |

`JointStatePublisher` 的 `update_rate=50` 参数在暂停时不生效，因为它走的是 tick 周期而非物理步周期，所以会以 ~700Hz 的速度重复同一个 joint 状态——**制造了"一切正常"的假象**。

**tf2_monitor 的 1.79e+09 delay 是怎么来的？**

tf2_monitor 默认用 **墙钟时间** 与消息里的 **仿真时间戳** 做差。仿真暂停时 sim_time 卡在一个固定值（比如 1137.64），墙钟一直跑（比如 Unix 时间戳 1762000000），差值就是 1762000000 − 1137.64 ≈ 1.76e+09 —— 这是**秒级的 Unix 时间戳**被当成了纳秒来显示的假象。

正确用法：

```bash
ros2 run tf2_ros tf2_monitor --ros-args -p use_sim_time:=true
# 或启动后输入 's' 键切换 sim time
```

**修复 — 从 gz transport 侧恢复世界运行**：

```python
import gz.transport13 as gzt
import gz.msgs10 as gzmsgs
import time

# 创建服务调用
svc = gzt.ServiceCall("world_control", gzmsgs.WorldControl)
req = gzmsgs.WorldControl()
req.pause = False

# /world/indoor/control 是标准 gz-sim 世界控制服务
result = svc.Request("/world/indoor/control", req, 5000)  # 超时 ms
print(f"Resume result: {result}")
```

**恢复后验证**：

```
/world/indoor/stats: paused=False, rtf≈1.0, sim_time 正常推进
/tf:        50Hz（odom→base_link 由 DiffDrive 发布）
/odom:      50Hz
/scan:      10Hz
/imu/data:  50Hz
/joint_states: 50Hz（bridge 限频生效）
```

### 3.4 为什么之前排查容易绕远路

这个问题最坑的地方是**制造了两个互相矛盾的信号**：

| 信号 | 指示 | 真相 |
|------|------|------|
| `/joint_states` 有数据、50Hz | "仿真正常运行中" | 其实是暂停时重复上一帧的假象 |
| `/odom` 空、`/scan` 空、tf delay 巨大 | "DiffDrive/Lidar/IMU 插件坏了" | 插件没坏，只是依赖物理步的逻辑在暂停时不执行 |

**经验教训**：当 ROS 话题层出现"部分有、部分无"的分裂状态时，**第一反应不应该是怀疑某个具体插件，而应该立刻去查仿真世界状态（WorldStatistics）**——尤其是手动点开过 GUI 的场景。

***

## 4. 诊断方法论沉淀

### 4.1 ROS 2 + Gazebo 联合仿真标准诊断清单

每次启动仿真后，按以下顺序确认系统健康：

```
[1] 进程存活检查
    ros2 node list                ← ROS 侧：rsp, bridge, 各 slam/nav 节点
    ps aux | grep "gz sim"        ← gz server + gui
    ros2 topic hz /clock          ← 仿真时钟桥接是否正常

[2] WorldStatistics（gz transport 原生，跳过 bridge）
    订阅 /world/<world_name>/stats → 确认 paused=False, rtf≈1.0
    ⚠️ 这是最快发现暂停的方法，应该在任何问题时第一个查

[3] 关键话题（ROS 侧）
    ros2 topic hz /joint_states   ← bridge → rsp 链路
    ros2 topic hz /odom           ← DiffDrive 插件
    ros2 topic hz /scan           ← Lidar 插件
    ros2 topic hz /imu/data       ← IMU 插件
    ros2 topic hz /tf            ← rsp + DiffDrive 合并

[4] TF 树完整性
    ros2 run tf2_ros tf2_monitor --ros-args -p use_sim_time:=true
    # 或：ros2 run tf2_tools view_frames
```

### 4.2 gz transport Python 客户端快速上手

**库路径坑**：IDE 启动的 shell 通常会注入错误的 `LD_LIBRARY_PATH`（指向旧版或不匹配的 libstdc++），Python 端 `import gz.transport13` 会失败。标准解法：

```bash
env -u LD_LIBRARY_PATH -u LD_PRELOAD bash
export LD_LIBRARY_PATH=/opt/ros/jazzy/opt/gz_transport_vendor/lib:\
/opt/ros/jazzy/opt/gz_msgs_vendor/lib:\
/opt/ros/jazzy/opt/gz_utils_vendor/lib:\
/opt/ros/jazzy/opt/gz_math_vendor/lib:\
/opt/ros/jazzy/opt/gz_math_vendor/lib/python3/site-packages
```

**常用 gz.msgs10 消息类型**：

| 用途 | 类名 | 字段（常用） |
|------|------|-------------|
| 世界统计 | `WorldStatistics` | `paused`(bool), `rtf`(float), `sim_time`(Time: sec+nsec) |
| 世界控制 | `WorldControl` | `pause`(bool) |
| 机器人 pose | `Pose_V` | `pose` 数组 |
| 关节状态 | `JointStates` | `name` 数组 + `position/velocity/force` 数组 |
| TF | `Pose_V` | 同上，由 DiffDrive 插件发布到 `/tf` |
| 里程计 | `Odometry` | `header`, `pose`, `twist` |
| IMU | `IMU` | `orientation`, `angular_velocity`, `linear_acceleration` |
| 激光扫描 | `LaserScan` | `angle_min/max`, `ranges[]`, `intensities[]` |

**快速模板 — 订阅计数**：

```python
import gz.transport13 as gzt
import time

c = 0
def cb(msg):
    global c
    c += 1
    # msg 有 .SerializeToString()、ByteSize() 等方法

sub = gzt.Subscriber("/world/indoor/stats", cb)
time.sleep(3)
print(f"Got {c} messages")
```

### 4.3 ROS 2 CLI 正确用法速查

```bash
# ROS shell 必须 source 才能用 ros2 命令
source /opt/ros/jazzy/setup.bash
source install/setup.bash        # 如果有 workspace

# tf2_monitor 正确姿势（永远开 use_sim_time）
ros2 run tf2_ros tf2_monitor --ros-args -p use_sim_time:=true

# topic hz 看频率
ros2 topic hz /scan -w 20        # 窗口 20 条更稳定

# 完整的诊断
ros2 doctor --report             # 环境诊断
ros2 lifecycle get /planner_server  # Nav2 生命周期状态
```

### 4.4 避坑速查表

| 坑 | 现象 | 解法 |
|----|------|------|
| **GUI 暂停** | 部分话题有数据、tf delay 巨大、sim time 冻结 | 查 `/world/<name>/stats` 的 `paused` 字段；或手动点 GUI 继续按钮；headless:=true 避免 |
| **IDE shell 污染 LD_LIBRARY_PATH** | `import gz.transport13` 报符号找不到 | `env -u LD_LIBRARY_PATH bash` 启动干净 shell |
| **Wheel radius 不匹配** | DiffDrive 里程计漂移、robot_state_publisher TF 与 DiffDrive TF 不一致 | xacro 几何的 radius 和 diff_drive 插件的 wheel_radius 必须一字不差 |
| **JointStatePublisher 限频失效** | 暂停时重复发送上一帧，看起来"数据流正常" | 这是 gz-sim 的正常 tick 行为，别被误导 |
| **base_link 高度试错** | 轮子悬空/陷地、设备仓抖动 | 先定死统一高度基准再写 xacro，禁止"调一点试试"的循环 |
| **create 启动等待超时** | 日志显示 100s+ 才等到 `/robot_description` | 重启前 `pkill -9 gz ros2` 清理旧进程，DDS 会缓存过时信息 |
| **ROS 话题没数据但 bridge 活着** | bridge log 显示转发 0 条 | 问题在上游（gz 插件），用 gz transport 原生话题确认 |

***

## 5. 后续可做的改进

1. **在 launch 脚本里加 WorldStatistics 自检**：sim_bringup 启动完成后自动订阅 `/world/stats` 打印 paused/rtf，早发现暂停问题
2. **rviz2 启动参数固化 use_sim_time**：在 launch 文件里通过 `<param>` 或 `rviz2 -use_sim_time` 固化
3. **IMU 位置可以进一步优化**：当前 (x=−0.10, y=0) 已经在差速中心，但 z=0.06 离底盘顶面 1mm，可以降到 0.051 让视觉更贴合
4. **Cartographer 建图验证**：URDF 改造后的机器人需要重新建图（mapping.launch.py 已就绪）

***

## 6. 文件索引

| 文件 | 路径 |
|------|------|
| 底盘 xacro | `amr_sim_ws/src/amr_description/urdf/amr_base.xacro` |
| IMU xacro | `amr_sim_ws/src/amr_description/urdf/amr_imu.xacro` |
| Lidar xacro | `amr_sim_ws/src/amr_description/urdf/amr_lidar.xacro` |
| Camera xacro | `amr_sim_ws/src/amr_description/urdf/amr_camera.xacro` |
| 主模型组装 | `amr_sim_ws/src/amr_description/urdf/amr_robot.xacro` |
| Bridge 话题配置 | `amr_sim_ws/src/amr_gazebo/config/bridge_topics.yaml` |
| 仿真启动 | `amr_sim_ws/src/amr_gazebo/launch/sim_bringup.launch.py` |
| SLAM 启动 | `amr_sim_ws/src/amr_slam/launch/mapping.launch.py` |
| gz server 日志 | `~/.gz/sim/log/<timestamp>/server_console.log` |
| ROS 日志 | `~/.ros/log/latest/launch.log` 或 `/tmp/ros_log/` |
