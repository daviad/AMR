#!/usr/bin/env python3
"""地图质量定量评估：与新生成的真值栅格逐像素比对。

指标：
1) 画布/分辨率/占用率/未知率
2) 逐墙覆盖率（沿墙中心线每 0.05 m 采样，法向 ±0.15 m 内有占用即算覆盖）
3) 墙厚中位数（沿法向统计连续占用像素长度）与双层墙比例（法向 ±0.35 m 内 >=2 段占用）
4) 伪占用（真值自由区且图中占用）
5) 混淆矩阵：TP/FP/FN/TN，召回率/精确率/IoU（只统计已观测像素 v>=0）
输出 /tmp/amr_probe/map_quality.json
"""
import json
import math
import threading
import time

import rclpy
from nav_msgs.msg import OccupancyGrid
from rclpy.executors import MultiThreadedExecutor
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy

# ---- 世界几何（indoor.world） ----
BOXES = [
    # (cx, cy, sx, sy, yaw)
    (-2.0, 2.0, 0.5, 0.5, 0.0),          # box_1
    (2.5, -1.5, 0.5, 0.5, 0.3),          # box_2
    (2.5, 0.0, 0.6, 0.6, 0.0),           # front_box_red
    (2.5, 1.2, 0.5, 0.5, 0.0),           # front_box_green
    (2.5, -1.2, 0.5, 0.5, 0.0),          # front_box_blue
    (-4.7, -3.4, 0.2, 0.4, 0.0),         # charge_dock_post
]
CYLINDERS = [(3.0, 2.5, 0.25), (-1.0, -2.5, 0.25)]
WALLS = [
    # (name, axis, fixed, lo, hi, normal)  axis='x' 表示墙沿 x 方向延伸
    ('wall_north', 'x', 4.0, -5.1, 5.1, (0, 1)),
    ('wall_south', 'x', -4.0, -5.1, 5.1, (0, 1)),
    ('wall_east', 'y', 5.0, -4.1, 4.1, (1, 0)),
    ('wall_west', 'y', -5.0, -4.1, 4.1, (1, 0)),
    ('partition_v1', 'y', 1.0, 0.5, 4.0, (1, 0)),
    ('partition_h1', 'x', 0.0, -5.0, -2.0, (0, 1)),
]
WALL_HALF_T = 0.05  # 墙厚 0.1 m


def in_box(x, y, cx, cy, sx, sy, yaw):
    ca, sa = math.cos(-yaw), math.sin(-yaw)
    dx, dy = x - cx, y - cy
    lx = ca * dx - sa * dy
    ly = sa * dx + ca * dy
    return abs(lx) <= sx / 2 + 1e-9 and abs(ly) <= sy / 2 + 1e-9


def truth_occ(x, y):
    for cx, cy, sx, sy, yaw in BOXES:
        if in_box(x, y, cx, cy, sx, sy, yaw):
            return True
    for cx, cy, r in CYLINDERS:
        if math.hypot(x - cx, y - cy) <= r + 1e-9:
            return True
    for name, axis, fixed, lo, hi, nrm in WALLS:
        if axis == 'x':
            if lo - 1e-9 <= x <= hi + 1e-9 and abs(y - fixed) <= WALL_HALF_T + 1e-9:
                return True
        else:
            if lo - 1e-9 <= y <= hi + 1e-9 and abs(x - fixed) <= WALL_HALF_T + 1e-9:
                return True
    return False


rclpy.init()
node = rclpy.create_node('map_quality')
h = {}
node.create_subscription(OccupancyGrid, '/map', lambda m: h.setdefault('m', m),
                         QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL,
                                    reliability=ReliabilityPolicy.RELIABLE))
ex = MultiThreadedExecutor()
ex.add_node(node)
threading.Thread(target=ex.spin, daemon=True).start()
for _ in range(150):
    if 'm' in h:
        break
    time.sleep(0.1)
m = h['m']
info = m.info
w, hh, res = info.width, info.height, info.resolution
ox, oy = info.origin.position.x, info.origin.position.y
data = m.data


def cell_at(x, y):
    c = int((x - ox) / res)
    r = int((y - oy) / res)
    if 0 <= c < w and 0 <= r < hh:
        return c, r, data[r * w + c]
    return None, None, None


occ = sum(1 for v in data if v >= 65)
free = sum(1 for v in data if 0 <= v < 25)
unk = w * hh - occ - free
known = occ + free

# ---- 逐墙覆盖率 / 墙厚 / 双层 ----
wall_stats = []
thick_samples = []
double_samples = []
for name, axis, fixed, lo, hi, nrm in WALLS:
    n_probe = n_cov = 0
    n = int((hi - lo) / 0.05) + 1
    for i in range(2, n - 2):  # 端点内缩，避开与其他墙的转角
        s = lo + i * 0.05
        px, py = (s, fixed) if axis == 'x' else (fixed, s)
        covered = False
        for off in [j * 0.05 for j in range(-3, 4)]:
            c, r, v = cell_at(px + nrm[0] * off, py + nrm[1] * off)
            if v is not None and v >= 65:
                covered = True
                break
        n_probe += 1
        n_cov += 1 if covered else 0
        # 法向 ±0.35 m 扫描占用段数 → 墙厚/双层
        runs = []
        cur = 0
        for j in range(-7, 8):
            off = j * 0.05
            c, r, v = cell_at(px + nrm[0] * off, py + nrm[1] * off)
            if v is not None and v >= 65:
                cur += 1
            else:
                if cur:
                    runs.append(cur)
                cur = 0
        if cur:
            runs.append(cur)
        if len(runs) == 1:
            thick_samples.append(runs[0] * res)
        elif len(runs) >= 2:
            double_samples.append(max(runs) * res)
    wall_stats.append({'name': name, 'probes': n_probe, 'covered': n_cov,
                       'coverage_pct': round(100.0 * n_cov / max(1, n_probe), 1)})

thick_sorted = sorted(thick_samples)
thick_med = thick_sorted[len(thick_sorted) // 2] if thick_sorted else None
n_all = len(thick_samples) + len(double_samples)

# ---- 混淆矩阵 ----
tp = fp = fn = tn = 0
for r in range(hh):
    y = oy + r * res
    for c in range(w):
        x = ox + c * res
        v = data[r * w + c]
        if v < 0:
            continue  # 未知像素不参与
        t = truth_occ(x, y)
        o = v >= 65
        if t and o:
            tp += 1
        elif o and not t:
            fp += 1
        elif t and not o:
            fn += 1
        else:
            tn += 1

# 伪占用：真值自由且距任一障碍 >=0.12 m 的像素里，图中占用
fp_strict = 0
free_strict = 0
for r in range(hh):
    y = oy + r * res
    for c in range(w):
        x = ox + c * res
        v = data[r * w + c]
        if v < 0 or truth_occ(x, y):
            continue
        # 距障碍 >=0.12 m 判定（用 truth_occ 采样邻域）
        far = True
        for ddx in (-0.12, 0, 0.12):
            for ddy in (-0.12, 0, 0.12):
                if truth_occ(x + ddx, y + ddy):
                    far = False
                    break
            if not far:
                break
        if far:
            free_strict += 1
            if v >= 65:
                fp_strict += 1

out = {
    'map': {'width': w, 'height': hh, 'resolution': res,
            'origin': [round(ox, 3), round(oy, 3)],
            'span_m': [round(w * res, 2), round(hh * res, 2)]},
    'counts': {'occupied': occ, 'free': free, 'unknown': unk, 'total': w * hh,
               'occ_ratio_pct': round(100.0 * occ / (w * hh), 2),
               'unknown_ratio_pct': round(100.0 * unk / (w * hh), 2)},
    'walls': wall_stats,
    'wall_coverage_overall_pct': round(100.0 * sum(x['covered'] for x in wall_stats) /
                                       max(1, sum(x['probes'] for x in wall_stats)), 1),
    'wall_thickness_median_m': round(thick_med, 3) if thick_med else None,
    'wall_thickness_samples': len(thick_samples),
    'double_layer_samples': len(double_samples),
    'double_layer_pct': round(100.0 * len(double_samples) / max(1, n_all), 1),
    'confusion': {'tp': tp, 'fp': fp, 'fn': fn, 'tn': tn,
                  'recall_pct': round(100.0 * tp / max(1, tp + fn), 2),
                  'precision_pct': round(100.0 * tp / max(1, tp + fp), 2),
                  'iou_pct': round(100.0 * tp / max(1, tp + fp + fn), 2)},
    'false_occ_strict': {'cells': fp_strict, 'free_strict_cells': free_strict,
                         'pct': round(100.0 * fp_strict / max(1, free_strict), 3)}
}
print(json.dumps(out, ensure_ascii=False, indent=1))
with open('/tmp/amr_probe/map_quality.json', 'w') as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
ex.shutdown()
rclpy.shutdown()
