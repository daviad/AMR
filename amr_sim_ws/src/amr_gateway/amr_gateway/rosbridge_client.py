"""rosbridge 客户端：网关是它唯一的业务客户端。

为什么用 rosbridge 而不是 rclpy：
- 网关保持纯 Python，不需要 source ROS 环境、不受 DDS 配置影响；
- /map 是 TRANSIENT_LOCAL + latched，rosbridge 对每个 topic 只建一个 DDS 订阅，
  由“第一个订阅者”的 QoS 决定。网关独占订阅，所以 QoS 固定在这里，客户端再多也
  不会把 QoS 带偏（这正是旧 App 直连时“等待地图数据…”的根因）。

订阅清单（与 docs/架构-网关收口.md §4 一致）：
  /map                        nav_msgs/OccupancyGrid            latched
  /amcl_pose                  geometry_msgs/PoseWithCovarianceStamped
  /tf                         tf2_msgs/TFMessage
  /plan                       nav_msgs/Path
  /scan                       sensor_msgs/LaserScan
  /camera/image_raw/compressed sensor_msgs/CompressedImage
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import math
import time

import websockets

log = logging.getLogger("gateway.rosbridge")

LATCHED_QOS = {
    "durability": "transient_local",
    "reliability": "reliable",
    "history": "keep_last",
    "depth": 1,
}

SUBSCRIPTIONS = [
    {"topic": "/map", "type": "nav_msgs/OccupancyGrid",
     "queue_length": 1, "qos": LATCHED_QOS},
    {"topic": "/amcl_pose", "type": "geometry_msgs/PoseWithCovarianceStamped",
     "queue_length": 1, "throttle_rate": 50},
    {"topic": "/tf", "type": "tf2_msgs/TFMessage",
     "queue_length": 1, "throttle_rate": 100},
    {"topic": "/plan", "type": "nav_msgs/Path",
     "queue_length": 1, "throttle_rate": 200},
    {"topic": "/scan", "type": "sensor_msgs/LaserScan",
     "queue_length": 1, "throttle_rate": 250},
    {"topic": "/camera/image_raw/compressed", "type": "sensor_msgs/CompressedImage",
     "queue_length": 1, "throttle_rate": 300},
]


class RosbridgeFeed:
    def __init__(self, url: str, map_cache, hub, policy: dict):
        self._url = url
        self._map = map_cache
        self._hub = hub
        self._policy = policy
        self._connected = False
        self._stop = False
        self._last_pose_bcast = 0.0
        self._last_pose = None          # (x, y, yaw) 用于把激光点旋到 map 系
        self._latest_jpeg: bytes | None = None
        self._latest_jpeg_ts = 0.0
        self._pose_interval = float(policy.get("pose_min_interval_ms", 50)) / 1000.0
        self._scan_stride = max(1, int(policy.get("scan_stride", 4)))

    @property
    def connected(self) -> bool:
        return self._connected

    def snapshot_jpeg(self) -> bytes | None:
        return self._latest_jpeg

    async def run(self):
        """断线 2s 退避重连；重连后重新订阅（rosbridge 不保留订阅）。"""
        backoff = 2.0
        while not self._stop:
            try:
                async with websockets.connect(
                        self._url, ping_interval=None, max_size=8 * 2 ** 20,
                        open_timeout=5) as ws:
                    log.info("rosbridge 已连接：%s", self._url)
                    await self._subscribe_all(ws)
                    was_connected = self._connected
                    self._connected = True
                    if not was_connected:
                        self._hub.broadcast("degraded", {
                            "component": "rosbridge", "up": True,
                            "detail": "rosbridge connected"})
                    ping = asyncio.create_task(self._ping_loop(ws))
                    try:
                        async for raw in ws:
                            self._dispatch(raw)
                    finally:
                        ping.cancel()
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001
                log.warning("rosbridge 断开：%s", e)
            finally:
                if self._connected:
                    self._connected = False
                    self._hub.broadcast("degraded", {
                        "component": "rosbridge", "up": False,
                        "detail": "rosbridge disconnected"})
            await asyncio.sleep(backoff)

    def stop(self):
        self._stop = True

    async def _subscribe_all(self, ws):
        for sub in SUBSCRIPTIONS:
            await ws.send(json.dumps({"op": "subscribe", **sub}))

    async def _ping_loop(self, ws):
        # rosbridge 自身不主动发心跳，客户端每 5s 发一次 op=ping 保活
        while True:
            await asyncio.sleep(5)
            try:
                await ws.send(json.dumps({"op": "ping"}))
            except Exception:  # noqa: BLE001
                return

    # ───────────────── 消息分发 ─────────────────
    def _dispatch(self, raw):
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            return
        if msg.get("op") != "publish":
            return
        topic = msg.get("topic")
        payload = msg.get("msg")
        if topic is None or not isinstance(payload, dict):
            return
        try:
            if topic == "/map":
                self._on_map(payload)
            elif topic == "/amcl_pose":
                self._on_pose(payload, "amcl")
            elif topic == "/tf":
                self._on_tf(payload)
            elif topic == "/plan":
                self._on_plan(payload)
            elif topic == "/scan":
                self._on_scan(payload)
            elif topic == "/camera/image_raw/compressed":
                self._on_image(payload)
        except Exception as e:  # noqa: BLE001 - 单条消息异常不能打断订阅
            log.debug("处理 %s 失败：%s", topic, e)

    def _on_map(self, msg):
        meta = self._map.update_from_ros(msg)
        if meta is None:
            return
        self._hub.broadcast("map_meta", {
            "version": meta["version"], "width": meta["width"],
            "height": meta["height"], "resolution": meta["resolution"],
            "updated_at": meta["updated_at"],
        })

    def _on_pose(self, msg, source):
        pose = (msg.get("pose") or {}).get("pose") or {}
        p = pose.get("position") or {}
        o = pose.get("orientation") or {}
        x = float(p.get("x", 0.0))
        y = float(p.get("y", 0.0))
        yaw = _yaw(o.get("z", 0.0), o.get("w", 1.0))
        self._emit_pose(x, y, yaw, source)

    def _on_tf(self, msg):
        for tr in msg.get("transforms") or []:
            parent = str(tr.get("header", {}).get("frame_id", "")).lstrip("/")
            child = str(tr.get("child_frame_id", "")).lstrip("/")
            if parent in ("map", "odom") and child in ("base_link", "base_footprint"):
                t = tr.get("transform") or {}
                p = t.get("translation") or {}
                r = t.get("rotation") or {}
                self._emit_pose(float(p.get("x", 0.0)), float(p.get("y", 0.0)),
                                _yaw(r.get("z", 0.0), r.get("w", 1.0)), "tf")
                return

    def _emit_pose(self, x, y, yaw, source):
        now = time.monotonic()
        self._last_pose = (x, y, yaw)
        # 节流：rosbridge 已按 throttle_rate 限频，这里再兜一层防止 ws 洪泛
        if now - self._last_pose_bcast < self._pose_interval:
            return
        self._last_pose_bcast = now
        self._hub.broadcast("pose", {
            "x": round(x, 3), "y": round(y, 3), "theta": round(yaw, 4),
            "source": source, "stamp_ms": _now_ms(),
        })

    def _on_plan(self, msg):
        points = []
        for p in msg.get("poses") or []:
            pos = ((p or {}).get("pose") or {}).get("position") or {}
            if "x" not in pos or "y" not in pos:
                continue
            points.append([round(float(pos["x"]), 3), round(float(pos["y"]), 3)])
        self._hub.broadcast("plan", {"points": points, "stamp_ms": _now_ms()})

    def _on_scan(self, msg):
        ranges = msg.get("ranges") or []
        angle_min = float(msg.get("angle_min", 0.0))
        angle_inc = float(msg.get("angle_increment", 0.0))
        range_max = float(msg.get("range_max", 12.0))
        pose = self._last_pose or (0.0, 0.0, 0.0)
        ox, oy, oyaw = pose
        points = []
        # 每 stride 个采样一次；App 侧只用来看“雷达扫到什么”，不做建图
        for i in range(0, len(ranges), self._scan_stride):
            r = ranges[i]
            if not isinstance(r, (int, float)):
                continue
            if not math.isfinite(r) or r <= 0.05 or r >= range_max:
                continue
            a = oyaw + angle_min + angle_inc * i
            points.append([round(ox + r * math.cos(a), 3),
                           round(oy + r * math.sin(a), 3)])
        self._hub.broadcast("scan", {"points": points[:400], "stamp_ms": _now_ms()})

    def _on_image(self, msg):
        data = msg.get("data")
        if not isinstance(data, str):
            return
        try:
            self._latest_jpeg = base64.b64decode(data)
            self._latest_jpeg_ts = time.monotonic()
        except (ValueError, TypeError):
            pass

    def image_age_s(self) -> float | None:
        if self._latest_jpeg is None:
            return None
        return time.monotonic() - self._latest_jpeg_ts


def _yaw(z, w) -> float:
    return math.atan2(2.0 * float(w) * float(z), 1.0 - 2.0 * float(z) ** 2)


def _now_ms() -> int:
    return int(time.time() * 1000)
