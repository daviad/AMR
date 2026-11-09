#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""plan_probe.py —— 对 3 个航点逐个探测 /plan：全路径点数 + 占用栅格穿墙检查"""
import json
import math
import time

import rclpy
from nav2_msgs.action import NavigateToPose
from nav_msgs.msg import OccupancyGrid, Path
from rclpy.action import ActionClient
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile

GOALS = [(-3.8, 3.4, 90.0), (4.2, -3.2, -90.0), (0.5, 0.35, 180.0)]
OUT = "/tmp/amr_probe/plan_probe.json"

rclpy.init()
node = Node("plan_probe")
st = {"map": None, "plans": []}

qlat = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL)
node.create_subscription(OccupancyGrid, "/map", lambda m: st.__setitem__("map", m), qlat)
node.create_subscription(Path, "/plan", lambda m: st["plans"].append(m), 50)
ac = ActionClient(node, NavigateToPose, "navigate_to_pose")


def spin_for(sec):
    t0 = time.time()
    while time.time() - t0 < sec:
        rclpy.spin_once(node, timeout_sec=0.05)


spin_for(6)
print("server=%s map=%s" % (ac.wait_for_server(timeout_sec=20),
                            st["map"] is not None), flush=True)

m = st["map"]
res, ox, oy = m.info.resolution, m.info.origin.position.x, m.info.origin.position.y
w, h, data = m.info.width, m.info.height, m.data


def check(path):
    occ = unk = out = 0
    length = 0.0
    prev = None
    for ps in path.poses:
        p = ps.pose.position
        cx = int(math.floor((p.x - ox) / res))
        cy = int(math.floor((p.y - oy) / res))
        if not (0 <= cx < w and 0 <= cy < h):
            out += 1
        else:
            v = data[cy * w + cx]
            if v >= 65:
                occ += 1
            elif v < 0:
                unk += 1
        if prev is not None:
            length += math.hypot(p.x - prev[0], p.y - prev[1])
        prev = (p.x, p.y)
    return {"n": len(path.poses), "occupied": occ, "unknown": unk,
            "outside": out, "length_m": round(length, 2)}


results = []
for gx, gy, gyaw in GOALS:
    st["plans"] = []
    g = NavigateToPose.Goal()
    g.pose.header.frame_id = "map"
    g.pose.header.stamp = node.get_clock().now().to_msg()
    g.pose.pose.position.x = gx
    g.pose.pose.position.y = gy
    g.pose.pose.orientation.z = math.sin(math.radians(gyaw) / 2)
    g.pose.pose.orientation.w = math.cos(math.radians(gyaw) / 2)
    fut = ac.send_goal_async(g)
    rclpy.spin_until_future_complete(node, fut, timeout_sec=15)
    gh = fut.result()
    if gh is None or not gh.accepted:
        results.append({"goal": [gx, gy, gyaw], "accepted": False})
        print("REJECTED", gx, gy, flush=True)
        continue
    f2 = gh.get_result_async()
    rclpy.spin_until_future_complete(node, f2, timeout_sec=200)
    status = int(f2.result().status) if f2.done() else -1
    spin_for(1.0)
    plans = st["plans"]
    best = max(plans, key=lambda p: len(p.poses)) if plans else None
    rec = {"goal": [gx, gy, gyaw], "status": status, "plans_seen": len(plans),
           "plan_lengths": [len(p.poses) for p in plans][:12],
           "best_plan": check(best) if best else None}
    results.append(rec)
    print(json.dumps(rec, ensure_ascii=False), flush=True)

json.dump(results, open(OUT, "w"), ensure_ascii=False, indent=1)
print("SUMMARY", json.dumps(results, ensure_ascii=False), flush=True)
node.destroy_node()
rclpy.shutdown()
