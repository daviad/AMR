# AGENTS.md — AMR 仿真项目 AI 入口

在 Gazebo Sim 8.15 中仿真一台差速巡检 AMR（建图/导航/巡检/回充），Flutter 同一工程产出 Android/iOS/Web 三端；纯仿真，无真机。
本文件只做「去哪读」的索引；项目规则与通信契约仍以 `AI_CONTEXT.md`、`.cursorrules` 为准。

## 目录地图
| 路径 | 干什么 |
|---|---|
| `amr_start.sh` | 一键清理/编译/启动/自检（653 行，别整读，按 `section "` grep） |
| `amr_start_windows.ps1` | Windows 侧一键脚本：同步副本 + 构建/安装 App；需先跑 WSL 侧 `amr_start.sh`（本脚本只检查端口并提示） |
| `amr_web_start.ps1` | Windows 侧 Web 一键脚本：`flutter build web` + 静态服务，打开 `/#/dashboard` |
| `amr_app/` | Flutter 工程；平台差异靠条件导入分叉 |
| `amr_app/lib/` | App 源码（细则见 `amr_app/lib/AGENTS.md`） |
| `amr_sim_ws/src/` | 7 个 ROS 2 包（细则见 `amr_sim_ws/AGENTS.md`） |
| `amr_sim_ws/src/amr_nav/maps/` | 唯一地图 `indoor.yaml` + `indoor.pgm` |
| `amr_sim_ws/src/amr_gazebo/config/mediamtx.yml` | 视频端口与 `camera` / `camera_low` 路径 |
| `docs/` | 运行手册、架构、视频链路、Windows/Web 手册；`docs/RUNBOOK.md` 是唯一权威运行手册（细则见 `docs/AGENTS.md`） |
| `tools/` | WSL → Windows 副本同步与只读校验 |
| `CHECK.md` | 527 行验收单，只在做验收时按标题跳读 |
| `learn/` | 学习笔记，`.gitignore` 已排除，**不读不改** |
| `amr_sim_ws/{build,install,log}`、`amr_app/build`、`amr_app/.dart_tool` | 生成物，**不改不手写** |

## 改代码前必读的 2 个文件
1. `AI_CONTEXT.md` 第 47–69 行（§4 易错点 + §5 通信契约）；不要读全文 126 行。
2. `docs/AI-ROUTING.md` — 先按任务类型认领文件:行，再打开对应文件。

## 硬约束
- 不读不改 `learn/`。
- 不动 `build/`、`install/`、`log/`、`.dart_tool/` 等生成物。
- 改地图前先备份：`cp amr_sim_ws/src/amr_nav/maps/indoor.{pgm,yaml} /tmp/`。
- 网络、防火墙、`adb reverse` 由用户在 Windows 侧处理；AI 不启停系统 mosquitto（1883）。
- 目标点只走 MQTT `amr/cmd/goal`，禁止 rosbridge 双发。
- 改 topic/消息/接口 → 同步 `AI_CONTEXT.md` §5 + `docs/architecture.md` §5。

## 验证入口（优先脚本，不手敲长命令）
```bash
cd /home/dxw/amr
./amr_start.sh --dry-run     # 先看会 kill/删/启什么
./amr_start.sh               # 默认：清理 + 按需编译 + headless 启动 + 自检
./amr_start.sh --stop        # 只清理残留
./amr_start.sh --build       # 强制 colcon build
```
- 自检代码在 `amr_start.sh` 第 492–538 行（`section "3. 验证"`）。
- 日志：`~/arm_logs/<时间戳>/{full_bringup.log,verify.log,build.log,pids.txt}`。
- App：`flutter analyze`；Gradle/模拟器在 Windows 副本 `C:\Users\dxw\Documents\dev\amr_app` 上跑更稳。
