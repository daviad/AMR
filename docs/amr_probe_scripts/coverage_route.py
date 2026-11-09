#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""coverage_route.py —— 建图阶段室内全覆盖路线（真值闭环）

用途：Cartographer 建图时按脚本路线把室内每个区域都扫到，不只绕外墙。
- 反馈源：/gz_truth（Gazebo 真值位姿，仅用于脚本驾驶，不参与建图）
- 速度：直行 0.22-0.30 m/s，航向误差大时先原地对齐
- 判定：距目标 <0.12 m 视为到达；单点超时 90 s，总超时 900 s
- 停止：发送零速 5 s 后退出，输出 /tmp/amr_probe/coverage_route.json
"""
import json
import math
import time

import rclpy
from geometry_msgs.msg import Twist
from rclpy.node import Node
from tf2_msgs.msg import TFMessage

OUT = "/tmp/amr_probe/coverage_route.json"

# (x, y) —— 三个区域蛇形覆盖：下部横带 / 上部西区 / 上部东区
WAYPOINTS = [
    (-4.2, -0.6), (-4.2, -3.4), (0.0, -3.4), (4.4, -3.4),
    (4.4, -0.6), (0.0, -0.6), (-2.0, -0.6), (-4.2, -0.6),
    (-4.2, -1.9), (-2.0, -1.9),
    (-1.4, 0.3), (-4.5, 0.6), (-4.5, 3.5), (-3.4, 3.5),
    (-3.4, 1.3), (-1.2, 1.3), (-1.2, 3.5), (-0.1, 3.5),
    (-0.1, 0.9), (0.6, 0.9), (0.6, 0.2), (1.4, 0.2),
    (1.4, 0.6), (4.4, 0.6), (4.4, 1.9), (1.5, 1.9),
    (1.5, 3.5), (4.4, 3.5), (4.4, 3.1), (3.7, 3.1),
    (1.5, 3.1), (1.4, 0.2), (0.2, 0.2), (0.0, 0.0),
]


def wrap(a):
    while a > math.pi:
        a -= 2 * math.pi
    while a < -math.pi:
        a += 2 * math.pi
    return a


rclpy.init()
node = Node("coverage_route")
pub = node.create_publisher(Twist, "/cmd_vel", 10)
st = {"truth": None, "t": 0.0}


def on_truth(m):
    if not m.transforms:
        return
    tr = m.transforms[0].transform
    p = tr.translation
    q = tr.rotation
    yaw = math.atan2(2 * (q.w * q.z + q.x * q.y),
                     1 - 2 * (q.y * q.y + q.z * q.z))
    st["truth"] = (p.x, p.y, yaw)
    st["t"] = time.time()


node.create_subscription(TFMessage, "/gz_truth", on_truth, 10)


def spin_for(sec):
    t0 = time.time()
    while time.time() - t0 < sec:
        rclpy.spin_once(node, timeout_sec=0.05)


def send(v, w):
    t = Twist()
    t.linear.x = float(v)
    t.angular.z = float(w)
    pub.publish(t)


def stop():
    for _ in range(50):
        send(0.0, 0.0)
        spin_for(0.1)


# 唤醒真值（静止时 gz 不发 /gz_truth）
send(0.05, 0.0)
t0 = time.time()
while st["truth"] is None and time.time() - t0 < 6:
    rclpy.spin_once(node, timeout_sec=0.05)
stop()

if st["truth"] is None:
    print("ABORT: 未收到 /gz_truth", flush=True)
    node.destroy_node()
    rclpy.shutdown()
    raise SystemExit(1)

log = []
t_start = time.time()
for i, (gx, gy) in enumerate(WAYPOINTS):
    t_wp = time.time()
    reached = False
    while time.time() - t_wp < 90:
        rclpy.spin_once(node, timeout_sec=0.05)
        if time.time() - st["t"] > 5.0:
            send(0.0, 0.0)
            continue
        x, y, yaw = st["truth"]
        dx, dy = gx - x, gy - y
        dist = math.hypot(dx, dy)
        if dist < 0.12:
            reached = True
            break
        err = wrap(math.atan2(dy, dx) - yaw)
        if abs(err) > 0.55:
            send(0.0, math.copysign(min(0.6, 1.5 * abs(err)), err))
        else:
            v = 0.30 * max(0.35, math.cos(err))
            send(v, max(-0.7, min(0.7, 1.2 * err)))
    log.append({"i": i, "wp": [gx, gy], "reached": reached,
                "elapsed_s": round(time.time() - t_wp, 1),
                "pose": [round(st["truth"][0], 2), round(st["truth"][1], 2)]})
    print("WP %02d %s -> %s in %.1fs pose=%s" % (
        i, (gx, gy), "OK" if reached else "TIMEOUT",
        log[-1]["elapsed_s"], log[-1]["pose"]), flush=True)
    if time.time() - t_start > 900:
        print("ABORT: 总超时", flush=True)
        break

stop()
final = st["truth"]
out = {"waypoints": WAYPOINTS, "log": log,
       "total_s": round(time.time() - t_start, 1),
       "final_pose": [round(final[0], 3), round(final[1], 3),
                      round(math.degrees(final[2]), 1)]}
json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=1)
print("DONE", json.dumps({"total_s": out["total_s"],
                          "reached": sum(1 for r in log if r["reached"]),
                          "n": len(WAYPOINTS),
                          "final": out["final_pose"]}), flush=True)
node.destroy_node()
rclpy.shutdown()
