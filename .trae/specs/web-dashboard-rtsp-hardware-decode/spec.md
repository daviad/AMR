# 规格：Web 后台大屏 + RTSP 视频流 + 硬解码

> ⚠️ **状态：已归档（2026-10-28 历史规格）**。当前实现已不同：RTSP `18554`、HLS `18888`、WHEP `8889`（ICE `8189`），路径 `camera` / `camera_low`；App 主视频走 WHEP，HLS 供大屏页，RTSP 为手动兜底；`/dashboard` 是 Android/Web 共享路由。权威说明见 `docs/RUNBOOK.md` §3.7 与 `docs/视频流全链路.md`。

## 问题陈述

当前 AMR 系统仅通过 Android App 访问，视频流仅支持 rosbridge CompressedImage（JPEG 软解）。需要：
1. 新增 Web 后台大屏，支持桌面浏览器监控与控制
2. App 端视频流支持在「rosbridge JPEG」与「RTSP H.264」之间切换
3. 视频播放统一走硬件解码，降低 CPU 占用

## 用户与目标

| 用户 | 目标 |
|---|---|
| 运维人员（Web 大屏） | 在桌面浏览器查看地图、机器人位姿、视频、状态，执行巡检控制 |
| 现场人员（App） | 按需切换视频流方式（低延迟 JPEG / 高质量硬解 RTSP） |

## 范围（In Scope）

1. **仿真端 RTSP 推流**：mediamtx + gstreamer，将 `/camera/image_raw` 编码为 H.264，提供 RTSP + HLS
2. **App 视频流切换**：相机页新增源切换按钮（rosbridge / RTSP），RTSP 走 `video_player` 硬解
3. **Web 后台大屏**：Flutter Web 单页，含地图+位姿+视频+状态+巡检控制

## 非目标（Out of Scope）

- 多机器人支持
- Web 端巡检点/路线 CRUD（仅展示与启动）
- 录像/回放功能
- 真机部署（仅仿真环境）

## 功能需求

### FR1 仿真端 RTSP 推流
- 系统启动时自动运行 mediamtx（RTSP :8554 + HLS :8888）
- gstreamer pipeline 订阅 `/camera/image_raw`，编码 H.264，推送至 `rtsp://localhost:8554/camera`
- mediamtx 提供 HLS：`http://localhost:8888/camera/index.m3u8`
- 推流延迟 < 500ms

### FR2 App 视频流切换
- 相机页顶部提供切换按钮：「rosbridge」/「RTSP」
- rosbridge 模式：现有 `RosbridgeCompressedPlayer`（JPEG）
- RTSP 模式：`RtspVideoPlayer` 用 `video_player` 播放 `rtsp://<host>:8554/camera`，硬解 H.264
- 切换时释放旧播放器资源，启动新播放器
- 切换状态持久化（SharedPreferences）

### FR3 Web 后台大屏
- Flutter Web 构建，浏览器访问 `http://<host>:<port>`
- 大屏页面包含：
  - 左侧：地图（/map）+ 机器人位姿（/tf）+ 导航路径（/plan）
  - 右上：视频画面（HLS）
  - 右下：机器人状态（电量/模式/巡检进度）+ 巡检控制按钮
- 复用 App 的 rosbridge_client、mqtt_client、provider 层
- Web 端视频用 HLS（`http://<host>:8888/camera/index.m3u8`）

## 非功能需求

- **性能**：RTSP 硬解后 App CPU 占用较 JPEG 软解降低 ≥30%
- **兼容性**：Web 大屏支持 Chrome/Edge 最新版
- **延迟**：Web 端视频延迟 < 2s（HLS）
- **可用性**：切换视频流不崩溃，无内存泄漏

## 约束与依赖

| 项 | 说明 |
|---|---|
| mediamtx | 需用户 `sudo apt install` 或下载二进制 |
| gstreamer | 需安装 `gstreamer1.0-tools gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly`（含 x264 编码器） |
| video_player | Flutter 官方库，Android 端用 ExoPlayer 硬解 |
| Web HLS | 浏览器原生不支持 RTSP，通过 mediamtx 转 HLS |
| Flutter Web | amr_app 需 `flutter create --platforms=web .` |

## 假设

- 仿真端与 Web/App 在同一局域网，端口 8554/8888 可达
- Android 模拟器通过 `10.0.2.2` 访问主机 RTSP/HLS 服务
- mediamtx 绑定 `0.0.0.0`

## 待确认问题

- mediamtx 安装方式：apt 还是下载二进制？（需用户确认，影响 tasks 拆分）
- Web 大屏是否需要独立端口部署，还是 `flutter run -d chrome` 调试即可？

---

## 验收标准

### AC1 仿真端 RTSP 推流可用（rule）
**条件**：启动 full_bringup 后，`ffplay rtsp://localhost:8554/camera` 或 VLC 能看到摄像头画面。
**证据**：`gst-launch-1.0 rtspsrc location=rtsp://localhost:8554/camera ! fakesink` 不报错，或保存一帧 H.264 解码后与 /camera/image_raw 内容一致。

### AC2 App 视频源切换功能（rule）
**条件**：相机页有「rosbridge」「RTSP」两个按钮，点击切换后视频源切换，旧播放器释放。
**证据**：切换后 logcat 输出 `[Video] switching to RTSP` 或 `[Video] switching to rosbridge`，且画面正常。

### AC3 RTSP 模式硬解码（rule）
**条件**：RTSP 模式下 App 使用 `video_player` 播放，不使用 `Image.memory`。
**证据**：代码中 `RtspVideoPlayer` 使用 `VideoPlayerController`，无 `base64Decode`/`Image.memory` 调用。

### AC4 Web 大屏可访问且展示完整（rule）
**条件**：`flutter build web` 成功，浏览器打开后显示地图、机器人位姿、视频、状态、巡检控制。
**证据**：构建无报错，页面 4 个区域均有数据渲染。

### AC5 Web 端视频播放（rule）
**条件**：Web 大屏视频区域通过 HLS 播放摄像头画面。
**证据**：浏览器 DevTools Network 有 `.m3u8` 和 `.ts` 请求，视频区域有画面。

### AC6 复用通信层（rubric）
**维度**：Web 大屏与 App 共享 rosbridge/mqtt/provider 代码的程度。
**评分**：0=完全重复，1=部分共享，2=完全复用（仅新增 DashboardPage，通信层零修改或仅 Web 适配）。
**通过阈值**：≥ 1
**证据**：`lib/providers/`、`lib/comm/` 目录无重复实现。

### AC7 切换无内存泄漏（rule）
**条件**：反复切换视频源 10 次，App 不崩溃，无未取消的 StreamSubscription。
**证据**：logcat 无 `Bad state: Stream has already been listened to` 或内存持续增长报错。
