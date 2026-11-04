# AMR 视频流 + 控制面 验收检查单（CHECK）

> 日期：2026-11-03 · 环境：WSL2 Ubuntu 24.04 + ROS2 Jazzy + Gazebo Sim 8 + Flutter
> 目标：验证「视频流替换逐帧 JPEG」「MQTT 单一控制面 + 应用层状态机」「Nav2 Action 透传」「故障注入降级」「端到端 trace」。
> 所有命令在 WSL 的 `/home/dxw/amr` 下执行；Windows/Android 模拟器步骤见第 9 节。

---

## 0. 本次已实测通过的基线

| 检查项 | 命令/证据 | 结果 |
|---|---|---|
| ROS 构建 | `colcon build --symlink-install` | 7 个包全部 Finished |
| Flutter 静态检查 | `flutter analyze` | `No issues found!` |
| Flutter 单测 | `flutter test` | 16 个用例全部通过 |
| 主码流 RTSP | `ffprobe rtsp://127.0.0.1:18554/camera` | H.264 640×480 @15fps |
| 低码流 RTSP | `ffprobe rtsp://127.0.0.1:18554/camera_low` | H.264 320×240 @15fps |
| WebRTC WHEP | `POST /camera/whep`（application/sdp） | `201 Created` + SDP answer（H.264 / `setup:active`） |
| 控制面桥 | 向 `/amr/cmd/goal` 发指令（无 Nav2） | RESULT `FAILED / NAV2_UNAVAILABLE`，trace 落盘 |
| cmd_id 幂等 | 同 `cmd_id` 重复投递 | `duplicate_replayed`，未重复执行 |
| 拍照链路 | `/camera/image_raw/compressed` 单帧 | 与视频链路解耦（见第 6.3 节） |

> 说明：验收时必须重新跑一遍第 2～8 节，表中只是“已跑通一次”的参考值，不是免测项。

---

## 1. 环境准备

### 1.1 依赖自检

```bash
# ROS 与关键包
source /opt/ros/jazzy/setup.bash
ros2 pkg list | grep -E "nav2_bringup|rosbridge_server|mqtt_client|image_transport"

# MediaMTX / GStreamer
ls -l ~/bin/mediamtx
env -u LD_LIBRARY_PATH gst-inspect-1.0 x264enc >/dev/null && echo "x264enc OK"
env -u LD_LIBRARY_PATH gst-inspect-1.0 rtspclientsink >/dev/null && echo "rtspclientsink OK"

# 代理（仅首次拉依赖时需要）
export HTTP_PROXY=http://127.0.0.1:65532 HTTPS_PROXY=http://127.0.0.1:65532 \
       ALL_PROXY=socks5://127.0.0.1:65532 NO_PROXY=localhost,127.0.0.1,::1
```

### 1.2 端口占用检查

| 端口 | 用途 | 检查 |
|---|---|---|
| 1884 / 9002 | MQTT TCP / WebSocket | `ss -lntp \| grep -E '1884\|9002'` |
| 9090 | rosbridge | `ss -lntp \| grep 9090` |
| 18554 | RTSP（TCP） | `ss -lntp \| grep 18554` |
| 8889 | WebRTC WHEP 信令 | `ss -lntp \| grep 8889` |
| 8189 | WebRTC ICE（UDP+TCP） | `ss -lunp \| grep 8189` |
| 18888 | HLS（Web 大屏） | `ss -lntp \| grep 18888` |

> 若 WSL 是 mirrored 网络，Windows 侧已占用的低端口（1883 等）会冲突；本项目固定用 1884 / 9002。

---

## 2. 构建与静态检查

```bash
# 2.1 ROS
cd /home/dxw/amr/amr_sim_ws
source /opt/ros/jazzy/setup.bash
ROS_HOME=/tmp/ros_home ROS_LOG_DIR=/tmp/ros_logs colcon build --symlink-install
source install/setup.bash

# 2.2 Flutter
cd /home/dxw/amr/amr_app
FLUTTER=/home/dxw/.local/flutter/bin/flutter
PUB_HOSTED_URL=https://pub.dev $FLUTTER pub get
PUB_HOSTED_URL=https://pub.dev $FLUTTER analyze     # 期望：No issues found!
PUB_HOSTED_URL=https://pub.dev $FLUTTER test        # 期望：All tests passed (16 个)
```

通过标准：

- [ ] `colcon build` 0 失败包
- [ ] `flutter analyze` 0 issue
- [ ] `flutter test` 全绿，重点是 `test/command_state_machine_test.dart` 的 16 条状态机用例

---

## 3. 启动全链路

```bash
# 终端 A：MQTT Broker（必须先起）
mosquitto -c /home/dxw/amr/amr_sim_ws/src/amr_comm/config/mosquitto.conf

# 终端 B：仿真 + Nav2 + 视频 + 控制桥
source /opt/ros/jazzy/setup.bash
source /home/dxw/amr/amr_sim_ws/install/setup.bash
export ROS_HOME=/tmp/ros_home ROS_LOG_DIR=/tmp/ros_logs
ros2 launch amr_bringup full_bringup.launch.py headless:=true

# 终端 C：初始化 AMCL（约 15s 后）
ros2 topic pub --once /initialpose geometry_msgs/msg/PoseWithCovarianceStamped \
"{header: {frame_id: map}, pose: {pose: {position: {x: 0.0, y: 0.0}, orientation: {w: 1.0}}}}"
```

启动时序（launch 内置）：

| 时间 | 组件 |
|---|---|
| 0s | Gazebo + ros_gz_bridge + MediaMTX(18554/8889/18888) |
| 5s | rosbridge(9090) + mqtt_client + image_republish(拍照) |
| 6s | `mission_bridge`（MQTT → Nav2 Action） |
| 8s | `gst_video_source`（Gazebo 图像 → 双路 H.264 → MediaMTX） |
| 10s | Nav2 |
| 12s | inspection_node |

常用参数：

```bash
# 不启动 Gazebo 摄像头，用测试图源验证视频链路
ros2 launch amr_bringup full_bringup.launch.py video_source:=test

# 回退到旧的 ffmpeg 单路推流
ros2 launch amr_bringup full_bringup.launch.py use_legacy_video:=true

# 自定义 trace 文件
ros2 launch amr_bringup full_bringup.launch.py trace_log_path:=/tmp/amr_trace.jsonl
```

通过标准：

- [ ] `ros2 node list` 能看到 `mission_bridge`、`gst_video_source`、`mqtt_client`、`rosbridge_websocket`
- [ ] `ros2 topic list` 含 `/amr/cmd/ack`、`/amr/cmd/feedback`、`/amr/cmd/result`、`/amr/trace`、`/video/metrics`、`/video/health`
- [ ] `ros2 topic hz /camera/image_raw` 有稳定帧率（gazebo 源）

---

## 4. 视频链路检查

### 4.1 RTSP 双码流

```bash
env -u LD_LIBRARY_PATH ffprobe -hide_banner -v error \
  -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate \
  -of default=nw=1 rtsp://127.0.0.1:18554/camera

env -u LD_LIBRARY_PATH ffprobe -hide_banner -v error \
  -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate \
  -of default=nw=1 rtsp://127.0.0.1:18554/camera_low
```

- [ ] 主码流有输出，参数与 `full_bringup` 的 `main_width/main_height/fps` 一致
- [ ] 低码流有输出，分辨率/码率更低
- [ ] 日志中不出现 `461 Unsupported Transport` 导致的失败（TCP fallback 警告可忽略，最终必须拿到流）

### 4.2 WebRTC WHEP 信令

```bash
curl -s -D - -o /tmp/whep_answer.sdp \
  -X POST -H 'Content-Type: application/sdp' -H 'Accept: application/sdp' \
  --data-binary @/tmp/offer.sdp http://127.0.0.1:8889/camera/whep
```

`/tmp/offer.sdp` 最小可用模板（**必须带 fingerprint**，否则 MediaMTX 返回 400）：

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

- [ ] 返回 `HTTP/1.1 201 Created` 且 `Location: /camera/whep/<id>`
- [ ] answer 含 `m=video ... UDP/TLS/RTP/SAVPF`、`a=setup:active`、H.264
- [ ] 退出时 `DELETE <Location>` 能清理会话（App 内部已自动 DELETE）

> SDP answer 的 ICE 候选来自本机网卡。WSL mirrored 模式下会包含 `192.168.0.103`；Android 模拟器必须用这个地址（`10.0.2.2` 只对经典 NAT 生效，MediaMTX 实测不会主动采用）。

### 4.3 视频指标与健康

```bash
# 采集端指标（编码延迟 P50/P95/P99、fps、状态）
ros2 topic echo /video/metrics

# 健康摘要（state / pushed / main_fps / last_error）
ros2 topic echo /video/health

# MQTT 侧（App/Web 大屏可直接消费）
mosquitto_sub -h 127.0.0.1 -p 1884 -t 'amr/status/video#' -v
```

- [ ] `state` 为 `ONLINE`，`main_fps` 稳定
- [ ] 断流后 ≤5s 变为 `OFFLINE`，`last_error` 给出原因
- [ ] `encode_latency_ms` 的 P50/P95/P99 均为数字（不是 `null`）

### 4.4 弱网降级与恢复（无 sudo 的故障注入）

```bash
# 模拟帧停顿：暂停 GStreamer 节点
GST_PID=$(pgrep -f gst_video_source.py | head -1)
kill -STOP $GST_PID     # 2~3s：App 应显示 DEGRADED
sleep 3
kill -CONT $GST_PID     # 恢复后应回到 HEALTHY

# 模拟视频彻底中断：停掉 MediaMTX
pkill -f "mediamtx.*mediamtx.yml"
# App 应在约 3s 内显示 LOST，并出现“视频中断，正在重连…”
# 重启 MediaMTX 后 App 指数退避重连（2/4/8s，上限 10s）
~/bin/mediamtx /home/dxw/amr/amr_sim_ws/src/amr_gazebo/config/mediamtx.yml
```

- [ ] DEGRADED 期间控制面仍可用（App 健康条显示“控制面在线”，仍可下发/取消指令）
- [ ] LOST 时显示最后帧时间戳与重连次数
- [ ] 恢复后自动回到主码流（auto 模式，连续 4 次 healthy 升回）

---

## 5. 控制面检查（MQTT → Nav2 Action）

### 5.1 观察所有业务回执

```bash
mosquitto_sub -h 127.0.0.1 -p 1884 -q 1 -t 'amr/cmd/#' -v
```

另开终端观察 trace：

```bash
tail -f /tmp/amr_trace.jsonl
# 或 ros2 topic echo /amr/trace
```

### 5.2 正常导航指令

```bash
cat > /tmp/goal.json <<EOF
{
  "cmd_id": "cmd-check-$(date +%s)",
  "trace_id": "trace-check-$(date +%s)",
  "type": "NAVIGATE_TO_POSE",
  "timestamp_ms": $(date +%s%3N),
  "ttl_ms": 8000,
  "payload": {"frame_id": "map", "x": 1.0, "y": 0.0, "theta": 0.0}
}
EOF

mosquitto_pub -h 127.0.0.1 -p 1884 -q 1 -t amr/cmd/goal -m "$(cat /tmp/goal.json)"
```

期望回执顺序：

1. `amr/cmd/ack`：`status=ACCEPTED`，`latency_ms`（MQTT→Goal 接受）
2. `amr/cmd/feedback` 多次：`state=EXECUTING`，含 `nav_state`（PLANNING/CONTROLLING/RECOVERING）、`number_of_recoveries`、`distance_remaining`、`eta_sec`；每秒心跳 `heartbeat=true`
3. `amr/cmd/result`：`status=SUCCEEDED`，`latency_ms`、`total_recoveries`

- [ ] ACK 先于第一条 Feedback
- [ ] Feedback 中恢复次数在遇到障碍时递增，且 `nav_state=RECOVERING`（说明没有把 Nav2 拍平成二元状态）
- [ ] Result 只出现一次终态

### 5.3 cmd_id 幂等（重复投递）

```bash
# 连续发两次完全相同的信封
mosquitto_pub -h 127.0.0.1 -p 1884 -q 1 -t amr/cmd/goal -m "$(cat /tmp/goal.json)"
mosquitto_pub -h 127.0.0.1 -p 1884 -q 1 -t amr/cmd/goal -m "$(cat /tmp/goal.json)"
```

- [ ] `mission_bridge` 日志出现 `重复 cmd_id=...，回放上次结果`
- [ ] 机器人**没有**执行第二次物理移动
- [ ] 客户端收到上一次的 ACK/Feedback/Result 回放

### 5.4 TTL 过期

```bash
python3 - <<'PY'
import json, time
envelope = {
  "cmd_id": "cmd-expired-%d" % int(time.time()),
  "trace_id": "trace-expired",
  "timestamp_ms": int(time.time()*1000) - 60000,
  "ttl_ms": 1000,
  "payload": {"frame_id": "map", "x": 1.0, "y": 0.0, "theta": 0.0},
}
open('/tmp/goal_expired.json','w').write(json.dumps(envelope))
PY
mosquitto_pub -h 127.0.0.1 -p 1884 -q 1 -t amr/cmd/goal -m "$(cat /tmp/goal_expired.json)"
```

- [ ] ACK `status=REJECTED`，`error_code=EXPIRED`
- [ ] RESULT `status=FAILED`，`error_code=EXPIRED`
- [ ] 机器人不产生任何移动

### 5.5 取消

```bash
# 先发一条会持续执行的指令，然后：
cat > /tmp/cancel.json <<EOF
{"cmd_id": "cancel-$(date +%s)", "trace_id": "trace-cancel", "target_cmd_id": "<上面的 cmd_id>"}
EOF
mosquitto_pub -h 127.0.0.1 -p 1884 -q 1 -t amr/cmd/cancel -m "$(cat /tmp/cancel.json)"
```

- [ ] 收到取消 ACK（`action=CANCEL`）
- [ ] RESULT `status=CANCELLED` / `error_code=CANCELLED_BY_USER`
- [ ] 无活动指令时取消 → RESULT `FAILED / NO_ACTIVE_COMMAND`

### 5.6 故障注入（验证 App 的 UNKNOWN / STALE）

```bash
# 停掉 launch 内的 mission_bridge，改为手动带故障参数启动
pkill -f mission_bridge.py
source /opt/ros/jazzy/setup.bash
source /home/dxw/amr/amr_sim_ws/install/setup.bash

# A. 丢 ACK：App 应在 1.2s 后进入 UNKNOWN（不是永久“已发送”）
ros2 run amr_comm mission_bridge.py --ros-args \
  -p fault_drop_ack:=true -p trace_log_path:=/tmp/amr_trace.jsonl

# B. 丢 Result：App 应在 120s 后进入 UNKNOWN，重发同 cmd_id 可收敛
ros2 run amr_comm mission_bridge.py --ros-args -p fault_drop_result:=true

# C. 稀疏 Feedback：关闭心跳，App 应在 3s 无 Feedback 后进入 STALE
ros2 run amr_comm mission_bridge.py --ros-args -p heartbeat_feedback:=false

# D. 注入延迟（注意：同步 sleep 会阻塞执行器，仅用于小延迟）
ros2 run amr_comm mission_bridge.py --ros-args -p fault_extra_delay_ms:=500
```

- [ ] A：App 指令卡片显示“送达未知”，点“重发”后收到回放并收敛
- [ ] B：120s 未终态 → “送达未知”，重发同 `cmd_id` 后拿到 Result
- [ ] C：卡片显示“状态陈旧”，迟到 Feedback 到达后恢复“执行中”
- [ ] D：回执时间明显上升，trace 中 `latency_ms` 对应增加

---

## 6. App 侧检查（Android）

### 6.1 视频

- [ ] 默认进入摄像头页即为 WebRTC（不是 JPEG 轮播）
- [ ] 顶部健康条：`HEALTHY` / fps / 分辨率 / RTT / jitter / decode P50·P95 / 重连次数
- [ ] 画质菜单：自动 / 主码流 / 低码流；自动模式在 DEGRADED 连续 2 次后切低码流，连续 4 次 healthy 升回
- [ ] LOST 横幅：最后帧时间、重连提示、控制面在线/离线状态
- [ ] 切换视频源（WebRTC / RTSP / rosbridge JPEG）后旧播放器被正确释放，无黑屏叠帧

### 6.2 控制

- [ ] 地图页点选目标 → 只发 MQTT `amr/cmd/goal`（抓包或看日志确认**没有**二次 rosbridge `/goal_pose`）
- [ ] 指令卡片依次显示 待发送→已发送→已确认→执行中→已完成
- [ ] 卡片展示 Nav2 `nav_state`、恢复次数、剩余距离、ETA
- [ ] 取消、重发、关闭按钮可用；终态后“重发”不再出现
- [ ] App 日志出现 `[CMD_TRACE] {...}`，`cmd_id`/`trace_id` 与机器人 trace 一致

### 6.3 拍照

- [ ] 点击拍照只取一帧 `/camera/image_raw/compressed`
- [ ] 拍照时视频预览不中断
- [ ] 弱网/视频 LOST 时仍可拍照（App 顶部提示可能显示拍照超时，这是控制面无关的链路问题）

拍照独立验证（不经 App）：

```bash
ros2 topic echo --once /camera/image_raw/compressed sensor_msgs/msg/CompressedImage \
  | head -5
```

---

## 7. 延迟数字采集

### 7.1 编码/推流延迟（客观、可复现）

```bash
mosquitto_sub -h 127.0.0.1 -p 1884 -t amr/status/video_metrics -C 1 | python3 -c '
import json,sys
m=json.load(sys.stdin)
for k in ("main","low"):
    print(k, m[k]["encode_latency_ms"])
'
```

### 7.2 端到端（glass-to-glass）延迟

1. `full_bringup` 中 `overlay_clock:=true` 会在画面左下角叠加 `HH:MM:SS.mmm`。
2. 用手机/模拟器截图，记录画面时钟。
3. 与同一时刻的本机时间相减，得到端到端延迟。

采样 20 次，记录 P50/P95/P99 到下表（验收门限建议：P95 ≤ 300ms，局域网 WebRTC 通常 80～200ms）。

| 场景 | P50 | P95 | P99 | 样本数 |
|---|---|---|---|---|
| 主码流 局域网 | | | | |
| 低码流 弱网 | | | | |
| RTSP fallback | | | | |

### 7.3 App 侧 WebRTC stats

- `decodeP50Ms` / `decodeP95Ms`：`totalDecodeTime` 增量 / `framesDecoded` 增量
- `rttMs`：`candidate-pair.currentRoundTripTime`
- `jitterMs`：`inbound-rtp.jitter`
- 这些值直接显示在摄像头页顶部健康条，可截图留证。

---

## 8. trace 汇总与验收

```bash
# 按 cmd_id 汇总各阶段
python3 - <<'PY'
import json, collections
rows = collections.defaultdict(list)
for line in open('/tmp/amr_trace.jsonl'):
    r = json.loads(line)
    if r.get('cmd_id'):
        rows[r['cmd_id']].append((r['timestamp_ms'], r['component'], r['event'], r.get('latency_ms'), r.get('error_code')))
for cid, items in rows.items():
    print('==', cid)
    for t, comp, ev, lat, err in sorted(items):
        print(f'  {t} {comp:15s} {ev:20s} latency={lat} err={err}')
PY
```

验收门限：

- [ ] 每条指令的 trace 至少包含 App 侧 `command_created/published` 和桥侧 `mqtt_received/goal_sent/goal_accepted/first_feedback/result`
- [ ] `cmd_id` 在 App 与机器人两侧完全一致
- [ ] 故障注入后状态机一定收敛到 UNKNOWN / STALE / 终态之一，**不存在永久悬挂**
- [ ] 视频中断时控制链路仍可下发/取消（视频面与控制面解耦）
- [ ] 第 7.2 节有实测 P50/P95/P99 数字，而非“感觉很快”

---

## 9. Windows + Android 模拟器运行

### 9.1 代码同步到 Windows

```powershell
# Windows PowerShell：把 WSL 源码同步到构建副本
robocopy \\wsl$\Ubuntu\home\dxw\amr\amr_app C:\Users\dxw\Documents\dev\amr_app /MIR /XD .dart_tool build .git
```

### 9.2 主机地址选择

| 方式 | AMR_HOST | 说明 |
|---|---|---|
| WSL mirrored 网络（推荐） | `192.168.0.103`（`hostname -I` 查） | WebRTC UDP 8189 可直达，视频最稳 |
| `adb reverse` | `127.0.0.1` | 只反向 TCP（9090/1884/8889/18554），**WebRTC UDP 不通**，视频会退化为 RTSP/JPEG |

### 9.3 启动

```powershell
$env:JAVA_HOME="C:\Users\dxw\.jdks\jbr-21.0.11"   # 必须 JDK 21，不能用 25
cd C:\Users\dxw\Documents\dev\amr_app
C:\Users\dxw\fvm\flutter\bin\flutter pub get
C:\Users\dxw\fvm\flutter\bin\flutter run -d emulator-5554 --dart-define=AMR_HOST=192.168.0.103
```

若用 adb reverse：

```powershell
$adb="C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe"
& $adb reverse tcp:9090 tcp:9090
& $adb reverse tcp:1884 tcp:1884
& $adb reverse tcp:8889 tcp:8889
& $adb reverse tcp:18554 tcp:18554
C:\Users\dxw\fvm\flutter\bin\flutter run -d emulator-5554 --dart-define=AMR_HOST=127.0.0.1
```

### 9.4 Windows 防火墙

需放行入站（专用网络）：TCP 9090、1884、8889、18554、18888；UDP 8189。

```powershell
New-NetFirewallRule -DisplayName "AMR-TCP" -Direction Inbound -Protocol TCP `
  -LocalPort 9090,1884,8889,18554,18888 -Action Allow -Profile Private
New-NetFirewallRule -DisplayName "AMR-WebRTC-UDP" -Direction Inbound -Protocol UDP `
  -LocalPort 8189 -Action Allow -Profile Private
```

### 9.5 Android 端自检

- [ ] App 能连 MQTT（首页 MQTT 指示灯变绿）
- [ ] 摄像头页 WebRTC 出画面且健康条为 HEALTHY
- [ ] 地图下发指令后卡片走到终态
- [ ] 若 WebRTC 一直 `connecting`：先在模拟器浏览器打开 `http://192.168.0.103:8889/camera` 看 MediaMTX 页面，再检查 UDP 8189 与防火墙

---

## 10. 清理

```bash
pkill -f mission_bridge.py
pkill -f gst_video_source.py
pkill -f "mediamtx.*mediamtx.yml"
pkill -f "ros2 launch amr_bringup"
pkill -f "mosquitto -c .*mosquitto.conf"
rm -f /tmp/amr-gst-registry.bin
```

---

## 附：关键文件索引

| 模块 | 文件 |
|---|---|
| GStreamer 虚拟摄像头 | [gst_video_source.py](file:///home/dxw/amr/amr_sim_ws/src/amr_gazebo/scripts/gst_video_source.py) |
| MediaMTX 配置 | [mediamtx.yml](file:///home/dxw/amr/amr_sim_ws/src/amr_gazebo/config/mediamtx.yml) |
| 控制面桥 | [mission_bridge.py](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/scripts/mission_bridge.py) |
| MQTT 映射 | [mqtt_client.yaml](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/config/mqtt_client.yaml) |
| 一键启动 | [full_bringup.launch.py](file:///home/dxw/amr/amr_sim_ws/src/amr_bringup/launch/full_bringup.launch.py) |
| App 视频服务 | [video_stream_service.dart](file:///home/dxw/amr/amr_app/lib/services/video_stream_service.dart) |
| App 指令状态机 | [command.dart](file:///home/dxw/amr/amr_app/lib/models/command.dart) |
| App 指令中心 | [mission_command_controller.dart](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart) |
| 状态机单测 | [command_state_machine_test.dart](file:///home/dxw/amr/amr_app/test/command_state_machine_test.dart) |
