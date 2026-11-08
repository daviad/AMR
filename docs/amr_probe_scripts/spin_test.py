#!/usr/bin/env python3
"""原地自旋标定：python3 spin_test.py GROUP
序列：+180/-180 各 5 次 + +360/-360 各 5 次，角速度 0.4 rad/s。
每组记录 odom yaw、AMCL(map->base_link) yaw、真值 yaw 的增量及比值。
"""
import json
import math
import subprocess
import sys
import threading
import time

import rclpy
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry
from rosgraph_msgs.msg import Clock
from rclpy.executors import MultiThreadedExecutor
from rclpy.node import Node
from tf2_ros import Buffer, TransformListener

GROUP = sys.argv[1] if len(sys.argv) > 1 else 'A'
OMEGA = 0.4
SETTLE_S = 2.5
SEQ = [(180, 1), (180, -1), (180, 1), (180, -1), (180, 1),
       (360, 1), (360, -1), (360, 1), (360, -1), (360, 1)]


def wrap(a):
    while a > math.pi:
        a -= 2 * math.pi
    while a < -math.pi:
        a += 2 * math.pi
    return a


def yaw_of(q):
    return math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))


def truth_pose():
    for _ in range(20):
        out = subprocess.run(['gz', 'model', '-m', 'amr_robot', '-p'],
                             capture_output=True, text=True).stdout.strip().splitlines()
        if len(out) >= 2:
            try:
                p = out[-2].strip().strip('[]').split()
                rpy = out[-1].strip().strip('[]').split()
                return float(p[0]), float(p[1]), float(p[2]), float(rpy[2])
            except (ValueError, IndexError):
                pass
        time.sleep(0.2)
    raise RuntimeError('truth pose unavailable')


class Spin(Node):
    def __init__(self):
        super().__init__('spin_test')
        self.pub = self.create_publisher(Twist, '/cmd_vel', 10)
        self.odom = None
        self.sim_t = 0.0
        self.tf = Buffer()
        self.listener = TransformListener(self.tf, self)
        self.create_subscription(Odometry, '/odom', self.on_odom, 20)
        self.create_subscription(Clock, '/clock', self.on_clock, 20)

    def on_odom(self, m):
        p = m.pose.pose.position
        self.odom = (p.x, p.y, yaw_of(m.pose.pose.orientation))

    def on_clock(self, c):
        self.sim_t = c.clock.sec + c.clock.nanosec * 1e-9

    def map_yaw(self):
        for _ in range(10):
            try:
                t = self.tf.lookup_transform('map', 'base_link', rclpy.time.Time())
                return yaw_of(t.transform.rotation)
            except Exception:
                time.sleep(0.2)
        return None

    def spin(self, deg, sign):
        dur = math.radians(deg) / OMEGA
        z = OMEGA * sign
        t0 = self.sim_t
        period = 0.05
        while self.sim_t - t0 < dur:
            msg = Twist()
            msg.angular.z = z
            self.pub.publish(msg)
            time.sleep(period)
        msg = Twist()
        self.pub.publish(msg)
        t_end = self.sim_t
        stop = t_end
        while self.sim_t - stop < SETTLE_S:
            self.pub.publish(Twist())
            time.sleep(0.05)
        return t_end - t0


rclpy.init()
n = Spin()
ex = MultiThreadedExecutor()
ex.add_node(n)
threading.Thread(target=ex.spin, daemon=True).start()
while n.sim_t == 0.0 or n.odom is None:
    time.sleep(0.2)
time.sleep(0.5)

rows = []
for i, (deg, sign) in enumerate(SEQ):
    o0 = n.odom[2]
    m0 = n.map_yaw()
    tr0 = truth_pose()
    dur = n.spin(deg, sign)
    o1 = n.odom[2]
    m1 = n.map_yaw()
    tr1 = truth_pose()
    cmd = math.radians(deg) * sign
    odom_d = wrap(o1 - o0)
    map_d = wrap(m1 - m0) if (m0 is not None and m1 is not None) else None
    truth_d = wrap(tr1[3] - tr0[3])
    rows.append({
        'i': i + 1, 'cmd_deg': deg * sign, 'cmd_s': round(dur, 2),
        'odom_deg': round(math.degrees(odom_d), 2),
        'amcl_deg': round(math.degrees(map_d), 2) if map_d is not None else None,
        'truth_deg': round(math.degrees(truth_d), 2),
        'odom_over_cmd': round(odom_d / cmd, 4),
        'truth_over_cmd': round(truth_d / cmd, 4),
        'odom_over_truth': round(odom_d / truth_d, 4) if abs(truth_d) > 1e-4 else None,
        'amcl_over_truth': round(map_d / truth_d, 4) if (map_d is not None and abs(truth_d) > 1e-4) else None,
        'truth_xy': [round(tr1[0], 3), round(tr1[1], 3)],
    })
    print(json.dumps(rows[-1], ensure_ascii=False), flush=True)


def summary(key, magset):
    vals = [r[key] for r in rows if abs(r['cmd_deg']) == magset and r[key] is not None]
    if not vals:
        return None
    mean = sum(vals) / len(vals)
    var = sum((v - mean) ** 2 for v in vals) / len(vals)
    return {'n': len(vals), 'mean': round(mean, 4), 'std': round(math.sqrt(var), 4)}


summ = {}
for mag in (180, 360):
    for key in ('odom_over_cmd', 'truth_over_cmd', 'odom_over_truth', 'amcl_over_truth'):
        summ['%s_%d' % (key, mag)] = summary(key, mag)
out = {'group': GROUP, 'omega': OMEGA, 'reps': rows, 'summary': summ}
path = '/tmp/amr_probe/spin_%s.json' % GROUP
with open(path, 'w') as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print('WROTE', path, json.dumps(summ, ensure_ascii=False))
ex.shutdown()
rclpy.shutdown()
