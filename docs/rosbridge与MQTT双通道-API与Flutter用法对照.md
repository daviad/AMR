# rosbridge 与 MQTT 双通道：API 契约与 Flutter 用法对照

本文回答两个问题：App 里为什么同时存在两条连接，以及"遥测走 rosbridge、指令走 MQTT"在**接口层**和 **Flutter 代码层**分别意味着什么。读完应能回答：`rosConnectionProvider` 为什么是 `StreamProvider`、`missionCommandProvider` 为什么是可调方法的对象、换一种写法会坏在哪。

> 读者假设：熟悉 Android/iOS 与架构，但对 Flutter 只是初学。每个 Flutter/Dart 术语首次出现时会用一句话解释。

---

## 1. 定位与端点

两条连接的职责是**单向切开**的，不是"两条等价的备份链路"。

| | rosbridge（遥测） | MQTT（指令） |
|---|---|---|
| 方向 | 机器人 → App，只读 | 双向：App → 机器人发命令，机器人 → App 回执 |
| 承载内容 | `/map`、`/scan`、`/tf`、`/odom`、`/amcl_pose`、`/plan`、`/camera/image_raw/compressed` | `amr/cmd/goal`、`cancel`、`mode`、`estop`、`inspection/*`、`return_charge`，回执 `amr/cmd/ack`、`feedback`、`result`、`amr/trace` |
| 地址 | `ws://<host>:9090`（[constants.dart:15](file:///home/dxw/amr/amr_app/lib/core/constants.dart#L15)、[constants.dart:35](file:///home/dxw/amr/amr_app/lib/core/constants.dart#L35)） | 移动端 TCP `1884`、Web 端 WebSocket `9002`（[constants.dart:21](file:///home/dxw/amr/amr_app/lib/core/constants.dart#L21)、[constants.dart:24](file:///home/dxw/amr/amr_app/lib/core/constants.dart#L24)） |
| 协议 | 原生 WebSocket + rosbridge JSON | MQTT 3.1.1（`mqtt_client` 10.2.1） |
| 服务端 | `rosbridge_websocket`，监听 `address: ''`（所有网卡，[rosbridge.launch.py:18-22](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/launch/rosbridge.launch.py#L18-L22)） | `mosquitto`，两个 listener 都绑 `0.0.0.0`（[mosquitto.conf:3-8](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/config/mosquitto.conf#L3-L8)） |
| 客户端类 | `RosbridgeClient`（手写协议） | `AppMqttClient`（封装现成库） |
| 保活 | 5s 一次 `{"op":"ping"}`，10s 无消息判死（[rosbridge_client.dart:108-119](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L108-L119)） | 库内置 `keepAlivePeriod=30`（[mqtt_client.dart:46](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L46)） |
| 重连 | 固定 2s 重试（[rosbridge_client.dart:101-106](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L101-L106)） | 库 `autoReconnect` + 5s 手动兜底轮询（[mqtt_client.dart:47-48](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L47-L48)、[L68-78](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L68-L78)） |

---

## 2. 报文格式

**rosbridge：一条连接上多路复用，用 `op` 字段区分动作。** App 实际用到 5 个 op（[rosbridge_protocol.dart:9-34](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_protocol.dart#L9-L34)）：`subscribe` / `unsubscribe` / `advertise` / `publish` / `ping`。

订阅报文的可选字段是 `type`、`queue_length`（本地队列深度）、`throttle_rate`（毫秒节流）、`qos`：

```json
{"op":"subscribe","topic":"/map","type":"nav_msgs/OccupancyGrid",
 "queue_length":1,"throttle_rate":500,
 "qos":{"durability":"transient_local","reliability":"reliable","history":"keep_last","depth":1}}
```

回包统一是 `{"op":"publish","topic":...,"msg":{...}}`，`msg` 内部按 ROS 消息类型序列化（`nav_msgs/OccupancyGrid` 的 `info` + `data` 数组等）。

**MQTT：一个 topic 一种语义，payload 是纯 JSON**，结构由共享包 `amr_contracts` 定义。下行命令信封（[message_models.dart:10-31](file:///home/dxw/amr/amr_app/packages/amr_contracts/lib/src/message_models.dart#L10-L31)）：

```json
{"cmd_id":"cmd-1a2b-9f8e","trace_id":"trace-...","type":"NAVIGATE_TO_POSE",
 "timestamp_ms":1699312000000,"ttl_ms":8000,
 "payload":{"frame_id":"map","x":1.2,"y":0.5,"theta":0.0}}
```

回执三类：`ack`（`status`/`error_code`/`latency_ms`）、`feedback`（`nav_state`/`number_of_recoveries`/`distance_remaining`/`eta_sec`/`heartbeat`）、`result`（`status`/`error_code`/`error_msg`），解析见 [command.dart:78-175](file:///home/dxw/amr/amr_app/packages/amr_contracts/lib/src/command.dart#L78-L175)。

差别可以一句话记住：**rosbridge 的 `topic` 是路由字段，MQTT 的 `topic` 是业务字段。** 所以 MQTT 一侧出现了"用 3 个 topic 分流 3 种回执"的设计，rosbridge 永远只有一种 `publish`。

---

## 3. 交互模型：纯订阅 vs 应用层伪 RPC

**rosbridge 是纯订阅推送，没有请求-响应。** 全仓库没有 `call_service` 调用；`RosbridgeClient.publish()` 虽然定义了（[rosbridge_client.dart:166-171](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L166-L171)），但 `lib/` 下**没有任何调用点**。唯一"一次性取数"是拍照：`subscribe('/camera/image_raw/compressed').first.timeout(6s)` 后立即退订（[photo_capture_service.dart:18-25](file:///home/dxw/amr/amr_app/lib/services/photo_capture_service.dart#L18-L25)）——这是客户端技巧，不是协议能力。

**MQTT 是 pub/sub 传输 + 应用层伪 RPC。** `mission_bridge.py` 在 `/amr/cmd/goal` 上收请求，把 ACK/Feedback/Result 发到三个不同 topic，靠 `cmd_id` 关联（校验点：[mission_command_controller.dart:182](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart#L182)、[L199](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart#L199)、[L213](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart#L213)）。

和真 RPC 相比缺三样：没有统一响应通道、协议层没有 call-id 回带、没有"响应必然到达"的语义。这三样都靠应用层自己补（状态机 + 超时 + 重发 + 服务端回放）。

---

## 4. 确认与重试

| | rosbridge | MQTT |
|---|---|---|
| 送达确认 | **无**。`subscribe`/`publish` 都没有响应报文，只能"看有没有数据来" | QoS1 的 PUBACK 由 broker 保证 |
| 发布 QoS | 不适用 | `publishCommand` 硬编码 `atLeastOnce`（[mqtt_client.dart:140-144](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L140-L144)） |
| 订阅 QoS | 每条订阅自己声明，且受首订阅锁定（见第 6 节） | `ack`/`result` = 1，`feedback` = 0（[mission_command_controller.dart:47](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart#L47)、[L50](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart#L50)、[L53](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart#L53)；对应服务端 [mqtt_client.yaml:82-96](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/config/mqtt_client.yaml#L82-L96)，分级理由见 [constants.dart:16-20](file:///home/dxw/amr/amr_app/lib/core/constants.dart#L16-L20)） |
| 应用层重试 | 无 | `retry()` 复用同一 `cmd_id` 重发（[mission_command_controller.dart:124-134](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart#L124-L134)） |
| 服务端幂等 | 不适用（只读） | `_seen` 缓存 256 条，重复 `cmd_id` 只回放不重执行（[mission_bridge.py:144-162](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/scripts/mission_bridge.py#L144-L162)、[L376-382](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/scripts/mission_bridge.py#L376-L382)） |
| 超时 | 无（靠 10s 心跳判死） | ack 1.2s / feedback 3s（每条 feedback 重置）/ result 120s / cancel 5s（[mission_command_controller.dart:144-166](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart#L144-L166)） |

一个反直觉点：`retry()` 重发的是**原封不动的旧信封**，里面 `timestamp_ms` 还是创建时刻；服务端按 `now - timestamp_ms > ttl_ms(8000)` 判 `EXPIRED`（[mission_bridge.py:134-142](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/scripts/mission_bridge.py#L134-L142)）。所以 8 秒后再点"重发"必然失败。

---

## 5. 错误模型

- **rosbridge：三层都被弱化。** WS `onError` 的参数被丢弃（`onError: (_) => _onDisconnected()`，[rosbridge_client.dart:55](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L55)），关闭码不读；服务端返回的 `{"op":"status","level":"error","msg":"..."}`（如订阅类型写错）在 `_onData` 里被 `if (json['op'] == 'publish')` 直接过滤（[L76-86](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L76-L86)）。结果：**订阅失败是静默的**，表现为"一直没有数据"。
- **MQTT：传输层错误静默、业务层错误结构化。** `connect()` 的 catch 只做 disconnect（[mqtt_client.dart:60-64](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L60-L64)），CONNACK 返回码不读；但业务错误被建模成 `errorCode`：`NOT_PUBLISHED` / `ACK_REJECTED` / `ACK_TIMEOUT` / `RESULT_TIMEOUT` / `CANCEL_TIMEOUT` / `EXPIRED`（[command.dart:240-245](file:///home/dxw/amr/amr_app/packages/amr_contracts/lib/src/command.dart#L240-L245)、[L284-322](file:///home/dxw/amr/amr_app/packages/amr_contracts/lib/src/command.dart#L284-L322)），并显示到任务卡。

---

## 6. 会话与状态语义

- **`/map` 的 latched 语义 + QoS 首订阅锁定**：QoS 机制本身已在 [rosbridge-QoS与latched话题.md](file:///home/dxw/amr/docs/rosbridge-QoS与latched话题.md) 详解，本文不重复。只需记住结论：rosbridge 按 topic 复用 DDS 订阅，**第一个订阅者的 QoS 决定全局**（该文档 §3.2），所以 App 必须显式声明 `transient_local`（[map_provider.dart:13-18](file:///home/dxw/amr/amr_app/lib/providers/data/map_provider.dart#L13-L18)、[map_provider.dart:20-31](file:///home/dxw/amr/amr_app/lib/providers/data/map_provider.dart#L20-L31)），并且**依赖"App 是第一个订阅者"这个顺序假设**（护栏思路见该文档 §8）。
- **MQTT 无会话**：`startClean()`（[mqtt_client.dart:54-59](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L54-L59)）+ broker `persistence false`（[mosquitto.conf:10-11](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/config/mosquitto.conf#L10-L11)）→ 断线期间的消息全部丢弃、重连不补。
- **retained 只给了状态类**：`amr/status/battery`、`amr/status/mode`、`amr/status/video`、`amr/status/video_metrics` 是 `retained: true`（[mqtt_client.yaml:62-76](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/config/mqtt_client.yaml#L62-L76)、[L102-111](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/config/mqtt_client.yaml#L102-L111)）；**`ack`/`feedback`/`result` 全部 `retained: false`**（[mqtt_client.yaml:82-96](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/config/mqtt_client.yaml#L82-L96)）。

后果：App 断线错过 Result，只能靠 `retry()` 让服务端回放；而 `retry()` 又受第 4 节的 TTL 限制。

---

## 7. 安全边界（不对称）

- rosbridge：`address: ''` + 无 SSL + 无鉴权，但代码里**只订阅不发布**，危害限于"被旁观"。
- MQTT：两个 listener 都 `allow_anonymous true`（[mosquitto.conf:3-8](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/config/mosquitto.conf#L3-L8)），而 `amr/cmd/estop`、`amr/cmd/goal` 是**可写的物理控制通道**。同网段任何主机一条 `mosquitto_pub` 即可急停或挪车。

当前的安全模型只剩"局域网可信"这一条假设。

---

## 8. Flutter 层：两个客户端类的手法差异

两者对外签名很像（都是 `Stream<Map<String,dynamic>> subscribe(...)`），内部一份手写、一份薄封装。

**`RosbridgeClient`：协议细节全在 App 里**（[rosbridge_client.dart:12-193](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L12-L193)）

```dart
// subscribe：自己维护"topic → 多个 StreamController"的分发表 + 记住订阅参数
Stream<Map<String, dynamic>> subscribe(String topic,
    {String? type, int queueLength = 1, int? throttleRate,
     Map<String, dynamic>? qos}) {
  _subParams[topic] = _SubParams(type: type, queueLength: queueLength, ...); // L138
  late StreamController<Map<String, dynamic>> controller;
  controller = StreamController<Map<String, dynamic>>.broadcast(
    onListen: () {
      _listeners.putIfAbsent(topic, () => []).add(controller);
      _send(rosSubscribe(topic, type: type, ...));  // 自己拼 JSON
    },
    onCancel: () {
      _listeners[topic]?.remove(controller);
      if ((_listeners[topic]?.isEmpty ?? true)) {
        _listeners.remove(topic);
        _subParams.remove(topic);
        _send(rosUnsubscribe(topic));               // 最后一个订阅者走才真退订
      }
    },
  );
  return controller.stream;
}
```
（[rosbridge_client.dart:131-163](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L131-L163)）

**`AppMqttClient`：连接/心跳/重连交给库**（[mqtt_client.dart:17-157](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L17-L157)）

```dart
Future<void> connect() async {
  final client = createMqttClient(host, clientId, port, AppConstants.mqttWsPort);
  client.keepAlivePeriod = 30;                  // 库管心跳
  client.autoReconnect = true;                  // 库管重连
  client.resubscribeOnAutoReconnect = true;     // 库管重订阅
  client.onConnected = () { _connController.add(true); _resubscribeAll(); };
  client.onDisconnected = () => _connController.add(false);
  client.connectionMessage = MqttConnectMessage()...startClean();
  try { await client.connect(); } catch (_) { client.disconnect(); }  // 错误吞掉
  client.updates?.listen(_dispatch);            // 唯一收包入口
}

bool publishCommand(String topic, Map<String, dynamic> payload) {
  if (!isConnected || client == null) return false;  // 唯一的"确认信号"
  client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  return true;
}
```
（[mqtt_client.dart:39-79](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L39-L79)、[L134-149](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L134-L149)）

| 维度 | `RosbridgeClient` | `AppMqttClient` |
|---|---|---|
| 报文拼装 | 手写 + `jsonEncode`（[rosbridge_protocol.dart:9-34](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_protocol.dart#L9-L34)） | 库负责编解码，只给 `Map` |
| 连接事件 | 自己 `add` 到 `_connController`（[L61](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L61)） | 库回调转 Stream（[L49-53](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L49-L53)） |
| 错误暴露 | 全吞（[L55](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L55)） | 连接错误吞；命令用 `bool` 返回（[L136](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L136)） |
| 重连补什么 | `_advertised.clear()` + `_resubscribeAll()`（[L62-63](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L62-L63)、[L173-183](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L173-L183)），因 WS 一断服务端订阅全没 | 库处理大部分，App 仍保留 `_resubscribeAll`（[L83-87](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L83-L87)）+ 5s 兜底（[L68-78](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L68-L78)） |
| QoS 归属 | 调用方每条传 | 发布写死 QoS1（[L140-144](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L140-L144)） |

共同点：两边都要自己维护 "topic → StreamController 列表"（[rosbridge L29-30](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L29-L30)、[mqtt L26-27](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L26-L27)），因为两个底层库都只给裸消息回调。

---

## 9. Riverpod 的四种形态各自解决什么

Riverpod 可以理解为"全局单例容器 + 依赖注入 + 自动通知 UI"（近似 Android 的 Hilt + LiveData；iOS 无完全对应物，最接近 `@EnvironmentObject`）。`provider` 就是"一个由框架托管的、可被声明式依赖的值"。

**① `Provider<RosbridgeClient>` = 单例容器 + 副作用**（[rosbridge_provider.dart:7-12](file:///home/dxw/amr/amr_app/lib/providers/comm/rosbridge_provider.dart#L7-L12)）

```dart
final rosbridgeClientProvider = Provider<RosbridgeClient>((ref) {
  final client = RosbridgeClient(url: AppConstants.rosbridgeWsUrl);
  client.connect();                 // 创建即开始连接
  ref.onDispose(client.dispose);    // 容器销毁时收尾
  return client;
});
```

只管"从哪来、活多久"，不带状态、不通知 UI，首次 `read/watch` 才创建。

**② `StreamProvider<T>` = 把流包成 `AsyncValue<T>`**（[map_provider.dart:20-31](file:///home/dxw/amr/amr_app/lib/providers/data/map_provider.dart#L20-L31)、[rosbridge_provider.dart:15-17](file:///home/dxw/amr/amr_app/lib/providers/comm/rosbridge_provider.dart#L15-L17)）

`AsyncValue` 是一个"信封"，装 `loading / data / error` 三态。适合遥测：不需要自己保存"当前值"，只要最新一帧；页面销毁自动退订。

**③ `ChangeNotifierProvider<MissionCommandCenter>` = 可调用方法的对象 + 手动通知**（[mission_command_controller.dart:267-272](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart#L267-L272)）

`ChangeNotifier` 是 Flutter 内置观察者基类（等价 `LiveData` / `ObservableObject`）。它同时给"读状态"（`center.machine`）和"调动作"（`sendNavigate / cancel / retry / clear`）。

**④ 换 `StateNotifier` / `AsyncNotifier` 会怎样**

- `StateNotifier`：要求每次**整体替换** `state`，而 `CommandStateMachine` 是一堆可变字段 + `transitions` 列表（[command.dart:196-211](file:///home/dxw/amr/amr_app/packages/amr_contracts/lib/src/command.dart#L196-L211)），迁移要到处 `copyWith`，收益低。
- `AsyncNotifier`：会强制包 `AsyncValue`，但"一条指令加载中/出错"这个语义**不成立**（只有 `phase`），反而到处 `AsyncData(...)`。

---

## 10. UI 侧两种消费写法

**流 → `AsyncValue`：**

```dart
// 只要最新值，不区分三态（map_page.dart:74）
final rosConnected = ref.watch(rosConnectionProvider).valueOrNull ?? false;

// 三态分叉（dashboard_page.dart:152-156）
batteryAsync.when(
  data: (b) => '${b.level}% ${b.charging ? "⚡充电中" : ""}',
  loading: () => '…',
  error: (_, __) => '错误',
);
```

**`ChangeNotifier` → 直接读字段 + 调方法：**

```dart
final mission = ref.watch(missionCommandProvider);  // 拿控制器对象（map_page.dart:70）
if (mission.machine != null) _missionCard(mission); // 直接读可变字段（map_page.dart:151）

// 卡片内：center.cancel / center.retry / center.clear（map_page.dart:283,296,301）
```

对比：**"只要最新值"用流最自然**（不用自己存变量）；**"我要调方法"用对象最自然**（流没有方法）。反着来都别扭：给流挂一个"取消任务"无处安放；把 `phase` 塞进 `AsyncValue` 会被信封挡住。

---

## 11. 为什么这么选

| | 遥测 | 指令 |
|---|---|---|
| 频率 | 位姿 20Hz、地图 2Hz（`throttleRate:500`）、路径 5Hz | 每任务几次事件，feedback 1Hz |
| 语义 | latest-wins，旧帧无价值 | 事务性，事件不能丢、要能追 |
| 可丢帧 | 可以（`queueLength:1`） | 不可以（丢了卡在 UNKNOWN） |
| 需要确认 | 不需要 | 需要 ack / result / 超时 / 重试 / 取消 |
| 自然表达 | `Stream<T>` + `AsyncValue` | 有状态对象 + 方法 + 定时器 |

一句话：**流表达"世界现在什么样"，对象表达"这件事走到哪一步、我该做什么"。**

生态约束也是原因：Dart 没有成熟的 ROS 2 客户端库，只能走 rosbridge 网关 → `op` 报文、心跳、重连必须手写；`mqtt_client` 现成，但浏览器不能开原生 TCP，故做条件导入切 `MqttBrowserClient`（[mqtt_client.dart:5-6](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L5-L6)）。

---

## 12. 反过来做会怎样

- **用 rosbridge 发指令**：没有 `cmd_id` 关联、没有超时、没有幂等回放；WS 断开 2s 重连后不会补发，`op:publish` 无确认 → 命令丢了没人知道。现有 ack/feedback/result + 状态机正是为了补这三样。
- **用 MQTT 传地图/位姿**：`/map` 一帧是数百 KB 的整型数组，JSON 化后更大；20Hz 位姿 + 2Hz 地图会压垮 broker 与手机。且 MQTT 没有"丢弃积压只留最新"的表达（没有 `queue_length`），`retained` 还会把整张地图钉在 broker 上。

---

## 13. 朴素写法对照（不用 Riverpod、不用 Stream）

```dart
class _MapPageState extends State<MapPage> {
  final client = RosbridgeClient(url: 'ws://127.0.0.1:9090');
  bool _rosConnected = false;
  OccupancyGridData? _grid;
  Timer? _poll;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    client.connect();
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted && client.isConnected != _rosConnected) {
        setState(() => _rosConnected = client.isConnected);
      }
    });
    _sub = client.subscribe('/map', type: 'nav_msgs/OccupancyGrid', throttleRate: 500)
        .map(OccupancyGridData.fromMsg)
        .listen((g) => setState(() => _grid = g));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _sub?.cancel();
    client.dispose();   // 漏掉这行 = 泄漏一个 WebSocket + 两个定时器
    super.dispose();
  }
}
```

代价：轮询会漏掉"连上又立刻断开"的瞬态事件；`setState` 管不住重建范围；订阅/定时器/客户端生命周期全靠手写；两个页面都要地图时要么各建一条 WS、要么手写单例；测试时无法像 `ProviderScope.overrides`（[main.dart:43-47](file:///home/dxw/amr/amr_app/lib/main.dart#L43-L47)）那样注入假实现。

---

## 14. 风险与待修项

### 已修

| 项 | 证据 |
|---|---|
| `constants.dart` 曾把 `ack/feedback/result` 笼统写成 QoS 0，与 `mqtt_client.yaml` 不符 | 现已改为"ack/result = QoS1、feedback = QoS0"并写明分级理由：[constants.dart:16-20](file:///home/dxw/amr/amr_app/lib/core/constants.dart#L16-L20) |

### 未修（按严重度）

1. **MQTT 控制通道匿名可写**（安全）：`allow_anonymous true` + `0.0.0.0`，`amr/cmd/estop` 无鉴权（[mosquitto.conf:3-8](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/config/mosquitto.conf#L3-L8)）。
2. **急停/回充/切模式忽略发布返回值**（安全）：失败仍提示"已发送"（[map_page.dart:421-435](file:///home/dxw/amr/amr_app/lib/pages/map_page.dart#L421-L435)、[map_page.dart:230-233](file:///home/dxw/amr/amr_app/lib/pages/map_page.dart#L230-L233)）。
3. **`retry()` 复用旧信封导致 8s 后必 `EXPIRED`**（功能）：[mission_command_controller.dart:124-134](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart#L124-L134) + [mission_bridge.py:134-142](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/scripts/mission_bridge.py#L134-L142)。
4. **终态不 retained + `startClean` + 无持久化 → 断线错过 Result 不可自愈**（功能）：[mqtt_client.yaml:92-96](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/config/mqtt_client.yaml#L92-L96)、[mqtt_client.dart:54-59](file:///home/dxw/amr/amr_app/lib/comm/mqtt_client.dart#L54-L59)、[mosquitto.conf:10-11](file:///home/dxw/amr/amr_sim_ws/src/amr_comm/config/mosquitto.conf#L10-L11)。
5. **`/map` 依赖 QoS 首订阅顺序**（可用性）：App 必须抢在 Web 大屏之前订阅（[rosbridge_protocol.dart:5-8](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_protocol.dart#L5-L8)、[map_provider.dart:9-18](file:///home/dxw/amr/amr_app/lib/providers/data/map_provider.dart#L9-L18)）；机制见 [rosbridge-QoS与latched话题.md](file:///home/dxw/amr/docs/rosbridge-QoS与latched话题.md) §3.2，护栏方向见其 §8。
6. **rosbridge `op:status` 错误被吞**（可观测性）：[rosbridge_client.dart:76-86](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L76-L86)。
7. **rosbridge 乐观置位 + 10s 僵尸窗口**（可观测性）：连上即置 true（[L59-61](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L59-L61)），数据已停却仍显示绿色最长 10s（[L110-118](file:///home/dxw/amr/amr_app/lib/comm/rosbridge_client.dart#L110-L118)）。
8. **`cancel()` 失败静默**（交互）：`publishCommand` 返回 false 时无任何 UI 反馈（[mission_command_controller.dart:107-109](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart#L107-L109)）。
9. **迟到 ACK 恢复后 `errorCode` 不清理**（展示）：[command.dart:247-258](file:///home/dxw/amr/amr_app/packages/amr_contracts/lib/src/command.dart#L247-L258)，卡片仍渲染错误行（[map_page.dart:316-318](file:///home/dxw/amr/amr_app/lib/pages/map_page.dart#L316-L318)）。
10. **页面级 `ref.watch` 重建范围过大**（性能）：1Hz 心跳也整页重建 + 全画布重绘（[map_page.dart:70](file:///home/dxw/amr/amr_app/lib/pages/map_page.dart#L70)、[map_painter.dart:29](file:///home/dxw/amr/amr_app/lib/map/map_painter.dart#L29)）。

---

## 附：一段对照报文

```json
// rosbridge：订阅 + 回包（op 多路复用）
→ {"op":"subscribe","topic":"/map","type":"nav_msgs/OccupancyGrid","queue_length":1,"throttle_rate":500,
   "qos":{"durability":"transient_local","reliability":"reliable","history":"keep_last","depth":1}}
← {"op":"publish","topic":"/map","msg":{"info":{"resolution":0.05,"width":384,"height":384},"data":[-1,0,0,100,...]}}

// MQTT：一 topic 一语义，三 topic 靠 cmd_id 串成一次"调用"
→ amr/cmd/goal  QoS1  {"cmd_id":"cmd-1a2b-9f8e","type":"NAVIGATE_TO_POSE","ttl_ms":8000,"payload":{"x":1.2,"y":0.5,"theta":0.0}}
← amr/cmd/ack   QoS1  {"cmd_id":"cmd-1a2b-9f8e","status":"ACCEPTED","latency_ms":12.3}
← amr/cmd/feedback QoS0 {"cmd_id":"cmd-1a2b-9f8e","nav_state":"CONTROLLING","heartbeat":true}
← amr/cmd/result QoS1 {"cmd_id":"cmd-1a2b-9f8e","status":"SUCCEEDED"}
```
