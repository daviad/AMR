#!/usr/bin/env python3
"""带 cmd_vel 采样的单点导航诊断：python3 nav_rot_probe2.py X Y YAW"""
import math
import subprocess
import sys
import threading
import time

import rclpy
from geometry_msgs.msg import Twist
from nav2_msgs.action import NavigateToPose
from rosgraph_msgs.msg import Clock
from rclpy.action import ActionClient
from rclpy.executors import MultiThreadedExecutor
from rclpy.node import Node
from tf2_ros import Buffer, TransformListener


def yaw_of(q):
    return math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))


def truth_pose():
    for _ in range(20):
        out = subprocess.run(['gz', 'model', '-m', 'amr_robot', '-p'], capture_output=True, text=True).stdout.strip().splitlines()
        if len(out) >= 2:
            try:
                p = out[-2].strip().strip('[]').split()
                rpy = out[-1].strip().strip('[]').split()
                return float(p[0]), float(p[1]), float(rpy[2])
            except (ValueError, IndexError):
                pass
        time.sleep(0.3)
    raise RuntimeError('truth pose unavailable')


class Probe(Node):
    def __init__(self):
        super().__init__('rot_probe2')
        self.cli = ActionClient(self, NavigateToPose, 'navigate_to_pose')
        self.tf = Buffer()
        self.listener = TransformListener(self.tf, self)
        self.cmd = (0.0, 0.0)
        self.sim_t = 0.0
        self.create_subscription(Twist, '/cmd_vel', lambda m: setattr(self, 'cmd', (m.linear.x, m.angular.z)), 20)
        self.create_subscription(Clock, '/clock', lambda c: setattr(self, 'sim_t', c.clock.sec + c.clock.nanosec * 1e-9), 20)

    def map_pose(self):
        t = self.tf.lookup_transform('map', 'base_link', rclpy.time.Time())
        p = t.transform.translation
        return p.x, p.y, yaw_of(t.transform.rotation)


gx, gy, gyaw_deg = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
rclpy.init()
n = Probe()
ex = MultiThreadedExecutor()
ex.add_node(n)
threading.Thread(target=ex.spin, daemon=True).start()
while n.sim_t == 0.0:
    time.sleep(0.2)
while True:
    try:
        mp = n.map_pose()
        break
    except Exception:
        time.sleep(0.2)

goal = NavigateToPose.Goal()
goal.pose.header.frame_id = 'map'
goal.pose.header.stamp = n.get_clock().now().to_msg()
goal.pose.pose.position.x = gx
goal.pose.pose.position.y = gy
gyaw = math.radians(gyaw_deg)
goal.pose.pose.orientation.z = math.sin(gyaw / 2)
goal.pose.pose.orientation.w = math.cos(gyaw / 2)
print('start map yaw %.1f goal (%.2f,%.2f,%.1f)' % (math.degrees(mp[2]) % 360, gx, gy, gyaw_deg), flush=True)
fut = n.cli.send_goal_async(goal)
while not fut.done():
    time.sleep(0.1)
h = fut.result()
print('accepted', h.accepted, flush=True)
rf = h.get_result_async()
t0 = n.sim_t
i = 0
while n.sim_t - t0 < 60.0:
    tr = truth_pose()
    mp = n.map_pose()
    print('[%5.1f] cmd(lx=%+.3f az=%+.3f) truth(%6.2f,%6.2f,yaw %6.1f) map_yaw %6.1f done=%s' % (
        n.sim_t - t0, n.cmd[0], n.cmd[1], tr[0], tr[1], math.degrees(tr[2]) % 360,
        math.degrees(mp[2]) % 360, rf.done()), flush=True)
    time.sleep(0.5)
    i += 1
    if rf.done() and i > 4:
        break
print('status', rf.result().status if rf.done() else 'timeout', 'elapsed %.1f' % (n.sim_t - t0), flush=True)
if not rf.done():
    h.cancel_goal_async()
ex.shutdown()
rclpy.shutdown()
