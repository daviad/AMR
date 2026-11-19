# 视频模块模拟面试问答清单

> 针对 AMR 项目 Flutter 视频模块（`amr_app/lib/services/video_stream_service.dart`）的面试问答清单。
> 按真实面试"由浅入深"的节奏组织，每题给出 **回答骨架 + 加分点 + 可能追问**。

---

## 目录

- [第一部分：开场叙述题](#第一部分开场叙述题必考)
- [第二部分：协议与选型](#第二部分协议与选型)
- [第三部分：WebRTC 底层原理](#第三部分webrtc-底层原理)
- [第四部分：可观测性与性能](#第四部分可观测性与性能)
- [第五部分：稳定性设计](#第五部分稳定性设计)
- [第六部分：架构与抽象](#第六部分架构与抽象)
- [第七部分：场景排障题](#第七部分场景排障题最容易翻车)
- [第八部分：开放追问题](#第八部分开放追问题拉深度)
- [使用建议](#使用建议)

---

## 第一部分：开场叙述题（必考）

### Q1. 简单介绍一下你这个视频模块。

**回答骨架**（60 秒内说完）：
> 这是机器人远程驾驶场景的视频模块，Flutter 一套代码跑 Android/iOS/Web。核心是解决三件事：**多链路选型、链路可观测性、故障自愈**。
> - 链路上接了 WHEP / RTSP / rosbridge JPEG / HLS 四条通路，按场景切换
> - 用 WebRTC `getStats` 做秒级差分统计，产出 fps / jitter / 丢包 / 解码 P99
> - 用 HEALTHY / DEGRADED / LOST 三态机 + 指数退避做故障恢复

**加分点**：先说场景（远程驾驶对延迟敏感），再说技术，让面试官理解你做的不是播放器而是"实时驾驶链路"。

**追问**：为什么不用现成的播放器 SDK？→ 现成 SDK 不会帮你做四链路切换和秒级健康度判定。

---

### Q2. 这个模块你最有技术含量的地方是什么？

**回答骨架**：
> 两个地方：**多协议抽象**和**健康度可观测性**。
> - 三套后端（WebRTC / RTSP / rosbridge）能力差异巨大，我用一个 `VideoStreamPlayer` 接口 + nullable getter 把"能力差异"显式建模，UI 只按枚举分派
> - 健康度不是看连接状态，而是从 `inbound-rtp` 累计值做差分算真实 fps，再叠加 jitter / freeze / 丢包做三态判定，还统计了解码耗时 P99 来区分"网络卡"和"解码卡"

**追问**：P99 解码耗时怎么用？→ 如果 P99 超过帧间隔（如 33ms），说明解码器是瓶颈，要降码流或关 B 帧，不是网络问题。

---

## 第二部分：协议与选型

### Q3. 你为什么选 WebRTC 而不是 RTSP / RTMP / HLS？

**回答骨架**：

| 协议 | 延迟 | 穿透 | 浏览器 | 我的场景适配 |
|---|---|---|---|---|
| WebRTC (WHEP) | 50–150ms | 需 UDP / ICE-TCP | 原生支持 | 主路径 |
| RTSP over TCP | 中 | 一条 TCP | 不支持 | adb 环境 fallback |
| HLS | 秒级 | 纯 HTTP 最好 | hls.js / Safari 原生 | Web 大屏 |
| RTMP | 秒级 | 一般 | 已死 | 不考虑 |

> 驾驶场景下 100ms 和 1s 的延迟差别是"能不能开"的问题，所以主路径必须 WebRTC。

**追问**：WHEP 和 WebRTC 什么关系？→ WHEP 是把 WebRTC 信令收敛到一个 HTTP POST 的标准（draft-ietf-wish-whep），解决"每个厂商信令都不一样"的问题，拉流用 WHEP、推流用 WHIP。

---

### Q4. RTSP 为什么你必须强制 TCP interleaved？

**回答骨架**：
> 我们开发环境用 `adb reverse` 做端口映射，它**只转发 TCP**。RTSP 默认会协商成 RTP over UDP，UDP 包过不去，黑屏。所以在 fvp 配置里强制 `avformat.rtsp_transport=tcp`，让所有 RTP 走 RTSP 那条 TCP 连接的 interleaved channel。

**加分点**：主动提到这是"信令通但媒体不通"的典型案例，分层排障很重要。

**追问**：RTSP over TCP 有什么代价？→ TCP 头阻塞，丢包时整流会卡；UDP 丢一包只是花一下。所以主路径还是 WebRTC。

---

### Q5. 你的 Web 大屏为什么用 HLS 而不是 WebRTC？

**回答骨架**：
> 大屏是只看不操作的场景，延迟不敏感，但**部署环境复杂**（客户浏览器、代理、防火墙不可控）。HLS 走纯 HTTP，穿透最好，Safari 原生支持、Chrome 用 hls.js 就行，运维成本最低。为几百 ms 延迟去调 WebRTC 的 ICE 不值得。

**加分点**：体现"技术选型匹配场景"，不是追求新技术。

---

## 第三部分：WebRTC 底层原理

### Q6. 描述一下 WHEP 握手流程。

**回答骨架**：
1. 客户端 `createOffer` → 必须**显式 `addTransceiver`** 声明 recvonly video，否则 offer 没有 `m=video`
2. HTTP POST 把 SDP offer 发到 `/camera/whep`，`Content-Type: application/sdp`
3. 服务端回 **201 Created**，body 是 SDP answer
4. 客户端 `setRemoteDescription(answer)`
5. ICE 开始候选交换 → DTLS 握手 → SRTP 媒体流

**加分点**：主动说出"201 只证明 TCP 8889 信令通，不代表媒体面 UDP 8189 可达"，这是两个独立验证点。

**追问**：你手写 SDP 吗？→ 不手写，`createOffer` 生成，但要**看得懂**才能排障。

---

### Q7. SDP 里哪些字段是必须的？出错了会怎样？

**回答骨架**：

| 字段 | 作用 | 缺失后果 |
|---|---|---|
| `m=video` | 声明视频媒体段 | 服务端报 `no ice-ufrag`（找不到媒体段） |
| `a=ice-ufrag` / `a=ice-pwd` | ICE 认证凭据 | ICE 建不起来 |
| `a=fingerprint` | DTLS 证书指纹 | DTLS 握手失败 |
| `a=mid` | 与 BUNDLE 对齐 | 多 m-line 时绑定失败 |
| `a=candidate` | 候选地址 | 双方都没候选则 ICE failed |

**追问**：方向字段是什么视角？→ **本端视角**，客户端 `recvonly` 时服务端 answer 应该是 `sendonly`，方向不匹配的典型表现是"连上了但 0 帧"。

---

### Q8. ICE / STUN / TURN 是干什么的？你项目用了吗？

**回答骨架**：
> - **ICE** 是框架：收集候选（host / srflx / relay）→ 配对 → 连通性检查 → 选一条能通的
> - **STUN** 让端侧知道自己 NAT 后的公网地址
> - **TURN** 在直连失败时做中继，能救连通性但增加延迟和带宽成本
>
> 我项目 `iceServers: []`，没配 STUN/TUN——纯局域网用 host 候选就够。但 `adb reverse` 场景 UDP 不过，得靠 ICE-TCP 兜底或干脆降级到 RTSP。

**追问**：怎么判断最终选了哪条候选？→ 看 `getStats` 里 `candidate-pair` 的 `nominated: true` 那一项，里面写着 local/remote candidate 类型。

---

### Q9. 为什么 `iceConnectionState = failed` 时不应该去改 SDP？

**回答骨架**：
> ICE failed 说明 SDP 交换已经完成、双方已经在尝试连通了，问题出在**网络路径**：候选不可达、防火墙拦 UDP、NAT 类型不对。这时候改 SDP 没用，应该看候选列表、测 UDP 8189 是否可达、或者换 ICE-TCP。

**加分点**：体现"分层定位"思维——信令层 / 协商层 / 连通层 / 媒体层。

---

## 第四部分：可观测性与性能

### Q10. 你怎么知道视频卡不卡？

**回答骨架**：
> 不能靠肉眼，我用 WebRTC `getStats()` 每秒拉一次，从 `inbound-rtp` 里取：
> - `framesDecoded` 差分 → 真实 fps
> - `packetsLost` 差分 → 丢包速率
> - `freezeCount` 差分 → 画面冻结次数
> - `jitter` → 抖动
> - `totalDecodeTime / framesDecoded` → 单帧解码耗时
>
> 同时从 `candidate-pair` 拿 RTT。

**追问**：为什么要差分？→ 这些字段都是**累计值**，不拿当前减上次，fps 会越算越大。这是新人最常踩的坑。

---

### Q11. 你统计 P50/P95/P99 解码耗时做什么用？

**回答骨架**：
> 把"视频卡"这个模糊感受**归因**到具体子系统：
> - P99 解码低 + fps 低 + 丢包高 → **网络问题**，降码流或换通路
> - P99 解码高 + 网络正常 → **解码器瓶颈**，换硬解 / 降分辨率 / 让推流端关 B 帧
> - P99 解码正常 + fps 正常 + 用户感觉卡 → **渲染问题**，看 UI 线程是否被阻塞
>
> 我攒 120 个样本算分位数，约 2 分钟窗口，太短噪声大、太长反应慢。

**加分点**：主动说"分位数比平均数更能暴露尾延迟"。

---

### Q12. 你怎么区分 HEALTHY / DEGRADED / LOST？

**回答骨架**（背下阈值）：
- **LOST**：≥ 3 秒没有新帧（致命）
- **DEGRADED**：fps < 2.5 **或** jitter > 200ms **或** 单秒丢包 > 5 **或** 新增 freeze（受损但还活着）
- **HEALTHY**：其余

> DEGRADED 只上报 UI 让用户知道"在卡"，**不动连接**；只有连续 3 次 LOST 才触发重连。

**追问**：为什么 DEGRADED 不重连？→ 重建 PeerConnection 有几秒黑屏，抖动时频繁重建比抖动本身更影响体验。

---

## 第五部分：稳定性设计

### Q13. 你的重连策略是怎么设计的？

**回答骨架**：
> 三层防护：
> 1. **触发条件严**：3 秒无帧判 LOST，且要连续 3 次 LOST 才动手
> 2. **指数退避**：`1 << min(attempt, 3)`，实际 2/4/8/8...秒，上限 8 秒
> 3. **成功即复位**：收到新帧就把 `attempt` 归零，避免累计惩罚
>
> 还要保证**同一时间只有一个重连定时器**，否则会雪崩式并发重建。

**追问**：为什么不用固定间隔？→ 服务端挂掉时固定间隔会让所有客户端同时打服务端，退避 + 抖动是行业标准做法（我还能再加个 jitter 随机化，目前没做）。

---

### Q14. 切换视频源时为什么要先 stop 再 create？

**回答骨架**：
> 移动端硬解解码器是**稀缺资源**，两路 H.264 同时初始化在低端机上会直接报错或黑屏。所以我的顺序是：
> 1. `stop` 旧 player，释放解码器
> 2. `notifyListeners` 让 UI 切到占位图
> 3. `create` 新 player
>
> 反过来先 create 再 stop 就会出现双路并存，必然出问题。

**追问**：那切换时的黑屏怎么优化？→ 可以保留最后一帧做封面图，或者预热新连接到 `connecting` 状态再切换（我还没做，是改进点）。

---

### Q15. 你的 start() 怎么保证幂等？

**回答骨架**：
> 每个实现的 `start()` 入口都有 `if (_running) return` / `if (_controller != null) return`。否则 UI 侧重复调用会重复订阅流、重复建 PeerConnection，状态会很乱。这是资源管理的基本功。

---

## 第六部分：架构与抽象

### Q16. 三套后端能力差异那么大，你怎么抽象？

**回答骨架**：
> 用一个 `VideoStreamPlayer` 接口暴露 `renderer` / `controller` / `frameStream` **三个 nullable getter**——`null` 显式表达"这个后端没这项能力"：
> - WebRTC 实现：有 `renderer`，暴露 `healthStream`
> - RTSP 实现：只有 `controller`
> - rosbridge 实现：只有 `frameStream`，且 `healthStream` 返回 null
>
> UI 侧按 `VideoSource` 枚举分派到 `RTCVideoView` / `VideoPlayer` / `StreamBuilder + Image.memory`，加新后端不用动 UI。

**追问**：nullable 不会让 UI 到处判空吗？→ 会，这是有意的取舍——把"能力差异"显式暴露给 UI，比强行统一接口但运行时发现能力不存在要好。

---

### Q17. 健康度监测为什么 RTSP / rosbridge 没有？

**回答骨架**：
> WebRTC 的 `getStats` 是协议自带的，浏览器/原生实现都暴露了 `inbound-rtp`。RTSP 走 `video_player`，插件层没暴露等价统计；rosbridge 就是 JPEG 帧流，连"丢包"概念都不适用（WebSocket 是可靠传输）。所以这两条链路的 `healthStream` 直接返回 null，UI 不显示健康徽章——**有监测和没监测要显式区分，不能假装有**。

**加分点**：体现"不伪造数据"的工程严谨性。

---

## 第七部分：场景排障题（最容易翻车）

### Q18. 用户反馈"视频黑屏"，你怎么排查？

**回答骨架**（分层定位）：
1. **信令层**：WHEP POST 返 201 了吗？没有 → 网络/服务端问题
2. **协商层**：SDP 里 `m=video` 有吗？方向是 `recvonly` 吗？
3. **连通层**：ICE `nominated` 的 candidate-pair 有吗？没有 → 候选/防火墙问题
4. **媒体层**：`inbound-rtp.framesDecoded` 在涨吗？不涨 → 服务端没推流或 SRTP 解密失败
5. **渲染层**：`renderer.srcObject` 绑定了吗？widget 在树里吗？尺寸是 0 吗？
6. **平台层**：这个 H.264 profile 设备硬解支持吗？（High profile 在某些低端机不支持）

**加分点**：把这六层按"信令→协商→连通→媒体→渲染→平台"背下来，面试官会知道你真排过障。

---

### Q19. 真机上能连，模拟器上连不上，你会想到什么？

**回答骨架**：
- 模拟器的 `127.0.0.1` 指向**模拟器自己**，不是宿主机，要用 `10.0.2.2`
- `adb reverse` 只转发 TCP，如果走 UDP 的 WebRTC 必挂
- 模拟器硬解支持可能和真机不同，某些 H.264 profile 解不出来

---

### Q20. 视频能播，但过几分钟就卡死，你怎么定位？

**回答骨架**：
- 看 `freezeCount` 和 `framesDecoded` 差分——确认是"没新帧"还是"有帧但渲染卡"
- 看内存曲线——rosbridge JPEG 链路如果 `StreamController` 没限流会堆积，GC 压力大
- 看解码 P99——如果随时间上升，可能是解码器内存泄漏或温度降频
- 看 `packetsLost`——如果是网络劣化，看 RTT 是否同步上升

---

## 第八部分：开放追问题（拉深度）

### Q21. 如果要支持 100 路并发看视频，你的架构要怎么改？

**回答要点**：
- 单端 100 路解码不现实 → 必须走**服务端转发 + 客户端按需订阅**
- 大屏场景用 HLS + CDN 分发
- 驾驶场景用 SFU（如 mediamtx / Janus / mediasoup）做级联
- 客户端做**码流分级**（主码流/低码流），按窗口大小选流

---

### Q22. 你怎么做端到端延迟测量？

**回答要点**：
- 推流端在帧里烧时间戳（SEI 或水印），客户端解码后对比本地时钟
- 但要注意**时钟同步**（NTP 校准）
- 简化版：推流端拍一个秒表，客户端截图对比，肉眼读差

---

### Q23. 如果让你重做一遍，你会改什么？

**回答要点**（体现自省）：
- 退避策略加 jitter 随机化，避免多客户端同步重连
- 加**端到端延迟测量**，目前只有 RTT，没有真实玻璃到玻璃延迟
- 大屏侧 HLS 可以换 LL-HLS（低延迟 HLS），把秒级压到 1-2 秒
- 切源时做**预热**，新连接 ready 再切，消除黑屏

---

## 使用建议

1. **Q1 / Q2 / Q10 / Q13 / Q18** 是最高频题，背到脱口而出
2. 第三部分（WebRTC 原理）如果被问倒，坦白"这块我用得不多但我看过"，别硬编
3. 每个回答都主动**引到代码行号**——"这块在 video_stream_service.dart 的 422 行"，让面试官感觉你真写过
4. 追问不会就说"目前没想到，但我知道可以查 RFC 8829 / WHEP draft"，展现学习路径
