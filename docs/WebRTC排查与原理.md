# WebRTC 排查与原理（WHEP / SDP / ICE）

> 目的：把"WHEP 400 `no ice-ufrag`"这类故障的**原理**与**排查路径**讲清楚，下次遇到同类问题可以自己按层走一遍。
> 代码细节另见 [视频流全链路.md](视频流全链路.md)，本文偏原理与排障方法论。

---

## 1. 原理

### 1.1 WHEP 是什么

WHEP（WebRTC-HTTP Egress Protocol）是在 **HTTP 上完成一次 SDP 交换**的协议：

```text
客户端                                      服务端（MediaMTX）
  |  POST /camera/whep                          |
  |  Content-Type: application/sdp             |
  |  body = 本地 offer SDP                      |
  | ------------------------------------------->|
  |                                             |  创建会话、协商方向/编解码
  |  <----------------------------------------- |
  |  201 Created                               |
  |  Location: /camera/whep/<session-id>         |
  |  Content-Type: application/sdp              |
  |  body = 服务端 answer SDP                    |
  |                                             |
  |  （可选）PATCH Location + trickle ICE 片段    |
  |  （结束）DELETE Location                     |
```

- 它就是"用 HTTP 传 SDP"，不改变 WebRTC 的媒体面（媒体仍然是 RTP/RTCP，走 ICE/DTLS/SRTP）。
- WHIP 是它的**入向**版本（把媒体推给服务端），WHEP 是**出向**版本（从服务端取媒体）。两者共享同一套 HTTP 语义：`POST` 建会话 → `201 + Location` → `PATCH` 补充候选 → `DELETE` 结束。
- MediaMTX 同时提供：`POST /<path>/whep`、`Accept-Patch: application/trickle-ice-sdpfrag`、`Location` 头，返回值就是标准 WHEP 行为。

> 结论性判据：**只要你能拿到一个 HTTP 状态码（哪怕是 400/404），就说明 TCP 8889 是通的、HTTP 层是通的**，问题一定在 SDP 或更上层，与防火墙、UDP 8189 无关。

### 1.2 SDP 关键字段，以及缺了会报什么

一个能被打 MediaMTX 接受的最小 offer（媒体段部分）：

```text
v=0
o=- 0 0 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
m=video 9 UDP/TLS/RTP/SAVPF 96        ← 必须有一个媒体段
c=IN IP4 0.0.0.0
a=ice-ufrag:abcd                       ← ICE 用户名片段（凭据）
a=ice-pwd:abcdefghijklmnopqrstuvwx     ← ICE 密码（凭据）
a=ice-options:trickle
a=fingerprint:sha-256 11:22:...        ← DTLS 证书指纹
a=setup:actpass                        ← DTLS 角色协商（客户端一般 actpass）
a=mid:0                                ← 与 BUNDLE 关联的媒体标识
a=sendonly                             ← 方向（这里演示"我只发"）
a=rtpmap:96 H264/90000
a=fmtp:96 packetization-mode=1
```

| 字段 | 作用 | 缺了会怎样 |
|---|---|---|
| `m=video ...` | 声明一条媒体段（编解码、payload type、协议） | **没有任何媒体段** → 服务端解析不出 ICE 凭据，典型报错就是 `SetRemoteDescription called with no ice-ufrag` |
| `a=ice-ufrag` / `a=ice-pwd` | ICE 的 username/password fragment，用于候选校验与连通性检查 | 直接命中 `no ice-ufrag`；只有 ufrag 没有 pwd 同样会被拒 |
| `a=fingerprint` | DTLS 证书指纹，双方用它验证握手身份 | SDP 可能被接受、但 DTLS 握手失败，最终 `ICE/DTLS` 连不上（pion 侧常见报错是缺少 fingerprint / 指纹不匹配）※ |
| `a=setup` | DTLS 角色（`actpass`/`active`/`passive`） | 角色协商失败，表现为连接建立后立刻断开 ※ |
| `a=mid` | 媒体段标识，BUNDLE 用它把多条 m-line 绑到同一 5 元组 | 与 `a=group:BUNDLE` 对不上 → BUNDLE 校验失败（`bundled m-line not found` 一类）※ |
| `a=candidate` | ICE 候选（IP/端口/类型） | offer 里可以没有（等 trickle 或等服务端 answer 里的候选），但双方都没有候选时 `ICE failed` |

> ※ 标注的几条是**未实测**的推断（本次只实测了 `ice-ufrag` 缺失），用于解释"同类字段缺失通常会落在哪一层"。

方向语义（`a=sendonly` / `a=recvonly` / `a=sendrecv` / `a=inactive`）描述的是**本端**视角：

- 客户端只想收视频 → offer 里写 `recvonly`，服务端 answer 里对应 `sendonly`；
- 客户端只想推流（WHIP）→ `sendonly`；
- 方向不匹配时，最坏结果是建立了连接但拿不到 RTP（表现是"连上了、没画面"）。

### 1.3 unified-plan 与 transceiver：为什么"没有 transceiver 就没有 m= 段"

- Plan-B（旧）：一个 m-line 里塞所有 SSRC，`offerToReceiveVideo: true` 会被浏览器/库翻译成"请给我开一路视频"，由它内部补 `m=video`。
- unified-plan（现行）：**SDP 里的每条 `m=` 段都对应本端一个 `RTCRtpTransceiver`**。transceiver 是"一条媒体通道"的状态机（sender + receiver + direction）。
- 因此：**PC 里没有任何 transceiver 时，`createOffer()` 生成的就是一份没有媒体段的 SDP**——不是"少写了 ice-ufrag"，而是"连媒体段都没有"。这也解释了为什么服务端报的是 `no ice-ufrag`：它在整份 SDP 里找不到任何一条带 ICE 凭据的媒体段。
- 正确做法是显式建通道：

```dart
await pc.addTransceiver(
  kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
  init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
);
final offer = await pc.createOffer();
```

`RecvOnly` = 本端只收（MediaMTX 负责发），这正是"看摄像头"的场景。

### 1.4 ICE 面：UDP 8189 直连 vs ICE-TCP

- 默认媒体走 **UDP 8189**（MediaMTX 的 ICE 端口）。真正决定能否连上的是"候选是否可达"，而不是"信令是否成功"。
- MediaMTX 的 answer 里同时给出了 UDP 与 **TCP passive** 候选（本次实测 answer 里就有 `a=candidate:... tcp ... tcptype passive`），因此 **ICE-TCP 是一条可用的兜底路径**。
- `adb reverse` **只能转 TCP**：`adb reverse tcp:8189 tcp:8189` 会让设备内监听 8189 的流量转发到宿主机，从而让"TCP passive 候选"可达；UDP 8189 不会被转发。
- 所以：信令 200/201 只证明 TCP 8889 通；画面能不能出来，还要看 UDP 8189 是否放行，或者 ICE-TCP 是否被用上。

### 1.5 为什么 `offerToReceiveVideo` 在这里失效

| 时代/实现 | 行为 |
|---|---|
| Plan-B 时代（旧 Chrome / 旧封装） | `offerToReceiveVideo: true` 会被翻译成"创建一路视频接收"，从而生成 `m=video` |
| unified-plan + libwebrtc | 该约束已废弃，方向与媒体段由 transceiver 决定 |
| flutter_webrtc 1.6.3 Android | Dart 层把 constraints 传下去，但 `MethodCallHandlerImpl.peerConnectionCreateOffer` **根本不读这个 Map**，直接 `peerConnection.createOffer(observer)`；全仓搜 `offerToReceiveVideo` **0 命中** |

结论：写 `offerToReceiveVideo` 既不会报错，也不会起作用——它只是个被静默丢弃的字典键，最终产出一份没有媒体段的 offer。

---

## 2. 本次故障的完整证据链（按时间顺序）

1. **现象**：设备日志
   ```text
   I/flutter: [Video] WHEP failed: WHEP 400: {"status":"error","error":"SetRemoteDescription called with no ice-ufrag"}
   D/FlutterWebRTCPlugin: onConnectionChangeCLOSED
   [Video] reconnect in 2s / 4s / 8s（attempt 1..4 文案完全相同）
   ```
   关键点：能拿到 400 → 8889 通；**四次错误文案一字不差** → 确定性错误，不是网络抖动。

2. **读代码**：`amr_app/lib/services/video_stream_service.dart` 里
   ```dart
   final offer = await pc.createOffer({
     'offerToReceiveVideo': true,
     'offerToReceiveAudio': false,
   });
   ```
   建 PeerConnection 后从未 `addTransceiver`。

3. **追实现**：
   - `flutter_webrtc-1.6.3/lib/src/native/rtc_peerconnection_impl.dart` L354-L365：`createOffer([constraints])` 把 constraints 原样 `invokeMethod`；
   - `flutter_webrtc-1.6.3/android/.../MethodCallHandlerImpl.java` L2069-L2087：`peerConnectionCreateOffer(id, constraints, result)` 收下参数后**忽略**，直接 `peerConnection.createOffer(observer)`；
   - 搜 `offerToReceiveVideo`：**0 命中**（Android 侧根本不认这个键）。

4. **curl 对照实验**（Windows PowerShell → `http://localhost:8889/camera/whep`）：
   - 空 body → `HTTP/1.1 400` + `{"status":"error","error":"SetRemoteDescription called with no ice-ufrag"}`，**与日志逐字相同**；
   - 带 `m=video` + `a=ice-ufrag` + `a=ice-pwd` + `a=fingerprint` + `a=setup` + `a=mid` 的最小 SDP → **`HTTP/1.1 201 Created`**，返回 answer（含 `a=recvonly`、`a=ice-ufrag:GcPWBJkFQrGWlXCj`、多条 `a=candidate`），并带 `Location: /camera/whep/<id>` 与 `Accept-Patch`。
   - 同样端点、同样网络，只差 SDP 内容 → 400 / 201 分界，实锤是 SDP 层问题。

5. **修复**：在 `createOffer` 前加
   ```dart
   await pc.addTransceiver(
     kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
     init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
   );
   ```
   并改为无参 `createOffer()`。签名取自 `webrtc_interface-1.5.1/lib/src/rtc_rtp_transceiver.dart`（`RTCRtpTransceiverInit({direction, streams, sendEncodings})`）与 `flutter_webrtc-1.6.3` 的 `addTransceiver({track, kind, init})`。

6. **验证**：
   - `flutter analyze` → `No issues found!`；
   - `flutter build apk --debug` → 成功（`assembleDebug 5.1s`）；
   - 安装到 `emulator-5554` 后打开"摄像头"页，logcat：
     ```text
     [Video] peer state: ...Connecting
     [Video] WHEP OK http://127.0.0.1:8889/camera/whep
     [Video] peer state: ...Connected
     ```
     健康条：`视频 HEALTHY 5.0 fps · 320×240 · RTT 3 ms · jitter 15 ms · decode P50/P95 5/6 ms`。

---

## 3. 可复用的排查方法（重点）

### 3.1 分层定位法

按"从外到内"四层，每层都有独立的判据，不要跨层猜：

| 层 | 判据 | 不通时看什么 |
|---|---|---|
| ① 信令（HTTP） | 能否拿到**任意** HTTP 状态码 | `curl -I http://host:8889/`；拿不到 → TCP/端口/服务未起 |
| ② SDP（内容） | 状态码是 2xx 还是 4xx + 错误文案 | 2xx=false 时先看服务端错误，再对照 1.2 的字段表 |
| ③ ICE（连通性） | `iceConnectionState` / `connectionState` 是否 `connected`；answer 里有无候选 | `ICE failed`、候选为空、端口不可达 |
| ④ 解码/上屏 | `framesDecoded` 是否增长、`frameWidth/Height`、`decode` 耗时 | 连上了但 0 帧 → 方向不匹配/编码不支持/纹理问题 |

口诀：**信令能通不代表媒体能通；SDP 对了不代表 ICE 能通；ICE 通了不代表能出画。**

### 3.2 "能拿到 400 就说明网络通"

服务端返回 400 说明请求已经**完整到达应用层**并进入 SDP 解析阶段：

- TCP 三次握手成功（否则 curl 会报 connection refused/timeout）；
- HTTP 报文被解析（否则是 400 Bad Request 的语法错误或 431/414）；
- 因此可以**直接排除**防火墙、端口映射、UDP 8189 的嫌疑——这些只影响 ③ 层。

反过来说：如果连 400 都拿不到（超时 / refused），才需要查端口与防火墙。

### 3.3 最小可复现实验（Windows PowerShell，可直接复制）

```powershell
# 1) 准备两份 SDP：一份空，一份最小合法
Set-Content -Path .\sdp_empty.sdp -Value "" -Encoding ascii

$sdp = @"
v=0
o=- 0 0 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0
a=msid-semantic: WMS amr
m=video 9 UDP/TLS/RTP/SAVPF 96
c=IN IP4 0.0.0.0
a=rtcp:9 IN IP4 0.0.0.0
a=ice-ufrag:abcd
a=ice-pwd:abcdefghijklmnopqrstuvwx
a=ice-options:trickle
a=fingerprint:sha-256 11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00
a=setup:actpass
a=mid:0
a=sendonly
a=rtpmap:96 H264/90000
a=fmtp:96 packetization-mode=1
a=ssrc:1234 cname:amr-test
"@
Set-Content -Path .\sdp_ok.sdp -Value $sdp -Encoding ascii

# 2) 空 SDP：期望 400 + no ice-ufrag
curl.exe -sS -i -X POST http://localhost:8889/camera/whep `
  -H "Content-Type: application/sdp" -H "Accept: application/sdp" `
  --data-binary "@.\sdp_empty.sdp"

# 3) 最小合法 SDP：期望 201 Created + answer + Location
curl.exe -sS -i -X POST http://localhost:8889/camera/whep `
  -H "Content-Type: application/sdp" -H "Accept: application/sdp" `
  --data-binary "@.\sdp_ok.sdp"
```

要点：

- **不要用 `-d ""`**：PowerShell 会把空参数吃掉，curl 报 `option -d: requires parameter`；用空文件 + `--data-binary "@.\sdp_empty.sdp"`。
- 只测信令、不接媒体，`201` 之后会话会自己超时，对仿真无影响。
- 想回收会话：`curl.exe -X DELETE http://localhost:8889/camera/whep/<Location 里的 id>`（本次实测返回 404，说明简单 DELETE 路径不匹配，属正常，不影响结论）。

### 3.4 读 logcat 的关键 tag

| tag / 关键字 | 看什么 |
|---|---|
| `[Video]`（Flutter `debugPrint`） | 业务层：`WHEP failed/OK`、`peer state`、`quality -> low/main`、重连退避秒数 |
| `org.webrtc.Logging` | 原生层：ICE 候选收集、DTLS 握手、`ICE failed`、`Connection closed` |
| `sdp_offer_answer.cc` | `have-local-offer -> closed`：本地 offer 已生成但没能走到 `stable`，通常是远端拒绝/会话被关 |
| `FlutterWebRTCPlugin: onConnectionChangeCLOSED` | 连接进入 CLOSED（配合上一条判断是"建连失败"还是"中途断开"） |

**"同一错误在每次重连里逐字重复"** 是最有价值的信号：说明是确定性缺陷（代码/协议），不要去查网络抖动。

### 3.5 常见错误对照表

| 错误文案 / 现象 | 所在层 | 典型原因 |
|---|---|---|
| `SetRemoteDescription called with no ice-ufrag` | ② SDP | 没有媒体段（无 transceiver）或媒体段缺 ICE 凭据 |
| `invalid session` / `400 invalid session description` | ② SDP | SDP 版本/结构不合法、BUNDLE 与 mid 对不上 |
| `ICE failed` / `iceConnectionState: failed` | ③ ICE | 候选不可达、UDP 8189 未放行、未走 ICE-TCP |
| `404` / `Location` 指向的会话 404 | ①/② 信令-会话 | 路径写错（`/<path>/whep`）、会话已过期或被 DELETE |
| 浏览器 Console 报 CORS | ① 信令（浏览器） | 服务端 CORS 未放行页面来源（Android 原生 App 不受此限） |
| 连上了但 0 帧、`framesDecoded` 不增长 | ④ 解码/方向 | 方向不匹配、编码不支持、远端没发 |

---

## 4. 遗留与边界（未验证）

- **画面区域仍为纯黑**：健康条显示 5 fps、320×240、decode 5/6 ms，说明帧在解码；但无法判断是 Gazebo 场景本身全黑，还是纹理上屏（`RTCVideoRenderer`）有问题——需人工确认。
- **真机未验证**：本次在模拟器上额外做了 `adb reverse tcp:8889/8189/18554/1884/9090/18888`；真机没有 `adb reverse` 时，`127.0.0.1` 的方式不可用，必须换 `AMR_HOST` 为可达 IP，行为未实测。
- **UDP / ICE-TCP 未细分**：本次连接究竟走 UDP 8189 还是 TCP passive 候选，没有逐条核对候选对。
- **长稳未压测**：`quality -> low -> main` 的自动切换频率、长时间掉线恢复未做长时间观察。
- 1.2 里标 ※ 的字段缺失报错属推断，未逐一实测。
