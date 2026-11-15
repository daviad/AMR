# Android 真机网络联调手册（USB / 同网段）

> 适用：Windows 11 + WSL2（mirrored 网络）+ Flutter App + Android 真机（USB 调试）
> 对照：[WINDOWS侧操作手册.md](WINDOWS侧操作手册.md)（模拟器版）、[RUNBOOK.md](RUNBOOK.md)（仿真端启动）
> 本文全部命令与结论均为 2026-11-15 真机实测

***

## 0. 为什么模拟器能跑、换真机就"没通"

| 环节 | 模拟器 | 真机 |
|---|---|---|
| `127.0.0.1` 指谁 | 模拟器自己（靠 `adb reverse` 转给宿主机） | 手机自己（同样靠 `adb reverse`，机制一致） |
| 宿主机地址 | `10.0.2.2`（本项目被 Hyper-V 防火墙挡，禁用） | 只能用 WSL/Windows 的局域网 IP |
| 到宿主机端口的入站 | 走 adb 内部通道，**不过 Windows 防火墙** | 走物理网卡，**必须过 Windows 防火墙** |
| WebRTC 媒体 UDP 8189 | `adb reverse` 不支持，只能退 RTSP | 同左；走 Wi-Fi 直连时可用 |

一句话：模拟器从来没验证过"防火墙"这一环，真机第一次把它暴露出来。

***

## 1. 先选链路

| | 方式 A：同网段直连 | 方式 B：USB + `adb reverse` |
|---|---|---|
| `AMR_HOST` | WSL 局域网 IP（如 `192.168.0.103`） | `127.0.0.1` |
| 前提 | 手机与 PC 同一 Wi-Fi；防火墙放行 | USB 调试已授权；每次插拔重做映射 |
| 重建 APK | 需要（`AMR_HOST` 是编译期常量） | 需要 |
| WebRTC 视频（UDP 8189） | 可用，低延迟 | **不可用**，只能切 RTSP |
| 适合 | 长时间调试、看视频 | 现场没 Wi-Fi / 网络隔离严格 |

> 两条链路可以同时准备：APK 里 `AMR_HOST` 只能有一个值，所以**必须二选一**，但 `adb reverse` 可以额外设着当兜底。

***

## 2. 方式 A：同网段直连

### 2.1 取当前地址（不要硬编码）

```powershell
# Windows PowerShell
wsl -d Ubuntu -- hostname -I
```

本项目为 mirrored 网络，WSL 的 `eth0` 就是 Windows 的局域网地址；实测本次为 `192.168.0.103`，手机为 `192.168.0.102`。

### 2.2 放行防火墙（本次的根因）

先看 Windows 当前网络类别：

```powershell
Get-NetConnectionProfile | Select-Object Name,InterfaceAlias,NetworkCategory
```

本次实测 WLAN = `Public`，而建好的规则只对 `Private` 生效，于是手机 SYN 到 `192.168.0.103:9090` **超时**（不是 refused）。

管理员 PowerShell 二选一：

```powershell
# 方案 1：把已有规则的配置文件范围扩到公用（推荐，规则复用）
Set-NetFirewallRule -DisplayName 'AMR-*' -Profile Private,Public
```

```powershell
# 方案 2：把当前 Wi-Fi 改成"专用网络"（图形界面也可以）
Set-NetConnectionProfile -InterfaceAlias 'WLAN' -NetworkCategory Private
```

普通用户权限执行会报 `拒绝访问 / Windows System Error 5`，必须"以管理员身份运行 PowerShell"。

校验：

```powershell
Get-NetFirewallRule -DisplayName 'AMR-*' |
  ForEach-Object {
    $pf = $_ | Get-NetFirewallPortFilter
    '{0} | profile={1} | proto={2} | ports={3}' -f $_.DisplayName, $_.Profile, $pf.Protocol, ($pf.LocalPort -join ',')
  }
```

期望 `profile=Private, Public`，端口为 `9090,1884,8889,18554,18888`（TCP）与 `8189`（UDP）。

### 2.3 构建并安装

```powershell
cd \\wsl$\Ubuntu\home\dxw\amr
.\amr_start_windows.ps1 -AmrHost 192.168.0.103 -Mode install
```

或手动：

```powershell
flutter run -d <serial> --dart-define=AMR_HOST=192.168.0.103
```

### 2.4 在手机上验证（比在 PC 上测更有意义）

```powershell
$adb = 'C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe'
& $adb -s <serial> shell 'for p in 9090 1884 8889 18554; do toybox nc -w 2 192.168.0.103 $p </dev/null >/dev/null 2>&1 && echo "$p OK" || echo "$p FAIL"; done'
```

四个都 `OK` 才说明"手机 → PC"这条路通了；此时 App 会在 2 秒内自动重连，不需要重启。

***

## 3. 方式 B：USB + `adb reverse`

### 3.1 前置：设备真的可用

```powershell
& $adb devices
```

必须显示 `<serial>	device`。若是 `unauthorized`：解锁手机，在弹窗点"允许 USB 调试"；若是 `offline`：换线/换口，或 `adb kill-server` 后重来。

> 真机同样支持 `adb reverse`（Android 5.0+），它不是模拟器专属功能。`reverse --list` 里 transport 会显示 `UsbFfs`，模拟器则显示 `host-xx`。

### 3.2 登记 5 条映射

```powershell
$adb = 'C:\Users\dxw\fvm\android-sdk\platform-tools\adb.exe'
foreach ($p in 9090, 1884, 8889, 18554, 18888) {
  & $adb -s <serial> reverse "tcp:$p" "tcp:$p"
}
& $adb -s <serial> reverse --list
```

五条都要：`9090` rosbridge、`1884` MQTT、`8889` WHEP 信令、`18554` RTSP、`18888` HLS（大屏页）。少了 `18888` 时"地图正常但大屏页视频空白"。

> `amr_start_windows.ps1` 默认只登记前 4 条，用大屏页时手动补 `18888`。

### 3.3 在手机上自测映射

```powershell
& $adb -s <serial> shell 'for p in 9090 1884 8889 18554 18888; do toybox nc -w 2 127.0.0.1 $p </dev/null >/dev/null 2>&1 && echo "$p OK" || echo "$p FAIL"; done'
```

全 `OK` 说明 reverse 已生效。

### 3.4 构建时必须指向回环

```powershell
cd \\wsl$\Ubuntu\home\dxw\amr
.\amr_start_windows.ps1 -AmrHost 127.0.0.1 -Mode install
```

`AMR_HOST` 是 `String.fromEnvironment` 编译期常量：改代码、热重载都不生效，必须重装 APK。

### 3.5 视频只能走 RTSP

- WHEP 的 HTTP 信令走 TCP，可以 reverse；但媒体走 ICE UDP 8189，**reverse 不支持 UDP**，握手成功也出不了画面。
- 在相机页手动切到「RTSP」；RTSP over TCP 可被 reverse 承载，代价是比 WebRTC 高 100~200ms。
- 需要低延迟就回方式 A。

***

## 4. 三层自检清单

按顺序做，哪层不通过就先修哪层。

### 4.1 手机侧

```powershell
& $adb devices                              # device（不是 unauthorized/offline）
& $adb -s <serial> reverse --list           # 方式 B 才有内容
& $adb -s <serial> shell 'ip -4 addr show wlan0 | grep inet'   # 方式 A 看是否同网段
```

### 4.2 Windows 侧

```powershell
Test-NetConnection 127.0.0.1 -Port 9090                 # 方式 B 用回环
Test-NetConnection <WSL_IP> -Port 9090                  # 方式 A 用局域网 IP
Get-NetConnectionProfile | Select Name,NetworkCategory  # Public 时确认规则已覆盖
```

### 4.3 WSL 侧

```bash
ss -lntp | grep -E ':9090|:1884|:8889|:18554|:18888'   # 必须 0.0.0.0 或 *
ss -tn  | grep -E ':9090|:1884'                        # 应有 ESTAB，remote 为手机 IP 或 127.0.0.1
```

判据：有一条 `ESTAB` 且 `remote` 是手机地址（方式 A）或 `127.0.0.1`（方式 B），就说明传输层已通。

### 4.4 App 侧

```powershell
& $adb -s <serial> logcat -d -s flutter:V | Select-Object -Last 30
```

期望看到 `[Video] WHEP OK ...` 和 `RTCPeerConnectionStateConnected`；出现 `Connection timed out` 说明上一条链路还没通。

***

## 5. 故障对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| logcat：`Connection timed out ... <WSL_IP>` | 防火墙只放行了 Private，当前 Wi-Fi 是 Public | §2.2 |
| logcat：`Connection refused, address = 127.0.0.1` | APK 编译成回环但没做 `adb reverse` | §3.2 |
| `adb reverse` 报错 / `--list` 为空 | 无 `device` 状态；或 adb server 刚重启 | §3.1，重做 §3.2 |
| WS 绿、MQTT 灰 | `1884` 未映射，或 mosquitto 未启动 | 补映射；WSL 看 `ss -lntp` |
| 地图正常、大屏页视频空白 | `18888` 未映射 | 补 `adb reverse tcp:18888 tcp:18888` |
| WHEP 一直超时、切 RTSP 就有画面 | 方式 B 下 UDP 8189 无法 reverse | 属预期；要 WebRTC 用方式 A |
| 改了 `AMR_HOST` 没变化 | 编译期常量 | 重新 `flutter run` / 重装 APK |
| 重新插拔 USB 后全部失效 | reverse 规则不持久化 | 重做 §3.2；App 会自动重连 |

***

## 6. 两个最容易误判的点

1. **`SocketException ... port = 40268` 里的端口不是你配的端口。**
   真机日志里这个数字是手机分配的**本地临时端口**，每轮重连都会变（40146 → 40152 → 40268…）。真正的目标端口固定是 9090，不要照着这个数字去查服务端。
2. **`timed out` 和 `refused` 是两种故障。**
   `refused` = 包到了主机但没人监听（服务没起 / 端口没映射）；`timed out` = 包根本没到（防火墙、不同网段、IP 错）。本次真机就是 `timed out`，所以问题在防火墙而不是 rosbridge。

***

## 7. 已知问题（App 侧，待修）

实测真机连上后，rosbridge 上会累积多条 ESTAB（每 10~12 秒 +1），logcat 同时周期性出现 `Connection timed out`。

原因链：

1. `rosbridge_client.dart` 的 5s 心跳发出 `{"op":"ping"}` 后，若 10s 内没有任何消息进 `_lastMsgTime`，会判定僵死；
2. 判定僵死后走 `_onDisconnected()` → 2s 后重连，周期正好 10+2 秒；
3. `_doConnect()` 只 `_channelSub?.cancel()`，**没有 close 旧 socket**，因此每轮重连都留下一条 ESTAB。

影响：地图等 latched 话题会周期性重刷、状态灯闪烁，长时间运行会累积连接。修法是心跳改用 rosbridge 会回包的机制（或只在发送成功后计时），并在重连/断开时显式 `sink.close()`。

***

## 8. 端口速查

| 端口 | 协议 | 用途 | 需要 reverse |
|---|---|---|---|
| 9090 | WS/TCP | rosbridge（地图/遥测） | 是 |
| 1884 | TCP | MQTT（导航指令/状态） | 是 |
| 9002 | WS/TCP | MQTT over WS（仅浏览器） | 否 |
| 8889 | HTTP/TCP | WHEP 信令 | 是 |
| 18554 | RTSP/TCP | 视频兜底 | 是 |
| 18888 | HTTP/TCP | HLS（大屏页） | 是 |
| 8189 | UDP | WebRTC 媒体 | **不支持** |

> 这些端口无鉴权，只用于本地仿真网络，不要暴露到公网。
