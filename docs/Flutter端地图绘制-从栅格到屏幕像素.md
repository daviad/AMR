# Flutter 端地图绘制：从 `int8` 数组到屏幕像素

这份文档沿着一条因果链推导：机器人给的是什么东西 → 它怎么变成 Dart 对象 → 怎么变成位图 → 怎么变成屏幕上的像素 → 手势怎么反算回世界坐标。目标不是记住类和 API，而是能自己重建这套实现，并判断哪里还能更好。

> 阅读前提：知道 ROS 的 `nav_msgs/OccupancyGrid` 是什么即可，不需要 Flutter 经验。

---

## 0. 整体思路、出发点与技术选型（先读这一节）

> **先读这一节。** 后面所有章节都是这一节里某层的展开。如果你只想花五分钟理解这套东西，读完本节即可。

### 0.1 出发点：为什么 App 必须自己画

先看机器人侧给了什么：

| 机器人侧已有 | 形态 | 能直接显示吗 |
|---|---|---|
| `/map`（`map_server` 发布） | **latched 整图快照**：`width/height/resolution/origin` + `int8[]` | 不能，它是"带刻度的表格"，不是图片 |
| `/plan` / `/amcl_pose` / `/tf` | 持续推送的流 | 不能，是坐标点，需要画 |
| `map_server` 的 `static_map` 服务 | 请求-响应（PGM/YAML 已加载进内存） | 不能，是数据接口 |

机器人侧**没有任何"已经渲染好的画面"**。rviz 是跑在桌面上的 Qt + OGRE 程序，依赖桌面 GPU 栈，塞不进手机；rviz_web 需要额外的 web 桥 + 3D 渲染管线，对一张 2D 栅格来说过重；`map_server` 只负责"供给地图"，不负责"显示地图"。

如果反过来——让服务端渲染成图片再推给 App（比如定时发 PNG 截图）——会立刻遇到四个问题：延迟至少一个"渲染 + 编码 + 传输"的周期；位姿 20Hz 就意味着 20Hz 推图，编码 CPU 和带宽都按帧数线性增长；点击选点需要把屏幕坐标换算回世界坐标，服务端必须额外回传地图元数据做二次换算；离线或弱网时完全不可用。

所以"栅格 → 像素"这一步**只能在客户端做**。这不是偷懒，是没有别的选择。而一旦要在客户端做，就必须解决三件事的耦合：数据（会变）、视图（会被手指改）、命中（要把屏幕点反算回世界点）。这就是下面这套分层的由来。

### 0.2 一句话思路

> **把栅格烘焙成一张位图，把位图当作"带物理刻度的画布"，用两个标量（`scale`/`offset`）描述"相机"，剩下的全部退化成"把世界坐标换成屏幕坐标"的一次算术。**

分层图（每一层只依赖下面一层）：

```
┌────────────────────────────────────────────────────────────┐
│ 交互层   MapView(GestureDetector) + MapViewport             │
│          吃：屏幕坐标/手势增量   吐：世界坐标、scale/offset │
├────────────────────────────────────────────────────────────┤
│ 渲染层   MapPainter(CustomPainter) → MapLayer.paint(Canvas) │
│          吃：视口 + 各层数据     吐：Canvas 绘制指令        │
├────────────────────────────────────────────────────────────┤
│ 变换层   MapTransform（世界↔格） + MapViewport（格↔屏幕）   │
│          吃：Offset(米) / Offset(像素)  吐：Offset(像素)    │
├────────────────────────────────────────────────────────────┤
│ 状态层   Riverpod StreamProvider（map/plan/pose）           │
│          吃：Stream       吐：最新快照（AsyncValue 包着）   │
├────────────────────────────────────────────────────────────┤
│ 数据层   RosbridgeClient + OccupancyGridData.fromMsg        │
│          吃：WS 的 JSON   吐：Int8List + 元数据             │
└────────────────────────────────────────────────────────────┘
```

每层的"契约"和"为什么不能合并"：

| 层 | 输入 | 输出 | 合并进相邻层会怎样 |
|---|---|---|---|
| 数据层 | rosbridge JSON | `Int8List` + `width/height/resolution/origin` | 并进渲染层 → 协议细节渗进画图代码，换传输（比如直连 ROS 2）要重写绘制 |
| 状态层 | `Stream` | 最新一帧（`AsyncValue` 信封） | 并进 UI → 每个用到地图的页面各自订阅、各自解析，页面切换泄漏订阅 |
| 变换层 | 世界/像素 `Offset` | 像素/世界 `Offset` | 并进渲染层 → 手势命中测试要再抄一遍公式，两份 `scale` 一旦不同步，点击就偏 |
| 渲染层 | 视口 + 数据 | `Canvas` 指令 | 并进交互层 → 无法用 `Listenable` 单独触发重绘，每次手势都要重建整棵控件树 |
| 交互层 | 手势事件 | 视口参数 / 世界坐标 | 并进渲染层 → 渲染变成有状态、有副作用的函数，无法单独测试 |

术语速查（后面会反复用到）：`Offset` 是 Dart 的二维点/向量；`AsyncValue` 是 Riverpod 给异步数据套的"信封"，装 `loading / data / error` 三态；`Listenable` 是 Flutter 的"可被监听"基类，调 `notifyListeners()` 会通知所有监听者，`ChangeNotifier` 是它最常用的实现（自己维护监听者列表）；`CustomPainter` 是"直接往 Canvas 下绘制指令"的钩子（第 4 节展开），承载它的控件叫 `CustomPaint`；`Element` 是控件树里的实例节点（Widget 只是配置，Element 负责生命周期与状态）；`setState` 是 `StatefulWidget` 里"标记本控件需要重建"的方法；`TextPainter` 是手动排版并绘制文字的对象（不参与控件树，和 Canvas 上画图形一样只是一条指令）。

### 0.3 技术选型：用了什么，为什么不用别的

**① 绘制：`CustomPainter` + `Canvas`（立即模式）**

- **用了什么**：`MapPainter extends CustomPainter`，在 `paint()` 里按 `zIndex` 顺序调 `layer.paint(canvas, viewport)`（[map_painter.dart:19-26](file:///home/dxw/amr/amr_app/lib/map/map_painter.dart#L19-L26)）。
- **为什么**：一层底图 + 四条折线/圆点/文字，全部是"一次性指令"，没有可复用控件、没有布局概念。立即模式正好匹配。
- **不用 `RawImage`/`Image` 拼图**：`RawImage` 确实能显示那张烘焙好的 `ui.Image`，但它只能显示**一张**图，路径、圆点、编号文字仍然要另一个 `CustomPaint`；于是会出现两个坐标系、两套变换、两层命中测试。更关键的是：位图本身就是"底图 + 别的层"里最简单的那一层，为它单独引入 Widget 并不减少复杂度。
- **不用 `CustomMultiChildLayout`/`Stack` 堆 Widget**：147,456 个格子若各是一个 Widget，就意味着同样数量的 Element、每帧布局和每帧命中测试，成本随格数线性增长；而 Canvas 方案每帧只有常数条指令。即便只放几十个标记，每个标记也要参与布局与层合成，而 Canvas 一行 `drawCircle` 就够了。
- **不用 WebView/three.js**：WebView 是一个独立浏览器，拿不到 Flutter 的手势和状态，坐标要跨进程回传；three.js 是为连续 3D 场景设计的，2D 栅格用它等于引入一整套 3D 管线，还要处理跨端 JS 桥接。二者的复杂度都远高于"画一张图 + 几根线"。

**② 状态：Riverpod `StreamProvider`**

- **用了什么**：`mapProvider`/`planProvider`/`robotPoseProvider` 都是 `StreamProvider`（[map_provider.dart:20-31](file:///home/dxw/amr/amr_app/lib/providers/data/map_provider.dart#L20-L31)、[plan_provider.dart:9-33](file:///home/dxw/amr/amr_app/lib/providers/data/plan_provider.dart#L9-L33)、[tf_provider.dart:11-33](file:///home/dxw/amr/amr_app/lib/providers/data/tf_provider.dart#L11-L33)），由 `rosbridgeClientProvider` 这个单例（[rosbridge_provider.dart:7-12](file:///home/dxw/amr/amr_app/lib/providers/comm/rosbridge_provider.dart#L7-L12)）驱动。
- **为什么**：遥测是"订阅即最新值"，`StreamProvider` 自动完成三件事——订阅、把三态（loading/data/error）包成 `AsyncValue`、在容器销毁时取消订阅。地图、路径、位姿三个流共享同一条 WebSocket，页面只声明"我要最新值"。
- **不用 `setState`**：`setState` 属于某个 `State` 对象，两个页面都要位姿就得订阅两次或手写单例；`dispose` 漏一行就泄漏一条订阅。
- **不用裸 `ChangeNotifier`**：可以，但要把"订阅 → 缓存最新值 → 通知"全手写；而且通知是"对象变了"，UI 侧拿到的是可变对象，`AsyncValue` 的三态语义会丢。
- **不用 Bloc**：Bloc 的价值是"事件 → 状态的显式迁移"，适合有业务规则的场景；对"高频二进制流 → 最新值"没有收益，反而要多写 `Event`/`State` 两类样板。本项目的指令链路确实需要状态机，那里用的是 `CommandStateMachine` + `ChangeNotifierProvider`，而不是 Bloc。

**③ 视图变换：不是 `Transform`/`Matrix4`，而是两个标量 + 逐点映射**

这一点特别容易想当然，这里明确说：**代码里没有 `Transform` 组件，也没有 `Matrix4` 累积**。`MapViewport` 只持有 `double scale` 和 `Offset offset`（[map_viewport.dart:17-21](file:///home/dxw/amr/amr_app/lib/map/map_viewport.dart#L17-L21)），每个图元绘制前自己调 `worldToScreen`。

- **为什么这样更好**：Canvas 变换会把**线宽、半径、字号**一起缩放。若用 `canvas.scale(20)`，`strokeWidth: 2.5` 的路径线会变成 50 px，`TextPainter` 的 11 号字变成 220 号。逐点映射让这些尺寸永远停留在"屏幕空间"，图标大小不随缩放变化——这正是地图类应用的期望。
- **为什么不用 `Transform` 组件**：它是给**子控件**做仿射变换的，用在这里就意味着把地图做成控件树，回到 ① 反对的做法；而且命中测试还得自己再求逆。
- **什么时候必须换 `Matrix4`**：一旦需要**地图旋转**（跟随车头朝向）或倾斜/透视，两级"缩放+平移+翻折"的闭式解就不够用了，那时矩阵才是正确工具。当前设计不支持旋转，是刻意取舍。
- **另一个好处**：逆变换是两行闭式解（[map_viewport.dart:33-42](file:///home/dxw/amr/amr_app/lib/map/map_viewport.dart#L33-L42)），点击反算不需要求矩阵逆，也不会有数值误差累积。

**④ 色彩映射：三档离散（未知/空闲/占用）**

- **为什么**：`OccupancyGrid` 的语义只有三类，画成"概率渐变"是在视觉上编造数据里不存在的信息。`-1` 用深灰表示"没观测过"，`0` 用浅灰（不是纯白，避免和背景混淆），`100` 用黑（[base_map_layer.dart:59-75](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L59-L75)）。
- **一个细节**：占用格其实做了 `shade = 0xE8 - (v * 0xE8 ~/ 100)` 的线性压暗（`~/` 是整数除法），所以 1~100 之间有层次。这是"给可能的中间值留余地"，但真实地图里几乎只出现 0 和 100，看起来就是两档。

**⑤ `int8` 而不是 `float32`**

- **为什么**：这是 ROS 侧的消息约定（`nav_msgs/OccupancyGrid` 的 `data` 就是 `int8[]`），不是 App 的选择。带宽上差 4 倍：384×384 = 147,456 个格子，`int8` 就是 147,456 字节（约 144 KiB），换成 `float32` 是 589,824 字节（约 576 KiB）。这还没算 rosbridge 的 JSON——数组会变成一串 `-1,0,100,` 这样的文本，字符数远多于字节数。
- **代价**：精度只有 101 档（0–100），做不了"半格概率"的细腻可视化——但导航本来也不需要。

**⑥ 扩展口子：代价地图/膨胀层/更多叠加**

- **留了什么**：`MapLayer` 接口（`id`/`zIndex`/`visible`/`paint`/`hitTest`/拖拽回调，[map_layer.dart:11-40](file:///home/dxw/amr/amr_app/lib/map/map_layer.dart#L11-L40)）。新增一层只需实现接口、加进 `layers` 列表（[map_page.dart:107-113](file:///home/dxw/amr/amr_app/lib/pages/map_page.dart#L107-L113)），`MapView` 与 `MapPainter` 零改动。
- **缺了什么**：
  - 没有 `/scan`、`/odom` 图层（常量注释里提到，但 `lib/` 下没有订阅）。激光点云需要"点集 → 屏幕"的批量绘制和按距离着色，现有 `MapLayer` 能画，但没有现成的数据通路。
  - `zIndex` 是 `int`，而排序用的是 `List.sort`（[map_view.dart:41-42](file:///home/dxw/amr/amr_app/lib/map/map_view.dart#L41-L42)），Dart 的 `sort` **不保证稳定**：若两个图层 `zIndex` 相同，它们的绘制先后没有契约。加代价地图层时应保证 `zIndex` 唯一。
  - 没有透明度/混合模式的统一入口（`Paint` 各自 new），代价地图的半透明叠加要每层自己处理。
  - `hitTest` 只返回单个 `id` 且从上层开始，适合"点选一个标记"，不适合"框选多个点"。
  - 只支持 `map` 这一个坐标系；多 frame（如 `odom` 系下的实时位姿）需要额外的 TF 链，当前 `/tf` 只用于兜底取位姿（[tf_provider.dart:22-31](file:///home/dxw/amr/amr_app/lib/providers/data/tf_provider.dart#L22-L31)），没有做坐标变换树。

### 0.4 这套方案的边界

- **数据量上限**：当前地图 384×384 = **147,456 格**，RGBA 缓冲 `147,456 × 4 = 589,824` 字节（约 576 KiB）。循环体是"读 1 字节、写 4 字节、两次分支"，按**每格 10 ns 的保守假设**估算：147,456 格 ≈ **1.5 ms** 的纯循环，另加 `decodeImageFromPixels` 的解码与纹理上传。1000×1000（100 万格）≈ 10 ms 循环 + 4 MB 纹理；2000×2000（400 万格）≈ 40 ms 循环 + 16 MB 纹理，已是 16.6 ms 帧预算的 2.4 倍；同时 `data` 有 400 万个元素，每种 JSON 文本化按 3–4 个字符算就是 12–16 MB，传输先垮。**按帧预算判断，实用上限在 1000×1000 量级。**（以上是量级估算，不是实测。）
- **节点数上限**：可以数出来——一段 10 m、按 0.1 m 采样的路径是 `10 / 0.1 = 100` 个点，折线重算就是 100 次坐标变换；巡检点几十个，每个一次 `drawCircle` + 一次 `TextPainter`。需要担心的是"点数 × 每秒重绘次数"，到上万点才值得缓存 `Path`。
- **20Hz 位姿的重绘压力**：位姿 20Hz（`throttleRate: 50`，[tf_provider.dart:18](file:///home/dxw/amr/amr_app/lib/providers/data/tf_provider.dart#L18)），每次更新都触发页面 build → 新 `MapPainter` → `shouldRepaint` 恒真 → **五层全量重绘**（[map_painter.dart:29](file:///home/dxw/amr/amr_app/lib/map/map_painter.dart#L29)）。底图只是一次 `drawImageRect`，但显示列表每帧重录。20 次/秒的全量重录在低端机上可能丢帧——这需要实测，代码本身给不出结论。
- **Web 上的差异**：
  - 项目有 `web/` 目标。CanvasKit 渲染器下，`drawImageRect`、`FilterQuality.none`、`decodeImageFromPixels` 的语义与移动端一致，行为可预期，代价是首次加载要下载 Skia 的 WASM 包。
  - 旧版可选的 **html 渲染器**用 Canvas2D/DOM 实现，同样的代码能跑，但 `FilterQuality` 的映射、复杂 `Path` 与裁剪的性能、文字度量都不同；它没有光栅缓存，意味着"重绘"是真的每次重画。Flutter 3.29 起 html 渲染器已移除，只剩 CanvasKit/skwasm，本项目的 SDK 下限是 3.22（[pubspec.yaml:8](file:///home/dxw/amr/amr_app/pubspec.yaml#L8)），所以两种渲染器都可能被用到。
  - 会失效或表现不同的做法：依赖 `dart:io` 的本地文件（本项目未用）、依赖固定 `devicePixelRatio` 的像素对齐、以及"靠光栅缓存抵消全量重绘"这种优化（html 渲染器下不成立）。
  - `TextPainter` 在 Web 上走浏览器字体，编号文字的字宽/行高与移动端略有差异，可能导致圆点编号偏移 1–2 px。

---

## 1. 起点：地图本质上是什么

`/map` 不是图片，是**一张带物理刻度的表格**。消息里最关键的四项：

| 字段 | 含义 |
|---|---|
| `info.width` / `info.height` | 行列数（格数，不是米） |
| `info.resolution` | **米/格**（注意方向：不是格/米） |
| `info.origin.position` | 第 0 行第 0 列那一格的**左下角**在世界坐标中的位置（米） |
| `data` | 行优先的 `int8` 数组，长度 = `width × height` |

`data` 的取值只有三种语义：`-1` 未知、`0` 空闲、`100` 占用。

**为什么是 -1/0/100 而不是 0.0~1.0 的概率？** 因为这是 **2D 占据栅格（occupancy grid）** 的"结论"，不是"信念"。`map_server` 内部可能保留概率，但对外发布的是三值化结果：`occupancy_threshold` 以上算占用（100），以下算空闲（0），没观测过的保持 -1。原因有三：

1. 体积：一字节一格，384×384 就是 147,456 字节（约 144 KiB）；同样格数换成 `float32` 概率要 589,824 字节（约 576 KiB），再经 rosbridge 的 JSON 文本化还要再涨。
2. 语义：导航规划只需要"能不能走"，不需要"有多大概率能走"。
3. 兼容：`-1` 天然区分"没看过"和"看过且空闲"——这对未知区域探索很关键。

顺带说明 `data[row * width + col]` 的行序：**row 0 是最下面那行（世界 y 最小）**。这一点决定了后面所有的翻转，也是"常见误解"里第一条的根源。

**latched 的后果**：`/map` 只在 `map_server` 加载地图时发一帧，靠 `TRANSIENT_LOCAL` 让晚来的订阅者补发（latched 的意思是：发布方把最后一帧留在内存，新订阅者一连上就能收到它）。机制见 [rosbridge-QoS与latched话题.md](file:///home/dxw/amr/docs/rosbridge-QoS与latched话题.md) §2.1–§2.2，本文不重复。所以 App 拿到的是**快照**，不是持续更新的流：`mapProvider` 是 `StreamProvider`，但实际只会产出极少数几帧（[map_provider.dart:20-31](file:///home/dxw/amr/amr_app/lib/providers/data/map_provider.dart#L20-L31)）。

---

## 2. 数据落地：从 `Map` 到 `OccupancyGridData`

ROS 侧经过 rosbridge 后是一坨 `Map<String, dynamic>`（Dart 的字典，`dynamic` 表示值类型在编译期未知），`fromMsg` 只做三件事：拆字段、把 `List<dynamic>` 拷贝成 `Int8List`（`dart:typed_data` 里的定长有符号字节数组，元素范围 -128..127，连续内存、无装箱）、补上 `originX/originY`（[occupancy_grid.dart:29-46](file:///home/dxw/amr/amr_app/lib/models/occupancy_grid.dart#L29-L46)）。

```dart
factory OccupancyGridData.fromMsg(Map<String, dynamic> msg) {
  final info = msg['info'] as Map<String, dynamic>;
  final origin = info['origin'] as Map<String, dynamic>;
  final position = origin['position'] as Map<String, dynamic>;
  final raw = msg['data'] as List<dynamic>;    // JSON 数组，元素是 num
  final data = Int8List(raw.length);
  for (var i = 0; i < raw.length; i++) {
    data[i] = (raw[i] as num).toInt();         // 逐元素拷贝
  }
  return OccupancyGridData(
    width: (info['width'] as num).toInt(),
    height: (info['height'] as num).toInt(),
    resolution: (info['resolution'] as num).toDouble(),
    originX: (position['x'] as num).toDouble(),
    originY: (position['y'] as num).toDouble(),
    data: data,
  );
}
```

三个字段在后续计算中的角色分工非常清晰：

- `resolution` + `origin`：只参与**世界 ↔ 格**换算（`MapTransform`，[occupancy_grid.dart:60-82](file:///home/dxw/amr/amr_app/lib/models/occupancy_grid.dart#L60-L82)）。
- `width/height`：只参与**格 ↔ 图像像素**（位图尺寸、`height - y` 的翻转基准）。
- `data`：只在**建位图那一次**被遍历。

**为什么必须缓存而不是每次 build 重新解析？** 因为 JSON 里 `data` 是 `List<dynamic>`，一个 384×384 的地图有 147,456 个装箱的 `num` 对象。`MapPage` 的 build 被 20Hz 位姿带着跑，若每次 build 都重新解析，就是每秒 `20 × 147,456 = 2,949,120` 次拆箱与类型转换。`fromMsg` 只在 `mapProvider` 出新帧时跑（latched 下通常只有一次），把结果收敛成 `Int8List`（连续内存、无装箱），位图又进一步把它压成"一次性产物"：`OccupancyGridData` 由 `mapProvider` 创建一次，图层用 `identical(grid, _grid)` 判等，同一实例直接返回（[base_map_layer.dart:36-44](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L36-L44)）。

---

## 3. 两次坐标变换（重点）

上一节结束时手里有了一张"米/格"已知、原点已知的位图。下一个问题自然是：**给定的世界点落在位图哪一格、又落在屏幕哪一个像素。** 这是后面所有绘制、命中、点击取点的公共前提，所以先把它一次算清楚。

整条链是**两级**，不是一级：

```
世界(米) ──MapTransform──▶ 地图位图像素(格) ──scale/offset──▶ 屏幕(逻辑像素)
```

### 3.1 世界 → 位图像素：为什么 y 要翻

代码只有两行（[occupancy_grid.dart:73-76](file:///home/dxw/amr/amr_app/lib/models/occupancy_grid.dart#L73-L76)）：

```dart
Offset worldToPixel(Offset world) => Offset(
      (world.dx - origin.dx) / resolution,
      height - (world.dy - origin.dy) / resolution,
    );
```

第一行是**平移后除以分辨率**：先减 `origin` 把"世界原点"挪到"地图左下角"，再除以米/格得到格数。
第二行多了一个 `height -`：因为世界 y 向上、图像 y 向下。不减这一下，整张地图会上下颠倒。

反向（[L78-81](file:///home/dxw/amr/amr_app/lib/models/occupancy_grid.dart#L78-L81)）：

```dart
Offset pixelToWorld(Offset pixel) => Offset(
      origin.dx + pixel.dx * resolution,
      origin.dy + (height - pixel.dy) * resolution,
    );
```

两者互为逆运算，都是"一次线性缩放 + 一次平移 + 一次翻折"，所以不需要矩阵也能手写。

**手算一遍**。设 `resolution = 0.05`（米/格）、`origin = (-10, -10)`、`width = height = 384`，地图覆盖世界 `x ∈ [-10, 9.2)`、`y ∈ [-10, 9.2)`。

取世界点 `P = (1.2, -0.5)`：

```
col  = (1.2 - (-10)) / 0.05 = 11.2 / 0.05 = 224.0
row↑ = (-0.5 - (-10)) / 0.05 = 9.5 / 0.05 = 190.0   （从下往上数）
py   = 384 - 190.0 = 194.0                          （图像行，从上往下数）
```

所以位图上的坐标是 `(224.0, 194.0)`。

注意这个点**恰好落在格子的角上**（两个方向都是整数）。此时"落在哪一格"取决于约定。正确约定是**半开区间**：第 `col` 格覆盖 `x ∈ [origin.x + col*res, origin.x + (col+1)*res)`。于是 `(1.2, -0.5)` 属于第 224 列、第 190 行（从下数），也就是：

```
数据下标 = row * width + col = 190 * 384 + 224 = 73,184
这一格覆盖 x ∈ [1.20, 1.25)、y ∈ [-0.50, -0.45)
```

换个不在格线上的点看得更清楚：`P2 = (1.22, -0.47)`：

```
col = 11.22/0.05 = 224.4 → floor 224
row↑ = 9.53/0.05 = 190.6 → floor 190
py  = 384 - 190.6 = 193.4
```

**为什么用 `floor` 而不是 `round`？** 因为格是一个左闭右开的区间，`floor` 就是把连续坐标"落到所属区间"的唯一正确操作：

- `round` 在 `0.49` 和 `0.51` 之间来回跳，会把格心当成边界，视觉上表现为"点总是偏向格子中心";
- 更严重的是负数：Dart 的 `round()` 是"远离零取整"，`-0.5` 会取到 `-1`，而 `floor(-0.5)` 是 `-1`、`floor(-2.5)` 是 `-3`——一旦 `origin` 为负、坐标算出负小数，`round` 的语义就不再与"格边界"对齐。

实现上要注意一个细节：`worldToPixel` 返回的是**连续**坐标（`194.0` 这种值），代码从不用它去取 `data[...]`——取格只在 `_buildImage` 里按整数 `py/px` 做（[base_map_layer.dart:53-77](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L53-L77)）。连续坐标只用于画矩形和画点，所以"边界上落到哪一格"不影响显示。如果你以后要写"点击查询这一格是障碍吗"，就必须补 `floor` 和边界钳制。

### 3.2 位图像素 → 屏幕：scale 与 offset

这一级是纯仿射：

```dart
Offset pixelToScreen(Offset pixel) => pixel * scale + offset;   // L29
Offset screenToPixel(Offset screen) => (screen - offset) / scale; // L31
```

（[map_viewport.dart:29-31](file:///home/dxw/amr/amr_app/lib/map/map_viewport.dart#L29-L31)）

- `scale` 的单位是**屏幕逻辑像素/格**，不是像素/米。换算成"像素/米"要再除以 `resolution`：`pxPerMeter = scale / resolution`（机器人半径就是这么算的，[robot_layer.dart:33-36](file:///home/dxw/amr/amr_app/lib/map/layers/robot_layer.dart#L33-L36)）。
- `offset` 的单位是屏幕逻辑像素，表示"位图原点 (0,0) 画在屏幕的哪个位置"。

**为什么顺序是"先缩放再平移"，不能反？** 若反过来写成 `(pixel + offset) * scale`，那么当你改变 `scale` 时，`offset` 的含义也跟着被放大，手势每次缩放都会让地图"飞走"；写成 `pixel * scale + offset` 时，`offset` 是独立的屏幕量，缩放只改变 `scale`，平移只改变 `offset`，两个自由度正交、可独立累积。这也是所有视图框架（Android `View` 的 `matrix`、iOS `CGAffineTransform`、Skia）都采用"scale 后 translate"的原因。

**手算屏幕位置**。假设画布是 390×700 逻辑像素，`fitToContent` 计算：

```
sx = 390/384 = 1.015625
sy = 700/384 = 1.822917
scale = min(sx, sy) * 0.95 = 1.015625 * 0.95 = 0.96484375
centerPixel = (192, 192)
offset = (390/2, 700/2) - (192,192)*0.96484375
       = (195, 350) - (185.25, 185.25) = (9.75, 164.75)
```

（[map_viewport.dart:57-66](file:///home/dxw/amr/amr_app/lib/map/map_viewport.dart#L57-L66)；`scale` 的注释明确写了单位是"屏幕像素 / 地图位图像素"，[L20-21](file:///home/dxw/amr/amr_app/lib/map/map_viewport.dart#L20-L21)）

再把上面的 `P=(224, 194)` 送进去：

```
screen.x = 224*0.96484375 + 9.75    = 216.125    + 9.75    = 225.875
screen.y = 194*0.96484375 + 164.75  = 187.1796875 + 164.75 = 351.9296875 ≈ 351.93
```

即世界点 `(1.2, -0.5)` 出现在 390×700 画布的 `(225.875, 351.93)`，几乎就是画布中心稍右一点——因为地图中心 `(192,192)` 被 `fitToContent` 对齐到了画布中心，而这个点离地图中心很近（差 32 格 x、2 格 y）。

### 3.3 屏幕 → 世界：逆变换（点击取点用）

就是上面两条式子逐级取逆，**不需要求矩阵逆**：

```
screenToWorld(s) = pixelToWorld( screenToPixel(s) )
                 = pixelToWorld( (s - offset) / scale )
                 = origin + ((s - offset)/scale 的 x, height - ... 的 y) * resolution
```

完整实现见 [map_viewport.dart:38-42](file:///home/dxw/amr/amr_app/lib/map/map_viewport.dart#L38-L42)。手算：手指点在上一节算出的 `(225.875, 351.9296875)`：

```
pixel = ((225.875-9.75)/0.96484375, (351.9296875-164.75)/0.96484375)
      = (216.125/0.96484375, 187.1796875/0.96484375)
      = (224.0, 194.0)
world = (-10 + 224*0.05, -10 + (384-194)*0.05)
      = (-10 + 11.2, -10 + 9.5) = (1.2, -0.5)
```

严格回到起点、没有残差（因为上面两个中间量是同一组常量算出来的）。

> 顺带解释为什么这里不用 `Matrix4`：只有"缩放 + 平移"两件事，闭式逆变换两行就写完；用矩阵反而要维护 `invert()`、`transform3`、齐次坐标，且 2D 场景里 `Matrix4` 的 z 分量是浪费。真正的代价是——以后若要支持旋转地图，闭式解就不够用了，得换成矩阵。

---

## 4. 绘制：为什么是 `CustomPainter`

第 3 节已经把"一个世界点落在屏幕哪个像素"算清楚了。这一节回答下一个问题：**谁来把这些像素真正画出来，以及为什么不是别的方案。**

**`CustomPainter` 是什么**：Flutter 里的"直接下绘制指令"的钩子，等价 Android 的 `View.onDraw(Canvas)`、iOS 的 `UIView.draw(_:)`。它不参与控件树——不产生子控件、不走布局、不做命中测试，只拿到一块 `Canvas` 和尺寸，然后调用 `drawRect/drawImage/drawPath`。

**为什么不用 Widget 堆叠？** 地图如果拆成 147,456 个 `Container`/`Positioned`，每个格子都要：创建 Element、参与布局、参与命中测试、被合成层管理——成本随格数线性增长。Canvas 方案每帧的指令数是常数级（1 次 `drawImageRect` + 几个图元），两者对象/指令规模差 4–5 个数量级。**这是结构差异，不依赖具体设备的性能**；不是"某台机器实测更慢"，而是"一个随格数增长、一个不随格数增长"。

**`shouldRepaint` 的语义**：`CustomPainter` 是不可变描述对象，Flutter 每次 `build` 都会 new 一个 `MapPainter`；框架用它和旧 painter 比较，决定要不要重新执行 `paint()`。这里返回恒 `true`（[map_painter.dart:29](file:///home/dxw/amr/amr_app/lib/map/map_painter.dart#L29)），意味着**任何一次重建都全量重绘**。后面第 8 节会算这笔账。

**逐格 `drawRect` vs `drawImage`：量级差多少？**

| 做法 | 每帧绘制指令数 | 数据搬运 | 代价是否随格数增长 |
|---|---|---|---|
| 逐格 `drawRect` | 147,456 次（384×384） | 每格一个 `Rect` + `Paint` 都要进显示列表 | 是，线性增长 |
| 一次 `drawImageRect` | **1 次** | 1 张已解码纹理 | 否，只在采样面积上受填充率影响 |

快多少取决于设备与光栅化路径，代码里没有实测数据，所以这里只给可验证的结论：**指令数从 147,456 降到 1，且不再随格数增长。**

所以正确做法是**把表格烘焙成位图**：一次循环把 `-1/0/100` 映射成 RGBA，交给 `ui.decodeImageFromPixels` 生成 `ui.Image`，之后每帧只做一次贴图（[base_map_layer.dart:46-96](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L46-L96)、[L98-119](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L98-L119)）。

烘焙一次的开销：384×384 = **147,456 格**，RGBA 缓冲 `147,456 * 4 = 589,824` 字节（约 576 KB）；循环内每格读 1 字节、写 4 字节、做两次比较。按第 0.4 节"每格 10 ns"的保守假设，纯循环约 **1.5 ms**，再加解码与纹理上传。由于 `/map` 是 latched 单帧，这个开销通常一辈子只付一次，不在热路径上。（估算，非实测。）

颜色映射的意图也值得说清（[L59-75](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L59-L75)）：

- `-1` 未知 → `(0x60,0x60,0x68)` 深灰蓝：视觉上"这里没数据"，与浅灰的空闲区形成对比；
- `0` 空闲 → `0xE8` 浅灰：**不是纯白**，因为纯白会和白色背景/边框混在一起，看不出地图范围；
- 其他（1~100）→ 按值线性压暗：`shade = 0xE8 - (v * 0xE8 ~/ 100)`（代码用的是整数除法 `~/`），即 `100` 时 `0xE8 - 232 = 0`，全黑。这样保留了"部分占据"的层次，虽然真实地图里绝大多数只会是 0 或 100。

**为什么未知区域不画成透明？** 因为 alpha 被固定写成 `0xFF`（[base_map_layer.dart:76](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L76)）。若把 `-1` 画成透明，它会露出后面的背景色，视线上和"空闲"很难区分；将来叠加代价地图或激光层时，未知区域还会透出下层，造成"那里有东西"的错觉。不透明的深灰才是"明确表示没有数据"。

**为什么 `filterQuality = none`？** 见第 5 节贴图细节：最近邻保证每格要么黑要么白，双线性会把墙/地的边界糊成灰边，等于在视觉上编造"半占用地带"。

---

## 5. 渲染管线：`paint()` 里到底下了什么

第 4 节得出了"把栅格烘焙成位图、每帧只贴一次"的结论。这一节看这条结论落到代码里是什么样：文件怎么分、`paint` 下哪些指令、图层顺序怎么定、以及贴图时的采样与设备像素细节。

### 5.1 文件分工与调用顺序

`lib/map` 一共 9 个文件，职责是一条直线，没有反向依赖：

| 文件 | 行数 | 职责 |
|---|---|---|
| `map_layer.dart` | 40 | 图层接口：`paint` / `hitTest` / 拖拽 / `visible` / `zIndex` |
| `map_viewport.dart` | 67 | 两级变换（世界↔像素、像素↔屏幕）+ 缩放/平移原语 |
| `map_view.dart` | 129 | 有状态外壳：图层排序、手势、命中分发、首帧适配 |
| `map_painter.dart` | 30 | 按序调用各图层 `paint`，自身不做任何计算 |
| `layers/base_map_layer.dart` | 120 | 栅格 → 位图缓存 → 一次贴图 |
| `layers/path_layer.dart` | 44 | `/plan` 折线 |
| `layers/inspection_points_layer.dart` | 123 | 编号巡检点 + 朝向线 + 拖拽命中 |
| `layers/robot_layer.dart` | 55 | 机器人圆 + 朝向箭头 |
| `layers/target_point_layer.dart` | 51 | 待确认目标环 + 十字 |

一次刷新与一次点击的调用顺序：

```
MapPage.build
  → updateGrid / updatePath / updatePoints / updatePose / updateGoal   （只更新图层持有的数据）
  → MapView.build
       → 按 zIndex 排序图层、把 repaintListenable 合并成 Listenable.merge
       → LayoutBuilder 拿尺寸，首帧 fitToContent
  → RenderCustomPaint.markNeedsPaint
  → MapPainter.paint(canvas, size)
       → 各 layer.paint(canvas, viewport)   （zIndex 升序）

用户点击
  → MapView._onTapUp(localPosition)
       → _hitTest 自顶向下问各图层            （命中屏幕半径 20px）
       → 命中 → layer.onTap(id, ...)
       → 未命中 → viewport.screenToWorld(localPosition) → 页面 onMapTap
```

`MapPainter.paint` 本身几乎不做事（[map_painter.dart:19-26](file:///home/dxw/amr/amr_app/lib/map/map_painter.dart#L19-L26)）：

```dart
void paint(Canvas canvas, Size size) {
  canvas.save();
  canvas.clipRect(Offset.zero & size);   // 防止内容画到画布外
  for (final layer in layers) {
    layer.paint(canvas, viewport);       // 按 zIndex 升序，后画的在上
  }
  canvas.restore();
}
```

图层顺序由 `zIndex` 决定，`MapView` 在 build 时排序（[map_view.dart:41-42](file:///home/dxw/amr/amr_app/lib/map/map_view.dart#L41-L42)）：

| zIndex | 图层 | 内容 | 为什么在这个位置 |
|---|---|---|---|
| 0 | `BaseMapLayer` | 栅格底图（1 次 `drawImageRect`） | 永远最底，其他都在它上面 |
| 10 | `PathLayer` | `/plan` 蓝色折线 | 要压在底图上，但不能盖住点/车 |
| 40 | `InspectionPointsLayer` | 橙色编号点 + 朝向线 + 文字 | 要能被点到、被盖在机器人之上也无妨 |
| 50 | `RobotLayer` | 绿圆 + 白边 + 朝向箭头 | 高于路径与点，作业位置最需要看清 |
| 60 | `TargetPointLayer` | 红色圆环 + 十字 + 箭头 | 最上层，待确认目标必须始终可见 |

**顺序为什么重要**：Canvas 是"画家算法"，后画的覆盖先画的，没有 z-buffer。层级错了不会报错，只会出现"路径压在机器人身上"这种视觉错误。

**当前实际没有的两层**：`/scan` 与 `/odom` 只在常量注释里被列出（[constants.dart:12](file:///home/dxw/amr/amr_app/lib/core/constants.dart#L12)），`lib/` 下**没有订阅、也没有图层**。所以这套渲染里没有激光点云/costmap 膨胀层。若以后要加，按 `MapLayer` 接口实现即可，`MapView` 不用改（[map_layer.dart:11-40](file:///home/dxw/amr/amr_app/lib/map/map_layer.dart#L11-L40)）。

底图那一次贴图的细节（[base_map_layer.dart:103-118](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L103-L118)）：

```dart
final topLeft     = viewport.pixelToScreen(Offset.zero);
final bottomRight = viewport.pixelToScreen(Offset(width, height));
final dst = ui.Rect.fromPoints(topLeft, bottomRight);   // 屏幕上的矩形
canvas.drawImageRect(
  image,
  ui.Rect.fromLTWH(0, 0, width, height),                 // 源：整张位图
  dst,                                                   // 目标：缩放后的屏幕矩形
  Paint()..filterQuality = FilterQuality.none,           // 最近邻
);
```

`src` 坐标系是位图像素（0..384），`dst` 是屏幕逻辑像素——`drawImageRect` 一次完成"缩放 + 平移"，相当于把第 3.2 节的公式交给 GPU。

`FilterQuality.none`（最近邻）在这个场景是**对的**：栅格地图的本质是离散格子，双线性插值会把"黑墙/白地"的边界糊成灰边，语义上产生不存在的"半占用地带"。而最近邻保证每一格要么黑要么白。代价是格子边界有锯齿——但那是数据本身的形状。

**`isAntiAlias`**：代码里各图层都用默认值（路径/圆环/圆的 `Paint` 未显式设 `isAntiAlias`，默认 `true`）。这对折线和圆是对的（曲线/斜线需要抗锯齿）；对"正好轴对齐"的矩形反而无所谓。真正需要注意的反而是文字：`TextPainter` 会自己做抗锯齿与亚像素定位。

**`devicePixelRatio` 的影响**（`devicePixelRatio` = 一个逻辑像素对应多少个物理像素，3x 屏就是 3）：Flutter 的所有 Canvas 坐标都是**逻辑像素**，引擎在光栅化时再乘以 `devicePixelRatio`。这带来两个可感知的结果：

1. 位图只有 384×384 个源像素。在 3x 屏上按 `scale=0.96484375` 铺开，占 `384 * 0.96484375 = 370.5` 逻辑像素、`370.5 * 3 = 1111.5` 物理像素，也就是**位图被放大了约 2.9 倍**（1111.5 / 384 ≈ 2.894）。最近邻放大会让每格变成约 3×3 的方块——这就是"格子看起来有点粗"的原因，属于预期行为。
2. 逻辑像素与格子的比例决定了"最小可读尺寸"。按上面的 `scale`，一个 0.18 m 的机器人只有 `0.18 * 0.96484375 / 0.05 = 3.4734375` 逻辑像素，几乎看不见，所以代码把它钳到 `8.0`（[robot_layer.dart:33-36](file:///home/dxw/amr/amr_app/lib/map/layers/robot_layer.dart#L33-L36)）——**此时画出来的圆已经不代表真实尺寸了**，只是一个"图标"。

## 6. 叠加层：谁在更新、谁必须重绘

第 5 节讲的是"一帧怎么画出来"，这一节换成时间维度：**每帧由谁触发，哪些层真的需要重画，哪些只是被拖着重画。**

| 图层 | 数据源 | 刷新率 | 更新方式 |
|---|---|---|---|
| 底图 | `/map` | 一次性（latched） | `updateGrid` → `ChangeNotifier` → `notifyListeners` |
| 路径 | `/plan` | 节流 200ms（[plan_provider.dart:11-17](file:///home/dxw/amr/amr_app/lib/providers/data/plan_provider.dart#L11-L17)） | 页面 build 时 `updatePath`，无 notifier |
| 巡检点 | Hive 本地 | 用户操作时 | `updatePoints`，拖拽时 `notifyListeners` |
| 机器人 | `/amcl_pose` 主 + `/tf` 兜底，再合并节流到 50ms（[tf_provider.dart:11-33](file:///home/dxw/amr/amr_app/lib/providers/data/tf_provider.dart#L11-L33)） | **20Hz** | 页面 build 时 `updatePose` |
| 目标点 | 本地 `navigationControllerProvider` | 交互时 | 页面 build 时 `updateGoal` |

`MapPage.build` 每次都把所有图层对象"喂"一遍（[map_page.dart:62-69](file:///home/dxw/amr/amr_app/lib/pages/map_page.dart#L62-L69)），但图层对象是 `late final` 持有的（[L44-52](file:///home/dxw/amr/amr_app/lib/pages/map_page.dart#L44-L52)），所以位图缓存和拖拽状态不会丢。

**哪一层可以缓存、哪一层不行：**

- 底图**必须缓存**（位图），且只有 `grid` 实例变化才重建；重复帧被 `identical` 挡掉（[base_map_layer.dart:36-44](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L36-L44)）。
- 路径**可以缓存**成 `Path` 对象，但当前每次 `paint` 都重新 `moveTo/lineTo`（[path_layer.dart:33-41](file:///home/dxw/amr/amr_app/lib/map/layers/path_layer.dart#L33-L41)）。按"10 m 路径、0.1 m 采样"`10 / 0.1 = 100` 个点，重算就是 100 次坐标变换；只有当点位上万时才值得缓存。
- 机器人**不能缓存**，20Hz 位姿就是它的全部内容。
- 巡检点、目标点绘制成本极低（十几个圆 + 文字），不必缓存。

**当前实现里的重复计算：**

1. `path_layer.dart:34-37` 对第一个点调了两次 `worldToScreen`（`moveTo` 的 x 和 y 各一次）。微不足道，但说明"每帧重算"的写法容易累积小浪费。
2. 20Hz 位姿刷新 → 页面 build → 新 `MapPainter` → **所有图层全部重画**，包括那张只变过一到两次的底图。底图虽然只是一次 `drawImageRect`，但每帧都要重新录制显示列表并重新采样纹理。
3. **单帧底图被 20Hz 位姿拖着重绘**：`/map` 是 latched 的**一帧**，不是 2Hz 流。`map_provider.dart` 里确实写了 `throttleRate: 500`（[L27](file:///home/dxw/amr/amr_app/lib/providers/data/map_provider.dart#L27)），但节流只是"最快多久放一条"，不会把一帧变成连续流（该文件 L7-L12 的注释自己也写明了"只在加载地图时发一帧"）。真正的浪费在于：五层共用一个 `CustomPaint`，位姿每 20Hz 触发一次页面 build，整套显示列表（含那张从没变过的位图）就被重录一次。

**单帧快照到达时，UI 靠什么被通知？**（latched 只来一次，没有"下一帧"可以等）

- **占位出现**：`mapProvider` 解出 `OccupancyGridData` → `MapPage.build` 里 `ref.watch(mapProvider).valueOrNull` 拿到它 → `_baseLayer.updateGrid(grid)`（[map_page.dart:62-63](file:///home/dxw/amr/amr_app/lib/pages/map_page.dart#L62-L63)）。第一次拿到时，`grid == null` 的分支刚被换掉，`MapView` 在这次 build 里**首次创建**，所以"占位矩形"由"新建控件必须绘制"保证，不依赖通知。
- **真图出现**：`decodeImageFromPixels` 是异步的，回调回来时页面早已 build 完。这时靠的是图层自己的 `ChangeNotifier`：`updateGrid` 末尾 `notifyListeners()`（[base_map_layer.dart:36-44](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L36-L44)），而它的 `repaintListenable` 返回 `this`（[L27-28](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L27-L28)）；`MapView` 把这些 `Listenable` 合并进 `MapPainter` 的 `repaint` 参数（[map_view.dart:43-46](file:///home/dxw/amr/amr_app/lib/map/map_view.dart#L43-L46)、[L68](file:///home/dxw/amr/amr_app/lib/map/map_view.dart#L68)）。`notifyListeners()` → `RenderCustomPaint.markNeedsPaint()`（`RenderCustomPaint` 是 `CustomPaint` 控件对应的渲染对象，负责真正执行 `paint`）→ 重绘。`_image` 还空着时先画 `0xFF606068` 的占位矩形（[base_map_layer.dart:107-111](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L107-L111)）；解码完成后再 `notifyListeners()` 一次（[L88-92](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L88-L92)），把占位换成真图。
- 这条通道**只重绘、不重建 Widget**：`shouldRepaint` 回答的是"重建之后要不要重画"，而 `repaint` 直接绕过 build 触发 `paint`。
- **首帧的 `scale` 还不是适配值**：`MapViewport` 构造时 `scale = 20.0`（[map_viewport.dart:13](file:///home/dxw/amr/amr_app/lib/map/map_viewport.dart#L13)），`fitToContent` 在 `addPostFrameCallback` 里通过 `setState` 补做（[map_view.dart:51-56](file:///home/dxw/amr/amr_app/lib/map/map_view.dart#L51-L56)），所以"适配后的画面"比地图数据到达还要晚一帧；那一帧里 384 格被按 20 px/格铺成 7680 px，靠 `clipRect` 裁到可见区域。
- 如果连 `grid` 都没有，`paint` 直接 `return`（[L101](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L101)）；而此时页面根本不创建 `MapView`，显示的是 `Text('等待地图数据…')`（[map_page.dart:104-105](file:///home/dxw/amr/amr_app/lib/pages/map_page.dart#L104-L105)）。

## 7. 交互

**先纠正一个常见假设**：这套代码**没有用 `Transform` 组件，也没有用 `canvas.scale/translate`**，更没有累积 `Matrix4`。它把变换存成两个标量（`offset`、`scale`），每个图元绘制前自己做一次 `worldToScreen`。手势累积等价于对这两个标量做加减乘。

```dart
// map_view.dart:87-110
void _onScaleStart(ScaleStartDetails details) {
  final hit = _hitTest(details.localFocalPoint);   // 先问图层要人要图
  if (hit != null && hit.layer.draggable) {         // 命中可拖拽的巡检点
    _dragLayer = hit.layer; _dragHitId = hit.hitId;
    hit.layer.onDragStart(hit.hitId, details.localFocalPoint, _viewport);
  } else { _dragLayer = null; _dragHitId = null; }
}

void _onScaleUpdate(ScaleUpdateDetails details) {
  if (_dragLayer != null) {                        // 拖点：只移动这一个元素
    _dragLayer!.onDragUpdate(_dragHitId!, details.localFocalPoint, _viewport);
    return;
  }
  setState(() {                                    // 拖地图/缩放：改视口
    _viewport.panBy(details.focalPointDelta);
    _viewport.zoomAt(details.localFocalPoint, details.scale);
  });
}
```

**为什么用"逐点算坐标"而不是 `canvas.scale`？** 因为 Canvas 变换会**连同线条宽度、文字大小一起缩放**。若在 `paint` 里 `canvas.scale(20)`，`strokeWidth = 2.5` 的路径线会变成 50 px，圆形半径、`TextPainter` 的 11 号字全部被放大 20 倍。改成逐点算，`strokeWidth`、`radius`、`fontSize` 始终是屏幕空间常量，视觉上"图标大小不随缩放变化"——这正是地图类应用的期望行为。

`Transform` 组件同理：那是给**子控件**做仿射变换的，用在这里意味着把地图变成子控件树，回到第 4 节反对的做法。

**`zoomAt` 的"以手指为中心"**（[map_viewport.dart:45-50](file:///home/dxw/amr/amr_app/lib/map/map_viewport.dart#L45-L50)）：

```dart
final before = screenToPixel(focal);        // 缩放前，手指下面是哪个位图像素
scale = (scale * factor).clamp(minScale, maxScale);
offset = focal - before * scale;            // 解方程：focal = before*scale + offset
```

代数上就是把"手指处的像素在缩放后仍然落在手指下"这个约束解出来。手算验证：`scale=0.96484375, offset=(9.75,164.75), focal=(195,350)` → `before=((195-9.75)/0.96484375, (350-164.75)/0.96484375)=(192.0,192.0)`；放大 2 倍后 `scale=1.9296875`，`offset = 195 - 192*1.9296875 = -175.5`；代回 `pixelToScreen(192)=192*1.9296875-175.5=195` ✓。

边界是 `minScale=0.05`、`maxScale=50`（[map_viewport.dart:26-27](file:///home/dxw/amr/amr_app/lib/map/map_viewport.dart#L26-L27)）。钳制只保证 `scale` 落在区间里，**不保证画面可读**；两个极端下的退化行为要分开看（所有尺寸都是屏幕常量，算起来很直接）：

- **缩到 `scale = 0.05`**：384 格整图只有 `384 * 0.05 = 19.2` 逻辑像素。
  - `drawImageRect` 把 384×384 位图压进 19.2×19.2 px，每格 0.05 px，最近邻采样会丢掉绝大部分格子——显示的是"整图的稀疏抽样"，不是缩略图。
  - 路径线宽 `2.5` px（[path_layer.dart:29-30](file:///home/dxw/amr/amr_app/lib/map/layers/path_layer.dart#L29-L30)）比整张图还粗；机器人半径被 `clamp(8.0, 48.0)` 撑到 8 px（[robot_layer.dart:33-36](file:///home/dxw/amr/amr_app/lib/map/layers/robot_layer.dart#L33-L36)），同样比整图大。
  - 巡检点命中半径 20 px（[inspection_points_layer.dart:55-61](file:///home/dxw/amr/amr_app/lib/map/layers/inspection_points_layer.dart#L55-L61)）覆盖整图之外的所有区域，一次点击会命中倒序遍历里的第一个点。
  - 想让整图至少占 30 px，需要 `scale ≥ 30/384 = 0.078125`，而代码允许到 0.05——**"可用的最小缩放"没有任何约束，这是设计上的空白。**
- **放大到 `scale = 50`**：1 格 = 50 逻辑 px，整图 `384 * 50 = 19,200` px（以 390 px 宽的手机屏算，约 49 个屏宽）。
  - 机器人真实半径 `0.18 * (50/0.05) = 180` px，被上限 `48` 截断——同一行 `clamp(8.0, 48.0)` 同时承担"防太小"和"防太大"两个意图。
  - 巡检点命中半径 20 px 只覆盖 `20/50 = 0.4` 格，点中心画的是 11 px 的圆（[L89](file:///home/dxw/amr/amr_app/lib/map/layers/inspection_points_layer.dart#L89)），**看得见却点不中**。
  - `FilterQuality.none` 下每格变成 50×50 的纯色块，边界锯齿宽度也是 50 px；语义正确（格子就是格子），视觉很粗。

结论：`scale` 的语义是"屏幕 px / 格"，而线宽、点半径、命中半径、字号全都是屏幕常量——**缩放改变的是"地图多大"，不是"图元多大"**。所以图元不会在极端缩放下"等比退化"，反而会相对地图失真。这是"逐点映射"方案的固有代价，不是 bug；要缓解只能在 `paint` 里按 `scale` 动态调这些常量。

**点击落点 → `map` 坐标 → 下发**：

```dart
// map_view.dart:121-128
void _onTapUp(TapUpDetails details) {
  final hit = _hitTest(details.localPosition);      // 先给图层（巡检点）机会
  if (hit != null) { hit.layer.onTap(hit.hitId, details.localPosition, _viewport); return; }
  widget.onMapTap?.call(_viewport.screenToWorld(details.localPosition));  // 反算世界坐标
}
```

```dart
// map_page.dart:390-399
void _onMapTap(Offset world) {
  switch (_editMode) {
    case _MapEditMode.navigate:  ref.read(navigationControllerProvider.notifier).setPending(world);
    case _MapEditMode.addPoint:  _addPointAt(world);
    case _MapEditMode.editPoints: break;
  }
}
```

之后"确认导航"按钮把这个 `world` 和滑杆给的 `theta` 交给 `NavigationController.confirm()`（[map_page.dart:374-380](file:///home/dxw/amr/amr_app/lib/pages/map_page.dart#L374-L380)、[navigation_controller.dart:47-56](file:///home/dxw/amr/amr_app/lib/providers/navigation/navigation_controller.dart#L47-L56)），再经 `sendNavigate` 由 `buildGoalCommand` 组包（[mission_command_controller.dart:73-81](file:///home/dxw/amr/amr_app/lib/providers/navigation/mission_command_controller.dart#L73-L81)）。注意：**朝向不来自点击**，点击只给位置，角度由用户拖滑杆决定。

命中测试用的是**屏幕距离**而非世界距离：巡检点的判定半径是 20 屏幕像素（[inspection_points_layer.dart:55-61](file:///home/dxw/amr/amr_app/lib/map/layers/inspection_points_layer.dart#L55-L61)），所以放大后更好点、缩小后更容易误点——这是"在屏幕空间判定"的自然结果。

**一个真实缺陷**：`details.scale` 是**从手势开始到现在的累计倍数**（开始时为 1.0），而代码每一帧都拿它乘一次当前 `scale`（[map_view.dart:108](file:///home/dxw/amr/amr_app/lib/map/map_view.dart#L108)）。正确写法是使用 `scale / _lastScale` 的增量，或记录手势起始 `scale` 后用 `startScale * details.scale`。当前写法会让捏合呈指数放大：手指放大 1.2 倍的过程中若产生 10 帧，最终缩放约为 `1.2^10 ≈ 6.2` 倍。同一段里 `panBy` 用的是**增量** `focalPointDelta`，两者语义不一致，也说明这里没有统一的"手势基准"概念。

## 8. 可优化点（现状 → 代价 → 改法）

**① 逐格绘制** —— 现状：已经用离屏位图（[base_map_layer.dart:80-92](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L80-L92)）。代价：若退回逐格 `drawRect`，每帧 147,456 次绘制调用，缩放时每帧都付。改法：保持现状；若要进一步优化，可用 `ImageShader` 做平铺，但当前只有一张图、无平铺需求，收益为零。

**② `shouldRepaint` 恒为 `true`** —— 现状：[map_painter.dart:29](file:///home/dxw/amr/amr_app/lib/map/map_painter.dart#L29)。代价：任何 build 都全量重绘。位姿 20Hz 一条流就足以触发每秒 20 次全图层重绘；连接状态、电量、编辑模式等与地图无关的重建也走同一条路。改法：给 `MapViewport` 加 `revision` 计数（手势时 +1），`MapPainter` 持有 `layers` 快照与 `revision`，`shouldRepaint` 比较这两者；静态层变化继续走 `repaint`（`Listenable`）通道，不必依赖重建。

**③ 静态底图与动态层耦合** —— 现状：五层共用一个 `CustomPaint`。代价：机器人动一下，底图纹理也要重新采样一次，且整个地图区域的显示列表被重录。改法：拆成两个 `CustomPaint`/`RepaintBoundary`：底层只画 `BaseMapLayer`（仅在 grid 变化时重绘），上层画其余四层；或给 `MapView` 外包 `RepaintBoundary`（`RepaintBoundary` 会把子树光栅化成一张独立的缓存图层，子树重绘不再连带外部区域），至少不让重绘波及页面其他区域。

**④ `repaint` 只挂了一半图层** —— 现状：只有 `BaseMapLayer` 和 `InspectionPointsLayer` 提供 `repaintListenable`（[map_layer.dart:20-22](file:///home/dxw/amr/amr_app/lib/map/map_layer.dart#L20-L22)、[base_map_layer.dart:27-28](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L27-L28)、[inspection_points_layer.dart:27-28](file:///home/dxw/amr/amr_app/lib/map/layers/inspection_points_layer.dart#L27-L28)），路径/机器人/目标只能靠页面重建驱动。代价：位姿与路径被迫走"重建 → 新 painter → 重绘"这条更重的路。改法：让每个动态图层也暴露 `Listenable`（内部持有 pose/path 并 `notifyListeners`），页面 `build` 只负责初始注入。

**⑤ 位图构建在主 isolate 且带"丢帧"守卫** —— 现状：RGBA 填充是同步 `for` 循环，跑在主 isolate（`isolate` 是 Dart 的独立执行单元，UI 的每一帧都在主 isolate 上跑；不同 isolate 有自己的堆、不共享内存，只能靠消息传数据），`_building` 为真时新 grid 直接 return（[L46-48](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L46-L48)），异步解码回来后若 `grid` 已变则丢弃（[L87-92](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L87-L92)）。代价：地图连续更新时可能出现"旧图丢弃、新图没建"的空白窗口；这 147,456 格的循环按 §0.4 的每格 10 ns 估算约 **1.5 ms**，等于 16.6 ms 帧预算的近 9%，与位姿刷新叠加时不可控（估算，非实测）。改法：把 RGBA 填充移进 `Isolate`（`compute`），UI isolate 只保留 `decodeImageFromPixels`；并把构建队列改成"保留最新的一个"而不是"直接丢弃"。

**⑥ 首次适配只做一次** —— 现状：`_fitted` 置 `true` 后不再重置（[map_view.dart:51-56](file:///home/dxw/amr/amr_app/lib/map/map_view.dart#L51-L56)）。代价：换地图（重建后尺寸不同）不会重新 `fitToContent`，视野会停在旧比例。改法：以 `transform` 的实例/尺寸变化为触发条件重置。

**⑦ 手势缩放用累计 `details.scale`** —— 见第 7 节末。代价：捏合非线性、手感失控。改法：在 `_onScaleStart` 记录 `_gestureStartScale = _viewport.scale`，`_onScaleUpdate` 用 `_viewport.setScale(_gestureStartScale * details.scale, focal)`。

**⑧ `origin` 的方向被忽略** —— 现状：`fromMsg` 只读了 `origin.position`，未读 `origin.orientation`（[occupancy_grid.dart:31-43](file:///home/dxw/amr/amr_app/lib/models/occupancy_grid.dart#L31-L43)）。代价：带 yaw 的地图会整体画歪（当前地图都是 yaw=0，所以没暴露）。改法：解析四元数得到 yaw，在 `worldToPixel` 里加一次旋转。

## 9. 常见误解

1. **"origin 是左上角"** —— 不是。ROS 的 `origin` 是**图像左下角那一格的原点**（[occupancy_grid.dart:21-23](file:///home/dxw/amr/amr_app/lib/models/occupancy_grid.dart#L21-L23)），所以世界 y 向上、图像 y 向下，必须做 `height - ...` 翻转。
2. **"`data` 的第 0 行是图像顶部"** —— 不是。`data` 行序从世界底部开始；位图第 0 行才是顶部。二者相差一次整行翻转：`rowBase = (h - 1 - py) * w`（[base_map_layer.dart:55](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L55)）。
3. **"resolution 是像素/米"** —— 是**米/像素**（米/格）。所以 `pxPerMeter = scale / resolution`，而不是 `scale * resolution`。
4. **"scale 就是地图缩放比例，1.0 表示原始大小"** —— `scale` 的单位是"屏幕逻辑像素/格"，默认 20（[map_viewport.dart:13](file:///home/dxw/amr/amr_app/lib/map/map_viewport.dart#L13)）只是占位值，`fitToContent` 会把它改成 0.96484375（390×700 画布下）。真正"1 格 = 1 像素"时 `scale == 1`。
5. **"用 `round` 取格更准"** —— 不对。格是半开区间 `[c*res, (c+1)*res)`，只有 `floor` 能正确落格；`round` 在负坐标上的行为还会破坏这个约定。
6. **"屏幕坐标 = 位图像素坐标"** —— 差一个仿射：`screen = pixel*scale + offset`，`scale=0.96484375` 时两者接近但不等，绝不能混用。
7. **"绘图用了 `Matrix4`/`Transform`"** —— 没有。变换是 `scale` + `offset` 两个标量，逐点手算（[map_viewport.dart:29-42](file:///home/dxw/amr/amr_app/lib/map/map_viewport.dart#L29-L42)）。
8. **"角度直接用 `cos/sin` 画就行"** —— 要取 `Offset(cos θ, **-sin θ**)`（[robot_layer.dart:47](file:///home/dxw/amr/amr_app/lib/map/layers/robot_layer.dart#L47)、[inspection_points_layer.dart:100](file:///home/dxw/amr/amr_app/lib/map/layers/inspection_points_layer.dart#L100)、[target_point_layer.dart:45](file:///home/dxw/amr/amr_app/lib/map/layers/target_point_layer.dart#L45)），因为屏幕 y 向下，世界 y 向上。漏掉负号会让朝向上下镜像。
9. **"地图是持续推送的流"** —— 是 latched 的单帧快照。App 端看起来像流，只是因为 `StreamProvider` 统一了形态。
10. **"机器人圆是按真实尺寸画的"** —— 有 `clamp(8.0, 48.0)`（[robot_layer.dart:36](file:///home/dxw/amr/amr_app/lib/map/layers/robot_layer.dart#L36)）。在典型缩放（0.96484375、resolution 0.05）下真实半径是 `0.18 * 19.296875 = 3.4734375` px，被放大到 8 px，此时它是个图标，不是比例尺。
11. **"地图整体在平移 = 地图数据在漂移"** —— 只是 `offset` 变了（[map_viewport.dart:52-54](file:///home/dxw/amr/amr_app/lib/map/map_viewport.dart#L52-L54)）。`panBy` 改的是"位图原点画在屏幕的哪个位置"，`worldToPixel` 的输入输出一个数都没动。判断数据有没有漂移要看**世界坐标**（地图 `origin`、位姿），不是看画面位置。
12. **"`notifyListeners()` 会重建页面"** —— 不会。它只通知挂在 `repaint` 上的监听者（`RenderCustomPaint`），走 `markNeedsPaint`，**不触发 `build`**。反过来，页面重建也**不会**重建位图：`updateGrid` 用 `identical(grid, _grid)` 早退（[base_map_layer.dart:36-37](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L36-L37)），位图只在 grid 实例变化时才重建。
13. **"`worldToPixel` 的结果可以直接拿去查 `data[]`"** —— 不能。它返回的是**连续**坐标（可能是 `194.0`、`193.4`），`data` 要的是整数下标：必须 `floor` 落格，并钳制到 `0 ≤ col < width`、`0 ≤ row < height`，否则越界直接抛 `RangeError`。代码本身从不这么用——取格只发生在 `_buildImage` 的整数双层循环里（[base_map_layer.dart:53-57](file:///home/dxw/amr/amr_app/lib/map/layers/base_map_layer.dart#L53-L57)）。
