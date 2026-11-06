# rosbridge 的 QoS「先到者说了算」与 latched 话题踩坑实录

> 教学向排障手册。以 2026-11-06 本仓库 `/map` 空白事故为样本，讲清 **rosbridge 的实现行为** 与 **DDS/ROS 2 规范** 的差别，并给出可复用的排查命令与修复路径。
>
> 关键词：`TRANSIENT_LOCAL`（latched）、`VOLATILE`、QoS 首次注册锁定、rosbridge 多客户端复用。

---

## 1. 现象

Android App 由一键脚本启动后：

| 观察点 | 状态 |
| --- | --- |
| 顶栏 `WS` 指示灯 | 绿色 |
| 顶栏 `MQTT` 指示灯 | 绿色 |
| 视频画面 | 正常（`/camera/image_raw/compressed` 有数据） |
| 地图页 | 纯黑，中央「等待地图数据…」 |
| 电量 / 模式（`76%` / `manual`） | 正常刷新 |

**结论：连接层没问题，业务链路也没问题，只有 `/map` 这一条数据没到。**

一个容易误判的点：App 的「等待地图数据…」占位条件是 `grid == null`（见 [map_page.dart](../amr_app/lib/pages/map_page.dart#L104-L105)），也就是**首帧从未到达**，不是「收到但解析为空」。

---

## 2. 两个机制叠加才导致空白

### 2.1 机制一：`/map` 是 latched（只发一次）

`map_server` 以 `RELIABLE + TRANSIENT_LOCAL` 发布 `/map`，并且**只在加载地图时发一帧**，之后不再重复发布。

实测证据（本次事故）：

```bash
# 8 秒内零输出 → 说明不是周期发布，而是"贴一次公告"
$ ros2 topic hz /map
（无输出）
```

`/map` 元信息：`resolution=0.05 width=214 height=174`，`map_load_time` 的 `sec=9`（bringup 后约第 9 秒才发布）。

### 2.2 机制二：rosbridge 把订阅 QoS 锁成了 `VOLATILE`

`ros2 topic info /map --verbose` 在故障期显示：

```
Node name: map_server            PUBLISHER     Reliability: RELIABLE   Durability: TRANSIENT_LOCAL
Node name: rosbridge_websocket   SUBSCRIPTION  Reliability: BEST_EFFORT  Durability: VOLATILE
```

`TRANSIENT_LOCAL` 的发布者 + `VOLATILE` 的订阅者：**能匹配、不报错，但拿不到历史帧**。于是那唯一一帧永远收不到。

### 2.3 用类比记住两种 Durability

| QoS | 类比 | 晚到的人能否拿到过去的内容 |
| --- | --- | --- |
| `TRANSIENT_LOCAL` | 公告板：通知**贴在那里**，谁后来路过都能看到 | 能，拿到「最后一次」的历史样本（受 depth 限制） |
| `VOLATILE` | 广播喇叭：**只播给当时在线的人**，播完就没了 | 不能 |

所以「latched 只发一次 + 订阅是 VOLATILE」= 你在广播结束后才进场，永远听不到。

---

## 3. rosbridge 侧的规则（附源码）

**版本**：`ros-jazzy-rosbridge-library 2.7.1-1noble.20260912.164625`
**源码路径**：`/opt/ros/jazzy/lib/python3.12/site-packages/rosbridge_library/`

### 3.1 键名就是 `qos`，子键支持 durability / reliability / history / depth 等

`capabilities/subscribe.py:254` 声明允许字段：

```python
(False, "qos", dict),
```

`capabilities/subscribe.py:309-311` 解析：

```python
qos: QoSProfile | None = None
if "qos" in msg:
    qos = extract_qos_profile(msg["qos"])
```

`internal/qos_extraction.py:85-109` 支持的子键：`history`、`depth`、`reliability`、`durability`、`deadline`、`lifespan`。

> 也就是说：**App 发 `qos` 是合法且有意义的**，我们这次 App 侧改动（`durability: transient_local`）写法没写错。

### 3.2 真正的坑：QoS 只在「该 topic 的第一次注册」时决定

`internal/subscribers.py:342` docstring 原文：

> `The QoS profile is determined at the first registration of a subscriber.`

`internal/subscribers.py:351-356`：

```python
if topic not in self._subscribers:
    self._subscribers[topic] = MultiSubscriber(
        topic, client_id, callback, node_handle, msg_type=msg_type, raw=raw, qos=qos
    )
else:
    self._subscribers[topic].subscribe(client_id, callback)
```

**注意 `else` 分支：`qos` 根本没被传进去，后到客户端的 `qos` 被静默丢弃。**

### 3.3 默认 QoS 是「猜」的，且只在创建时猜一次

`internal/subscribers.py:156-190`（节选）：

```python
qos = QoSProfile(
    depth=10,
    durability=DurabilityPolicy.VOLATILE,
    reliability=ReliabilityPolicy.BEST_EFFORT,
)

infos = node_handle.get_publishers_info_by_topic(topic)

if len(infos) > 0 and all(
    pub.qos_profile.durability == DurabilityPolicy.TRANSIENT_LOCAL for pub in infos
):
    qos.durability = DurabilityPolicy.TRANSIENT_LOCAL
    qos.reliability = ReliabilityPolicy.RELIABLE
```

docstring 也自认这点：

> `This is not perfect because more publishers may come online after our subscriber is set up`

**这解释了两个看似矛盾的事实：**

- 订阅 `/robot_description`（latched，App 从不订阅）时，默认订阅就能拿到 1 帧 —— 因为订阅那一刻 publisher 已在；
- 订阅 `/map` 时默认拿不到 —— 因为 App 连上 rosbridge 的时刻早于 `map_server` 发布（bringup 后第 ~9 秒），`get_publishers_info_by_topic` 返回空列表 → 落到默认 `VOLATILE/BEST_EFFORT`，并**永久锁定**。

### 3.4 条目何时删除

`internal/subscribers.py:369-376`：

```python
if topic not in self._subscribers:
    return

self._subscribers[topic].unsubscribe(client_id)

if not self._subscribers[topic].has_subscribers():
    self._subscribers[topic].unregister()
    del self._subscribers[topic]
```

只有「最后一个客户端也退订」时才删。反过来说：**只要还有任何一个客户端挂着，这个 topic 的 QoS 就永远是第一次那个。**

---

## 4. DDS / ROS 2 的真实规则（用来对比）

**本节重点：「首次注册锁定」是 rosbridge 的实现选择，不是 DDS 规范。**

DDS 里 **每个 reader 各自持有自己的 QoS**，匹配只看 `requested (reader)` 与 `offered (writer)` 的组合是否合法：

| writer（offered） | reader（requested） | 是否匹配 | 历史帧 |
| --- | --- | --- | --- |
| `TRANSIENT_LOCAL` | `TRANSIENT_LOCAL` | ✅ | 收到已发布的保留样本 |
| `TRANSIENT_LOCAL` | `VOLATILE` | ✅（合法，不报错） | ❌ 只收之后的新帧 |
| `RELIABLE` | `BEST_EFFORT` | ✅（合法，不报错） | 尽力而为 |
| `BEST_EFFORT` | `RELIABLE` | ❌ 不匹配 | 不建立连接 |

所以如果**直接**用 rclpy/rclcpp 写客户端，C 即使晚加入，只要自己声明 `transient_local` 就能收到历史帧 —— 与 B 的选择完全无关。

rosbridge 之所以变成「topic 级 QoS」，是因为它把「首次注册时算出的那份 QoS profile」缓存在 topic 级的 `MultiSubscriber` 上，供该 topic 的所有客户端共享。注意它并**没有**让所有 client 复用同一个 DDS 订阅对象：**每个 client 各建一个订阅对象，但共用这一份 QoS**。代价就是：**先注册的那个人替所有人做了 QoS 决定。**

> 实测依据：故障期 `ros2 topic info /map --verbose` 里 rosbridge 的 SUBSCRIPTION 是 **4 条**（对应 4 个客户端）；重启 rosbridge、僵尸连接消失后变成 **3 条** —— 条目数与客户端数一一对应。看到多条 SUBSCRIPTION 不是异常，正是「每 client 一个订阅对象、共用一份 QoS」的直接表现。

> 这也是为什么故障期 `ros2 topic echo /map --once`（直接建 rclpy 订阅，用自己的 QoS）能拿到数据，而 App 拿不到 —— 两条路径的 QoS 决策完全不同。

**关键副作用：这类不匹配不会在日志里报错。** 因为 `TRANSIENT_LOCAL writer + VOLATILE reader` 属于「合法但不收历史」，rosbridge / DDS 都不会输出 `incompatible QoS` 警告，日志干净得像没事发生。

---

## 5. 四种情形对照表

设 A = `map_server`（`RELIABLE + TRANSIENT_LOCAL`，只发一帧）。

| # | 情形 | 谁决定了 QoS | 该订阅最终的 QoS | 后到客户端 C 能收到历史帧吗 |
| --- | --- | --- | --- | --- |
| 1 | 首个订阅者是 B，B 自带 `qos: transient_local` | B | `TRANSIENT_LOCAL` | ✅ 能 |
| 2 | 首个订阅者是 B，B 未传 qos，但 A 的 publisher **已 advertise** | rosbridge 推断（看到 A → 升级） | `TRANSIENT_LOCAL` | ✅ 能 |
| 3 | 首个订阅者是 B，B 未传 qos，A **尚未 advertise** | rosbridge 推断（空列表 → 默认） | `VOLATILE / BEST_EFFORT` | ❌ 不能（本事故） |
| 4 | 首个订阅者 B 显式传了 `volatile`，随后 C 传 `transient_local` | B（C 的 qos 被丢弃） | `VOLATILE` | ❌ 不能 |

第 4 行正是你问的「B、C 都是 VOLATILE（C 继承 B 的选择）」：

- **能收到** A 在 C 订阅**之后**新发布的帧；
- **收不到** A 在 C 订阅**之前**发的那一帧历史样本；
- 对 `/map` 这种**一次性（latched）话题**，`订阅之后`永远不会有新帧，所以**必空**；
- 对高频话题（如 `/scan`、`/tf`、`/camera/...`），几毫秒后就有新帧，问题被「自愈」掩盖 —— 这正是「视频正常、只有地图空」的原因。

---

## 6. 为什么 force-stop App 也没用

故障期做过实验：`adb shell am force-stop com.amr.amr_app` 后等 20 秒（远超 `unregister_timeout=10.0`），`/map` 的 rosbridge 订阅**仍然是** `BEST_EFFORT/VOLATILE`，订阅数也不变。

原因：`has_subscribers()`（`subscribers.py:369-376`）依赖 rosbridge 认为「客户端已退订」。而客户端是经 `adb reverse` 转发的 **半开 TCP 连接**，rosbridge 侧看到的仍是 ESTAB：

```bash
$ ss -tnp | grep 9090
ESTAB 0 0 127.0.0.1:9090 127.0.0.1:58905 users:(("python3",pid=<rosbridge>))
ESTAB 0 0 127.0.0.1:9090 127.0.0.1:50613 users:(("python3",pid=<rosbridge>))
```

于是 `has_subscribers()` 恒为真 → `del self._subscribers[topic]` 永不执行 → QoS 永久锁死，**只能重启 rosbridge 进程**。

### 判读方法

| 手段 | 看什么 |
| --- | --- |
| `ros2 topic info /map --verbose` | rosbridge 那条 SUBSCRIPTION 的 `Durability` 是否为 `TRANSIENT_LOCAL` |
| `ss -tnp \| grep 9090` | 是否还有 ESTAB 连接（僵尸连接会让订阅条目永不释放） |
| rosbridge 日志 | `[Client <uuid>] Subscribed to /map` —— 对不上实际在线客户端数，就是僵尸 |

---

## 7. 排障命令清单（可直接复制）

```bash
source /opt/ros/jazzy/setup.bash
source ~/amr/amr_sim_ws/install/setup.bash

# 1) 话题是否存在、类型是什么
ros2 topic list | grep -i map
ros2 topic type /map                       # 期望: nav_msgs/msg/OccupancyGrid

# 2) 关键：发布者 QoS 与每个订阅者 QoS
ros2 topic info /map --verbose
# 期望: Publisher count: 1 / map_server / RELIABLE + TRANSIENT_LOCAL
# 判据: rosbridge_websocket 那条 SUBSCRIPTION 必须是 RELIABLE + TRANSIENT_LOCAL

# 3) 是否"只发一次"（latched 的典型特征：无输出）
ros2 topic hz /map

# 4) 历史帧是否还在（绕开 rosbridge，直接用 rclpy 订阅）
ros2 topic echo /map --qos-durability transient_local --qos-reliability reliable --field info --once
# 期望: resolution: 0.05 / width: 214 / height: 174 ...

# 5) 反证：用 VOLATILE 订阅，应该拿不到
ros2 topic echo /map --qos-durability volatile --qos-reliability best_effort --once
# 期望: 无输出（超时）

# 6) map_server 生命周期
ros2 lifecycle get /map_server             # 期望: active [3]

# 7) 节点是否都在
ros2 node list | grep -E "map_server|rosbridge"
```

**读法口诀**：先看 publisher 的 `Durability`，再看 rosbridge 那条 `SUBSCRIPTION` 的 `Durability`。两者不一致时，latched 话题必空。

---

## 8. 修复路径

### 路径 ①：重启 rosbridge（临时、立即有效）

在 `map_server` 已经 active 的前提下重启 rosbridge，下次首个注册就会推断/采纳 `TRANSIENT_LOCAL`：

```bash
kill <rosbridge_pid>
source /opt/ros/jazzy/setup.bash
source ~/amr/amr_sim_ws/install/setup.bash
nohup python3 /opt/ros/jazzy/lib/rosbridge_server/rosbridge_websocket \
  --ros-args --params-file /tmp/launch_params_<xxx> \
  > /tmp/rosbridge_restart.log 2>&1 &
```

本次实测（23:08:48 重启，App 1 秒内自动重连）：

```
rosbridge_websocket  SUBSCRIPTION  Reliability: RELIABLE   Durability: TRANSIENT_LOCAL
```

地图随即出图。

**副作用**：这样拉起的 rosbridge **脱离了原 `ros2 launch amr_bringup full_bringup.launch.py` 父进程**（本次 pid 由 2470 变为 20239），`launch` 不再托管它；下次整栈重启会恢复由 launch 管理。别把它当成常态做法。

### 路径 ②：启动顺序护栏（根治方向）

让「首个订阅」永远发生在 `map_server` active 之后：

1. 起栈后轮询直到 `ros2 lifecycle get /map_server` 返回 `active`（或 `ros2 topic info /map` 的 `Publisher count >= 1`）；
2. 再安装/启动 App（或让 App 的连接延后到这一步）。

这样无论默认推断还是显式 qos，结果都是 `TRANSIENT_LOCAL`。

### 路径 ③（备选）：1 Hz 重发节点

新增一个小节点，以 `transient_local` 订阅 `/map`，再以 1 Hz 转发到新话题（如 `/map_repub`），App 改订新话题。

| 项 | 代价 |
| --- | --- |
| 改动面 | ROS 侧新增节点/launch 条目 + App 话题常量（2 处） |
| 优点 | 完全与 rosbridge 的首次注册锁解耦，任何客户端都能收到 |
| 缺点 | 多一个常驻节点、多 1 Hz 带宽、语义漂移风险（多个地图来源）；不是本次采纳方案 |

### App 侧已经做的（辅助，不是根治）

给 `/map` 显式声明 latched QoS，覆盖「App 抢先订阅」的情形：

- [rosbridge_protocol.dart](../amr_app/lib/comm/rosbridge_protocol.dart) —— `rosSubscribe` 增加可选 `qos` 透传；
- [rosbridge_client.dart](../amr_app/lib/comm/rosbridge_client.dart) —— `subscribe(..., qos)`，并存入 `_SubParams`，重连重订阅时带上；
- [map_provider.dart](../amr_app/lib/providers/data/map_provider.dart) —— `_latchedQos = {durability: transient_local, reliability: reliable, history: keep_last, depth: 1}`。

> 注意：它只在**首次注册**时有效。若已有别的客户端先把该 topic 注册成 `VOLATILE`，App 的 qos 依然会被丢弃（第 3.2 节）。所以路径 ② 才是根治。

---

## 9. 通用教训

1. **所有 latched topic 在 rosbridge 下都有同样风险**：`/map`、`/map_metadata`、`/robot_description`、`/tf_static` 等。
2. **只有「一次性」话题会暴露问题**：高频话题几毫秒后就来新帧，自动掩盖。
3. 排查时**不要只看 WS 灯和日志**：这类不匹配不报错、不打日志，只能靠 `--verbose` 的 QoS 字段判读。
4. **不要指望 force-stop 客户端来重置 QoS**：只要连接是半开的，注册条目就活着。
5. 记住分界线：**订阅时刻 vs publisher advertise 时刻**。这在「一键脚本同时拉起整栈 + App」的场景里非常容易踩中。

---

## 10. 附录

### 10.1 本次事故时间线（本地时间 2026-11-06）

| 时间 | 事件 |
| --- | --- |
| 21:36:21 | rosbridge 启动（pid 493141，由 `full_bringup.launch.py` 拉起） |
| ~21:36:2x | 旧版 App（无 qos）自动重连并订阅 `/map` → publisher 尚未出现，QoS 锁成 `VOLATILE` |
| ~21:36:30 | `map_server` 发布 latched `/map`（`map_load_time` sec=9） |
| 22:14:28 / 22:14:33 | 含 qos 修复的 APK 构建 / 安装，但注册仍被复用 → 地图仍空 |
| 23:01:53 / 23:01:57 | 用户再跑一键脚本，重建 / 重装（`lastUpdateTime=15:01:57 UTC`） |
| 23:07:35 | 抓包证实 App 确实发送 `qos={durability: transient_local, ...}`；同时存在无 qos 客户端 |
| 23:08:48 | 重启 rosbridge（pid 20239） |
| 23:08:49-51 | 3 个客户端 1~3 秒内自动重连 |
| ~23:09 | `/map` 订阅变为 `RELIABLE + TRANSIENT_LOCAL`；截图确认地图出图 |

### 10.2 本次修复涉及的文件

| 文件 | 改动 |
| --- | --- |
| [lib/comm/rosbridge_protocol.dart](../amr_app/lib/comm/rosbridge_protocol.dart) | `rosSubscribe` 新增可选 `qos` 字段并透传 |
| [lib/comm/rosbridge_client.dart](../amr_app/lib/comm/rosbridge_client.dart) | `subscribe` 新增 `qos` 参数；`_SubParams` 保存 `qos`；重连重订阅带上 |
| [lib/providers/data/map_provider.dart](../amr_app/lib/providers/data/map_provider.dart) | `/map` 订阅显式声明 `_latchedQos` |

### 10.3 一句话总结

> **DDS 里每个订阅者各管各的 QoS；rosbridge 为了多客户端复用，把 QoS 提升成 topic 级缓存 —— 于是「先到者替所有人做主」。latched 话题撞上这个行为，就是「WS 绿、视频好、地图空」。**
