# amr_app/lib/AGENTS.md — 分层与导入方向

| 目录 | 职责 | 入口 / 规模 |
|---|---|---|
| `core/` | 常量、topic、消息模型 | `constants.dart`、`topic_mapping.dart`、`message_models.dart` |
| `comm/` | rosbridge / MQTT 传输 | `rosbridge_client.dart`(191)、`mqtt_client.dart`(157) |
| `providers/` | Riverpod 状态 | `providers/data/*`、`providers/comm/*`、`providers/navigation/*` |
| `pages/` | 四个页面 | `map_page`(459)、`camera_page`(315)、`inspection_page`(256)、`dashboard_page`(256) |
| `map/` | 渲染与图层 | `map_view.dart`、`map_painter.dart`、`layers/*` |
| `services/` | 视频 / 拍照 / 落盘 | `video_stream_service.dart`(812，大文件) |
| `models/` | 数据模型 | `occupancy_grid.dart`、`command.dart`(11，再导出 `amr_contracts`) |
| `widgets/` | 复用弹窗 | `point_editor_dialog.dart`(108) |

## 规则
- 导入方向：`pages → providers → comm → models/core`。禁止反向（`comm/` 不得 import `pages/`）。
- Riverpod 不依赖 `BuildContext`：流用 `StreamProvider`，命令用 `Notifier`。
- 新增地图叠加层实现 `MapLayer` 接口，不改 `MapView` 核心。
- 超过 300 行的文件（`video_stream_service.dart`、`map_page.dart`、`packages/amr_contracts/lib/src/command.dart`）先 `grep -n` 再读 ±40 行。

## 验证
`flutter analyze lib`（只改一页时：`flutter analyze lib/pages/<page>.dart`）。
