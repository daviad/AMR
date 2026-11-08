# Windows 侧操作手册（AMR 巡检 App）

> 版本：v1.1 | 日期：2026-11-08（网关收口：App 走 HTTP 8080 / WS 8081，9090/1884 仅调试）
> 适用：Windows 11 + WSL2（Ubuntu 24.04）+ Android 模拟器 `Small_Phone` + Flutter App
> 配套文档：[RUNBOOK.md](RUNBOOK.md)（WSL 仿真端启动）、[CHECK.md](../CHECK.md)（完整验收）

***

## 0. 这份手册解决什么问题

`~/amr/amr_start.sh` 只在 WSL 里跑，负责 Gazebo、Nav2、业务网关（HTTP **8080** / WS **8081**）、mosquitto、视频流这些**仿真端**进程（rosbridge 已降级为网关内部/调试通道）。它**管不到 Windows 侧**的三件事：

1. Android 模拟器与 Windows 主机之间的端口映射（`adb reverse`）；
2. Windows 防火墙对 WSL 端口的入站放行；
3. App 启动时注入的 `AMR_HOST`（决定 App 去连哪个 IP，**网关 host 也用它**，无需额外的 gateway host 参数）。

App 代码里的默认值是 `AMR_HOST=127.0.0.1`、网关 HTTP `8080` / WS `8081`（见 `lib/core/constants.dart` 的 `gatewayHttpPort` / `gatewayWsPort`）。在 Windows 上跑普通桌面程序时这是对的，但**在 Android 模拟器里，`127.0.0.1` 指的是模拟器自己，不是 Windows，更不是 WSL**。所以只要没做端口映射或指错 IP，App 就表现为：

- 顶栏 `GW` / `WS` / `MQTT` 三个指示灯是灰色；
- 地图页一直停在「等待地图数据…」；
- `adb logcat` 里反复出现 `SocketException: Connection refused, address = 127.0.0.1`。

> 2026-11-03 实测结论：这套环境下仿真端一切正常（`/map` 由 `map_server` 正常发布、lifecycle 为 `active`），问题只在上述 Windows 侧连接链路；补上 `adb reverse` 后 App 在几秒内自动重连（WS 指数退避 2→10s），地图随即渲染。

***

## 1. 每次模拟器重启后必做（方式 B：adb reverse）

**Android 模拟器每重启一次，下面的 4 条就要重做一次。** 打开 PowerShell（Windows 原生终端，不要用 WSL 里的 shell）：

```powershell
# adb 全路径（SDK 唯一入口是 C:\Users\dxw\fvm\android-sdk；C:\Users\dxw\AppData\Local\Android\Sdk 只作为 emulator/system-images 的 junction 实体，不要直接用那个路径）
$adb = 'C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe'

# 1) 业务网关 HTTP（App 鉴权/任务/地图/快照，必用）
& $adb reverse tcp:8080  tcp:8080
# 2) 业务网关 WS（位姿/路径/扫描/任务状态推送，必用）
& $adb reverse tcp:8081  tcp:8081
# 3) WebRTC WHEP 信令（App 主视频）
& $adb reverse tcp:8889  tcp:8889
# 4) RTSP 兜底视频
& $adb reverse tcp:18554 tcp:18554

# 可选（调试用）：rosbridge 9090 / MQTT 1884 不再是 App 通道，只有手动排障时才需要
# & $adb reverse tcp:9090 tcp:9090
# & $adb reverse tcp:1884 tcp:1884

# 确认规则已生效
& $adb reverse --list
```

期望输出类似（`host-xx` 前缀是 adb 内部的 host transport 编号，不同机器可能不同）：

```
host-15 tcp:8080 tcp:8080
host-15 tcp:8081 tcp:8081
host-15 tcp:8889 tcp:8889
host-15 tcp:18554 tcp:18554
```

> `amr_start_windows.ps1` 默认就是这 4 条（`-GatewayHttpPort` / `-GatewayWsPort` / `-WhepPort` / `-RtspPort` 可覆盖），执行脚本后无需再手敲。

**为什么模拟器重启后就失效？**
`adb reverse` 规则是登记在 adb server 上、绑定到当前模拟器连接（transport，如 `emulator-5554`）的。模拟器一重启就是一条新的 transport，旧规则不会继承；执行 `adb kill-server` 重启 adb server 同样会清空。所以每次开机都要重来一遍。

**需要重启 App 吗？**
不需要。App 的网关 WS 客户端断开后按指数退避重连（2s → 10s 封顶，`lib/comm/gateway_ws_client.dart`），规则加上后几秒内 `GW` / `WS` 灯就会变绿。

> ⚠️ `adb reverse` 只支持 TCP、不支持 UDP，所以 WebRTC（UDP 8189）拿不到 ICE 候选，视频**不会自动切源**：不会自己退到 RTSP/HLS，需要在 App 的相机页手动切换到「RTSP（TCP 兼容）」选项（或改用 Web 端），画面可用但延迟比方式 A 高 100~200ms。
> 如果你对视频延迟敏感，用下面的方式 A。

***

## 2. 等效方案：`--dart-define=AMR_HOST=<WSL IP>` + 防火墙放行（方式 A）

思路是让 App 直接连 WSL 的局域网 IP，绕开模拟器的 `127.0.0.1`。

### 2.1 查当前 WSL IP（不要硬编码）

```powershell
wsl -d Ubuntu -- hostname -I
```

> 本手册编写时实测为 `192.168.0.103`，但 WSL 的 IP 会随网络环境/重启变化，**每次都以 `hostname -I` 的输出为准**。下文命令里的 `<WSL_IP>` 请替换成实际值。

### 2.2 一次性放行防火墙（需要管理员权限的 PowerShell）

```powershell
# 管理员 PowerShell 中执行
# 若之前按旧口径建过 9090/1884 的 AMR-TCP 规则，先删掉再重建
Get-NetFirewallRule -DisplayName "AMR-TCP" -ErrorAction SilentlyContinue | Remove-NetFirewallRule

New-NetFirewallRule -DisplayName "AMR-TCP" -Direction Inbound -Protocol TCP `
  -LocalPort 8080,8081,8889,18554,18888 -Action Allow -Profile Private

New-NetFirewallRule -DisplayName "AMR-WebRTC-UDP" -Direction Inbound -Protocol UDP `
  -LocalPort 8189 -Action Allow -Profile Private
```

> `8080`/`8081` 是业务网关（HTTP/WS），App 必用；`8889` 是 WHEP 信令、`18888` 是 HLS、`18554` 是 RTSP。`9090`/`1884`/`9002` 只在调试直连时才有意义，正常业务不放行也不影响 App。

防火墙规则是持久化的，**做一次即可**，重启后仍有效；只有 WSL IP 变了才需要改启动命令里的 IP。

### 2.3 启动 App 时注入 IP

```powershell
cd C:\Users\dxw\Documents\dev\amr_app
$env:JAVA_HOME = 'C:\Users\dxw\.jdks\jbr-21.0.11'
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"

# 现查现用，不硬编码 IP（本手册编写时为 192.168.0.103）
$wslIp = (wsl -d Ubuntu -- hostname -I).Trim().Split()[0]
flutter run -d emulator-5554 --dart-define=AMR_HOST=$wslIp
```

`AMR_HOST` 是编译期常量（`String.fromEnvironment`），**改了必须重新 `flutter run` / 重新装 APK**，热重载不生效。

### 2.4 什么时候选哪种

| | 方式 A：AMR_HOST + 防火墙 | 方式 B：adb reverse |
|---|---|---|
| 配置成本 | 高（防火墙需管理员 + 改启动命令 + 重启 App） | 低（`amr_start_windows.ps1` 一条命令 / 手敲 4 条） |
| 模拟器重启后 | 不用重做（IP 不变时） | **必须重做** |
| WebRTC 视频（UDP 8189） | 直连，低延迟 | 不支持 UDP，WebRTC 失败；需手动切 RTSP，+100~200ms |
| 适合场景 | 长期开发 / 对视频延迟敏感 | 临时演示、快速恢复现场 |

### 2.5 为什么不能用 `10.0.2.2`

`10.0.2.2` 是 Android 模拟器给「宿主机」预留的别名，理论上是标准做法；但本机是 **WSL2 mirrored 网络 + Hyper-V**，这条路径会被 Hyper-V 防火墙拦截，表现为**连接超时**而不是 refused。RUNBOOK §3.3 已明确标注不要使用，这里保持一致：

> ❌ 不要用 `--dart-define=AMR_HOST=10.0.2.2`。

***

## 3. 自检：逐项确认链路

按顺序做，任一项不符合就先修那一项。

### 3.1 模拟器在线

```powershell
flutter devices
# 输出里应能看到 emulator-5554
```

若找不到 `flutter` 命令，用全路径：

```powershell
C:\Users\dxw\fvm\flutter\bin\flutter.bat devices
```

### 3.2 端口映射存在

```powershell
& 'C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe' reverse --list
```

### 3.3 WSL 侧端口在监听、且已有连接

```bash
# 在 WSL 里执行
# 1) 监听状态（-l 只看 listener）：业务网关 HTTP/WS
ss -lntp | grep -E ':8080|:8081'

# 2) 已建立连接（注意这里不带 -l，-l 会过滤掉 ESTAB）
ss -tnp | grep -E ':8080|:8081'
```

判断标准：
- 监听：`0.0.0.0:8080`（网关 HTTP）、`0.0.0.0:8081`（网关 WS）；
- 连接：至少各有几条 `ESTAB`（App 的 HTTP 短连接 + WS 长连接）。没有 `ESTAB` 说明 App 还没连上，回到 §1 检查 `adb reverse`。
- 网关没起时先看 `curl http://localhost:8080/healthz`，再查 `amr_start.sh` 是否带了 `--no-gateway`。

### 3.4 地图链路是否真的通

```bash
# 在 WSL 里执行
source /opt/ros/jazzy/setup.bash
source ~/amr/amr_sim_ws/install/setup.bash

# map_server 是否已激活
ros2 lifecycle get /map_server          # 期望 active [3]

# /map 是否在发布、是否有订阅方（网关通过 rosbridge 订阅并落盘）
ros2 topic info -v /map | grep -E 'Publisher count|Subscription count|Node name'

# 网关是否已把地图落盘、HTTP 能否取到元数据
curl -s -H 'Authorization: Bearer amr-dev-token' http://127.0.0.1:8080/api/v1/map/meta
ls -l ~/.amr_gateway/maps/map.pgm ~/.amr_gateway/maps/map.json
```

期望：`Subscription count` 至少为 3（`amcl`、`global_costmap`、`rosbridge_websocket`）；出现 `rosbridge_websocket` 说明网关已经订阅上 `/map`。`/api/v1/map/meta` 返回带 `version` 的 JSON（还没落盘时是 404 `MAP_NOT_READY`）。

> 补充：`/map` 是 `TRANSIENT_LOCAL` 的 latched 话题，`map_server` 只在激活时发一次。网关的 rosbridge 客户端把订阅升级为 `transient_local`，拿到后写成 PGM + JSON（`version` = sha1）。App 不再直连 `/map`，而是通过网关 HTTP 下载 `map.pgm` 并本地缓存，所以**不需要重发地图**，网关重启也能从磁盘恢复版本。

### 3.5 App 界面

- 顶栏 `GW`、`WS`、`MQTT` 三个点**均为绿色**（`MQTT` 反映网关内部链路，断开时业务接口返回 503）；
- 地图页出现栅格地图 + 中心机器人图标，不再显示「等待地图数据…」。

### 3.6 连不上时看 App 日志

```powershell
& 'C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe' logcat -d | Select-String -Pattern 'SocketException|GatewayClient|GatewayWs'
```

---

## 4. 故障对照表

| 现象 | 最可能原因 | 处理 |
|---|---|---|
| logcat：`Connection refused, address = 127.0.0.1` | App 用默认 `AMR_HOST=127.0.0.1`，且没有 `adb reverse` | 按 §1 加 4 条 reverse |
| 地图区「等待地图数据…」+ `GW`/`WS` 灯灰 | 网关 8080/8081 没通（与上一行同源） | 同上；`curl http://localhost:8080/healthz`；再看 §3.3 是否有 `ESTAB` |
| `GW` 灯绿、`WS` 灯灰 | `8081` 没映射，或网关 WS 未监听 | 补 `adb reverse tcp:8081`；`ss -lntp \| grep 8081` |
| `GW`、`WS` 绿、`MQTT` 灯灰 | 网关与 mosquitto（1884，WSL 内部）断开 | 不用映射 1884；查 `~/arm_logs/<最新>/mosquitto.log` 与 `~/.amr_gateway/gateway.log`，业务接口此时返回 503 |
| `GW`、`WS`、`MQTT` 都绿，地图仍空白 | `/map` 没发布 / `map_server` 未 active / 网关未落盘 | `ros2 lifecycle get /map_server`；`ros2 lifecycle set /map_server activate`；再按 §3.4 查 `/api/v1/map/meta` 与 `~/.amr_gateway/maps/` |
| 地图有了，但机器人不在原点 / 无 TF | AMCL 没收到初始位姿 | 重跑 `./amr_start.sh`，或按 RUNBOOK §2.4 补发 `/initialpose`（脚本已带协方差+重试） |
| 视频页无画面 | `8889`（WHEP）/ `18554`（RTSP）没映射；或 UDP 8189 被挡 | 补 reverse；方式 B 下需在 App 相机页手动切到 RTSP |
| 刚才还好，模拟器重启后又不行 | `adb reverse` 规则随模拟器重启丢失 | 重跑 §1 |
| 改了 `AMR_HOST` 但没变化 | 它是编译期常量 | 必须重新 `flutter run` / 重装 APK |

---

## 5. 常用路径与命令

| 项 | 值 |
|---|---|
| adb | `C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe`（SDK 唯一入口；`C:\Users\dxw\AppData\Local\Android\Sdk` 只作为 junction 实体，不要直接用） |
| 启动模拟器 | `& 'C:\Users\dxw\fvm\android-sdk\emulator\emulator.exe' -avd Small_Phone` |
| Flutter SDK | `C:\Users\dxw\fvm\flutter` |
| JDK 21（构建用） | `C:\Users\dxw\.jdks\jbr-21.0.11` |
| Flutter 构建副本 | `C:\Users\dxw\Documents\dev\amr_app` |
| Flutter 源码（WSL，主） | `/home/dxw/amr/amr_app` |
| 仿真端脚本 | `~/amr/amr_start.sh` |
| 仿真端日志 | `~/arm_logs/<时间戳>/` |

启动模拟器后建议等系统完全开机，再用 `flutter devices` 确认 `emulator-5554` 已就绪，然后再做 §1。

---

## 6. 注意

- 本手册只动 Windows 侧（模拟器端口映射 / 防火墙 / App 启动参数），**不要为了修连接问题去 `pkill` WSL 里的仿真进程**。
- 仿真端是否需要启动、怎么启动，看 [RUNBOOK.md](RUNBOOK.md) 或直接用 `~/amr/amr_start.sh`。
- 如果按 §1/§3 全部做完仍连不上，先确认 WSL 侧 8080/8081 有监听（`ss -lntp`），再确认 Windows 有到 WSL 的网络路径（`Test-NetConnection <WSL_IP> -Port 8080`）。

### 6.1 相关脚本参数（与 `amr_start_windows.ps1` / `amr_web_start.ps1` 对齐）

| 参数 | 默认 | 说明 |
|---|---|---|
| `-GatewayHttpPort` | `8080` | 业务网关 HTTP；同时用于端口检查与 `adb reverse` |
| `-GatewayWsPort` | `8081` | 业务网关 WS；同时用于端口检查与 `adb reverse` |
| `-NetMode` | `mirrored` | 默认 mirrored（`AMR_HOST=localhost`/`127.0.0.1`）；`-NetMode nat` 切回 NAT（改用 WSL IP） |
| `-WslIp` | 自动探测 | NAT 模式下显式指定 WSL IP |
| `-WhepPort` / `-RtspPort` | `8889` / `18554` | 视频端口，参与 reverse 与端口检查 |
| `-Port`（仅 `amr_web_start.ps1`） | `8090` | Web 静态托管端口；dev server 用 8091，**避开网关 8080/8081** |

```powershell
# 默认：mirrored + 网关 8080/8081
.\amr_start_windows.ps1

# 自定义端口 / 切回 NAT
.\amr_start_windows.ps1 -GatewayHttpPort 8080 -GatewayWsPort 8081 -NetMode nat -WslIp 192.168.0.103
```
