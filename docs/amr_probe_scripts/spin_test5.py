#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""spin_test5.py  GROUP  —— 原地自旋 + 直线标定（/gz_truth 真值 + 连续解缠）

真值来源改为已有的 /gz_truth（bridge: /world/indoor/dynamic_pose/info -> TFMessage），
不再调用 `gz model -p`（当前 gz 服务 80% 概率 5 s 超时，会把一轮拖到 15 min）。
段内 20 Hz 连续采样 /odom、map->base_link、/gz_truth 三路 yaw 并解缠；
段首尾用墙钟计时（RTF≈1），不再依赖 /odom 时间戳。

用法: python3 spin_test5.py A|B|C
输出: /tmp/amr_probe/spin5_<GROUP>.json
"""
import json
import math
import sys
import time

import rclpy
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry
from rclpy.node import Node
from sensor_msgs.msg import JointState, LaserScan
from tf2_ros import Buffer, TransformListener
from tf2_msgs.msg import TFMessage

GROUP = sys.argv[1] if len(sys.argv) > 1 else "A"
OUT = "/tmp/amr_probe/spin5_%s.json" % GROUP

OMEGA = 0.4
VLINE = 0.20
SETTLE_S = 2.5
WHEEL_SEP = 0.33
WHEEL_R = 0.06

SEQ = [(180, 1), (180, -1), (180, 1), (180, -1), (180, 1),
       (360, 1), (360, -1), (360, 1), (360, -1), (360, 1)]


def unwrap_step(prev, cur):
    return (cur - prev + 180.0) % 360.0 - 180.0


def yaw_from_quat(q):
    return math.degrees(math.atan2(2.0 * (q.w * q.z + q.x * q.y),
                                   1.0 - 2.0 * (q.y * q.y + q.z * q.z)))


class Spin(Node):
    def __init__(self):
        super().__init__("spin_probe5")
        self.pub = self.create_publisher(Twist, "/cmd_vel", 10)
        self.odom = None
        self.js = None
        self.min_range = None
        self.tyaw = None
        self.txy = None
        self.truth_n = 0
        self.truth_frames = set()
        self.create_subscription(Odometry, "/odom", self._odom, 10)
        self.create_subscription(JointState, "/joint_states", self._js, 10)
        self.create_subscription(LaserScan, "/scan", self._scan, 10)
        self.create_subscription(TFMessage, "/gz_truth", self._truth, 10)
        self.buf = Buffer()
        self.listener = TransformListener(self.buf, self)
        self._prev = None
        self._acc = [0.0, 0.0, 0.0]

    def _odom(self, msg):
        self.odom = msg

    def _js(self, msg):
        self.js = msg

    def _scan(self, msg):
        ok = [r for r in msg.ranges if r > 0.0 and not math.isnan(r)]
        self.min_range = round(min(ok), 3) if ok else None

    def _truth(self, msg):
        # /gz_truth（= /world/indoor/dynamic_pose/info）每帧只带模型位姿，
        # child_frame_id 为空；取第一帧即 amr_robot 的世界位姿（z=0.08 = base_link）。
        self.truth_n += 1
        if not msg.transforms:
            return
        tr = msg.transforms[0]
        self.truth_frames.add("%r->%r" % (tr.header.frame_id, tr.child_frame_id))
        self.tyaw = yaw_from_quat(tr.transform.rotation)
        p = tr.transform.translation
        self.txy = [round(p.x, 3), round(p.y, 3)]

    def _tf_yaw(self, parent, child):
        try:
            tr = self.buf.lookup_transform(parent, child, rclpy.time.Time())
        except Exception:
            return None
        return yaw_from_quat(tr.transform.rotation)

    def _acc_sample(self):
        if self.odom is None:
            return
        o = yaw_from_quat(self.odom.pose.pose.orientation)
        a = self._tf_yaw("map", "base_link")
        t = self.tyaw
        if self._prev is None:
            self._prev = (o, a, t)
            return
        po, pa, pt = self._prev
        self._acc[0] += unwrap_step(po, o)
        if a is not None and pa is not None:
            self._acc[1] += unwrap_step(pa, a)
        if t is not None and pt is not None:
            self._acc[2] += unwrap_step(pt, t)
        self._prev = (o, a if a is not None else pa, t if t is not None else pt)

    def pump(self, twist, dur):
        t0 = time.time()
        while time.time() - t0 < dur:
            self.pub.publish(twist)
            for _ in range(2):
                rclpy.spin_once(self, timeout_sec=0.0)
            self._acc_sample()
            time.sleep(0.02)

    def spin(self, deg, sign):
        self.pump(_tw(0.0, OMEGA * sign), math.radians(deg) / OMEGA)
        self.pump(_tw(0.0, 0.0), SETTLE_S)

    def go_line(self, dist):
        sign = 1.0 if dist > 0 else -1.0
        self.pump(_tw(VLINE * sign, 0.0), abs(dist) / VLINE)
        self.pump(_tw(0.0, 0.0), SETTLE_S)

    def wheel_deg(self):
        if self.js is None or len(self.js.name) < 2:
            return None
        pos = dict(zip(self.js.name, self.js.position))
        l = pos.get("left_wheel_joint")
        r = pos.get("right_wheel_joint")
        if l is None or r is None:
            return None
        return math.degrees((r - l) * WHEEL_R / WHEEL_SEP)

    def reset_acc(self):
        self._prev = None
        self._acc = [0.0, 0.0, 0.0]
        for _ in range(6):
            rclpy.spin_once(self, timeout_sec=0.0)
        self._acc_sample()


def _tw(lin, ang):
    m = Twist()
    m.linear.x = lin
    m.angular.z = ang
    return m


def ratio(d, n):
    return round(d / n, 4) if n else None


def summarize(rows, key):
    vals = [r[key] for r in rows if r.get(key) is not None]
    if not vals:
        return None
    n = len(vals)
    mean = sum(vals) / n
    var = sum((v - mean) ** 2 for v in vals) / n if n > 1 else 0.0
    return {"n": n, "mean": round(mean, 4), "std": round(math.sqrt(var), 4),
            "min": round(min(vals), 4), "max": round(max(vals), 4)}


def main():
    rclpy.init()
    node = Spin()
    t0 = time.time()
    while node.odom is None and time.time() - t0 < 30:
        rclpy.spin_once(node, timeout_sec=0.1)
    if node.odom is None:
        print("NO ODOM")
        return
    # 预热：静止时 gz 不发 dynamic_pose，先动一下把 /gz_truth 唤醒
    for _ in range(4):
        node.pub.publish(_tw(0.0, 0.25))
        for _ in range(2):
            rclpy.spin_once(node, timeout_sec=0.0)
        time.sleep(0.1)
    node.pump(_tw(0.0, 0.0), 2.5)
    print("ready, truth_msgs=%d frames=%s" % (node.truth_n, sorted(node.truth_frames)))
    if node.truth_n == 0:
        print("NO TRUTH")
        return

    rows = []
    for i, (deg, sign) in enumerate(SEQ, 1):
        node.reset_acc()
        w0 = node.wheel_deg()
        r0 = node.min_range
        node.spin(deg, sign)
        for _ in range(10):
            rclpy.spin_once(node, timeout_sec=0.0)
        d_odom, d_amcl, d_truth = node._acc
        w1 = node.wheel_deg()
        cmd = deg * sign
        d_wheel = None if (w0 is None or w1 is None) else (w1 - w0)
        rec = {
            "i": i, "cmd_deg": cmd,
            "odom_deg": round(d_odom, 2), "amcl_deg": round(d_amcl, 2),
            "truth_deg": round(d_truth, 2),
            "wheel_deg": None if d_wheel is None else round(d_wheel, 2),
            "odom_over_cmd": ratio(d_odom, cmd),
            "amcl_over_cmd": ratio(d_amcl, cmd),
            "truth_over_cmd": ratio(d_truth, cmd),
            "wheel_over_cmd": None if d_wheel is None else ratio(d_wheel, cmd),
            "truth_over_odom": None if d_odom == 0 else ratio(d_truth, d_odom),
            "amcl_over_truth": None if d_truth == 0 else ratio(d_amcl, d_truth),
            "scan_min_before": r0, "scan_min_after": node.min_range,
            "truth_xy": node.txy,
        }
        rows.append(rec)
        print(json.dumps(rec, ensure_ascii=False), flush=True)

    line = []
    for dist in (1.0, -1.0):
        node.reset_acc()
        w0 = node.wheel_deg()
        o0 = (node.odom.pose.pose.position.x, node.odom.pose.pose.position.y)
        t0xy = list(node.txy) if node.txy else None
        node.go_line(dist)
        for _ in range(10):
            rclpy.spin_once(node, timeout_sec=0.0)
        w1 = node.wheel_deg()
        o1 = (node.odom.pose.pose.position.x, node.odom.pose.pose.position.y)
        t1xy = list(node.txy) if node.txy else None
        d_truth = None if (t0xy is None or t1xy is None) else math.hypot(
            t1xy[0] - t0xy[0], t1xy[1] - t0xy[1])
        d_odom = math.hypot(o1[0] - o0[0], o1[1] - o0[1])
        d_wheel = None if (w0 is None or w1 is None) else math.radians(abs(w1 - w0)) * WHEEL_R
        rec = {
            "cmd_m": dist,
            "odom_m": round(d_odom, 4),
            "truth_m": None if d_truth is None else round(d_truth, 4),
            "wheel_m": None if d_wheel is None else round(d_wheel, 4),
            "truth_over_cmd": None if d_truth is None else ratio(d_truth, abs(dist)),
            "odom_over_truth": None if (d_truth in (None, 0)) else round(d_odom / d_truth, 4),
            "wheel_over_truth": None if (d_wheel is None or d_truth in (None, 0)) else round(d_wheel / d_truth, 4),
            "scan_min": node.min_range,
        }
        line.append(rec)
        print(json.dumps(rec, ensure_ascii=False), flush=True)

    r180 = [r for r in rows if r["cmd_deg"] == 180]
    r360 = [r for r in rows if r["cmd_deg"] == 360]
    keys = ("odom_over_cmd", "amcl_over_cmd", "truth_over_cmd",
            "wheel_over_cmd", "truth_over_odom", "amcl_over_truth")
    out = {"group": GROUP, "rows": rows, "line": line,
           "truth_msgs_total": node.truth_n,
           "truth_frames": sorted(node.truth_frames),
           "summary": {"180": {k: summarize(r180, k) for k in keys},
                       "360": {k: summarize(r360, k) for k in keys}}}
    with open(OUT, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print("WROTE", OUT)
    node.destroy_node()
    rclpy.shutdown()


if __name__ == "__main__":
    main()
