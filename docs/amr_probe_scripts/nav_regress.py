#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nav_regress.py —— base_link -> base_footprint 改动后的最小回归（2 个航点）

航点 1：短距离（约 0.4 m），且相对当前朝向需要掉头；
航点 2：回到已验证的自由点，再掉头一次。
判定：status=4 SUCCEEDED；/plan 路径不落在占用栅格（>=65）与未知栅格（-1）；
      终点 AMCL 与 /gz_truth 的水平误差。
输出：/tmp/amr_probe/nav_regress.json
"""
import json
import math
import time

import rclpy
from geometry_msgs.msg import PoseStamped, PoseWithCovarianceStamped
from nav2_msgs.action import NavigateToPose
from nav_msgs.msg import OccupancyGrid, Path
from rclpy.action import ActionClient
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile
from tf2_msgs.msg import TFMessage

OUT = "/tmp/amr_probe/nav_regress.json"

rclpy.init()
node = Node("nav_regress")

st = {"amcl": None, "truth": None, "plan": None, "map": None}


def on_map(m):
    st["map"] = m


def on_plan(m):
    st["plan"] = m


def on_amcl(m):
    p = m.pose.pose.position
    q = m.pose.pose.orientation
    y = math.degrees(math.atan2(2 * (q.w * q.z + q.x * q.y),
                                1 - 2 * (q.y * q.y + q.z * q.z)))
    st["amcl"] = {"xy": [p.x, p.y], "yaw": round(y, 2)}


def on_truth(m):
    if not m.transforms:
        return
    tr = m.transforms[0].transform.translation
    st["truth"] = {"xy": [tr.x, tr.y], "z": tr.z}


qlat = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL)
node.create_subscription(OccupancyGrid, "/map", on_map, qlat)
node.create_subscription(Path, "/plan", on_plan, 10)
node.create_subscription(PoseWithCovarianceStamped, "/amcl_pose", on_amcl, 10)
node.create_subscription(TFMessage, "/gz_truth", on_truth, 10)
ac = ActionClient(node, NavigateToPose, "navigate_to_pose")


def spin_for(sec):
    t0 = time.time()
    while time.time() - t0 < sec:
        rclpy.spin_once(node, timeout_sec=0.05)


def plan_report():
    """统计 /plan 上落在占用/未知栅格的点数。"""
    if st["map"] is None or st["plan"] is None:
        return {"plan": None}
    m = st["map"]
    res, ox, oy = m.info.resolution, m.info.origin.position.x, m.info.origin.position.y
    w, h, data = m.info.width, m.info.height, m.data
    occ = unk = out = 0
    worst = []
    for ps in st["plan"].poses:
        cx = int(math.floor((ps.pose.position.x - ox) / res))
        cy = int(math.floor((ps.pose.position.y - oy) / res))
        if cx < 0 or cy < 0 or cx >= w or cy >= h:
            out += 1
            continue
        v = data[cy * w + cx]
        if v >= 65:
            occ += 1
            worst.append(round(v))
        elif v < 0:
            unk += 1
    return {"plan": True, "poses": len(st["plan"].poses),
            "occupied": occ, "unknown": unk, "outside": out}


GOALS = [(0.10, 0.10, 0.0), (0.45, -0.13, 0.0)]
res = []
spin_for(8)
print("map_ok=%s amcl=%s truth=%s" % (
    st["map"] is not None, st["amcl"], st["truth"]), flush=True)
print("server=%s" % ac.wait_for_server(timeout_sec=20), flush=True)

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
    status = int(f2.result().status) if f2.done() else -1
    spin_for(2.0)
    end = dict(st["amcl"]) if st["amcl"] else None
    truth = dict(st["truth"]) if st["truth"] else None
    err = None
    if end and truth:
        err = round(math.hypot(end["xy"][0] - truth["xy"][0],
                               end["xy"][1] - truth["xy"][1]), 3)
    rec = {"goal": [gx, gy], "status": status,
           "elapsed_s": round(time.time() - t, 2),
           "goal_err_m": round(math.hypot(end["xy"][0] - gx, end["xy"][1] - gy), 3)
           if end else None,
           "amcl_truth_err_m": err,
           "end_amcl": end, "end_truth": truth}
    rec.update(plan_report())
    res.append(rec)
    print(json.dumps(rec, ensure_ascii=False), flush=True)

print("SUMMARY", json.dumps(res, ensure_ascii=False), flush=True)
json.dump(res, open(OUT, "w"), ensure_ascii=False, indent=1)
node.destroy_node()
rclpy.shutdown()
