"""地图落盘与版本：rosbridge /map → PGM(P5) + map.json。

编码约定（与 map_server 导出的一致）：
  0   = 占用（黑）
  254 = 空闲（白）
  205 = 未知（灰）
PGM 行序上→下（图片习惯）；App 解析后翻转成 OccupancyGrid 的行序（行 0 在底部）。
"""
from __future__ import annotations

import hashlib
import json
import os
import threading
import time


def _occ_to_pixel(value: int) -> int:
    if value < 0:
        return 205
    if value >= 65:
        return 0
    if value <= 25:
        return 254
    # 中间值（rare）：按占用概率线性映射
    return int(255 - (value / 100.0) * 255)


class MapCache:
    def __init__(self, maps_dir: str, on_update=None):
        self._dir = maps_dir
        self._lock = threading.Lock()
        self._meta: dict | None = None
        self._pgm: bytes | None = None
        self._on_update = on_update
        os.makedirs(self._dir, exist_ok=True)
        self._load_from_disk()

    # ── 对外读取 ──
    def meta(self) -> dict | None:
        with self._lock:
            return dict(self._meta) if self._meta else None

    def pgm(self, version: str | None) -> bytes | None:
        with self._lock:
            if not self._meta:
                return None
            if version and version != self._meta["version"]:
                return None
            return self._pgm

    # ── 写入（来自 rosbridge）──
    def update_from_ros(self, msg: dict) -> dict | None:
        info = msg.get("info") or {}
        data = msg.get("data")
        if not isinstance(data, list) or not info:
            return None
        width = int(info.get("width", 0))
        height = int(info.get("height", 0))
        if width <= 0 or height <= 0 or len(data) != width * height:
            return None
        resolution = float(info.get("resolution", 0.05))
        origin = (info.get("origin") or {}).get("position") or {}
        ox = float(origin.get("x", 0.0))
        oy = float(origin.get("y", 0.0))
        q = (info.get("origin") or {}).get("orientation") or {}
        oz = float(q.get("z", 0.0))
        ow = float(q.get("w", 1.0))
        yaw = _yaw_from_quat(oz, ow)

        raw = bytes(0 if v < 0 else max(0, min(100, int(v))) for v in data)
        version = hashlib.sha1(
            f"{width}|{height}|{resolution}|{ox}|{oy}|{yaw}|".encode("utf-8") + raw
        ).hexdigest()[:12]

        with self._lock:
            if self._meta and self._meta["version"] == version:
                return None  # 同一张图，不重复落盘/广播

        pixels = bytearray(width * height)
        # data 行 0 在世界坐标底部 → 翻转成图片行 0 在顶部
        for row in range(height):
            src = (height - 1 - row) * width
            dst = row * width
            for col in range(width):
                pixels[dst + col] = _occ_to_pixel(int(data[src + col]))

        pgm = b"P5\n%d %d\n255\n" % (width, height) + bytes(pixels)
        meta = {
            "version": version,
            "width": width,
            "height": height,
            "resolution": resolution,
            "origin": {"x": ox, "y": oy, "yaw": yaw},
            "row_order": "top_down",
            "encoding": "P5",
            "updated_at": int(time.time() * 1000),
        }
        self._write_atomic(pgm, meta)
        with self._lock:
            self._pgm = pgm
            self._meta = meta
        if self._on_update:
            self._on_update(dict(meta))
        return meta

    def _write_atomic(self, pgm: bytes, meta: dict):
        pgm_path = os.path.join(self._dir, "map.pgm")
        json_path = os.path.join(self._dir, "map.json")
        for path, blob in ((pgm_path, pgm),
                           (json_path, json.dumps(meta, ensure_ascii=False, indent=2).encode("utf-8"))):
            tmp = path + ".tmp"
            with open(tmp, "wb") as f:
                f.write(blob)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)

    def _load_from_disk(self):
        """网关重启后不必等 /map 也能继续服务（版本从磁盘恢复）。"""
        pgm_path = os.path.join(self._dir, "map.pgm")
        json_path = os.path.join(self._dir, "map.json")
        if not (os.path.exists(pgm_path) and os.path.exists(json_path)):
            return
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                meta = json.load(f)
            with open(pgm_path, "rb") as f:
                pgm = f.read()
            self._meta = meta
            self._pgm = pgm
        except (OSError, json.JSONDecodeError):
            pass


def _yaw_from_quat(z: float, w: float) -> float:
    import math
    return math.atan2(2.0 * w * z, 1.0 - 2.0 * z * z)
