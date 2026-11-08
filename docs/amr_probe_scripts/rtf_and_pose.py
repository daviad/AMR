#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rtf_and_pose.py —— 打印实时因子 RTF 与 /gz_truth 的模型位姿 xyz"""
import time

import rclpy
from geometry_msgs.msg import Twist
from rclpy.node import Node
from rosgraph_msgs.msg import Clock
from tf2_msgs.msg import TFMessage

rclpy.init()
node = Node("rtf_pose")
node.pub = node.create_publisher(Twist, "/cmd_vel", 10)
st = {"clock": None, "xyz": None, "n": 0}


def cb(c):
    st["clock"] = c.clock.sec + c.clock.nanosec * 1e-9


def tb(m):
    if m.transforms:
        p = m.transforms[0].transform.translation
        st["xyz"] = [round(p.x, 3), round(p.y, 3), round(p.z, 3)]
        st["n"] += 1


node.create_subscription(Clock, "/clock", cb, 10)
node.create_subscription(TFMessage, "/gz_truth", tb, 10)

t = time.time()
drain = time.time() + 3
while time.time() < drain:
    rclpy.spin_once(node, timeout_sec=0.02)

# 动一下让 /gz_truth 开始发
m = Twist()
m.angular.z = 0.15
t0 = time.time()
while time.time() - t0 < 1.2:
    node.pub.publish(m)
    rclpy.spin_once(node, timeout_sec=0.0)
    time.sleep(0.03)
m.angular.z = 0.0
t0 = time.time()
while time.time() - t0 < 2.0:
    node.pub.publish(m)
    rclpy.spin_once(node, timeout_sec=0.0)
    time.sleep(0.03)

c0 = st["clock"]
w0 = time.time()
time.sleep(8)
while st["clock"] is not None and time.time() - w0 < 8.3:
    rclpy.spin_once(node, timeout_sec=0.02)
c1 = st["clock"]
dw = 8.2
print("clock %.3f -> %.3f, dsim=%.2f, RTF=%.2f" % (c0, c1, c1 - c0, (c1 - c0) / dw))
print("gz_truth msgs=%d xyz=%s" % (st["n"], st["xyz"]))
node.destroy_node()
rclpy.shutdown()
