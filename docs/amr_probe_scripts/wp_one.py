#!/usr/bin/env python3
"""单航点可达性复测：python3 wp_one.py NAME X Y YAW"""
import json
import math
import sys

sys.argv += []
import importlib.util

spec = importlib.util.spec_from_file_location('wpr', '/tmp/amr_probe/wp_reach.py')
# 直接复用 wp_reach.py 里的类和函数（不执行其主流程）
src = open('/tmp/amr_probe/wp_reach.py').read()
src = src.split("rclpy.init()")[0]
mod = type(sys)('wpr')
exec(compile(src, 'wp_reach_core', 'exec'), mod.__dict__)
import rclpy

name = sys.argv[1]
gx, gy, gyaw = float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])

rclpy.init()
n = mod.Nav()
import threading
from rclpy.executors import MultiThreadedExecutor
ex = MultiThreadedExecutor()
ex.add_node(n)
threading.Thread(target=ex.spin, daemon=True).start()
import time
while n.map is None or n.sim_t == 0.0:
    time.sleep(0.2)
while n.map_pose() is None:
    time.sleep(0.2)
if not n.cli.wait_for_server(timeout_sec=5.0):
    print('ACTION SERVER NOT AVAILABLE')
    raise SystemExit(1)
r = n.goto((gx, gy, gyaw), timeout=120.0)
time.sleep(1.0)
tr = mod.truth_pose()
mp = n.map_pose()
plan = n.check_plan()
rec = {
    'name': name, 'goal': [gx, gy, gyaw], 'ok': r['ok'], 'status': r.get('status'),
    'reason': r.get('reason'), 'elapsed_sim_s': r.get('elapsed_sim_s'),
    'truth_xy_m_yaw_deg': [round(tr[0], 3), round(tr[1], 3), round(math.degrees(tr[2]) % 360, 1)],
    'goal_err_truth_m': round(math.hypot(tr[0] - gx, tr[1] - gy), 3),
    'goal_yaw_err_truth_deg': round(math.degrees(mod.wrap(tr[2] - gyaw)), 2),
    'map_vs_truth_m': round(math.hypot(mp[0] - tr[0], mp[1] - tr[1]), 3) if mp else None,
    'map_vs_truth_yaw_deg': round(math.degrees(mod.wrap(mp[2] - tr[2])), 2) if mp else None,
    'plan': plan,
}
print(json.dumps(rec, ensure_ascii=False))
with open('/tmp/amr_probe/wp_one.json', 'w') as f:
    json.dump(rec, f, ensure_ascii=False, indent=1)
ex.shutdown()
rclpy.shutdown()
