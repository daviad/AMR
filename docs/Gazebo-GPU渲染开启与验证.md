# Gazebo GPU 渲染：开启、验证与真机迁移

> 面向本项目（`amr_sim_ws` + `amr_start.sh`）的实操手册。
> 结论先行：**本机 WSL2 的 GPU 已经生效**，判断依据是进程真加载了 D3D12 并打开了 `/dev/dxg`，而不是看某个配置项有没有开。

---

## 目录

- [1. 先理解渲染栈](#1-先理解渲染栈)
- [2. WSL2 下开启 GPU](#2-wsl2-下开启-gpu)
- [3. 五层验证法](#3-五层验证法)
- [4. 本次实测数据](#4-本次实测数据)
- [5. 真机怎么用 GPU](#5-真机怎么用-gpu)
- [6. 常见坑](#6-常见坑)
- [7. 排障顺序](#7-排障顺序)

---

## 1. 先理解渲染栈

```
gz sim -s
  └─ gz-sensors（Sensors 系统）
       └─ gz-rendering
            └─ Ogre2（OGRE-Next）
                 └─ OpenGL 3.3+（GLX 或 EGL）
                      └─ Mesa
                           ├─ d3d12 / iris / radeonsi / nvidia  → GPU
                           └─ swrast / llvmpipe                 → CPU
```

三条必须记住的事实：

1. **`gz sim -s` 不画窗口，但照样渲染。** `-s` 只是不启动 GUI，传感器仍要在服务端出图。
2. **一个世界只有一条渲染线程。** 相机和 `gpu_lidar` 挂在同一个 `RenderEngine` 实例上，串行排队，不是并行。
3. **GPU 和软件渲染只差最后一级。** 上层代码完全一样，区别只在 Mesa 最终加载了哪个驱动。所以"开 GPU"的本质是**让 Mesa 选对驱动**，没有任何 gz 侧的开关。

---

## 2. WSL2 下开启 GPU

### 2.1 前置条件

| 检查项 | 命令 | 期望 |
|---|---|---|
| GPU 设备节点 | `ls -l /dev/dxg` | 存在 |
| WSL 侧 GPU 库 | `ls /usr/lib/wsl/lib/libd3d12core.so` | 存在 |
| Windows 驱动 | Windows 侧 `nvidia-smi` | 正常显示显卡 |
| Mesa 版本 | `dpkg -l \| grep mesa` | ≥ 22 才稳定支持 d3d12 |

> **不要在 WSL 里安装 Linux 版 NVIDIA 驱动**。WSL 的 GPU 由 Windows 驱动通过 `/dev/dxg` 提供，装 Linux 驱动会破坏这一层。

### 2.2 三个环境变量

`amr_start.sh` 里已经处理（约在 350 行附近）：

```bash
unset LD_LIBRARY_PATH            # 关键
if [ -e /dev/dxg ]; then
  export GALLIUM_DRIVER=d3d12    # 让 Mesa 走 D3D12 直通
fi
```

三条各自的理由：

- **`unset LD_LIBRARY_PATH`**：IDE、conda、各种注入会把别的 `libstdc++`/`libGL` 塞到最前面，Mesa 加载到错误版本后**可能静默回退到 swrast**。实测过：不清理时 `glxinfo` 直接报 `couldn't find RGB GLX visual`。
- **`export GALLIUM_DRIVER=d3d12`**：显式指定驱动，避免 Mesa 在某些环境下自动选 swrast。
- **顺序很重要**：必须是"先清空、再 source ROS"。反过来会把 ROS 的库路径也删掉，`gz sim` 会找不到自己的 vendor 库。

### 2.3 不需要额外开关

`gz sim` 没有 `--gpu` 这类参数。走哪条 GL 路径完全由运行时环境决定，所以**验证只能看运行时证据**。

---

## 3. 五层验证法

从便宜到贵，逐层排除。**不要跳过 L2 直接看 L4**，否则会被时序问题误导。

### L1 · GL 探针（10 秒）

```bash
env -u LD_LIBRARY_PATH glxinfo -B | grep -E "Device|Accelerated|OpenGL version"
env -u LD_LIBRARY_PATH eglinfo -B | head -20
```

期望输出（WSL2 + NVIDIA）：

```
Device: D3D12 (NVIDIA GeForce RTX 5060 Ti)
Accelerated: yes
```

如果看到 `llvmpipe` 或 `Accelerated: no`，说明当前 shell 里 GL 是软件路径——但**不能据此断定 gz 也在用软件**，因为 gz 可能跑在另一套环境里。继续 L2。

### L2 · 进程证据（最硬的证据）

先找对进程。注意 `pgrep -f "gz sim"` 会匹配到自己的 shell wrapper，必须排除：

```bash
for d in /proc/[0-9]*; do
  cl=$(tr '\0' ' ' < $d/cmdline 2>/dev/null)
  case "$cl" in
    *gz*) case "$cl" in */bin/bash*|*pgrep*) ;; *) echo "${d#/proc/} | $cl";; esac ;;
  esac
done
```

拿到 PID 后查两件事：

```bash
P=<上一步的 PID>

# 证据 1：是否加载了 WSL 的 D3D12 库
grep -oE "/usr/lib/wsl/lib/[a-zA-Z0-9_.]+" /proc/$P/maps | sort -u

# 证据 2：是否打开了 GPU 设备节点
ls -l /proc/$P/fd | grep dxg
```

判据：

| 现象 | 判定 |
|---|---|
| 加载 `libd3d12core.so`、`libdxcore.so`，且有 `/dev/dxg` fd | **GPU 生效** |
| 只加载 `libgallium`，无 `/dev/dxg`，耗时高 | 软件渲染（swrast） |
| 有 `libgallium` 且有 `/dev/dxg` | GPU 生效（Mesa 24.1+ 把驱动合并进了 `libgallium`，属正常） |

### L3 · GPU 利用率（辅助）

```bash
nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader
```

参考值：**320×240@15Hz 大约 4%**。不要期待很高——分辨率越小，利用率越低，用低利用率反推"没开 GPU"是常见误判。

注意：WSL 下 `nvidia-smi` 看不到具体进程，只能看总利用率。

### L4 · 业务层：消息率 vs 内容率（最关键）

这是本项目真正需要看的指标。

```bash
env -u LD_LIBRARY_PATH bash -c '
source /opt/ros/jazzy/setup.bash
source ~/amr/amr_sim_ws/install/setup.bash
timeout 40 python3 - <<"EOF"
import rclpy, hashlib, time
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import Image

class N(Node):
    def __init__(self):
        super().__init__("frame_probe")
        self.n = 0; self.uniq = set()
        self.create_subscription(Image, "/camera/image_raw", self.cb, qos_profile_sensor_data)
    def cb(self, m):
        self.n += 1
        self.uniq.add(hashlib.md5(bytes(m.data)).hexdigest())

rclpy.init(); n = N(); t0 = time.time()
while time.time() - t0 < 15:
    rclpy.spin_once(n, timeout_sec=0.1)
d = time.time() - t0
print(f"msgs={n.n} ({n.n/d:.2f} Hz)  unique={len(n.uniq)} ({len(n.uniq)/d:.2f} Hz)")
rclpy.shutdown()
EOF'
```

**必须先让场景动起来**，否则测出来永远是假的：

```bash
# 另一个终端，持续 12 秒
ros2 topic pub -r 20 /cmd_vel geometry_msgs/msg/Twist \
  "{linear: {x: 0.0}, angular: {z: 0.45}}"
```

读法：

| 消息率 | 内容率 | 含义 |
|---|---|---|
| 15Hz | ≈15Hz | 真的 15fps |
| 15Hz | 明显低 | 渲染跟不上，按节拍重发旧帧 |
| 任意 | ≈0 | 场景静止，**测量无效**，先动起来 |

### L5 · 时序层

```bash
# 看 /scan 的 header.stamp 与 /clock 的差值是否单调增长
ros2 topic echo /scan --field header.stamp
ros2 topic echo /clock --field clock
```

正常：差值稳定在一个小范围（本项目实测 0.02–0.11s）。
异常：差值持续增大（例如 4s→16s），说明渲染队列积压，`/scan` 被挤到后面，Cartographer 会发散。

---

## 4. 本次实测数据

2026-11-19，`amr_start.sh` 正常启动，机器人以 0.45 rad/s 自旋：

| 指标 | 实测值 | 判定 |
|---|---|---|
| 渲染后端 | `libd3d12core.so` + `/dev/dxg` fd 36 | GPU 生效 |
| GPU 利用率 | 4% | 算力不是瓶颈 |
| 相机消息率 | 15.15 Hz | 节拍达成 |
| 相机新画面率 | 11.45 Hz（213 帧中 161 帧不同） | 约 24% 为重复帧 |
| 帧间隔 | 60–70 ms，稳定 | 无长尾卡顿 |
| `/scan` 相对 `/clock` | 0.02–0.11 s，稳定 | 无漂移 |

**同一台机器、静止场景下**测到的"新画面 0.07Hz"是**假阴性**——画面本来就没变。这也说明早期文档里那条"0.61Hz 新画面"的结论需要复核测量条件。

结论：GPU 已生效；15Hz 节拍达成，但真实新画面 11.45Hz，仍差约 24%。由于 GPU 只用了 4%，剩余损耗更可能在图像回读/格式转换/桥接序列化，而不是渲染算力。

---

## 5. 真机怎么用 GPU

真机的关键差别：**没有 `/dev/dxg`，走的是标准 Linux 图形栈**。

### 5.1 NVIDIA 独显（常见工控机 / 工作站）

```bash
# 1. 确认驱动（不要用 nouveau）
nvidia-smi
lsmod | grep nvidia

# 2. 确认 GL 走 NVIDIA
env -u LD_LIBRARY_PATH glxinfo -B | grep -E "Device|OpenGL renderer"

# 3. headless（无 X）走 EGL
ls /usr/share/glvnd/egl_vendor.d/      # 应有 10_nvidia.json

# 4. 多卡机器指定 GPU
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
```

**服务化部署要点**：systemd 服务里没有 `DISPLAY`，必须走 EGL。用 `Xvfb` 顶替会让渲染退回软件（Xvfb 本身是 CPU 光栅化），反而更慢。

### 5.2 Intel 核显

```bash
ls /dev/dri/renderD128
glxinfo -B | grep "OpenGL renderer"     # 期望 Mesa Intel(R) ...
sudo usermod -aG render,video $USER     # 否则无权限打开设备
```

### 5.3 AMD 独显 / APU

Mesa `radeonsi`，检查项同 Intel：`/dev/dri/renderD128` + 用户属组 + `glxinfo` 显示 `AMD`。

### 5.4 容器内运行

```bash
# 方式一：只透传渲染设备（Intel / AMD）
docker run --device /dev/dri -v /tmp/.X11-unix:/tmp/.X11-unix ...

# 方式二：NVIDIA 容器（需 nvidia-container-toolkit）
docker run --gpus all -e NVIDIA_DRIVER_CAPABILITIES=graphics ...
```

**不要**把宿主机的 `libGL.so` 挂进容器，会导致驱动版本不匹配、静默回退软件渲染。

### 5.5 Jetson / ARM 板卡

- **Jetson**：L4T 自带驱动，无需额外安装。注意 Ogre2 需要的 GL 版本，老版本 L4T 可能只到 GLES。
- **RK3588 等 Mali 平台**：依赖厂商专有 GL 库，Mesa panfrost 与 Ogre2 的兼容性需要实测，不要假设开箱可用。

### 5.6 真机迁移检查表

| # | 检查项 | 通过标准 |
|---|---|---|
| 1 | 驱动 | `nvidia-smi` / `glxinfo -B` 能看到厂商与型号 |
| 2 | 设备权限 | `/dev/dri/renderD128`（或 `/dev/dxg`）可访问 |
| 3 | GL 版本 | ≥ 3.3（Ogre2 硬性要求） |
| 4 | headless 路径 | 无 X 时 EGL 能创建上下文 |
| 5 | 进程证据 | `/proc/<gz_pid>/maps` 中有厂商 GL 库 |
| 6 | 业务验证 | 运动场景下新画面率 ≈ 目标帧率 |

---

## 6. 常见坑

1. **`LD_LIBRARY_PATH` 污染** — 最隐蔽的一个。表现是 `glxinfo` 报 `couldn't find RGB GLX visual`，或 gz 直接起不来。解决：先 `unset`，再 source ROS。
2. **静止场景测内容率** — 画面不变，md5 恒定，会得出"帧率极低"的错误结论。必须让机器人运动。
3. **把 `-s` 当成"不渲染"** — `-s` 只是不画窗口，传感器照样渲染。
4. **Mesa 静默回退** — 驱动加载失败时不一定报错，可能直接退回 swrast，只能靠 L2 的进程证据发现。
5. **一条渲染线程** — 相机和 `gpu_lidar` 串行，谁重谁拖累别人。无法靠配置拆分，只能靠降负载或进程隔离。
6. **用 `nvidia-smi` 的低利用率反推"没开 GPU"** — 小分辨率场景本来就低。
7. **在 WSL 里装 Linux NVIDIA 驱动** — 会破坏 `/dev/dxg` 通路。

---

## 7. 排障顺序

```
L1 GL 探针 → L2 进程证据 → L3 GPU 利用率 → L4 内容率 → L5 时序漂移
```

原则：**先用 L2 证伪"GPU 没开"，再谈帧率和优化**。顺序反了，很容易在错误的假设上改参数（本项目就发生过：按"软件渲染"的结论把相机从 640×480@15Hz 降到 320×240@5Hz，而实际上 GPU 是通的）。
