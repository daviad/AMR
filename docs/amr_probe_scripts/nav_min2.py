#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nav_min2.py —— 贴地/frame 修正后的最小导航复验（用 /amcl_pose 取位姿）"""
import json
import math
import time

import rclpy
from geometry_msgs.msg import PoseStamped, PoseWithCovarianceStamped
from nav2_msgs.action import NavigateToPose
from rclpy.action import ActionClient
from rclpy.node import Node

rclpy.init()
node = Node("nav_min2")
st = {"pose": None}


def cb(m):
    p = m.pose.pose.position
    q = m.pose.pose.orientation
    y = math.degrees(math.atan2(2 * (q.w * q.z + q.x * q.y),
                                1 - 2 * (q.y * q.y + q.z * q.z)))
    st["pose"] = {"xy": [round(p.x, 3), round(p.y, 3)], "yaw": round(y, 2),
                  "frame": m.header.frame_id}


node.create_subscription(PoseWithCovarianceStamped, "/amcl_pose", cb, 10)
ac = ActionClient(node, NavigateToPose, "navigate_to_pose")

t0 = time.time()
while st["pose"] is None and time.time() - t0 < 30:
    rclpy.spin_once(node, timeout_sec=0.1)
print("start", st["pose"])
print("server:", ac.wait_for_server(timeout_sec=20))

GOALS = [(-0.0, 0.0, 0.0), (0.45, -0.13, 0.0)]
res = []
for gx, gy, gyaw in GOALS:
    g = NavigateToPose.Goal()
    g.pose.header.frame_id = "map"
    g.pose.header.stamp = node.get_clock().now().to_msg()
    g.pose.pose.position.x = gx
    g.pose.pose.position.y = gy
    g.pose.pose.orientation.z = math.sin(math.radians(gyaw) / 2)
    g.pose.pose.orientation.w = math.cos(math.radians(gyaw) / 2)
    t = time.time()
    fut = ac.send_goal_async(g)
    rclpy.spin_until_future_complete(node, fut, timeout_sec=15)
    gh = fut.result()
    if gh is None or not gh.accepted:
        res.append({"goal": [gx, gy], "accepted": False})
        print("REJECTED", gx, gy, flush=True)
        continue
    f2 = gh.get_result_async()
    rclpy.spin_until_future_complete(node, f2, timeout_sec=150)
    status = f2.result().status if f2.done() else -1
    for _ in range(3):
        rclpy.spin_once(node, timeout_sec=0.05)
    res.append({"goal": [gx, gy], "status": int(status),
                "elapsed_s": round(time.time() - t, 2),
                "final": st["pose"]})
    print(json.dumps(res[-1], ensure_ascii=False), flush=True)

print("SUMMARY", json.dumps(res, ensure_ascii=False))
node.destroy_node()
rclpy.shutdown()
