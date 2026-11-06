# 实施任务队列

> ⚠️ **状态：已归档**。Task 1–6 实际已实现（下方 Status 未回填）；端口与地址以 `spec.md` 顶部说明和 `docs/RUNBOOK.md` §3.7 为准。

## 依赖关系

```
Task 1 (环境安装) → Task 2 (仿真推流) → Task 3 (RtspPlayer) → Task 4 (切换UI)
                                           ↘ Task 5 (Web平台) → Task 6 (大屏页) → Task 7 (验证)
```

---

## Task 1: 安装 mediamtx 与 gstreamer

**Priority**: high  
**Status**: pending  
**对应 AC**: AC1  
**Blocked By**: 无

### 工作内容
1. 安装 mediamtx（RTSP/HLS server）
2. 安装 gstreamer 工具链 + x264 编码器插件
3. 验证 `gst-inspect-1.0 x264enc` 可用

### Test Requirements

**TR1.1（rule）**：mediamtx 可执行文件存在且能启动
- 条件：`which mediamtx` 或二进制路径有效，`mediamtx --version` 有输出
- 证据：命令输出

**TR1.2（rule）**：gstreamer x264 编码器可用
- 条件：`gst-inspect-1.0 x264enc` 返回插件信息
- 证据：命令输出包含 `x264enc`

---

## Task 2: 仿真端 RTSP 推流 pipeline

**Priority**: high  
**Status**: pending  
**对应 AC**: AC1  
**Blocked By**: Task 1

### 工作内容
1. 创建 mediamtx 配置文件（RTSP :8554, HLS :8888, 允许推流）
2. 创建 gstreamer 推流脚本：订阅 `/camera/image_raw` → `videoconvert` → `x264enc` → `rtspclientsink` 推送至 `rtsp://localhost:8554/camera`
3. 将 mediamtx 启动 + gstreamer 推流集成到 full_bringup.launch.py（ExecuteProcess 或 Node 包装）

### Test Requirements

**TR2.1（rule）**：RTSP 推流可达
- 条件：`timeout 5 gst-launch-1.0 rtspsrc location=rtsp://localhost:8554/camera ! fakesink` 退出码 0 且有数据
- 证据：命令输出

**TR2.2（rule）**：HLS 流可达
- 条件：`curl -s http://localhost:8888/camera/index.m3u8` 返回 m3u8 内容
- 证据：curl 输出包含 `#EXTM3U`

---

## Task 3: App 端 RtspVideoPlayer 实现

**Priority**: high  
**Status**: pending  
**对应 AC**: AC2, AC3  
**Blocked By**: 无（不依赖仿真端，可并行）

### 工作内容
1. pubspec.yaml 添加 `video_player: ^2.9.0`
2. 实现 `RtspVideoPlayer implements VideoStreamPlayer`，内部用 `VideoPlayerController.network(rtspUrl)`
3. 修改 `videoStreamPlayerProvider` 为 StateNotifier 或类似机制，支持动态切换 player 实例
4. RTSP URL 通过 `AppConstants.rtspUrl`（`rtsp://$host:8554/camera`）

### Test Requirements

**TR3.1（rule）**：RtspVideoPlayer 使用 VideoPlayerController
- 条件：`RtspVideoPlayer` 类中实例化 `VideoPlayerController`，无 `Image.memory`
- 证据：代码审查

**TR3.2（rule）**：videoStreamPlayerProvider 支持切换
- 条件：可通过 ref 调用切换 player 实现，旧 player.stop() 被调用
- 证据：代码审查 + 单元测试（切换后 isRunning 状态正确）

---

## Task 4: App 相机页切换 UI

**Priority**: high  
**Status**: pending  
**对应 AC**: AC2, AC7  
**Blocked By**: Task 3

### 工作内容
1. 相机页 AppBar 加 `SegmentedButton` 或 `ToggleButtons`：rosbridge / RTSP
2. 切换时调用 provider 切换 player，StreamBuilder 重建
3. 用 SharedPreferences 持久化选择
4. 添加 `shared_preferences` 依赖

### Test Requirements

**TR4.1（rule）**：切换按钮存在且可交互
- 条件：相机页 AppBar 有两个选项按钮，点击后视觉状态切换
- 证据：UI 截图或 logcat 输出切换日志

**TR4.2（rule）**：切换后旧资源释放
- 条件：切换 10 次后无 `Stream has already been listened to` 错误
- 证据：logcat 无相关错误

---

## Task 5: Flutter Web 平台支持

**Priority**: medium  
**Status**: pending  
**对应 AC**: AC4  
**Blocked By**: 无

### 工作内容
1. `flutter create --platforms=web .`（在 amr_app 目录）
2. 处理 mqtt_client 在 Web 端的差异（mqtt_client 10.x 支持 WebSocket）
3. 确认 web_socket_channel 在 Web 端正常工作
4. `flutter pub get` 成功

### Test Requirements

**TR5.1（rule）**：web 目录生成
- 条件：`amr_app/web/index.html` 存在
- 证据：ls 输出

**TR5.2（rule）**：flutter pub get 成功
- 条件：无依赖冲突
- 证据：命令输出 "Got dependencies"

---

## Task 6: Web 大屏 DashboardPage

**Priority**: high  
**Status**: pending  
**对应 AC**: AC4, AC5, AC6  
**Blocked By**: Task 5

### 工作内容
1. 创建 `pages/dashboard_page.dart`，四象限布局：
   - 左上大区域：地图 + 机器人位姿 + 路径（复用 map/ 图层）
   - 右上：视频（HLS，用 `video_player` web 或 HTML5 `<video>`）
   - 右下：状态卡片（电量/模式/巡检进度）+ 巡检控制按钮
   - 左下：巡检点列表
2. 复用现有 providers（map_provider, tf_provider, battery_provider, mode_provider, inspection_provider）
3. Web 端视频用 HLS：`http://$host:8888/camera/index.m3u8`
4. main.dart 添加路由 `/dashboard`

### Test Requirements

**TR6.1（rule）**：DashboardPage 四区域布局存在
- 条件：页面包含地图、视频、状态、控制四个区域
- 证据：代码审查 + 截图

**TR6.2（rule）**：复用 provider 层
- 条件：DashboardPage 直接 `ref.watch` 现有 providers，无重复订阅逻辑
- 证据：代码审查

**TR6.3（rule）**：Web 端视频用 HLS
- 条件：视频播放器 URL 为 `http://$host:8888/camera/index.m3u8`
- 证据：代码审查

---

## Task 7: 全链路构建与验证

**Priority**: high  
**Status**: completed  
**对应 AC**: AC1, AC2, AC3, AC4, AC5, AC7  
**Blocked By**: Task 2, Task 4, Task 6

### 工作内容
1. `flutter build web` 构建 Web 版本
2. 启动仿真端，验证 RTSP/HLS 推流
3. App 端验证视频切换
4. Web 端验证大屏展示

### Test Requirements

**TR7.1（rule）**：flutter build web 成功
- 条件：构建无错误，输出 `amr_app/build/web/`
- 证据：构建输出

**TR7.2（rule）**：Web 大屏四区域均有数据
- 条件：浏览器打开后地图、视频、状态、控制均正常显示
- 证据：截图

**TR7.3（rule）**：App RTSP 切换后画面正常
- 条件：App 切到 RTSP 模式后有画面
- 证据：截图
