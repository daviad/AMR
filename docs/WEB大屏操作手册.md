# Web 大屏操作手册

> 适用场景：在 Windows 上把 Flutter Web 大屏跑起来，并连上 WSL 里的仿真后端。
> 本文只写"怎么敲、怎么查"，实现原理与源码分析见 [视频流全链路.md](视频流全链路.md)。

---

## 0. 前提

| 项 | 要求 |
|---|---|
| 构建目录 | **Windows 副本** `C:\Users\dxw\Documents\dev\amr_app`（不是 WSL 里的 `/home/dxw/amr/amr_app`） |
| Flutter | Windows 侧 `flutter --version` 可用，`flutter devices` 能看到 `web-server` |
| 后端 | WSL 侧仿真 + 业务网关（HTTP 8080 / WS 8081）+ mosquitto + mediamtx 已启动 |
| 网络模式 | `.wslconfig` 为 `networkingMode=mirrored` + `hostAddressLoopback=true`（Windows 与 WSL 的 `localhost` 互通） |

端口一览：

| 用途 | 端口 | 协议 | 备注 |
|---|---|---|---|
| 业务网关 HTTP | **8080** | HTTP+JSON | Web 端业务唯一出口（鉴权/任务/地图/快照） |
| 业务网关 WS | **8081** | WebSocket | 位姿/路径/扫描/任务状态推送 |
| Web 大屏静态托管 | 8090 | HTTP | `flutter build web` 产物 + `http.server` |
| Web 大屏 dev server | 8091 | HTTP | `flutter run -d web-server`；**避开网关 WS 8081** |
| HLS（大屏视频） | 18888 | HTTP | `/camera/index.m3u8` |
| WHEP / WebRTC | 8889 + UDP 8189 | HTTP + UDP | 相机页唯一视频通路 |
| RTSP | 18554 | TCP | **Web 端不可用**，仅 App/桌面 |

> 9090（rosbridge）/ 1884（MQTT TCP）/ 9002（MQTT WS）现在是 WSL 内部与调试通道，**Web 端不再直连**，也不要拿来当业务端口。

---

## 1. 最短启动流程（照抄即可）

### 1.1 起后端（WSL 侧）

```bash
# 先自查端口是否都在监听（业务网关 + 视频 + Web 静态/开发端口）
ss -lntp | grep -E ':(8080|8081|8889|18888|18554)'
```

期望能看到 `8080`、`8081`、`8889`、`18888`、`18554`。缺哪个就按 [RUNBOOK.md](RUNBOOK.md) 对应章节补起（仿真、业务网关、mediamtx）。`9090`/`1884`/`9002` 只有调试时才需要，不属于 Web 端必查项。

### 1.2 进 Windows 副本并拉依赖

```powershell
cd C:\Users\dxw\Documents\dev\amr_app
flutter pub get
```

> 若同时并行改了 WSL 源仓库，先用 `tools/sync_app_to_windows.ps1 -Check` 确认副本是最新的，再 `pub get`。

### 1.3 启动 Web 大屏

```powershell
flutter run -d web-server --web-port=8091 --dart-define=AMR_HOST=localhost
```

> dev server 用 **8091**：8080/8081 已被业务网关占用，8081 更是网关 WS 端口，撞上会直接 `EADDRINUSE`。

- **不要加 `--wasm`**：工程里有三处条件导入判 `dart.library.html`，wasm 下会退回 `dart:io`，直接编译失败。
- 改了 `--dart-define` 必须**停掉重跑**，热重载不会生效。

### 1.4 打开页面

```text
http://localhost:8091/#/dashboard
```

`#/dashboard` **必须带**：工程用的是普通 `routes`（hash 路由），不带 hash 会落到默认的地图页。

---

## 2. 地址与路由

### 2.1 `AMR_HOST` 写什么

- 只能写**裸主机名或 IP**：`localhost`、`192.168.0.103`。
- **不能**写 `http://localhost`，**不能**带端口（`localhost:8889`）。代码是字符串拼接 `http://$host:端口/...`，带了 scheme 会拼成 `http://http://...`。
- 当前 mirrored 网络模式下，`localhost` 就够：Windows ↔ WSL 的 localhost 互通，**不需要** `netsh portproxy`，也**不需要** WSL 的 LAN IP。
- 只有把 `.wslconfig` 改回 **NAT 模式**时，才需要：

  ```powershell
  flutter run -d web-server --web-port=8091 --dart-define=AMR_HOST=192.168.0.103
  ```

  并在 Windows 防火墙放行入站（当时用的就是 `192.168.0.103`）。

### 2.2 各页面的后端地址（代码内置，不用改）

| 能力 | 地址 | 说明 |
|---|---|---|
| 业务网关 HTTP | `http://<host>:8080` | 鉴权 `/api/v1/auth/login`、地图 `/api/v1/map/meta` + `/api/v1/map/pgm`、任务 `/api/v1/tasks`、锁 `/api/v1/lock`、快照 `/api/v1/snapshot` |
| 业务网关 WS | `ws://<host>:8081/ws?token=...` | 位姿/路径/扫描/任务状态推送 |
| 大屏视频 | `http://<host>:18888/camera/index.m3u8` + 本地 `hls.min.js` | 固定 HLS |
| 相机页视频 | WebRTC(WHEP `:8889`) | Web 上只有这一条，**不能用 RTSP**；拍照/单帧走网关 `/api/v1/snapshot` |

### 2.3 路由

| 地址 | 页面 |
|---|---|
| `http://localhost:8091/#/dashboard` | 大屏 |
| `http://localhost:8091/`（不带 hash） | 地图页（默认路由） |

---

## 3. 自检清单

Windows PowerShell 里逐条执行（`curl.exe` 是 Windows 自带的 curl）：

```powershell
curl.exe -sS http://localhost:8091/                          # 返回 index.html
curl.exe -I  http://localhost:8091/main.dart.js              # 200
curl.exe -I  http://localhost:8091/hls.min.js                # 200
curl.exe -sS http://localhost:8080/healthz                   # 200 {"ok":true,...}
curl.exe -I  http://localhost:8081/                          # 400/426（网关 WS 端点活着即正常）
curl.exe -I  http://localhost:18888/camera/index.m3u8        # 302 或 200
curl.exe -I  http://localhost:8889/                          # WHEP 端点有响应
```

浏览器里再确认：

- [ ] 顶部 `GW` / `WS` / `MQTT` 指示灯**均为绿色**（`MQTT` 是网关内部状态，断开会红灯并让业务接口返回 503）
- [ ] 地图能加载出栅格
- [ ] 大屏视频区出画
- [ ] 相机页能切到 WebRTC（WHEP）
- [ ] 帧规格与预期一致：**当前实际码流是 320×240 @ 5fps**（比 `视频流全链路.md` 里写的 640×480 小，属 gst 推流实际输出，不是故障）

后端端口自查（WSL）：

```bash
ss -lntp | grep -E ':(8080|8081|8889|18888|18554)'
```

---

## 4. 故障对照表

| 现象 | 最可能原因 | 处理 |
|---|---|---|
| `GW` 灯红 / 所有页面 503 | 网关 HTTP 8080 不通，或网关内部 MQTT 断开 | `curl.exe -sS http://localhost:8080/healthz`；看 `~/.amr_gateway/gateway.log` 与 `MQTT` 灯 |
| 地图一直转圈，但 `GW` 绿 | 网关 WS 8081 不通 | `ss -lntp \| grep 8081`；`curl.exe -I http://localhost:8081/` 应有响应；确认 `amr_start.sh` 没带 `--no-gateway` |
| 大屏视频黑屏，Console 报 CORS | HLS 的 `hlsAllowOrigins` 未包含页面来源 | 检查 mediamtx 配置里的 HLS CORS 设置（当前已配好，改过端口/来源才需调整） |
| 相机页一直 LOST | WHEP CORS 未放行，或 UDP 8189 没通 | 先确认 `:8889` 可达；再确认 Windows 防火墙放行 UDP 8189 |
| 页面白屏 / 404 | 路由没带 `#/dashboard` | 改用带 hash 的地址 |
| 页面能开但视频永远旧画面 | 浏览器缓存了旧的 `main.dart.js` | `Ctrl+F5` 强刷，或换端口重跑 |
| 改了代码刷新没变化 | 同上 | `Ctrl+F5`；仍不行就停掉重跑 |
| `flutter run` 报 web 编译错误、提示 `dart:io` | 加了 `--wasm` | 去掉 `--wasm` |
| 连不上后端但 WSL 里 `curl` 正常 | Windows 侧用了 NAT 模式的地址 | 改回 mirrored，或改用 WSL LAN IP 并放行防火墙 |
| Web 端想播 RTSP | Web 不支持 RTSP | 大屏用 HLS；相机页用 WHEP |

---

## 5. 常见坑

1. **固定端口会吃到旧构建产物**：`flutter run --web-port=8091` 下反复改代码，浏览器可能一直拿旧的 `main.dart.js`。先 `Ctrl+F5`，不行就换个端口（如 8092）。
2. **`AMR_HOST` 不能带 scheme / 端口**（见 2.1），拼错的表现是"所有后端都连不上"。
3. **别把 Web 端口配到 8080/8081**：这两个是业务网关（HTTP/WS），撞上会 `EADDRINUSE`；静态托管 8090、dev server 8091。
4. **不要加 `--wasm`**：已确认会编译失败（条件导入回落 `dart:io`）。
5. **不要在 Web 端找 RTSP**：`video_player` 在 Web 上没有 RTSP 后端。
6. **改 `--dart-define` 要重启**，热重载只刷新 Dart 代码，不重注入编译期常量。
7. **原生插件（fvp / flutter_webrtc 的 native 部分）与 Web 无关**：Web 端视频只用 `hls.min.js` 播放。

---

## 6. 生产式部署（可选）

```powershell
cd C:\Users\dxw\Documents\dev\amr_app
flutter build web --release --dart-define=AMR_HOST=localhost
```

产物在 `build\web`，任选一种静态托管：

```powershell
cd build\web
python -m http.server 8090
```

- IIS：把 `build\web` 设为站点物理路径，默认文档 `index.html`。
- nginx：`root <...>\build\web; try_files $uri $uri/ /index.html;`（hash 路由下 `try_files` 也可省略）。

> `AMR_HOST` 是**构建期**注入的，release 包换后端地址必须重新 build。

---

## 7. 尚未实测（保留为未验证）

- [ ] 浏览器（Chrome/Edge）实际出画：HLS 首帧时间、持续帧率、端到端延迟
- [ ] 相机页 WHEP 在浏览器里出画（含 CORS + UDP 8189 全放行的组合）
- [ ] Windows 防火墙放行 UDP 8189 前后 WebRTC 的差异对比
- [ ] IIS / nginx 生产托管路径与缓存头
- [ ] NAT 模式（`AMR_HOST=192.168.0.103`）下的完整复测

> 已核实、无需再验的边界：`--wasm` 不可用；Web 端无 RTSP；当前码流 320×240 @ 5fps；`#/dashboard` 必须带 hash。
