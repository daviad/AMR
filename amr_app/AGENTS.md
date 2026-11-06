# amr_app/AGENTS.md — Flutter 端边界

只改 `lib/` 与平台配置（`web/`、`android/`、`ios/`）。不碰 `build/`、`.dart_tool/`。
`lib/` 内部的分层细则见 `lib/AGENTS.md`；任务级分流见 `../docs/AI-ROUTING.md`。

## 入口
| 文件 | 作用 |
|---|---|
| `lib/main.dart:14-51` | 启动顺序：fvp(仅非 Web) → Hive Box → 横屏 → ProviderScope |
| `lib/app.dart:25-30` | 路由：`/` 地图、`/inspection`、`/camera`、`/dashboard` |
| `lib/core/constants.dart:8-30` | `AMR_HOST` 编译期常量 + 全部端口 |
| `lib/core/topic_mapping.dart` | 再导出 `amr_contracts` 的 topic 常量（定义在 `packages/amr_contracts/lib/src/topic_mapping.dart`） |

## 易踩
1. `AMR_HOST` 是 `String.fromEnvironment`，改代码无效，必须 `--dart-define=AMR_HOST=...`；Web 端只能写裸 host（不带 scheme、不带端口）。
2. Web 路由是 hash：大屏地址 `http://localhost:8081/#/dashboard`。
3. Web/IO 分叉全部用条件导入（`dashboard_video_*.dart`、`capture_saver_*.dart`、`mqtt_client_factory_*.dart`）；新增平台文件必须成对，否则 Web 编译失败。
4. WHEP 必须显式 `addTransceiver`（`services/video_stream_service.dart:373`），否则 offer 无 `m=video` → WHEP 400。
5. 大屏页（`/dashboard`，App/Web 共用）视频固定 HLS（`pages/dashboard_page.dart:39-40`），不走 WHEP/RTSP。
6. 目标点只经 `providers/navigation/mission_command_controller.dart` 发 `amr/cmd/goal`，禁止加 rosbridge 双发。

## 验证
- `flutter analyze` / `flutter test`（改单页时可只 analyze 该文件）。
- 构建前核对副本漂移：`../tools/sync_app_check.sh`。
- Windows 构建副本：`C:\Users\dxw\Documents\dev\amr_app`；Gradle 只在 Windows 原生终端跑。
