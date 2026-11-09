#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""nav3.py —— 新地图导航验证（3 个航点）

航点 1：跨越房间到西北远端（需绕过隔断，长路径）
航点 2：跨越到东南远端（房间另一端）
航点 3：就近点 + 目标朝向 180°（需要掉头）
判定：status=4 SUCCEEDED；/plan 不落在占用(>=65)/未知(-1)栅格；
      终点 AMCL 与 /gz_truth 真值误差；终点与目标的距离误差。
输出：/tmp/amr_probe/nav_newmap.json
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

OUT = "/tmp/amr_probe/nav_newmap.json"

rclpy.init()
node = Node("nav3")

st = {"amcl": None, "truth": None, "plan": None, "map": None}


def on_map(m):
    st["map"] = m


def on_plan(m):
    # 保留本航点内点数最多的一条（/plan 会分段发布，取最完整的一条做穿墙检查）
    if st["plan"] is None or len(m.poses) > len(st["plan"].poses):
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
    tr = m.transforms[0].transform
    p = tr.translation
    q = tr.rotation
    yaw = math.degrees(math.atan2(2 * (q.w * q.z + q.x * q.y),
                                  1 - 2 * (q.y * q.y + q.z * q.z)))
    st["truth"] = {"xy": [p.x, p.y], "z": p.z, "yaw": round(yaw, 2)}


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
    if st["map"] is None or st["plan"] is None:
        return {"plan": None}
    m = st["map"]
    res, ox, oy = m.info.resolution, m.info.origin.position.x, m.info.origin.position.y
    w, h, data = m.info.width, m.info.height, m.data
    occ = unk = out = 0
    for ps in st["plan"].poses:
        cx = int(math.floor((ps.pose.position.x - ox) / res))
        cy = int(math.floor((ps.pose.position.y - oy) / res))
        if cx < 0 or cy < 0 or cx >= w or cy >= h:
            out += 1
            continue
        v = data[cy * w + cx]
        if v >= 65:
            occ += 1
        elif v < 0:
            unk += 1
    return {"plan_poses": len(st["plan"].poses),
            "plan_occupied": occ, "plan_unknown": unk, "plan_outside": out}


def yaw_diff(a, b):
    d = (a - b + 180.0) % 360.0 - 180.0
    return abs(d)


GOALS = [
    (-3.8, 3.4, 90.0),    # 西北远端（绕过 partition_h1 / v1）
    (4.2, -3.2, -90.0),   # 东南远端（跨越整间房）
    (0.5, 0.35, 180.0),   # 就近点 + 目标朝向反向 = 必须掉头
]
res_out = []
spin_for(8)
print("map_ok=%s amcl=%s truth=%s" % (
    st["map"] is not None, st["amcl"], st["truth"]), flush=True)
print("server=%s" % ac.wait_for_server(timeout_sec=30), flush=True)

for gx, gy, gyaw in GOALS:
    g = NavigateToPose.Goal()
    g.pose.header.frame_id = "map"
    g.pose.header.stamp = node.get_clock().now().to_msg()
    g.pose.pose.position.x = gx
    g.pose.pose.position.y = gy
    g.pose.pose.orientation.z = math.sin(math.radians(gyaw) / 2)
    g.pose.pose.orientation.w = math.cos(math.radians(gyaw) / 2)
    st["plan"] = None
    t = time.time()
    fut = ac.send_goal_async(g)
    rclpy.spin_until_future_complete(node, fut, timeout_sec=15)
    gh = fut.result()
    if gh is None or not gh.accepted:
        res_out.append({"goal": [gx, gy, gyaw], "accepted": False})
        print("REJECTED", gx, gy, flush=True)
        continue
    f2 = gh.get_result_async()
    rclpy.spin_until_future_complete(node, f2, timeout_sec=240)
    status = int(f2.result().status) if f2.done() else -1
    spin_for(2.0)
    end = dict(st["amcl"]) if st["amcl"] else None
    truth = dict(st["truth"]) if st["truth"] else None
    err = yerr = None
    if end and truth:
        err = round(math.hypot(end["xy"][0] - truth["xy"][0],
                               end["xy"][1] - truth["xy"][1]), 3)
        yerr = round(yaw_diff(end["yaw"], truth["yaw"]), 1)
    rec = {"goal": [gx, gy, gyaw], "status": status,
           "elapsed_s": round(time.time() - t, 2),
           "goal_err_m": round(math.hypot(end["xy"][0] - gx, end["xy"][1] - gy), 3)
           if end else None,
           "goal_yaw_err_deg": round(yaw_diff(end["yaw"], gyaw), 1) if end else None,
           "amcl_truth_err_m": err, "amcl_truth_yaw_err_deg": yerr,
           "end_amcl": end, "end_truth": truth}
    rec.update(plan_report())
    res_out.append(rec)
    print(json.dumps(rec, ensure_ascii=False), flush=True)

print("SUMMARY", json.dumps(res_out, ensure_ascii=False), flush=True)
json.dump(res_out, open(OUT, "w"), ensure_ascii=False, indent=1)
node.destroy_node()
rclpy.shutdown()
