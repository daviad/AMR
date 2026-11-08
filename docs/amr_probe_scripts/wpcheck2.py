import math
import threading
import time

import rclpy
from nav_msgs.msg import OccupancyGrid
from rclpy.executors import MultiThreadedExecutor
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy

rclpy.init()
node = rclpy.create_node('wpcheck2')
h = {}
node.create_subscription(OccupancyGrid, '/map', lambda m: h.setdefault('m', m),
                         QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL,
                                    reliability=ReliabilityPolicy.RELIABLE))
ex = MultiThreadedExecutor()
ex.add_node(node)
threading.Thread(target=ex.spin, daemon=True).start()
for _ in range(100):
    if 'm' in h:
        break
    time.sleep(0.1)
m = h['m']
info = m.info


def clearance(x, y):
    c0 = int((x - info.origin.position.x) / info.resolution)
    r0 = int((y - info.origin.position.y) / info.resolution)
    best = 1e9
    bc = None
    for r in range(max(0, r0 - 60), min(info.height, r0 + 61)):
        row = r * info.width
        for c in range(max(0, c0 - 60), min(info.width, c0 + 61)):
            if m.data[row + c] >= 65:
                dx = (c - c0) * info.resolution
                dy = (r - r0) * info.resolution
                d = math.hypot(dx, dy)
                if d < best:
                    best = d
                    bc = (c, r)
    return round(best, 3), info.origin.position.x + bc[0] * info.resolution, info.origin.position.y + bc[1] * info.resolution


pts = [(-3.4, -2.4), (0.0, 2.5), (2.3, 2.7), (3.6, -2.6), (-3.5, -3.0), (4.0, -3.0),
       (0.0, 0.0)]
for p in pts:
    d, nx, ny = clearance(*p)
    print('%s 离最近障碍 %.3f m (最近点 %.2f,%.2f)' % (p, d, nx, ny))
ex.shutdown()
rclpy.shutdown()
