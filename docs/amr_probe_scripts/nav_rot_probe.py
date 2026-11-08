#!/usr/bin/env python3
"""原地定向诊断：目标=当前位置+指定偏航，采样 /cmd_vel 与各坐标系航向。"""
import json
import math
import subprocess
import threading
import time

import rclpy
from geometry_msgs.msg import PoseStamped, Twist
from nav2_msgs.action import NavigateToPose
from rosgraph_msgs.msg import Clock
from rclpy.action import ActionClient
from rclpy.node import Node
from rclpy.executors import MultiThreadedExecutor
from tf2_ros import Buffer, TransformListener


def wrap(a):
    while a > math.pi:
        a -= 2 * math.pi
    while a < -math.pi:
        a += 2 * math.pi
    return a


def yaw_of(q):
    return math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))


class Probe(Node):
    def __init__(self):
        super().__init__('rot_probe')
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


target_yaw_deg = float(__import__('sys').argv[1]) if len(__import__('sys').argv) > 1 else 0.0
rclpy.init()
n = Probe()
ex = MultiThreadedExecutor()
ex.add_node(n)
threading.Thread(target=ex.spin, daemon=True).start()
while n.sim_t == 0.0:
    time.sleep(0.2)
time.sleep(0.5)
tx, truth_y, truth_yaw = truth_pose()
mp = n.map_pose()
goal = NavigateToPose.Goal()
goal.pose.header.frame_id = 'map'
goal.pose.header.stamp = n.get_clock().now().to_msg()
goal.pose.pose.position.x = mp[0]
goal.pose.pose.position.y = mp[1]
gyaw = math.radians(target_yaw_deg)
goal.pose.pose.orientation.z = math.sin(gyaw / 2)
goal.pose.pose.orientation.w = math.cos(gyaw / 2)
print('start truth yaw %.1f map yaw %.1f target yaw %.1f' % (
    math.degrees(truth_yaw) % 360, math.degrees(mp[2]) % 360, target_yaw_deg), flush=True)
fut = n.cli.send_goal_async(goal)
while not fut.done():
    time.sleep(0.1)
h = fut.result()
print('accepted', h.accepted, flush=True)
rf = h.get_result_async()
t0 = n.sim_t
while not rf.done() and n.sim_t - t0 < 45.0:
    tr = truth_pose()
    mp = n.map_pose()
    print('[%5.1f] cmd(lx=%+.3f az=%+.3f) truth_yaw %6.1f map_yaw %6.1f' % (
        n.sim_t - t0, n.cmd[0], n.cmd[1], math.degrees(tr[2]) % 360, math.degrees(mp[2]) % 360), flush=True)
    time.sleep(0.5)
print('done status', rf.result().status if rf.done() else 'timeout', 'elapsed %.1f' % (n.sim_t - t0), flush=True)
ex.shutdown()
rclpy.shutdown()
