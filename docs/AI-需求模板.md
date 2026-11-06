# AI 需求模板（复制后填空）

目标：让 AI 一次就定位到文件，不靠猜。**最短可用 = 目标位置 + 现象 + 期望**。

## 模板
```text
【目标位置】Android App / Web 大屏 / 仿真端 / 不确定
【页面或模块】如：地图页顶部栏、相机页健康条、Nav2 amcl 参数
【现象】看到的 vs 预期，附报错原文或截图路径
【期望】改完后应该怎样（可验收）
【复现步骤】1. 2. 3.（写清启动方式：./amr_start.sh / --video test / adb reverse）
【允许改动范围】只改 amr_app/lib/pages/ / 可改配置 / 不限
【可提供日志】~/arm_logs/<时间戳>/verify.log、adb logcat、浏览器 Console
```

## 选填（有则更好）
- 最近改过什么（`git status` 或最近一次 commit）
- 已试过什么（避免 AI 重复踩）
- 环境：Android / iOS / Web；headless / GUI；mirrored / adb reverse
- 频率：必现 / 偶现，大概多久一次

## 填哪几项能省多少来回
| 填写项 | 不填的代价 | 预计省下 |
|---|---|---|
| 目标位置 | AI 从根目录扫，多读 5–10 个文件 | 2–3 轮 |
| 现象 + 报错原文 | 只能给通用排查树 | 2 轮 |
| 复现步骤 + 启动方式 | 分不清是 App / 仿真端 / 网络哪层 | 1–2 轮 |
| 允许改动范围 | 可能动到契约、地图或不该改的层 | 1 轮返工 |
| 日志路径 | AI 会让你重跑并再抓一次 | 1 轮 |

## 示例（照抄改）
```text
【目标位置】Android App
【页面或模块】相机页，WebRTC 主通道
【现象】进 /camera 后一直 connecting，约 10s 后显示 LOST；健康条不动；
         WHEP POST 返回 400。
【期望】3s 内进入 healthy，健康条随帧率变化。
【复现步骤】1) ./amr_start.sh  2) adb reverse 四条端口  3) flutter run  4) 进相机页
【允许改动范围】只改 amr_app/lib/services/video_stream_service.dart
【可提供日志】adb logcat | grep -E 'Video|WHEP'
```

## 不要写进模板
- 长篇背景故事：只给可执行事实。
- "帮我优化一下"这类没有验收标准的目标。
- 未核对的路径：贴错路径会让 AI 白读一轮。
