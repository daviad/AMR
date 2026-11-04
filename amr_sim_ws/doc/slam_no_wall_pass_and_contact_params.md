# AMR SLAM 仿真"穿墙"问题修复与接触参数工程设置指南

> 适用范围：`amr_sim_ws` 工作区（ROS 2 Jazzy + gz sim 8 + Cartographer 2D）
> 文档目标：阐明 SLAM 建图中"穿墙"、teleop 卡顿、**RViz2 与 Gazebo 位置严重不符**三类故障的根因，给出可迁移到真机的工程化修复方案，并系统说明摩擦系数与轮端扭矩的设置原则。

---

## 1. 问题现象

执行 `ros2 launch amr_slam mapping.launch.py headless:=false` 进行建图时出现三个问题：

| 编号 | 现象 | 表现 |
|------|------|------|
| P1 | 机器人"穿墙" | RViz2 中机器人模型穿过墙体，地图被错误拉伸；实际机器人已被墙挡住，但 `map -> base_link` 持续向前漂移 |
| P2 | Teleop 卡顿 | 操作键盘/手柄一段时间后响应变慢、延迟增大，/tf 频率异常偏高 |
| P3 | **RViz2 与 Gazebo 位置严重不符** | RViz2 中机器人偏离 Gazebo 实际位置数百米；地图被拉伸成 17.4 m × 471 m；定位**先冻结在起点、后以 1.16 m/s 持续发散** |

---

## 2. 根因分析

### 2.1 穿墙（P1）的根因

gz sim 的 `DiffDrive` 插件采用**速度控制模式**：给定目标轮速后，插件内部控制器会输出**任意大的扭矩**使轮子达到目标转速。当机器人撞墙时：

1. 物理引擎阻止车体前进（墙体 collision 拦截）；
2. 但轮子与地面之间没有足够的摩擦来"打滑"，且速度控制器无视 `max_wheel_torque` 继续驱动轮子；
3. 轮子**完美空转**（无打滑、无失速），`DiffDrive` 根据轮速积分出的 `/odom` 持续累加；
4. 实测撞墙 10 秒内 `odom -> base_link` 漂移 **~7 m**（此前可达 8~18 m）；
5. Cartographer 以该漂移的里程计作为位姿先验，而 `linear_search_window` 仅 0.10~0.30 m，scan matching 无法在搜索窗口内找到正确位姿，导致定位失败 → 机器人在地图中"穿墙"。

> 关键认知：这不是 Cartographer 的 bug，而是**不可信的轮式里程计**被当作定位先验的必然结果。真实机器人撞墙时电机同样会失速/打滑，轮式里程计也会漂移——只是漂移幅度通常小于仿真中的极端值。SLAM 系统必须具备在里程计不可信时仍能正确定位的能力。

### 2.2 Teleop 卡顿（P2）的根因

`/tf` 话题频率过高：

- Cartographer `pose_publish_period_sec = 5e-3` → `map -> odom` 以 **200 Hz** 发布；
- `joint_state_publisher` `update_rate = 50` → 轮子关节 TF 以 50 Hz 发布；
- `DiffDrive` `odom_publish_frequency = 50` → `odom -> base_link` 以 50 Hz 发布；
- 合计 `/tf` 频率约 **167 Hz**，高频 TF 洪泛导致 RViz2 渲染与 teleop 回调排队，表现为操作延迟。

### 2.3 RViz2/Gazebo 严重不符（P3）的根因：传感器时间戳滞后

这是比 P1/P2 更底层的故障，会**直接摧毁 SLAM**，而且在软件渲染环境下才会暴露。

**故障链**：

1. 本机无 GPU，gz sim 使用 `llvmpipe` 软件渲染；`gpu_lidar` 与 640×480@15 Hz 摄像头**共用同一条 ogre2 渲染队列**；
2. 渲染吞吐不足 → 激光雷达的深度图渲染被摄像头的帧不断推后，`/scan` 的 `header.stamp` 相对 `/clock` **持续滞后且单调增长**（实测 4 s → 16 s）；
3. Cartographer 是严格按时间对齐的多队列架构（`ordered_multi_queue`），它用扫描时间戳做运动外推并判断子图（submap）的插入顺序。扫描时间戳长期落后于当前轨迹时间，导致：
   - 扫描被判定为"过期"，`Queue waiting for data` 或直接丢弃；
   - 位姿外推基于错误的时序，**估计冻结**（Phase A 直线行驶 2 m 期间估计位姿停在起点不动）；
4. 持续时间越长滞后越大，最终彻底发散：`map -> base_link` 以约 1.16 m/s 匀速"漂移"，地图被拉伸至 471 m。

**放大因素：僵尸 `parameter_bridge`**。旧仿真的 bridge 进程不会随 launch 退出而消失（`pkill -f parameter_bridge` 对超长进程名不可靠），它会通过 gz transport 自动重连到新启动的 gzserver，造成：

- `/scan` 的 Publisher count 变成 **2**；
- 同一份扫描数据被重复投递两次，时间戳重复；
- Cartographer 报 `Ignored subdivision ... not before current subdivision time`，丢弃一半扫描。

**为什么不能换成 CPU lidar**：直觉方案是把 `gpu_lidar` 换成不依赖渲染的 CPU `lidar` 传感器。但 **gz-sim 8 的 sensors 系统不支持 CPU lidar**——其二进制中只链接了 `GpuLidarSensor`，`<sensor type="lidar">` 不会产生任何数据（实测 `/scan` 完全无输出，Cartographer 一直 `Queue waiting for data`）。因此只能在渲染侧降低负载。

**有效修复**：降低与 `gpu_lidar` 争抢渲染队列的摄像头负载。

| 参数 | 修复前 | 修复后 | 效果 |
|------|--------|--------|------|
| 摄像头分辨率 | 640×480 | 320×240 | 像素数降 4 倍 |
| 摄像头帧率 | 15 Hz | 5 Hz | 帧率降 3 倍 |
| **像素吞吐** | 4.6 Mpx/s | **0.38 Mpx/s** | **降约 12 倍** |
| `/scan` 时间戳相对 `/clock` 滞后 | 4 s → 16 s（单调增长） | **±0.07 s（稳定）** | 时间对齐恢复 |

> 360×1 的激光雷达深度图渲染本身极廉价，瓶颈完全来自摄像头。320×240@5 Hz 对巡检/目标识别用途仍然够用。

---


## 3. 工程方案总览

采用**多层防护**策略，按"正确性优先、仿真实度其次"排序：

| 层级 | 措施 | 作用 | 是否解决穿墙 |
|------|------|------|--------------|
| L1（核心） | Cartographer `use_odometry = false` | scan matching 成为唯一定位主干，不被漂移里程计带偏 | **是（决定性）** |
| L2（辅助） | 增大 `linear_search_window` 至 0.30 m | 提高 scan matching 对小范围漂移/打滑的容忍度 | 部分 |
| L3（辅助） | 设置轮端 `max_wheel_torque` + 轮/地摩擦系数 | 提升仿真真实度，使撞墙时轮子更倾向于打滑 | 否（gz sim 速度控制绕过扭矩限制） |
| L4（性能） | `pose_publish_period_sec` 降至 5e-2（20 Hz） | /tf 频率从 ~167 Hz 降至 ~82 Hz | 解决卡顿 |
| **L5（P3 决定性）** | **摄像头降为 320×240@5 Hz** | **解除渲染队列拥塞，`/scan` 时间戳恢复与 `/clock` 同步** | **是（解决 RViz2/Gazebo 不符）** |

> **重要**：L3 的摩擦/扭矩设置在本仿真器中无法阻止轮子空转（见 §5.4 说明），但它们是真机迁移时的合理参数，且对仿真真实度有边际改善，因此保留。真正解决穿墙的是 L1。

---

## 4. 核心修复：`use_odometry = false`

### 4.1 原理

Cartographer 的位姿估计融合多种传感器：

- 轮式里程计（odometry）→ 提供运动先验（prior）
- IMU → 提供姿态（roll/pitch/yaw 变化率）
- 激光 scan matching → 提供绝对位姿校正

当 `use_odometry = true` 时，Cartographer 把轮式里程计作为 scan matching 的初始猜测。若里程计漂移远超搜索窗口，scan matching 无法收敛到正确位姿。

当 `use_odometry = false` 时：

- Cartographer **不订阅** `/odom` 话题；
- 位姿先验仅来自 IMU（姿态）+ 上一帧位姿（位置假设小运动）；
- scan matching 成为位置估计的**唯一主干**；
- 由于激光扫描直接观测到墙体（距离不变），scan matching 能正确判断机器人未移动 → `map -> odom` 补偿 `odom -> base_link` 的漂移。

### 4.2 TF 树结构

```
map ──(Cartographer, scan matching)──> odom ──(DiffDrive 轮式里程计, 可能漂移)──> base_link
```

- `map -> odom`：由 Cartographer 发布，**基于 scan matching**，是定位真值的工程近似；
- `odom -> base_link`：由 `DiffDrive` 插件发布，基于轮速积分，撞墙时会漂移；
- Cartographer 通过调整 `map -> odom` 使最终 `map -> base_link` 正确。

### 4.3 配置位置

文件：[`amr_slam/config/cartographer_2d.lua`](file:///home/dxw/amr/amr_sim_ws/src/amr_slam/config/cartographer_2d.lua#L15-L20)

```lua
  -- 不使用轮式里程计作为先验。
  -- 原因：仿真(gz sim)中机器人撞墙时轮子完美空转无打滑，/odom 会漂移 8~18m，
  -- 远大于 scan matching 的搜索窗口，导致 Cartographer 定位失败、机器人"穿墙"。
  -- 真实机器人轮式里程计同样会漂移（打滑/磨损），SLAM 必须依赖 scan matching 作为定位主干。
  -- 设为 false 后 Cartographer 仅用激光 scan matching + IMU 估计位姿，工程上可迁移到真机。
  use_odometry = false,
```

### 4.4 工程正当性

`use_odometry = false` **不是"作弊"**，而是工业 SLAM 的常见且合理配置：

- 真实场景中，轮式里程计会因打滑、磨损、地面不平等因素漂移；
- Cartographer、slam_toolbox、GMapping 等主流 2D SLAM 均支持纯激光匹配模式；
- 在激光特征丰富的室内环境中，scan matching 的定位精度足以独立支撑建图；
- 该方案可直接迁移到真机，无需依赖仿真中的 ground truth。

> **反面教材**：用 Gazebo ground truth（`/gz_truth`）替代轮式里程计属于"作弊"——真机无 ground truth，建图算法在真机上必然失败。本方案已明确废弃该路径。

---

## 5. 摩擦系数设置指南

### 5.1 物理基础

摩擦系数 `μ`（mu）定义为最大静摩擦力与法向力之比：`f_max = μ · N`。

在 ODE/gz sim 中，接触摩擦采用**两分量模型**（与 MuJoCo 的三分量类似，但 gz/ODE 主要用两个方向）：

| 分量 | gz sim 参数 | 物理含义 | 对差速底盘的作用 |
|------|-------------|----------|------------------|
| 第一摩擦方向 | `mu1` | 沿接触面第一切线方向（通常为轮滚动方向） | 决定轮子纵向抓地力，过小会打滑、过大则完美空转 |
| 第二摩擦方向 | `mu2` | 沿接触面第二切线方向（通常为轮侧向） | 决定轮子侧向抗滑能力，影响转弯侧滑 |

> 经验法则（来自接触参数工程经验）：**优先把"滑动摩擦"作为主要调节维度**，避免把两个分量同时推到极端值。过高的统一摩擦系数会让接触约束过硬，引发求解抖动或"卡死"。

### 5.2 常见材料摩擦系数参考

| 接触材料对 | 静摩擦系数 μ | 说明 |
|------------|-------------|------|
| 橡胶轮胎 — 干燥沥青/混凝土 | 0.8 ~ 1.0 | 室内巡检机器人典型工况 |
| 橡胶轮胎 — 湿滑地面 | 0.4 ~ 0.6 | 雨天/清洁后地面 |
| 橡胶轮胎 — 木地板 | 0.6 ~ 0.8 | 写字楼室内 |
| 橡胶轮胎 — 瓷砖 | 0.5 ~ 0.7 | 商场/医院大厅 |
| 塑料轮 — 混凝土 | 0.4 ~ 0.6 | 经济型机器人 |
| 金属轮 — 金属导轨 | 0.15 ~ 0.3 | AGV 导轨场景 |

> 取值原则：取工况**下限偏保守**的值。例如室内橡胶轮取 `μ = 0.8 ~ 1.0`，仿真中可取 `1.0` 作为基准。

### 5.3 gz sim 中的设置位置与方法

摩擦系数需要在**两个地方**设置，缺一不可：

#### 5.3.1 轮子（URDF/Xacro 中）

文件：[`amr_description/urdf/amr_robot.xacro`](file:///home/dxw/amr/amr_sim_ws/src/amr_description/urdf/amr_robot.xacro#L18-L27)

```xml
  <!-- 驱动轮摩擦：mu1=纵向(滚动方向), mu2=侧向。
       真实橡胶轮 mu≈1.0；配合 max_wheel_torque 使撞墙时轮子打滑而非空转 -->
  <gazebo reference="left_wheel_link">
    <mu1>1.0</mu1>
    <mu2>1.0</mu2>
  </gazebo>
  <gazebo reference="right_wheel_link">
    <mu1>1.0</mu1>
    <mu2>1.0</mu2>
  </gazebo>
```

#### 5.3.2 地面（World 文件中）

文件：[`amr_gazebo/worlds/indoor.world`](file:///home/dxw/amr/amr_sim_ws/src/amr_gazebo/worlds/indoor.world#L51-L60)

```xml
          <!-- 地面摩擦：配合轮摩擦与 max_wheel_torque，
               使撞墙时轮子打滑而非完美空转，避免轮式里程计累积巨大漂移 -->
          <surface>
            <friction>
              <ode>
                <mu>1.0</mu>
                <mu2>1.0</mu2>
              </ode>
            </friction>
          </surface>
```

> **注意**：gz sim/ODE 中实际生效的摩擦系数是轮与地两个接触面 `mu` 的**最小值**（`μ_eff = min(μ_wheel, μ_ground)`）。因此两处必须一致设置，否则取较小值。

### 5.4 gz sim 速度控制模式下的限制

**重要发现**：在 gz sim 8 的 `DiffDrive` 系统插件中，当控制模式为**速度控制**（velocity control，默认）时，内部速度闭环会**绕过 `max_wheel_torque` 限制**，输出足够大的扭矩使轮子达到目标转速。因此：

- 即使设置了 `max_wheel_torque = 2.0` 和 `mu = 1.0`，撞墙时轮子仍会完美空转；
- 摩擦/扭矩设置**无法从物理层面阻止**本仿真中的里程计漂移；
- 这正是必须用 `use_odometry = false` 从 SLAM 层面解决穿墙的根本原因。

> 若未来需要让仿真更真实（轮子真正打滑），可考虑：改用 `gz-sim-diff-drive` 的力/扭矩控制接口、或自定义插件在轮子扭矩达到上限时停转。但这属于仿真器层面的改造，不影响 SLAM 算法的工程正确性。

### 5.5 本项目实际取值

| 参数 | 位置 | 取值 | 依据 |
|------|------|------|------|
| 轮 `mu1` / `mu2` | `amr_robot.xacro` | 1.0 / 1.0 | 橡胶轮-混凝土基准值 |
| 地面 `mu` / `mu2` | `indoor.world` | 1.0 / 1.0 | 与轮一致，保证有效摩擦为 1.0 |
| `max_wheel_torque` | `amr_robot.xacro` DiffDrive 插件 | 2.0 N·m | 见 §6.3 计算 |

---

## 6. 轮端扭矩设置指南

### 6.1 扭矩需求的工程计算

轮端扭矩需求由三部分组成：

```
T_wheel = T_accel + T_roll + T_slope
```

| 分量 | 公式 | 说明 |
|------|------|------|
| 加速扭矩 | `T_accel = m · a · r / n_drive` | `m` 整车质量，`a` 目标加速度，`r` 轮半径，`n_drive` 驱动轮数 |
| 滚动阻力扭矩 | `T_roll = μ_r · m · g · r / n_drive` | `μ_r` 滚动阻力系数（橡胶轮-硬地约 0.01~0.03） |
| 爬坡扭矩 | `T_slope = m · g · sin(θ) · r / n_drive` | `θ` 最大爬坡角度 |

### 6.2 本项目参数

| 参数 | 值 | 来源 |
|------|-----|------|
| 整车质量 `m` | ~13.4 kg | base 10 + top 2 + pole 0.3 + 两轮 1.0 + 脚轮 0.1 |
| 轮半径 `r` | 0.06 m | `amr_base.xacro` |
| 驱动轮数 `n_drive` | 2 | 差速底盘 |
| 目标加速度 `a` | 0.5 m/s² | 室内巡检典型值 |
| 滚动阻力系数 `μ_r` | 0.02 | 橡胶轮-环氧地坪 |
| 最大坡度 `θ` | 0°（室内平地） | 应用场景 |

### 6.3 扭矩计算

```
T_accel = 13.4 × 0.5 × 0.06 / 2 = 0.201 N·m
T_roll  = 0.02 × 13.4 × 9.81 × 0.06 / 2 = 0.079 N·m
T_slope = 0
T_wheel ≈ 0.28 N·m（理论需求）
```

考虑安全系数 1.5~2.0（电机效率、启动冲击、余量）：

```
T_nominal = 0.28 × 2.0 ≈ 0.56 N·m
```

本项目设置 `max_wheel_torque = 2.0 N·m`，约为理论需求的 **3.6 倍**，留有充足余量。若希望更贴近真机，可降至 `0.6 ~ 1.0 N·m`；但在 gz sim 速度控制模式下该值不生效，因此取较大值不影响仿真行为。

### 6.4 设置位置

文件：[`amr_description/urdf/amr_robot.xacro`](file:///home/dxw/amr/amr_sim_ws/src/amr_description/urdf/amr_robot.xacro#L35-L47)

```xml
    <plugin filename="gz-sim-diff-drive-system" name="gz::sim::systems::DiffDrive">
      <left_joint>left_wheel_joint</left_joint>
      <right_joint>right_wheel_joint</right_joint>
      <wheel_separation>0.33</wheel_separation>
      <wheel_radius>0.06</wheel_radius>
      <max_wheel_torque>2.0</max_wheel_torque>
      ...
    </plugin>
```

---

## 7. 完整配置变更清单

| 文件 | 变更项 | 原值 | 现值 | 目的 |
|------|--------|------|------|------|
| `amr_slam/config/cartographer_2d.lua` | `use_odometry` | `true` | `false` | 核心：scan matching 独立定位 |
| `amr_slam/config/cartographer_2d.lua` | `linear_search_window` | 0.10 | 0.30 | 提高 scan matching 容忍度 |
| `amr_slam/config/cartographer_2d.lua` | `pose_publish_period_sec` | 5e-3 (200Hz) | 5e-2 (20Hz) | 降低 /tf 频率，解决卡顿 |
| `amr_description/urdf/amr_robot.xacro` | 轮 `mu1`/`mu2` | 未设置 | 1.0 / 1.0 | 提升仿真实度 |
| `amr_description/urdf/amr_robot.xacro` | `max_wheel_torque` | 未设置 | 2.0 | 扭矩限制（真机参数） |
| `amr_description/urdf/amr_robot.xacro` | joint state `update_rate` | 50 | 30 | 降低 /tf 流量 |
| `amr_gazebo/worlds/indoor.world` | 地面 `mu`/`mu2` | 未设置 | 1.0 / 1.0 | 与轮摩擦匹配 |
| `amr_gazebo/config/bridge_topics.yaml` | `/odom`、`/tf` 桥接 | （曾被 ground truth 替代） | 已恢复 | 使用真实传感器链路 |
| `amr_gazebo/launch/sim_bringup.launch.py` | `ground_truth_odom` 节点 | 存在 | 已移除 | 废弃作弊方案 |
| `amr_gazebo/scripts/ground_truth_odom.py` | 脚本 | 存在 | 已删除 | 废弃作弊方案 |

---

## 8. 验证结果

### 8.1 穿墙验证（核心）

测试方法：机器人行驶至墙边后，持续以 0.5 m/s 推墙 10 秒，对比两个坐标系下位姿。

| 坐标系 | 起始 x (m) | 结束 x (m) | 漂移量 | 结论 |
|--------|-----------|-----------|--------|------|
| `map -> base_link`（Cartographer） | 2.145 | 2.144 | **-0.001** | 锁定墙边，未穿墙 ✓ |
| `odom -> base_link`（轮式里程计） | 38.655 | 45.655 | **+7.000** | 严重漂移（仿真伪影） |

结论：`use_odometry = false` 后，scan matching 正确识别机器人被墙挡住，`map -> base_link` 保持稳定。

### 8.2 正常运动追踪验证

测试方法：后退 → 左转 90° → 前进，观察 `map -> base_link` 轨迹。

| 阶段 | 位置 (x, y) | 航向 |
|------|------------|------|
| 起点（墙边） | (2.167, 0.005) | 0.0° |
| 后退后 | (0.907, 0.009) | 0.0° |
| 左转 + 前进后 | (0.480, 2.271) | 89.6° |

结论：scan matching 在正常行驶时正确追踪位姿，轨迹物理合理。

### 8.3 Teleop 响应验证

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| `/tf` 平均频率 | ~167 Hz | **~82 Hz** |
| teleop 操作延迟 | 明显卡顿 | 流畅 |

### 8.4 建图质量验证

- 地图分辨率：0.05 m/cell
- 地图尺寸：213 × 173 cells（约 **10.65 m × 8.65 m**，与房间真实尺寸 10 m × 8 m 一致）
- 行驶过程中地图持续扩展，墙体轮廓清晰

> 修复 P3 之前，同一场景的地图被拉伸到 17.4 m × **471.4 m**，且呈现纯平移涂抹轨迹（无墙体结构）。

### 8.5 传感器时间同步与定位精度验证（P3 修复后）

测试环境：`headless:=true`，软件渲染（llvmpipe），5 Hz 监视器对比 `/gz_truth`（Gazebo 真值）与 `map -> base_link`（Cartographer 估计）。

**(1) `/scan` 时间戳相对 `/clock` 的滞后**

| 采样时刻 | clock (s) | scan (s) | 滞后 |
|---------|-----------|----------|------|
| 1 | 297.800 | 297.800 | +0.000 |
| 2 | 297.970 | 297.900 | +0.070 |
| 3 | 297.990 | 298.000 | -0.010 |
| 4 | 298.220 | 298.200 | +0.020 |
| 5 | 298.480 | 298.500 | -0.020 |
| 6 | 298.700 | 298.700 | +0.000 |

滞后稳定在 **±0.07 s** 以内，且**不随时间增长**（修复前为 4 s → 16 s 单调增长）。

**(2) 定位误差（相对 Gazebo 真值）**

| 测试动作 | 真值位移 (m) | 估计位移 (m) | 最大误差 (m) | 结束误差 (m) |
|---------|-------------|-------------|-------------|-------------|
| 后退 1.83 m | 1.826 | 1.825 | 0.100 | 0.089 |
| 原地旋转（1.0 rad/s，2 s） | 0（位置） | 0.001 | 0.091 | 0.088 |
| 顶墙前进 10 s | 停在 x=-4.00 | 停在 x=-3.92 | 0.088 | 0.082 |

整段测试（约 160 s）误差范围 **0.043 ~ 0.146 m**，稳定不发散。

**(3) 差速驱动关节速度校验**

指令 `angular.z = 1.0 rad/s` 时，实测轮速为 `∓2.75 rad/s`，与理论值 `ω·(sep/2)/r = 1.0 × 0.165 / 0.06 = 2.75` 完全一致；6 s 内真值航向从 15.3° 变化到 -153.7°（约 240°），原地旋转功能正常。

> 测试方法提示：用 `ros2 topic pub` 每次新起进程发 `/cmd_vel` 时，publisher 与 bridge 的连接建立延迟会吞掉前几百毫秒的指令，容易误判为"机器人不转"。建议在同进程内先 warm-up 发布再执行动作序列。

---

## 9. 工程原则与注意事项

### 9.1 为什么不用 ground truth

Gazebo 可提供机器人真实位姿（`/gz_truth`），但用它替代轮式里程计属于**作弊**：

- 真机不存在 ground truth 信号；
- 建图算法依赖 ground truth 后，在真机上必然定位失败；
- 违背了"仿真验证可迁移到真机"的工程目标。

### 9.2 真机迁移建议

将本方案迁移到真机时：

1. **保持 `use_odometry = false`**：若真机灵达质量好、环境特征丰富，scan matching 足以独立定位；
2. **若真机遇长走廊/空旷区域**（scan matching 退化），可考虑重新启用 `use_odometry = true`，但需确保轮式里程计质量（编码器分辨率、防滑设计）；
3. **摩擦系数与扭矩按真机实际标定**：用 §5.2、§6 的方法根据真实轮胎/地面/电机参数设置；
4. **保留 IMU**：`use_imu_data = true` 提供姿态先验，对 scan matching 的角度收敛有显著帮助。

### 9.3 调参建议

- `linear_search_window`：正常行驶时帧间位移 < 0.1 m，0.30 m 窗口足够；若机器人高速（>1 m/s）或激光频率低（<5 Hz），需增大窗口或提高激光频率；
- `angular_search_window = 20°`：覆盖急转弯场景，一般无需调整；
- `pose_publish_period_sec`：20 Hz 已满足可视化与导航需求，无需更高。
- **摄像头负载**：软件渲染环境下，任何与 `gpu_lidar` 共用渲染队列的高分辨率传感器都会拖垮 `/scan` 时序。若以后启用更高分辨率视觉任务，建议把摄像头单独放到另一个 `ogre2` 渲染引擎实例，或改用 `camera` 的 `render_engine` 隔离（需实测）。

### 9.4 进程卫生（每次重启仿真前必做）

P3 的放大因素来自僵尸进程，因此重启仿真前必须确认进程真正清空：

```bash
# 检查残留（注意：pgrep -c 对超过 15 字符的进程名会返回 0，必须用 pgrep -f）
pgrep -af "gz sim|cartographer|parameter_bridge|robot_state_pub"

# 逐个按 PID 杀掉（不要只靠 pkill -f，可能漏掉同名旧进程）
kill -9 <PID> <PID>
```

启动后做两项体检：

```bash
# 1) /scan 必须只有一个发布者（>1 说明有僵尸 bridge 重连）
ros2 topic info /scan | grep Publisher

# 2) /scan 必须稳定在设定频率，且时间戳不落后 /clock
ros2 topic hz /scan
```

若 `/scan` Publisher count > 1，先清进程再重启，否则 Cartographer 会因重复时间戳丢弃扫描。

---

## 附录 A：构建与运行命令

```bash
# 构建
cd /home/dxw/amr/amr_sim_ws && source /opt/ros/jazzy/setup.bash && \
export LD_LIBRARY_PATH=/opt/ros/jazzy/lib:/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH && \
colcon build --packages-select amr_gazebo amr_description amr_slam

# 运行（带 RViz）
cd /home/dxw/amr/amr_sim_ws && source install/setup.bash && \
export ROS_LOG_DIR=/tmp/ros_logs && \
export LD_LIBRARY_PATH=/opt/ros/jazzy/lib:/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH && \
ros2 launch amr_slam mapping.launch.py headless:=false
```

## 附录 B：关键 TF 树

```
map
 └── odom          (Cartographer 发布, 基于 scan matching, 20 Hz)
      └── base_link (DiffDrive 发布, 基于轮式里程计, 50 Hz)
           ├── left_wheel_link   (joint_state_publisher, 30 Hz)
           ├── right_wheel_link  (joint_state_publisher, 30 Hz)
           ├── lidar_link        (static)
           └── imu_link          (static)
```
