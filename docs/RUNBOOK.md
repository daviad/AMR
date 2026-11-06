# 仿真巡检 AMR + Flutter 上位机 — 启动操作手册

> 版本：v2.0 | 日期：2026-11-03
> 适用于：Windows 11 + WSL2 (Ubuntu 24.04) + ROS2 Jazzy + Gazebo Sim 8 + Flutter 3.47
> 最近变更：视频从「rosbridge JPEG 逐帧 + ffmpeg 推流」升级为 **GStreamer 双码流 → MediaMTX → WebRTC(WHEP)**；导航控制从「rosbridge `/goal_pose` + MQTT 双发」改为 **MQTT 单通道 + cmd_id 幂等状态机 + Nav2 Action 透传**。

**完整验收步骤**（含故障注入、延迟实测、Windows 模拟器运行）见 [CHECK.md](../CHECK.md)。

***

## 0. 快速参考

| 项                        | 值                                    |
| ------------------------ | ------------------------------------ |
| 仿真端工作空间                  | `/home/dxw/amr/amr_sim_ws`           |
| Flutter 项目（WSL 源码，主）   | `/home/dxw/amr/amr_app`              |
| Flutter 项目（Windows 构建副本） | `C:\Users\dxw\Documents\dev\amr_app` |
| WSL IP（mirrored 模式）      | `192.168.0.103`（示例值，以 `hostname -I` 为准）    |
| rosbridge（WebSocket）     | `9090`                               |
| MQTT（TCP）               | `1884`                               |
| MQTT（WebSocket，Web 大屏用） | `9002`                               |
| RTSP 视频流（App fallback）  | `18554`（`rtsp://<host>:18554/camera`、`/camera_low`） |
| WebRTC WHEP（App 主视频）    | `8889`（`http://<host>:8889/camera/whep`） |
| WebRTC ICE（UDP/TCP）      | `8189`                               |
| HLS 视频流（Web 大屏）       | `18888`（`http://<host>:18888/camera/index.m3u8`） |
| JDK 21（构建用）              | `C:\Users\dxw\.jdks\jbr-21.0.11`     |
| Flutter SDK（Windows）     | `C:\Users\dxw\fvm\flutter`           |
| adb（全路径，未加入 PATH）        | `C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe` |
| Web 大屏（浏览器访问）            | `http://localhost:8081/#/dashboard`  |

***

## 1. 环境依赖清单

### 1.1 仿真端（WSL）

```bash
# 系统
Ubuntu 24.04 + ROS2 Jazzy + Gazebo Sim 8.15.0

# ROS 包
sudo apt install -y \
  ros-jazzy-nav2-bringup \
  ros-jazzy-cartographer-ros \
  ros-jazzy-rosbridge-suite \
  ros-jazzy-mqtt-client \
  ros-jazzy-image-transport \
  ros-jazzy-image-transport-plugins \
  mosquitto mosquitto-clients
```

### 1.2 Flutter 端（Windows）

- Flutter SDK 3.47（`C:\Users\dxw\fvm\flutter`）
- Android SDK（`C:\Users\dxw\fvm\android-sdk`）
- JDK 21（`C:\Users\dxw\.jdks\jbr-21.0.11`）
- Android 模拟器：`Small_Phone`（emulator-5554）

> ⚠️ **JDK 25 仅作提示**：历史上遇到过 Kotlin 2.4.0 编译卡住；但 2026-11-05 实测 JDK 25（Android Studio 自带 JBR）下三次 `flutter build apk --debug` 均成功。若构建确实卡死，再切 JDK 21。

***

## 2. 仿真端启动（WSL）

### 2.1 构建工作空间（首次或代码变更后）

> ⚠️ **必须先 `env -u LD_LIBRARY_PATH`**，否则 IDE/沙箱注入的旧版 `libstdc++` 会让 ROS2 Python 扩展报 `GLIBCXX_3.4.29 not found`；也避免 GStreamer 用系统旧插件库覆盖 `~/.local/gstreamer` 的新版本。

```bash
cd /home/dxw/amr/amr_sim_ws

# proxy（首次拉依赖时需要）
export HTTP_PROXY=http://127.0.0.1:65532 HTTPS_PROXY=http://127.0.0.1:65532 \
       ALL_PROXY=socks5://127.0.0.1:65532 NO_PROXY=localhost,127.0.0.1,::1

env -u LD_LIBRARY_PATH bash -lc '
  source /opt/ros/jazzy/setup.bash
  ROS_HOME=/tmp/ros_home ROS_LOG_DIR=/tmp/ros_logs PYTHONDONTWRITEBYTECODE=1 \
    colcon build --symlink-install
  source install/setup.bash
'
```

**Flutter 端构建**（WSL 或 Windows 侧均可，Windows 侧 Gradle 更稳）：

```bash
cd /home/dxw/amr/amr_app
export HTTP_PROXY=http://127.0.0.1:65532 HTTPS_PROXY=http://127.0.0.1:65532 \
       ALL_PROXY=socks5://127.0.0.1:65532 NO_PROXY=localhost,127.0.0.1,::1
PUB_HOSTED_URL=https://pub.dev /home/dxw/.local/flutter/bin/flutter pub get
PUB_HOSTED_URL=https://pub.dev /home/dxw/.local/flutter/bin/flutter analyze
PUB_HOSTED_URL=https://pub.dev /home/dxw/.local/flutter/bin/flutter test
```

### 2.2 启动 MQTT Broker

```bash
# 终端 1：启动 mosquitto（TCP 1884 + WebSocket 9002，允许匿名）
# 注意：系统自带 mosquitto 已占用 1883，本项目用 1884/9002
mosquitto -c /home/dxw/amr/amr_sim_ws/src/amr_comm/config/mosquitto.conf
```

验证：`ss -lntp | grep -E '1884|9002'` 有监听；`mosquitto_sub -t amr/status/battery -h 127.0.0.1 -p 1884` 应有电量消息。

### 2.3 一键启动全链路

```bash
# 终端 2：启动仿真 + Nav2 + 巡检 + rosbridge + mqtt 桥 + mediamtx + GStreamer 虚拟摄像头
env -u LD_LIBRARY_PATH bash -lc '
  source /opt/ros/jazzy/setup.bash
  cd /home/dxw/amr/amr_sim_ws
  source install/setup.bash
  export ROS_HOME=/tmp/ros_home ROS_LOG_DIR=/tmp/ros_logs PYTHONDONTWRITEBYTECODE=1
  rm -f /tmp/amr-gst-registry.bin /tmp/amr_trace.jsonl
  # headless=true 不显示 Gazebo GUI（如需 GUI 观察设为 false）
  # video_source:=test 用 videotestsrc 跳过 Gazebo（无仿真地图也能验证视频链路）
  ros2 launch amr_bringup full_bringup.launch.py \
    headless:=true \
    video_source:=gazebo \
    trace_log_path:=/tmp/amr_trace.jsonl
'
```

启动时序（launch 内置 TimerAction）：

| 时间 | 组件 | 说明 |
|---|---|---|
| 0s | Gazebo Sim + ros_gz_bridge + **MediaMTX** | RTSP 18554 / WHEP 8889 / ICE 8189 / HLS 18888 |
| 5s | rosbridge + mqtt_client + **image_transport republish** | republish 仅服务拍照（`/camera/image_raw/compressed`） |
| 6s | **mission_bridge** | MQTT 指令 → Nav2 `NavigateToPose`；ACK/Feedback/Result/取消/cmd_id 幂等 |
| 8s | **gst_video_source** | Gazebo `/camera/image_raw`（或 videotestsrc）→ tee → 双路 x264enc → RTSP → MediaMTX |
| 10s | Nav2 | AMCL + planner + controller（需 §2.4 初始位姿激活） |
| 12s | inspection_node | 巡检业务 + 电池仿真 |

> **关键参数**：
> - `video_source:=test`：跳过 Gazebo 摄像头，用 GStreamer videotestsrc 验证视频链路（地图/仿真不可用但 MediaMTX + WHEP 正常）
> - `use_legacy_video:=true`：回退旧 ffmpeg 单路 RTSP 推流（默认 false，勿用）
> - `trace_log_path`：默认 `/tmp/amr_trace.jsonl`，结构化 JSONL，含 `cmd_id / trace_id / latency_ms / event`
>
> **视频管线**：`camera`（主码流 640×480 / fps 可配）+ `camera_low`（低码流 320×240）；MediaMTX 同时提供 RTSP（TCP）、WebRTC WHEP、HLS。
>
> **故障注入**（供验证 App 降级）：停掉当前 bridge，手动启动带 fault 的实例（见 §5.4）。

### 2.4 初始化 AMCL 定位与 Nav2 激活

Nav2 lifecycle 节点需要初始位姿才能全部激活。启动后约 15s 在 **终端 3** 执行：

```bash
env -u LD_LIBRARY_PATH bash -lc '
  source /opt/ros/jazzy/setup.bash
  source /home/dxw/amr/amr_sim_ws/install/setup.bash
  export ROS_HOME=/tmp/ros_home ROS_LOG_DIR=/tmp/ros_logs
  ros2 topic pub --once /initialpose geometry_msgs/msg/PoseWithCovarianceStamped "{
    header: {frame_id: map},
    pose: {pose: {position: {x: 0.0, y: 0.0, z: 0.0}, orientation: {w: 1.0}}}
  }"
'
```

若部分 lifecycle 节点激活超时，手动兜底（launch 已自动 activate，一般不需要）：

```bash
env -u LD_LIBRARY_PATH bash -lc '
source /opt/ros/jazzy/setup.bash
source /home/dxw/amr/amr_sim_ws/install/setup.bash
for n in planner_server behavior_server bt_navigator waypoint_follower \
         velocity_smoother collision_monitor route_server docking_server; do
  ros2 lifecycle set /$n activate 2>/dev/null | grep -E "Transitioning|active"
done
'
```

### 2.5 验证仿真端就绪

```bash
# 关键节点
ros2 node list | grep -E "mission_bridge|gst_video_source|mqtt_client|rosbridge_websocket|mediamtx"

# 业务话题
ros2 topic list | grep -E "amr/|video/"
# 应有：/amr/cmd/{goal,ack,feedback,result,cancel}  /amr/trace  /video/{metrics,health}

# Nav2 action server
ros2 action list | grep navigate_to_pose

# 视频链路（test source 也应有画面）
env -u LD_LIBRARY_PATH ffprobe -hide_banner -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,r_frame_rate \
  -of default=nw=1 rtsp://127.0.0.1:18554/camera
env -u LD_LIBRARY_PATH ffprobe -hide_banner -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,r_frame_rate \
  -of default=nw=1 rtsp://127.0.0.1:18554/camera_low

# WHEP 协商（最小 SDP，必须带 fingerprint）
curl -s -D - -o /tmp/answer.sdp -X POST \
  -H 'Content-Type: application/sdp' -H 'Accept: application/sdp' \
  --data-binary @/tmp/amr_offer.sdp http://127.0.0.1:8889/camera/whep | head -8
# 期望：HTTP/1.1 201 Created，SDP answer 含 H.264 + setup:active

# 拍照通道（image_transport republish，与视频链路解耦）
env -u LD_LIBRARY_PATH bash -lc 'cd /home/dxw/amr/amr_sim_ws; source /opt/ros/jazzy/setup.bash; source install/setup.bash; \
  timeout 6 ros2 topic echo --once /camera/image_raw/compressed sensor_msgs/msg/CompressedImage' 2>/dev/null | head -3
```

WHEP 最小 SDP 模板 `/tmp/amr_offer.sdp`（必须带 `fingerprint:sha-256`）：

```
v=0
o=- 1 1 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
m=video 9 UDP/TLS/RTP/SAVPF 96
c=IN IP4 0.0.0.0
a=rtcp:9 IN IP4 0.0.0.0
a=ice-ufrag:amrtest
a=ice-pwd:amrtestamrtestamrtestam
a=ice-options:trickle
a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
a=setup:actpass
a=mid:0
a=sendrecv
a=rtcp-mux
a=rtpmap:96 H264/90000
a=fmtp:96 packetization-mode=1;profile-level-id=42e01f
a=candidate:1 1 UDP 2130706431 127.0.0.1 5555 typ host
a=end-of-candidates
```

### 2.6 建图（离线一次性）

仅在场景变更或需要重建地图时执行。日常导航直接加载 `amr_nav/maps/indoor.yaml`，不重复建图。

```bash
# 终端 2：仿真 + Cartographer（不含 Nav2/map_server，避免两者争抢 /map）
export ROS_LOG_DIR=/tmp/ros_log
cd /home/dxw/amr/amr_sim_ws
source /opt/ros/jazzy/setup.bash
source install/setup.bash
ros2 launch amr_slam mapping.launch.py headless:=false

# 终端 3：手动遥控走遍场景（App 的 manual 模式，或命令行直发 /cmd_vel）
ros2 topic pub /cmd_vel geometry_msgs/msg/Twist "{linear: {x: 0.2}}" -r 10

# 终端 4：覆盖完场景后存图（默认存为 indoor，可传其他名字）
ros2 run amr_slam save_map indoor
```

存图落在 `src/amr_nav/maps/`，随后重建一次 `amr_nav` 让 install 侧生效（用 `--symlink-install` 构建则立即可见）：

```bash
cd /home/dxw/amr/amr_sim_ws
colcon build --symlink-install --packages-select amr_nav
```

验证：`ros2 topic echo /map --once` 有 OccupancyGrid；`ls src/amr_nav/maps/indoor.{pgm,yaml}` 存在。
若 `save_map` 卡住不退出，说明 `/map` 发布端不是 transient local，改用关闭该选项的手动命令：

```bash
cd /home/dxw/amr/amr_sim_ws
ros2 run nav2_map_server map_saver_cli -f src/amr_nav/maps/indoor \
  --ros-args -p map_subscribe_transient_local:=false -p use_sim_time:=true
```

***

## 3. Flutter App 启动（Windows）

> 💡 不想逐条敲命令：§3.1–§3.5 的流程已固化成一键脚本，见 **§3.7**。下面的手动步骤保留，用于排障和看清每一步在做什么。

### 3.1 同步代码（WSL → Windows）

App 源码主副本在 WSL 侧 `/home/dxw/amr/amr_app`，构建副本在 Windows 侧 `C:\Users\dxw\Documents\dev\amr_app`。**不要手工 robocopy**，用带指纹的同步脚本（`tools/`，详细原理见 [视频流全链路.md 第 11 节](视频流全链路.md)）。

```powershell
# ①（仅首次/大改前）备份构建副本，不删除任何目录
Copy-Item -LiteralPath 'C:\Users\dxw\Documents\dev\amr_app' -Destination "C:\Users\dxw\Documents\dev\amr_app.bak-$(Get-Date -Format yyyyMMdd-HHmm)" -Recurse

# ② 只读漂移检查（构建前必跑；退出码 0=一致，1=副本过期）
powershell -ExecutionPolicy Bypass -File "\\wsl.localhost\Ubuntu\home\dxw\amr\tools\sync_app_to_windows.ps1" -Check

# ③ 正式同步（默认 /E：保留目标侧独有文件；要清理请显式加 -Purge）
powershell -ExecutionPolicy Bypass -File "\\wsl.localhost\Ubuntu\home\dxw\amr\tools\sync_app_to_windows.ps1"
```

> 以上命令已在真实 Windows PowerShell 5.1 中实测：`-Check` 正常输出漂移摘要并以退出码 1 结束（当前副本过期）。直接 `& '\\wsl...ps1' -Check` 也能跑，但脚本内的 `exit` 会影响调用方会话，推荐始终用 `powershell -File` 起独立进程。

```bash
# ④ WSL 内等价检查（内部调用同一个 ps1，指纹算法完全一致）
/home/dxw/amr/tools/sync_app_check.sh
```

- 同步成功后目标根目录会写 `SYNC_INFO.txt`（记录 `pubspec_sha256`、`lib_files`、`lib_sha256`），`-Check` 用它判断"副本是否最新"。
- （脚本 v5）排除 `.dart_tool` / `build` / `.git` / `.gradle` / `ephemeral` / `.vscode` 与 `*.iml` / `*.log` / `local.properties` / `.flutter-plugins-dependencies` / `.flutter-plugins`；`.idea` 不做整体镜像，只生成安全子集（`modules.xml`、`gradle.xml`、`runConfigurations/main_dart.xml`、根 `amr_app.iml`）；同步结束后自动执行 `flutter pub get`；默认 `robocopy /E` 不删除目标侧独有文件，需要清理时加 `-Purge`。
- 2026-11-05 已收敛：Windows 副本与源端 `lib/` 均为 51 个文件，`pubspec.yaml` 已含 `flutter_webrtc`。

> ⚠️ `C:\Users\dxw\amr_app_emulator` 已废弃，**不要再构建**。
> 本项目已加 `android:usesCleartextTraffic="true"` 和 INTERNET/ACCESS_NETWORK_STATE 权限；若同步后 AndroidManifest 没这两项，手动补。

### 3.2 启动模拟器

```powershell
# 在 PowerShell 中
& 'C:\Users\dxw\fvm\android-sdk\emulator\emulator.exe' -avd Small_Phone

# 如果模拟器已启动，先杀掉
Get-Process qemu-system-x86_64,emulator,adb -ErrorAction SilentlyContinue | Stop-Process -Force; & 'C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe' kill-server; Start-Sleep -Seconds 3; Remove-Item 'C:\Users\dxw\.android\avd\Small_Phone.avd\*.lock' -Force -ErrorAction SilentlyContinue; & 'C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe' devices
# 等几秒，确认没有 emulator 进程
tasklist | findstr /i emulator
```


等待模拟器开机完成（`flutter devices` 能看到 `emulator-5554`）。

### 3.3 网络连通（二选一）

#### 方式 A：WSL mirrored 网络（推荐，WebRTC UDP 可直达）

用 `hostname -I` 查 WSL LAN IP（如 `192.168.0.103`），`flutter run` 时传：

```powershell
flutter run -d emulator-5554 --dart-define=AMR_HOST=192.168.0.103
```

✅ WebRTC UDP 8189 可直连，视频走 WHEP 低延迟。  
✅ Windows 防火墙放行入站 TCP 9090/1884/8889/18554/18888 + UDP 8189：

```powershell
New-NetFirewallRule -DisplayName "AMR-TCP" -Direction Inbound -Protocol TCP -LocalPort 9090,1884,8889,18554,18888 -Action Allow -Profile Private
New-NetFirewallRule -DisplayName "AMR-WebRTC-UDP" -Direction Inbound -Protocol UDP -LocalPort 8189 -Action Allow -Profile Private
```

#### 方式 B：adb reverse（只能走 TCP，WebRTC 不通时需手动切到 RTSP）

模拟器每次重启后重设：

```powershell
$adb = 'C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe'
& $adb reverse tcp:9090 tcp:9090    # rosbridge
& $adb reverse tcp:1884 tcp:1884    # MQTT
& $adb reverse tcp:8889 tcp:8889    # WebRTC WHEP 信令
& $adb reverse tcp:18554 tcp:18554  # RTSP fallback
& $adb reverse --list               # 确认规则存在
```

> ⚠️ `adb reverse` **不支持 UDP**，所以 WebRTC 的 ICE 协商拿不到 UDP 候选对，会导致连接失败并反复重连（App 不会自动切源），需在相机页视频源菜单手动切到 RTSP（TCP interleaved）。视频可用但比 mirrored 路径高 100~200ms。

> ❌ 不要再用 `--dart-define=AMR_HOST=10.0.2.2`：Hyper-V 防火墙拦截该路径，连接超时。

### 3.4 构建并运行 App

⚠️ **必须在 Windows 原生终端（PowerShell / CMD / VS Code 终端）执行，不能从 WSL 启动 Gradle**，否则会卡在 `checkDebugDuplicateClasses`。

方式一：`flutter run`（开发调试，带热重载）

```powershell
cd C:\Users\dxw\Documents\dev\amr_app

# 建议用 JDK 21（JDK 25 下 2026-11-05 实测可构建；若卡死再切 21）
$env:JAVA_HOME = 'C:\Users\dxw\.jdks\jbr-21.0.11'
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"

# 代理（首次或 pub get 失败时）
$env:HTTP_PROXY  = 'http://127.0.0.1:65532'
$env:HTTPS_PROXY = 'http://127.0.0.1:65532'
$env:PUB_HOSTED_URL = 'https://pub.dev'

flutter pub get
flutter run -d emulator-5554 --dart-define=AMR_HOST=192.168.0.103
# 若用 adb reverse：不带 --dart-define 时源码默认 127.0.0.1；一键脚本（-AmrHost auto）默认传 LAN IP
```

方式二：构建 APK 后安装（验证用，推荐）

```powershell
cd C:\Users\dxw\Documents\dev\amr_app
$env:JAVA_HOME = 'C:\Users\dxw\.jdks\jbr-21.0.11'
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"

flutter build apk --debug
& 'C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe' install -r build\app\outputs\flutter-apk\app-debug.apk
& 'C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe' shell monkey -p com.amr.amr_app -c android.intent.category.LAUNCHER 1
```

> 包名为 `com.amr.amr_app`（不是 `com.example.amr_app`）。

### 3.5 Web 后台大屏

推荐用 **release 构建 + 静态服务**（体积小，不受调试缓存影响）：

```powershell
# 1) Windows 侧构建
cd C:\Users\dxw\Documents\dev\amr_app
flutter build web --dart-define=AMR_HOST=localhost
# 产物：C:\Users\dxw\Documents\dev\amr_app\build\web
```

```bash
# 2) WSL 侧起静态服务（Windows 浏览器可直连；需先执行上一段的 flutter build web 生成 build/web）
cd "/mnt/c/Users/dxw/Documents/dev/amr_app/build/web"
python3 -m http.server 8081 --bind 0.0.0.0
```

浏览器访问 `http://localhost:8081/#/dashboard`。大屏包含：地图 + 机器人位姿（左）、HLS 视频 / 状态 / 巡检控制（右）。

调试模式也可用，但**每次改代码后需换端口或清缓存**，否则浏览器会加载旧 `main.dart.js`：

```powershell
flutter run -d web-server --web-port=8080 --dart-define=AMR_HOST=localhost
```

> Web 端视频用 hls.js 播放（已内置于 web/index.html + web/hls.min.js，无需外网）。
> ⚠️ Flutter Web 的 URL 必须带 `#/dashboard`（hash 路由），少了会回退到地图页。

### 3.6 验证 App 连接

App 启动后依次确认：

- 顶栏 WS / MQTT 指示灯均为绿色
- 地图页显示栅格地图（`/map`）+ 机器人位姿跟随
- 点选地图 → 只发 MQTT `amr/cmd/goal`（**不再**有 rosbridge `/goal_pose` 双发）
- 指令卡片（地图页左上角）依次显示 `待发送 → 已发送 → 已确认 → 执行中 → 已完成`，并展示 Nav2 `nav_state`（PLANNING / CONTROLLING / RECOVERING）、恢复次数、剩余距离、ETA
- 相机页：**默认 WebRTC 预览**，顶部健康条显示 `HEALTHY` + fps + 分辨率 + RTT + jitter + decode P50/P95
- 相机页菜单：画质策略（自动/主码流/低码流）、视频源（WebRTC/RTSP/rosbridge JPEG）
- 拍照：与视频链路解耦，取 `/camera/image_raw/compressed` 单帧；**弱网/视频 LOST 时仍可拍照**（或超时提示）
- App 日志搜索 `[CMD_TRACE]`：`cmd_id`/`trace_id` 应与 WSL `tail -f /tmp/amr_trace.jsonl` 一致

Web 大屏打开后，检查：

- 左上「地图」卡有栅格地图 + 绿色机器人标记
- 右上「视频」卡播放 3D 场景画面
- 右中「状态」卡显示电量 / 模式 / 巡检
- 右下「巡检控制」卡有「开始 / 停止」按钮
- 顶栏 MQTT / ROS 指示灯为绿色

### 3.7 一键脚本（App / Web）

§3.1–§3.5 手动拼起来要敲十几条命令。两个脚本把整套流程固化成一条命令，默认值就是本机环境，所有路径都能用参数覆盖：

| 脚本 | 位置 | 作用 |
|---|---|---|
| `amr_start_windows.ps1` | `\\wsl.localhost\Ubuntu\home\dxw\amr\` | Windows 侧 App：同步 → 构建 → 安装 → 启动 → adb reverse |
| `amr_web_start.ps1` | 同上 | Web 大屏：release 构建 → 起静态服务 |

> 同步后（`sync_app_to_windows.ps1` v4 起）这两个脚本也会一并带到 Windows 侧 `amr_app` 目录（`C:\Users\dxw\Documents\dev\amr_app`），可直接在那里执行 `.\amr_start_windows.ps1` / `.\amr_web_start.ps1`。

> ⚠️ 必须在**普通 Windows PowerShell 5.1 窗口**（或 VS Code 的 PowerShell 终端）里执行，不要用管理员窗口，也不要在 Trae 的沙箱终端里跑 —— 沙箱会拦截 Gradle / Flutter 对工程目录的写入，表现为 `拒绝访问` 或 `Flutter failed to open a file`。

#### 3.7.1 App 一键启动

```powershell
powershell -ExecutionPolicy Bypass -File "\\wsl.localhost\Ubuntu\home\dxw\amr\amr_start_windows.ps1"
```

默认（`-Mode install`）等价于 §3.1–§3.4 全流程：

同步 Windows 副本 → 前置检查（flutter / adb / SDK / JDK / AVD）→ `gradlew.bat --stop` → `flutter pub get`（含 `.flutter-plugins-dependencies` 的 `/home/` 自检）→ 复用在线设备或启动 AVD 并轮询 `sys.boot_completed=1` → 检查 9090 / 1884 / 8889 / 18554 → `adb reverse` 四条 → `flutter build apk --debug` → `adb install -r` → `am start`。结束时打印设备、端口、WS 地址摘要。任一前置缺失只报"缺什么、你该怎么做"，不会甩红字堆栈。

**日常会用**：

| 参数 | 作用 |
|---|---|
| （无参数） | 全流程：同步 + 构建 + 安装 + 启动 + reverse |
| `-Mode attach` | 改用 `flutter run -d <设备>`，带热重载，占住终端（Ctrl+C 退出） |
| `-Mode build` | 只构建 APK，不碰设备 |
| `-NoSync` | 跳过同步（副本已最新，省 20~30s） |
| `-NetMode nat` | WSL 为 NAT 时使用；`AMR_HOST` 取 WSL IP，可用 `-WslIp` 显式指定 |
| `-Clean` | 先 `flutter clean`（「改了代码没生效」时用，耗时增加） |

**排障会用**：

| 参数 | 作用 |
|---|---|
| `-DryRun` | 只打印将执行的命令与各项判定结果，不产生副作用 |
| `-NoAvd` | 设备不在线时也不启动模拟器，直接以退出码 5 失败 |
| `-Avd <name>` | AVD 名，默认 `Small_Phone` |
| `-Project` / `-Flutter` / `-SdkRoot` / `-Jdk` / `-SyncScript` | 覆盖副本目录 / flutter.bat / Android SDK / JDK / 同步脚本路径 |
| `-RosbridgePort` / `-MqttPort` / `-WhepPort` / `-RtspPort` | 覆盖 9090 / 1884 / 8889 / 18554（同时用于端口检查与 `adb reverse`） |

`-Jdk` 指向的路径不存在时只警告并沿用当前 `JAVA_HOME`（不硬失败）；脚本只在自身进程内设置 `JAVA_HOME`，不污染你的终端配置。

#### 3.7.2 Web 一键启动

```powershell
powershell -ExecutionPolicy Bypass -File "\\wsl.localhost\Ubuntu\home\dxw\amr\amr_web_start.ps1"
```

默认流程：`flutter build web --release --dart-define=AMR_HOST=localhost`（mirrored 下）→ 校验 `build\web\index.html` → 起静态服务（优先 WSL `python3 -m http.server`，其次 Windows python，两者都没有会明确报错而不是假装成功）→ 打印访问地址。服务在前台运行，Ctrl+C 停止。

| 参数 | 用途 |
|---|---|
| （无参数） | release 构建 + 在 8081 起静态服务 |
| `-NoBuild` | 跳过构建，直接服务已有 `build\web`（改完代码只想重启服务时用） |
| `-Port <n>` | 静态服务端口，默认 **8081** |
| `-Open` | 起服务后自动打开浏览器 |
| `-Profile` | 构建 profile 版（默认 release） |
| `-Server auto\|wsl\|windows` | 指定静态服务运行位置（默认 auto） |
| `-RosbridgePort` / `-MqttWsPort` / `-HlsPort` | 覆盖 9090 / 9002 / 18888，仅用于启动前的连通性提示 |
| `-NetMode nat` / `-WslIp` | WSL 为 NAT 时构建 `AMR_HOST=WSL IP`，浏览器也用该 IP 访问 |
| `-NoBuild` + `-DryRun` | 排障：看它选中哪种 python、会执行哪条命令 |

> **端口口径**：脚本默认静态服务 **8081**，与 §3.5 的 `python3 -m http.server 8081` 一致，浏览器地址 `http://localhost:8081/#/dashboard`。§3.5 末尾的 `flutter run -d web-server --web-port=8080` 是另一条路径（Flutter 自带 dev server），不是静态服务。若想让静态服务也走 8080，加 `-Port 8080`，访问地址随之变成 `http://localhost:8080/#/dashboard`。

#### 3.7.3 先决条件与常见失败

- **先跑 WSL 侧**：脚本只做端口连通性提示，**不会**替你启动 Gazebo / rosbridge / MQTT / mediamtx。先按 §2.3 启动 `./amr_start.sh`，否则 App 能装上但 WS / MQTT 灯是灰的。
- **mirrored**（默认，`-AmrHost auto`）：App 取 WSL `eth0` 的 LAN IP（如 `192.168.0.103`），TCP 与 UDP 都直达；`adb reverse` 仍会设置作为 TCP 兜底（UDP 8189 无法转发）。Web 用 `localhost`。
- **nat**：App 与 Web 都改用 WSL IP（脚本自动 `hostname -I` 探测，失败回退 `127.0.0.1`），`-WslIp` 可覆盖。nat 下 `adb reverse` 仍会设置，但 WebRTC 的 UDP 8189 走直连，需按 §3.3 方式 A 放行防火墙。
- **App 首页 WS 未连接**：先确认 WSL 侧 `amr_start.sh` 还在跑，再看 1884/9090 是否可达。
- **相机页不出画面**：确认 App 的 `AMR_HOST` 是宿主 LAN IP（镜像模式下即 WSL `eth0`，如 `192.168.0.103`），不能用 `127.0.0.1`——`adb reverse` 只能转发 TCP，UDP 8189 过不去。
- **端口不通不会静默失败**：rosbridge / MQTT / WHEP / RTSP（Web 侧再加 MQTT-WS 9002 / HLS 18888）不通时逐条打印 `[警告]` 并说明后果。
- **`.flutter-plugins-dependencies` 含 `/home/`**：脚本会自动重跑一次 `flutter pub get` 并复查；仍残留则说明 WSL 侧生成物又被同步过来了，见 §3.1 的 v3 排除规则。
- **`local.properties` 是 WSL 路径**（`/home/...` 或 `/mnt/c/...`）：脚本会备份原文件并重写为 Windows 路径。
- **`ios/Flutter/ephemeral/.swift_pm.lock` 残留导致 `build web` 报 `cannot access the file or directory`**：Web 脚本在构建失败后会移走该 0 字节锁文件并自动重试一次。

**退出码**（App 与 Web 共用，便于脚本串联）：

| 退出码 | 含义 |
|---|---|
| 0 | 成功 |
| 2 | 参数错误 |
| 3 | 前置缺失（flutter / adb / SDK / 工程目录不存在） |
| 4 | 同步失败或构建失败 |
| 5 | 设备不在线、端口被占用、安装/启动失败 |

#### 3.7.4 已验证范围（截至 2026-11-06）

- **已实测**：`amr_start_windows.ps1 -Mode install -NoSync` 全流程退出码 0 —— `assembleDebug 27.7s`、APK 230.8 MB、`install Success`、App 进程已启动、4 条 `adb reverse` 规则在列，9090 / 1884 / 8889 / 18554 四项端口检查均为 OK。
- **已实测**：`amr_web_start.ps1 -NoBuild -Port 8099` 起服务后 `GET /index.html` 返回 200（2477 B）、`HEAD /main.dart.js` 返回 200，9090 / 9002 / 18888 三项提示均为 OK；单独执行 `flutter build web --release` 成功（23.7s）。
- **未实测**：AVD 冷启动（复用了当时已在线`emulator-5554`）、`-Mode attach`、`-NetMode nat`、`-Open`。
- **未完整跑通**：`amr_web_start.ps1` 的「构建 + 起服务」整条链路 —— 编写脚本的沙箱环境里 Flutter 打不开上述 `.swift_pm.lock`（脚本已内置移走后重试），构建与服务两端已分开验证。

***

## 4. 功能验证清单

### 4.1 地图与导航（P6）

| 步骤        | 预期结果                    |
| --------- | ----------------------- |
| App 地图页显示 | 栅格地图渲染，机器人在原点           |
| 点击地图任意点   | 弹出目标确认浮层                |
| 确认目标      | AMR 规划路径（`/plan`），沿路径行驶 |
| 到达目标      | 机器人停止，App 提示到达          |

### 4.2 巡检（P7）

| 步骤        | 预期结果            |
| --------- | --------------- |
| 巡检页创建巡检点  | 地图上出现可拖拽标记点     |
| 编排路线 → 启动 | AMR 依次到达各点，进度上报 |
| 巡检结束      | 状态回到 AUTO       |

### 4.3 回充与告警（P8）

| 步骤       | 预期结果                   |
| -------- | ---------------------- |
| 电量低于 20% | App 弹出低电量告警            |
| 自动回充     | AMR 驶向充电桩 (-4.1, -3.4) |
| 到达充电     | 电量开始上升（charging:true）  |
| 充满（95%）  | 恢复 AUTO 模式             |

> 测试低电量：`full_bringup.launch.py` 未声明 `initial_level`，直接 `ros2 launch ... initial_level:=<值>` 会报未知参数；需在 launch 中补 `DeclareLaunchArgument('initial_level', default_value='100.0')` 并透传给 `inspection_node`，或单独 `ros2 run amr_inspection inspection_node --ros-args -p initial_level:=21`。

### 4.4 视频流（P9，已重构为 GStreamer + MediaMTX + WebRTC）

| 步骤 | 预期结果 |
|---|---|
| 进入相机页 | **默认 WebRTC 预览**（MediaMTX WHEP 8889），1~2s 出画面 |
| 顶部健康条 | `HEALTHY` + fps + 分辨率 + RTT + jitter + decode P50/P95 |
| 点画质菜单 → 低码流 | 1s 内切到 `camera_low`，分辨率/码率降低 |
| 点画质菜单 → 自动 | 连续 2 次 DEGRADED/LOST 自动切低码流；连续 4 次 HEALTHY 自动升回 |
| 视频中断（停掉 mediamtx） | App 健康条变 `LOST`，需在相机页手动切到 RTSP / rosbridge（若启用） |
| 视频中断时拍照 | 仍可拍照（`/camera/image_raw/compressed` 独立链路） |
| 视频中断时导航 | 控制通道仍可用（MQTT 与 WebRTC 解耦） |
| 点击截图 | 保存 JPEG 到临时目录（Android：`/data/user/0/com.amr.amr_app/cache/amr_captures`） |
| 切到 rosbridge JPEG（调试） | 每帧独立拉取，**不做预览默认**，仅调试用 |

**媒体验证命令**（WSL 侧）：

```bash
# RTSP 主/低双路
env -u LD_LIBRARY_PATH ffprobe -hide_banner -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,r_frame_rate \
  -of default=nw=1 rtsp://127.0.0.1:18554/camera

# WHEP 协商（201 + H.264）
curl -s -D - -o /tmp/a.sdp -X POST -H 'Content-Type: application/sdp' -H 'Accept: application/sdp' \
  --data-binary @/tmp/amr_offer.sdp http://127.0.0.1:8889/camera/whep | head -5

# 健康/指标话题（已固化在 launch 中，GStreamer 每 2s 发布）
ros2 topic echo /video/health
ros2 topic echo /video/metrics   # 含 encode_latency_ms p50/p95/p99
```

***

## 5. 常用操作命令

### 5.1 仿真端调试

```bash
# 节点/话题
ros2 node list
ros2 topic list | grep -E "amr/|video/"
ros2 action list | grep navigate_to_pose

# 手动导航（直接 Nav2 Action，绕过 mission_bridge）
ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose "{
  pose: {header: {frame_id: map}, pose: {position: {x: 2.0, y: 1.0, z: 0.0}, orientation: {w: 1.0}}}
}"

# 通过 MQTT 控制面（含 cmd_id / trace_id / TTL，推荐）
NOW_MS=$(date +%s%3N); CMD_ID="cmd-debug-$(date +%s)"
mosquitto_pub -h 127.0.0.1 -p 1884 -q 1 -t amr/cmd/goal -m "{
  \"cmd_id\": \"$CMD_ID\", \"trace_id\": \"trace-$CMD_ID\",
  \"timestamp_ms\": $NOW_MS, \"ttl_ms\": 8000,
  \"payload\": {\"frame_id\": \"map\", \"x\": 2.0, \"y\": 1.0, \"theta\": 0.0}
}"
# 监听回执
mosquitto_sub -h 127.0.0.1 -p 1884 -q 1 -t 'amr/cmd/#' -v
# 取消当前导航
mosquitto_pub -h 127.0.0.1 -p 1884 -q 1 -t amr/cmd/cancel -m "{
  \"cmd_id\": \"cancel-$(date +%s)\", \"target_cmd_id\": \"$CMD_ID\"
}"

# 其他 MQTT 命令
mosquitto_pub -h 127.0.0.1 -p 1884 -t amr/cmd/mode -m '{"mode":"auto"}'
mosquitto_pub -h 127.0.0.1 -p 1884 -t amr/cmd/estop -m '{"stop":true}'
mosquitto_pub -h 127.0.0.1 -p 1884 -t amr/cmd/return_charge -m '{}'

# trace 实时追踪
tail -f /tmp/amr_trace.jsonl | python3 -c '
import sys, json
for line in sys.stdin:
    r = json.loads(line.strip())
    print(f"[{r.get(\"component\"):18s}] {r.get(\"event\"):22s} cmd={r.get(\"cmd_id\",\"\")[-12:]:12s} "
          f"trace={r.get(\"trace_id\",\"\")[-12:]:12s} lat={r.get(\"latency_ms\",\"\")} "
          f"status={r.get(\"status\",\"\")} err={r.get(\"error_code\",\"\")}")
'

# 清除 costmap
ros2 service call /global_costmap/clear_entirely_global_costmap std_srvs/srv/Empty
```

### 5.2 **故障注入**（验证 App 的 UNKNOWN / STALE / 降级）

停掉 launch 里的 mission_bridge，手动起带 fault 参数的实例：

```bash
pkill -f "mission_bridge.py"; sleep 2
env -u LD_LIBRARY_PATH bash -lc '
  source /opt/ros/jazzy/setup.bash
  source /home/dxw/amr/amr_sim_ws/install/setup.bash
  export ROS_HOME=/tmp/ros_home ROS_LOG_DIR=/tmp/ros_logs
  # A: 丢 ACK — App 1.2s 后进入 UNKNOWN
  timeout 600 ros2 run amr_comm mission_bridge.py --ros-args -p fault_drop_ack:=true
  # B: 丢 Result — App 120s 后进入 UNKNOWN；重发同 cmd_id 可收敛
  timeout 600 ros2 run amr_comm mission_bridge.py --ros-args -p fault_drop_result:=true
  # C: 稀疏 Feedback — 关闭心跳，App 3s 无 Feedback 后进入 STALE
  timeout 600 ros2 run amr_comm mission_bridge.py --ros-args -p heartbeat_feedback:=false
  # D: 模拟延迟（会阻塞 executor，小延迟测试）
  timeout 600 ros2 run amr_comm mission_bridge.py --ros-args -p fault_extra_delay_ms:=500
'
```

trace 会写出 `ack_dropped_by_fault` / `result_dropped_by_fault`，App 侧指令卡片的状态机（见 `lib/models/command.dart`）会相应迁移到 UNKNOWN / STALE。

### 5.3 日志与文件位置

| 类型 | 位置 | 说明 |
|---|---|---|
| ROS node 日志 | `/tmp/ros_logs/` | `ROS_LOG_DIR` 改到 tmp 避免 home 目录权限 |
| 应用 trace | `/tmp/amr_trace.jsonl` | JSONL：`event / cmd_id / trace_id / latency_ms / status / error_code` |
| 视频健康/指标 | ROS 话题 `/video/health` `/video/metrics` | GStreamer 每 2s 发布一次，经 mqtt_client 桥到 `amr/status/video_metrics`（retained） |
| MediaMTX 日志 | launch 内由 mediamtx 自己管理 | `tail -f` 无专用文件；WSL 前台进程 stdout |
| Flutter App 日志 | Android Studio logcat | 过滤 `[CMD_TRACE]` 或 `[Video]` |

***

## 6. 常见问题排查

### Q1：MQTT 状态上报无消息（电量/模式状态收不到）

**原因**：`/clock` 未桥接，use\_sim\_time 节点的定时器不触发。

**检查**：

```bash
ros2 topic hz /clock   # 应有数据
```

**修复**：确认 `bridge_topics.yaml` 包含 `/clock` 桥（`rosgraph_msgs/Clock ← gz.msgs.Clock`）。

### Q2：Nav2 生命周期节点激活超时

**原因**：未发布 `/initialpose`，AMCL 未收敛。

**修复**：发布 `/initialpose` 后，按 §2.4 顺序手动 activate 8 个节点。

### Q3：导航到充电桩恒失败

**原因**：dock 坐标陷入充电桩立柱膨胀区。

**修复**：dock 坐标已改为 `(-4.1, -3.4)`，在 inflation\_radius (0.4m) 外。

### Q4：WebRTC 不通 / 视频 LOST 持续重连

**原因**：`adb reverse` 不支持 UDP，WebRTC ICE 拿不到 UDP 候选对，协商失败。App 不会自动切源，需在相机页手动切到 RTSP / rosbridge JPEG。

**修复**（推荐）：改用 WSL mirrored IP + `--dart-define=AMR_HOST=<wsl_ip>` + Windows 防火墙放行 UDP 8189。确认 WSL 侧 MediaMTX 启动时有这两行：

```
[WebRTC] started with listeners on :8889 (TCP/HTTP), :8189 (UDP/ICE), :8189 (TCP/ICE)
```

**快速诊断**：

```bash
# WSL 侧 WHEP 最小 SDP 协商（CHECK §2.5 有模板）
curl -s -D - -o /tmp/a.sdp -X POST -H 'Content-Type: application/sdp' \
  -H 'Accept: application/sdp' --data-binary @/tmp/amr_offer.sdp \
  http://127.0.0.1:8889/camera/whep | head -5
# 期望 HTTP 201 + SDP answer 含 H.264
```

> ❌ `camera` path 不存在的话，说明 `gst_video_source` 没推流（WSL 侧看 `ros2 node list | grep gst_video_source`）。
> ❌ Android 模拟器浏览器访问 `http://192.168.0.103:8889/camera` 能看到 MediaMTX 页面 → 网络 OK；否则是防火墙。

### Q5：Flutter 构建卡在 `checkDebugDuplicateClasses`

**原因**：从 WSL 通过 `powershell.exe`/`cmd.exe` 启动 Windows Gradle 会卡死。

**修复**：在 Windows 原生终端执行 `flutter run`，不要从 WSL 启动。

### Q6：Kotlin 编译卡死

**原因**：历史记录显示 Android Studio 自带 JDK 25 曾导致 Kotlin 2.4.0 编译卡住；但 2026-11-05 实测 JDK 25 下构建成功，属“遇到再切”的提示。

**修复**：若确实卡死，设置 `JAVA_HOME=C:\Users\dxw\.jdks\jbr-21.0.11`。

### Q7：模拟器无法连接 rosbridge/MQTT/WHEP

**现象**：App 顶栏 WS/MQTT 灰色；相机页 `connecting` 后 LOST。

**修复**：
- 用 mirrored IP 方式：`--dart-define=AMR_HOST=<wsl_ip>`，同时放行 Windows 防火墙（见 §3.3）
- 用 adb reverse 方式：确认 §3.3 的四条规则都在（尤其是 `tcp:8889`），`adb reverse --list` 每条端口都在
- `10.0.2.2` 已被防火墙拦截，**不要再用**

### Q8：启动瞬间误触发低电量

**原因**：use\_sim\_time 首个 tick dt 跳变。

**修复**：`inspection_node` 的 `_on_tick` 已钳位 dt ≤5s。

### Q9：GStreamer / mission_bridge 启动报 `GLIBCXX_3.4.29 not found`

**现象**：`ImportError: ... rclpy_pybind11 ... version GLIBCXX_3.4.29 not found`

**原因**：IDE/沙箱注入的旧版 `libstdc++.so.6` 覆盖了系统新版。

**修复**：所有 ROS 命令前先 `env -u LD_LIBRARY_PATH`；再给 GStreamer 单独加本地库路径：

```bash
env -u LD_LIBRARY_PATH bash -lc 'source /opt/ros/jazzy/setup.bash; ...'
```

`full_bringup.launch.py` 已给 `gst_video_source` 节点硬编码了 `additional_env={'LD_LIBRARY_PATH': <local>...}`，但单独手动 `ros2 run` 时仍需自己 `env -u`。

### Q10：RTSP 视频黑屏（fallback 路径）

**原因**：`adb reverse` 只转发 TCP，RTSP 默认 UDP 传输无法穿透。

**修复**：代码已在 `main.dart` 通过 fvp 强制 TCP interleaved（`avformat.rtsp_transport=tcp`）。若仍黑屏，先确认 `adb reverse --list` 含 `tcp:18554`，并在 WSL 侧 `env -u LD_LIBRARY_PATH ffprobe -rtsp_transport tcp rtsp://127.0.0.1:18554/camera` 复验。

### Q11：GStreamer 报 `Could not write to resource` / `rtspclientsink` 断连

**原因**：MediaMTX 没启动或被 `kill -STOP` 导致；或 GStreamer registry 缓存（`/tmp/amr-gst-registry.bin`）坏了。

**修复**：确认 mosquitto + MediaMTX + full_bringup 都在跑；删 registry 缓存重启 GStreamer：

```bash
rm -f /tmp/amr-gst-registry.bin
pkill -f gst_video_source.py; sleep 2
# full_bringup 会自动拉起新的
```

### Q12：mission_bridge 对 MQTT 回执只发一次，App 收到重复怎么办

**设计语义**：
- **ACK/Result QoS1**：可重复投递；bridge 不重复发同 `cmd_id` 的 ACK/Result；App 也按 `cmd_id` 幂等处理
- **Feedback QoS0**：不保证投递；App 靠 1Hz 心跳判断断流
- **cmd_id 幂等**：重复信封 → `duplicate_replayed`，不重复执行

### Q13：mission_bridge 报 `NAV2_UNAVAILABLE`

**原因**：Nav2 没有 `navigate_to_pose` action server 或未 activate lifecycle。

**检查**：

```bash
ros2 action list | grep navigate_to_pose
for n in bt_navigator planner_server behavior_server; do ros2 lifecycle get /$n; done
```

**修复**：补 activate（§2.4）。

### Q14：故障注入后没有任何回执（ack_dropped_by_fault）

**现象**：App 指令卡片 1.2s 后进入 UNKNOWN。

**原因**：这是**预期行为**。trace 应能看到 `ack_dropped_by_fault`。

**修复**：确认 `mission_bridge` 是手动带 fault 参数启动，不是 full_bringup 拉起的正常实例：

```bash
ps aux | grep mission_bridge
# 期望看到 -p fault_drop_ack:=true / fault_drop_result:=true
```

### Q15：trace 中 `NAV2_ERROR_204` / `NAV2_ERROR_208`

**含义**：Nav2 `GoalStatus.STATUS_ABORTED / FAILED`。常见原因：
- 目标超出地图范围（204）
- 初始位姿未发，AMCL 未收敛
- 路径规划失败（costmap 空、障碍膨胀）

**修复**：发 `/initialpose` → 再导航；或换地图内已知可达目标。

### Q16：APK 构建报 `flutter version file not found`（fvp 插件）

**原因**：fvp 0.32 的 build.gradle 读取 `<flutter-sdk>/version` 文件，Flutter 3.47 已删除该文件。

**修复**：创建 `C:\Users\dxw\fvm\flutter\version`，内容为 `3.47.2`（与 `flutter --version` 一致）。

### Q17：Web 大屏右侧卡片不显示 / 视频黑屏

**原因**：浏览器缓存了旧版 `main.dart.js`（`flutter run -d web-server` 调试模式文件名不变，release 模式有 service worker 缓存）。

**修复**：硬刷新（Ctrl+F5）；或在 DevTools Console 执行 `navigator.serviceWorker.getRegistrations().then(rs=>rs.forEach(r=>r.unregister()))` 后刷新。

### Q18：Gazebo GUI 窗口弹出但 3D 视口空白（headless:=false 时）

**现象**：`ros2 launch amr_gazebo sim_bringup.launch.py headless:=false` 弹出 Gazebo 窗口但场景空白，无模型；终端报：

```
[GUI] [Err] [RenderEngineManager.cc:513] Failed to load plugin [] : couldn't load library on path [/opt/ros/jazzy/opt/gz_rendering_vendor/lib/].
```

**原因**：gz-sim 8.15 解析 world 文件内 `<gui>` 段的已知问题——从该段加载 MinimalScene 时丢失渲染引擎名（以空名调用 RenderEngineManager），3D 视口初始化失败。server 端不受影响（world 中 Sensors 插件显式 `render_engine=ogre2`），所以 headless 模式一直正常。

**修复**：已从 `indoor.world` 中删除 `<gui>` 段（已固化在源文件并有注释说明），GUI 改用默认布局 `~/.gz/sim/8/gui.config`（其中 MinimalScene 显式 `<engine>ogre2</engine>`），渲染正常。勿在 world 中重新添加 `<gui>` 段。

**验证**：先 `cd /home/dxw/amr/amr_sim_ws`，再执行 `gz sim -r install/amr_gazebo/share/amr_gazebo/worlds/indoor.world`，终端无任何错误输出即正常。


## 7. 启动顺序总览

```
┌─ [WSL 终端1] mosquitto -c mosquitto.conf ──────────── TCP 1884 + WS 9002
├─ [WSL 终端2] full_bringup.launch.py ──────────────────── 顺序启动:
│   │   t=0s:  Gazebo + ros_gz_bridge + MediaMTX (18554/8889/8189/18888)
│   │   t=5s:  rosbridge 9090 + mqtt_client + image_transport republish（拍照）
│   │   t=6s:  mission_bridge（MQTT → Nav2 Action，ACK/Feedback/Result/cancel）
│   │   t=8s:  gst_video_source（GStreamer appsrc → tee → x264enc ×2 → RTSP）
│   │   t=10s: Nav2（AMCL + bt_navigator + planner_server...）
│   │   t=12s: inspection_node（巡检业务 + 电池仿真）
│   │
├─ [WSL 终端3] ros2 topic pub --once /initialpose ...     ← Nav2 激活前，约 15s 后
│
├─ [Windows]  启动 Android 模拟器 Small_Phone
├─ [Windows]  方式 A（推荐）: mirrored IP + 防火墙放行 UDP 8189
│             flutter run -d emulator-5554 --dart-define=AMR_HOST=<wsl_ip>
│             方式 B（退化）: adb reverse tcp:9090/1884/8889/18554
│             flutter run -d emulator-5554                 ← WebRTC 不通时需手动切 RTSP
│
└─ [WSL/Windows]  flutter build web --dart-define=AMR_HOST=localhost
                  cd build/web && python3 -m http.server 8081
                  ↓
             App：地图 + 指令卡片（ACK/Feedback/Result 生命周期）
                   + 相机页（WebRTC 预览 + 健康条 + 降级菜单）+ 拍照
             Web：http://localhost:8081/#/dashboard
                  四区域（地图/视频/状态/巡检），视频走 HLS（媒体同一套）
```

清理命令：

```bash
pkill -9 -f "mission_bridge.py|gst_video_source.py|mediamtx|full_bringup.launch.py|mosquitto" 2>/dev/null
rm -f /tmp/amr_trace.jsonl /tmp/amr-gst-registry.bin
```

***

## 8. 项目文档索引

| 文档 | 路径 | 内容 |
|---|---|---|
| 验收检查单 | [CHECK.md](../CHECK.md) | 完整构建/视频/控制/故障注入/延迟/Windows 模拟器步骤 |
| 架构文档 | [architecture.md](file:///home/dxw/amr/docs/architecture.md) | 技术选型、数据流、通信契约、指令状态机、Flutter 多端形态（Android/iOS/Web）与条件导入分叉 |
| 开发计划 | [DEVELOPMENT_PLAN.md](file:///home/dxw/amr/docs/DEVELOPMENT_PLAN.md) | 阶段进度、验收标准、交接备注 |
| 需求文档 | [requirements.md](file:///home/dxw/amr/docs/requirements.md) | 功能需求 |
| 本手册 | [RUNBOOK.md](file:///home/dxw/amr/docs/RUNBOOK.md) | 启动操作与排障 |
| Windows 侧操作手册 | [WINDOWS侧操作手册.md](WINDOWS侧操作手册.md) | 模拟器 adb reverse / AMR_HOST / 防火墙 / 自检与故障对照 |
| 视频流全链路 | [视频流全链路.md](视频流全链路.md) | Gazebo 相机 → ROS 2 → GStreamer → MediaMTX → Flutter App 逐跳讲解；WebRTC/RTSP/HLS/rosbridge 四通路对比；Windows 构建副本同步与漂移校验 |
| Web 大屏操作手册 | [WEB大屏操作手册.md](WEB大屏操作手册.md) | Windows 副本启动命令、地址与路由、端口自检、故障对照、常见坑、生产部署 |
| AI 任务分流 | [AI-ROUTING.md](AI-ROUTING.md) | 按 10 类任务给出「先读文件:行 → 不要读 → 验证」，AI 协作入口 |
| AI 需求模板 | [AI-需求模板.md](AI-需求模板.md) | 用户填目标/现象/期望/范围的最小模板 |

***

## 9. Windows 侧必做（每次模拟器重启）

> **启动 App 前先按 [WINDOWS侧操作手册.md](WINDOWS侧操作手册.md) 完成 Windows 侧步骤，否则 App 会连不上 rosbridge/MQTT，地图页一直停在「等待地图数据…」。**

`amr_start.sh` 只覆盖 WSL 仿真端；模拟器端口映射（`adb reverse`）和防火墙放行必须在 Windows 侧手动完成（模拟器每次重启后 `adb reverse` 都会失效），具体命令与自检见该手册。

