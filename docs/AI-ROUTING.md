# AI 任务分流表

用法：先在下面认领任务 → 只打开「先读」列的路径:行 → 按需扩展。**不要整目录扫描**。
行号基于 2026-11-06 的源码；漂移时用给出的 grep 关键词重新定位。

## 通用纪律
1. 超过 300 行的文件禁止整读：先 `grep -n "<关键词>"`，再读 ±40 行窗口。
2. 每条任务都有「不要读」列，按它跳过——跳过才是省 token 的主要手段。
3. 文档优先读指定小节，不读全文；`docs/` 各文档规模见 `docs/AGENTS.md`。

## 全局免读清单（任何任务都不先读）
| 路径 | 原因 |
|---|---|
| `learn/` | 学习笔记，`.gitignore` 排除，与工程无关 |
| `amr_sim_ws/{build,install,log}`、`amr_app/{build,.dart_tool}` | 生成物 |
| `amr_sim_ws/src/amr_nav/maps/indoor.pgm` | 二进制图像，读不了也改不了 |
| `amr_app/pubspec.lock` | 锁文件，只在依赖冲突时查 |
| `CHECK.md`（527 行） | 只在做验收时按标题跳读 |
| `docs/2026-11-02-amr-urdf-refactor-sim-diagnosis.md`（533 行） | 历史诊断流水，只在复现同一现象时 grep |

## 大文件警戒线
| 文件 | 行数 | 打开方式 |
|---|---|---|
| `amr_app/lib/services/video_stream_service.dart` | 812 | `grep -nE "class\|_deriveState\|addTransceiver\|_pollStats"` |
| `amr_start.sh` | 653 | grep `section "` 后读目标段 |
| `docs/RUNBOOK.md` | 918 | 按 § 标题跳读 |
| `docs/architecture.md` | 782 | 按 § 标题跳读 |
| `docs/视频流全链路.md` | 762 | 按 § 标题跳读 |
| `mission_bridge.py` | 434 | grep `def _on_` |
| `gst_video_source.py` | 429 | grep `def _` |
| `nav2_params.yaml` | 312 | grep 节点名后读该块 |

---

## ① App 某页面 UI 不对（布局/文字/交互）
- **先读**
  - `amr_app/lib/app.dart:25-30` — 路由表，确认页面归属。
  - `amr_app/lib/pages/<page>.dart` — 先 `grep -nE "class|Widget build"`，再读 build 区块（约 60–80 行）。
  - `amr_app/lib/widgets/point_editor_dialog.dart:1-108` — 仅当问题在点位编辑弹窗。
- **不要读**：`providers/**`、`comm/**`、`amr_sim_ws/**`、`docs/architecture.md`（纯 UI 问题 90% 不在这）。
- **验证**：`cd /home/dxw/amr/amr_app && flutter analyze lib/pages/<page>.dart`；视觉验证在 Windows 副本 `flutter run`。

## ② App 视频黑屏 / 不连 / 健康条不动
- **先读**
  - `amr_app/lib/pages/camera_page.dart:41-186` — 页面 build、`_buildVideo`(134)、`_healthBar`(186)、源切换菜单(79-95)。
  - `amr_app/lib/services/video_stream_service.dart:331-420`（连接/WHEP 协商）、`:526-560`（健康判定 `_deriveState`）、`:794-812`（provider）。
  - `amr_app/lib/core/constants.dart:15-41` — 端口与 URL 组装。
  - `amr_app/lib/main.dart:19-29` — fvp 仅非 Web 注册（RTSP 硬解依赖它）。
- **不要读**：`docs/视频流全链路.md` 全文（读 §8 排查 423-536 即可）；`mission_bridge.py`；`dashboard_page.dart`。
- **验证（先分层，别先看代码）**
  - `ffprobe -rtsp_transport tcp rtsp://127.0.0.1:18554/camera`：有流→问题在 App；无流→问题在仿真端。
  - `ros2 topic echo /video/health --once`；`tail -30 ~/arm_logs/<最新>/full_bringup.log`。

## ③ Web 大屏地图空白 / 视频不播
- **先读**
  - `amr_app/lib/pages/dashboard_page.dart:39-40`（HLS 地址）、`:97-136`（地图卡/视频卡）。
  - `amr_app/lib/services/dashboard_video_web.dart:1-46` — `HtmlElementView` + `data-hls` 机制。
  - `amr_app/web/index.html:35-54` — hls.js 胶水脚本（浏览器无原生 HLS）。
  - `amr_app/lib/providers/data/map_provider.dart:7-18` — `/map` 订阅与节流。
  - `docs/WEB大屏操作手册.md:69-101`（地址与路由）、`:131-159`（故障/常见坑）。
- **不要读**：`video_stream_service.dart`（Web 大屏不走 WHEP/RTSP，这是最常见的误读）；`camera_page.dart`；`视频流全链路.md` §6（讲的是手机端）。
- **验证**：`curl -sI http://<host>:18888/camera/index.m3u8`；`ss -lntp | grep -E '9090|18888|9002'`；浏览器 Console 看 hls 报错。

## ④ 定位 / 规划不准
- **先读**
  - `amr_sim_ws/src/amr_nav/config/nav2_params.yaml:2-16`（AMCL）、`:25-86`（controller）、`:230-247`（velocity_smoother）、`:269-290`（collision_monitor）。
  - `amr_sim_ws/src/amr_nav/maps/indoor.yaml:1-6` — 分辨率/origin，坐标对不上先看这里。
  - `amr_app/lib/providers/data/tf_provider.dart:10-32` — 位姿主源 `/amcl_pose`、`/tf` 兜底。
  - `amr_app/lib/providers/navigation/navigation_controller.dart:21-58` — 目标点只经 MQTT（状态侧）；真实发送在 `mission_command_controller.dart:58`（`amr/cmd/goal` + cmd_id 幂等）。
- **不要读**：`docs/architecture.md` 全文；所有 page/widget；`gst_video_source.py`。
- **验证**：`ros2 topic echo /amcl_pose --once`；`ros2 action list | grep navigate_to_pose`；`ros2 topic hz /cmd_vel`；trace 见 `/tmp/amr_trace.jsonl`。

## ⑤ SLAM 建图飘移 / 穿墙
- **先读**
  - `amr_sim_ws/src/amr_slam/config/cartographer_2d.lua:1-60` — grep `TRAJECTORY_BUILDER_2D`、`POSE_GRAPH`（第 51 行有已回滚的 A/B 记录）。
  - `amr_sim_ws/src/amr_description/urdf/amr_lidar.xacro:34-64` — 雷达量程/采样/噪声/自遮挡说明。
  - `amr_sim_ws/src/amr_gazebo/worlds/indoor.world` — grep `<model name=` 看墙体与碰撞体。
  - `amr_sim_ws/src/amr_slam/launch/mapping.launch.py:1-40` — 建图不启 Nav2（原因写在文件头）。
- **不要读**：`nav2_params.yaml`（建图阶段不启 Nav2）；App 全部代码；`docs/architecture.md`。
- **验证**：`ros2 topic hz /scan`（应约 10 Hz）；`ros2 topic hz /map`；建图时 `headless:=false` 用 GUI 目测墙体。

## ⑥ 重新生成地图
- **先读**
  - `docs/RUNBOOK.md:230-266` — 唯一权威步骤（含 `save_map` 卡住时的替代命令）。
  - `amr_sim_ws/src/amr_slam/scripts/save_map`（35 行，可整读）。
  - `amr_sim_ws/src/amr_nav/maps/indoor.yaml:1-6` — 产物格式。
- **不要读**：RUNBOOK 其它章节；`视频流全链路.md`；任何 App 代码。
- **验证**：`ls -l amr_sim_ws/src/amr_nav/maps/indoor.{pgm,yaml}`；`ros2 topic echo /map --once`；`colcon build --symlink-install --packages-select amr_nav`。
- **注意**：覆盖前 `cp` 备份到 `/tmp/`；建图与 Nav2 不可同时启动。

## ⑦ 一键启动失败 / 残留进程
- **先读**
  - `amr_start.sh:9-21`（选项全集）、`:286-332`（clean/deep_clean）、`:380-395`（build）、`:492-538`（验证段）。
  - `docs/RUNBOOK.md:683-706`（Q1–Q3：MQTT/Nav2 激活/充电桩）。
- **不要读**：`amr_start.sh` 全文；`docs/architecture.md`；`amr_app/**`。
- **验证**
  - `./amr_start.sh --dry-run` → `./amr_start.sh --stop`；启动失败时加 `--keep` 保留现场，再读日志。
  - `tail -50 ~/arm_logs/<最新>/verify.log`；`ros2 node list | grep -E 'mission_bridge|gst_video_source|rosbridge_websocket'`。
- **环境坑**：命令前 `env -u LD_LIBRARY_PATH`（否则 `GLIBCXX_3.4.29 not found`）；`--clean-all` 会删 fuel 缓存，执行前先问用户。

## ⑧ Android 构建 / 运行失败
- **先读**
  - `docs/WINDOWS侧操作手册.md:27-67`（方式 B：`adb reverse`，仅 TCP 兜底；默认 mirrored 用 LAN IP）、`:124-192`（逐项自检）。
  - `docs/RUNBOOK.md:267-534`（§3 App 启动）、`:730-741`（Q5 卡 Gradle / Q6 JDK）、`:831-836`（Q16 fvp 报错）。
  - `amr_app/lib/core/constants.dart:8-9` — `AMR_HOST` 是编译期常量。
- **不要读**：`amr_sim_ws/**`；`lib/**`（除非是 Dart 编译错）。
- **验证**：`adb reverse --list`；WSL 侧 `ss -lntp | grep -E '1884|9090|8889'`；**在 Windows 原生终端** `flutter run`（不要从 WSL 起 Gradle）。
- **副本漂移**：`./tools/sync_app_check.sh`（只读，退出码 0=一致，1=需同步）。
- **同步行为**：`./tools/sync_app_to_windows.ps1` 用 `robocopy /E`，默认**不删除**目标侧独有文件；要清理需显式 `-Purge`，并把 `amr_start_windows.ps1`、`amr_web_start.ps1` 一并复制到目标目录。

## ⑨ 改 WebRTC 相关
- **先读**
  - `docs/WebRTC排查与原理.md:77-93`（transceiver 与 `m=` 段）、`:164-258`（分层定位/最小复现/错误对照）。
  - `amr_app/lib/services/video_stream_service.dart:331-420` — `addTransceiver` 在 **373 行**，删了就没 `m=video`。
  - `amr_sim_ws/src/amr_gazebo/config/mediamtx.yml:25-44` — 8889 信令 / 8189 ICE / 路径 `camera`、`camera_low`。
  - `amr_app/lib/core/constants.dart:24-41` — WHEP/RTSP 地址拼接。
- **不要读**：`dashboard_video_web.dart`（Web 大屏走 HLS）；`视频流全链路.md` 全文（读 §6 278-384）。
- **验证**：用 RUNBOOK `:173-228` 的 SDP 模板 POST 到 `/camera/whep`，期望 `201 Created` 且 answer 含 `m=video`；App 日志 grep `WHEP`。

## ⑩ 新增一个 ROS 节点 / 包
- **先读**
  - `amr_sim_ws/src/amr_inspection/setup.py:1-30` — Python 包 `entry_points` 模板。
  - `amr_sim_ws/src/amr_comm/CMakeLists.txt:1-20` — 脚本安装模板。
  - `amr_sim_ws/src/amr_bringup/launch/full_bringup.launch.py:60-190` — 挂载位置与 TimerAction 时序。
  - `docs/architecture.md:114-174`（§3.1 包结构）。
- **不要读**：`AI_CONTEXT.md` 全文（改完只同步 §3/§5）；`docs/DEVELOPMENT_PLAN.md`；`amr_app/**`。
- **验证**：`colcon build --symlink-install --packages-select <pkg>`；`ros2 pkg executables <pkg>`；`ros2 node list | grep <node>`。
- **契约**：新增 topic 必须同步 `amr_app/packages/amr_contracts/lib/src/topic_mapping.dart`（`lib/core/topic_mapping.dart` 只是再导出）、`AI_CONTEXT.md` §5、`docs/architecture.md` §5。

---

## 自测表（验证这套分流是否真的省 token）

| # | 任务 | 理想读取清单 | 文件数 / 行数 | 若乱读的代价 |
|---|---|---|---|---|
| ① | 地图页顶部按钮错位 | `app.dart:25-30`(6) + `map_page.dart:55-95`(41) + grep 2 次 | 2 / ≈50 | 整读 `map_page.dart` 459 行 |
| ② | 相机页黑屏 | 先 ffprobe（0 文件）；再看 `camera_page.dart:134-215`(82) + `video_stream_service.dart:331-420`(90) | 2 / ≈170 | 整读 812 行 + 762 行视频文档 |
| ⑤ | 建图墙体飘移 | `cartographer_2d.lua:1-60`(60) + `amr_lidar.xacro:34-64`(31) + `indoor.world` grep 模型名 | 2 / ≈100 | 整读 533 行诊断流水 + 782 行架构 |
| ⑦ | `./amr_start.sh` 起不来 | `amr_start.sh:9-21`(13)、`:492-538`(47) + `RUNBOOK:683-706`(24) + `verify.log` tail | 2 / ≈85 | 整读 653 行脚本 + 918 行 RUNBOOK |

**通过标准**：4 个任务都 ≤3 个文件、≤200 行正文，且验证命令可直接执行。若某任务实际读取超过表中 3 倍，先回来修本表，而不是继续读。
