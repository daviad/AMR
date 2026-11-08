#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ground_diag2.py —— 贴地诊断：以 map/odom/base_footprint/base_link 为根，逐对打印 z"""
import json
import subprocess
import time

import rclpy
from rclpy.node import Node
from tf2_ros import Buffer, TransformListener

PAIRS = [
    ("map", "odom"), ("odom", "base_footprint"), ("base_footprint", "base_link"),
    ("base_footprint", "left_wheel_link"), ("base_footprint", "right_wheel_link"),
    ("base_footprint", "front_caster_link"), ("base_footprint", "rear_caster_link"),
    ("base_footprint", "top_link"), ("top_link", "lidar_link"),
    ("base_footprint", "imu_link"), ("map", "base_link"),
]

rclpy.init()
node = Node("ground_diag2")
buf = Buffer()
lis = TransformListener(buf, node)


def look(p, c):
    t0 = time.time()
    while time.time() - t0 < 6:
        rclpy.spin_once(node, timeout_sec=0.1)
        try:
            tr = buf.lookup_transform(p, c, rclpy.time.Time())
            v = tr.transform.translation
            return [round(v.x, 4), round(v.y, 4), round(v.z, 4)]
        except Exception:
            pass
    return None


res = {}
for p, c in PAIRS:
    res["%s->%s" % (p, c)] = look(p, c)

gz = None
for _ in range(20):
    try:
        out = subprocess.run(["gz", "model", "-m", "amr_robot", "-p"],
                             capture_output=True, text=True, timeout=4)
        ls = [l for l in out.stdout.strip().splitlines() if l.strip()]
        if len(ls) >= 2 and len(ls[-2].split()) == 3 and len(ls[-1].split()) == 3:
            gz = {"xyz": [float(v) for v in ls[-2].split()],
                  "rpy": [float(v) for v in ls[-1].split()]}
            break
    except Exception:
        pass
    time.sleep(0.1)
res["gz_model_pose"] = gz
print(json.dumps(res, ensure_ascii=False, indent=1))
with open("/tmp/amr_probe/ground_diag2.json", "w") as f:
    json.dump(res, f, ensure_ascii=False, indent=1)
node.destroy_node()
rclpy.shutdown()
