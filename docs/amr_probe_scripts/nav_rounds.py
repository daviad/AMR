#!/usr/bin/env python3
"""场景 c/d：长直走廊 A<-B 往返连续 NavigateToPose。

路线：A=(-3.5,-3.0,yaw=pi) <-> B=(4.0,-3.0,yaw=0)，单程 7.5 m，y=-3.0 通道无静态障碍。
速度由 Nav2 参数写死：v<=0.3 m/s，omega<=0.5 rad/s，acc<=0.5/1.0。

用法：python3 nav_rounds.py [N_ROUNDS]
每轮记录：真值(gz model -p) / map->base_link / odom、终点误差、/plan 穿墙判据、仿真耗时。
输出：/tmp/amr_probe/nav_rounds.json
"""
import json
import math
import subprocess
import sys
import threading
import time

import rclpy
from geometry_msgs.msg import PoseStamped
from nav2_msgs.action import NavigateToPose
from nav_msgs.msg import OccupancyGrid, Odometry, Path
from rclpy.action import ActionClient
from rclpy.executors import MultiThreadedExecutor
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
from rosgraph_msgs.msg import Clock
from tf2_ros import Buffer, TransformListener

A = (-3.5, -3.0, math.pi)
B = (4.0, -3.0, 0.0)
N_ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 20
LEG_TIMEOUT_SIM = 90.0


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
                return (float(p[0]), float(p[1]), float(rpy[2]))
            except (ValueError, IndexError):
                pass
        time.sleep(0.3)
    raise RuntimeError('truth pose unavailable')


class Nav(Node):
    def __init__(self):
        super().__init__('nav_rounds')
        self.cli = ActionClient(self, NavigateToPose, 'navigate_to_pose')
        self.tf = Buffer()
        self.listener = TransformListener(self.tf, self)
        self.odom = None
        self.map = None
        self.sim_t = 0.0
        qos = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL,
                         reliability=ReliabilityPolicy.RELIABLE)
        self.create_subscription(OccupancyGrid, '/map', self.on_map, qos)
        self.create_subscription(Odometry, '/odom', self.on_odom, 20)
        self.create_subscription(Path, '/plan', self.on_plan, 10)
        self.create_subscription(Clock, '/clock', self.on_clock, 20)
        self.plans = []
        self.lock = threading.Lock()

    def on_map(self, m):
        self.map = m

    def on_odom(self, m):
        p = m.pose.pose.position
        self.odom = (p.x, p.y, yaw_of(m.pose.pose.orientation))

    def on_clock(self, c):
        self.sim_t = c.clock.sec + c.clock.nanosec * 1e-9

    def on_plan(self, m):
        with self.lock:
            self.plans.append(m)

    def map_pose(self):
        try:
            t = self.tf.lookup_transform('map', 'base_link', rclpy.time.Time())
            p = t.transform.translation
            return (p.x, p.y, yaw_of(t.transform.rotation))
        except Exception:
            return None

    def check_plan(self):
        with self.lock:
            if not self.plans:
                return None
            path = self.plans[-1]
        if self.map is None:
            return None
        info = self.map.info
        data = self.map.data
        n_occ = 0
        n = 0
        min_clear = 1e9
        for ps in path.poses:
            x = ps.pose.position.x
            y = ps.pose.position.y
            c = int((x - info.origin.position.x) / info.resolution)
            r = int((y - info.origin.position.y) / info.resolution)
            n += 1
            if not (0 <= c < info.width and 0 <= r < info.height):
                continue
            v = data[r * info.width + c]
            if v >= 65:
                n_occ += 1
            best = 99
            for dr in range(-4, 5):
                for dc in range(-4, 5):
                    rr, cc = r + dr, c + dc
                    if 0 <= rr < info.height and 0 <= cc < info.width:
                        if data[rr * info.width + cc] >= 65:
                            d = max(abs(dr), abs(dc))
                            if d < best:
                                best = d
            min_clear = min(min_clear, best * info.resolution)
        return {'points': n, 'occupied_points': n_occ,
                'min_wall_clearance_m': round(min_clear, 3)}

    def goto(self, goal, timeout=LEG_TIMEOUT_SIM):
        msg = NavigateToPose.Goal()
        msg.pose.header.frame_id = 'map'
        msg.pose.header.stamp = self.get_clock().now().to_msg()
        msg.pose.pose.position.x = goal[0]
        msg.pose.pose.position.y = goal[1]
        msg.pose.pose.orientation.z = math.sin(goal[2] / 2)
        msg.pose.pose.orientation.w = math.cos(goal[2] / 2)
        with self.lock:
            self.plans = []
        t0 = self.sim_t
        fut = self.cli.send_goal_async(msg)
        while not fut.done():
            time.sleep(0.1)
        handle = fut.result()
        if not handle.accepted:
            return {'ok': False, 'reason': 'rejected', 'elapsed_sim_s': 0}
        rf = handle.get_result_async()
        while not rf.done() and self.sim_t - t0 < timeout:
            time.sleep(0.1)
        elapsed = round(self.sim_t - t0, 1)
        if not rf.done():
            handle.cancel_goal_async()
            return {'ok': False, 'reason': 'timeout', 'elapsed_sim_s': elapsed}
        st = rf.result().status
        return {'ok': st == 4, 'status': int(st), 'elapsed_sim_s': elapsed}


rclpy.init()
n = Nav()
ex = MultiThreadedExecutor()
ex.add_node(n)
threading.Thread(target=ex.spin, daemon=True).start()
while n.map is None or n.sim_t == 0.0:
    time.sleep(0.2)
while n.map_pose() is None:
    time.sleep(0.2)
if not n.cli.wait_for_server(timeout_sec=5.0):
    print('ACTION SERVER NOT AVAILABLE')
    raise SystemExit(1)

rows = []
t_start = n.sim_t
for i in range(N_ROUNDS):
    goal = B if i % 2 == 0 else A
    r = n.goto(goal, timeout=LEG_TIMEOUT_SIM)
    time.sleep(1.0)
    tr = truth_pose()
    mp = n.map_pose()
    od = n.odom
    plan = n.check_plan()
    rec = {
        'round': i + 1,
        'goal': 'B' if i % 2 == 0 else 'A',
        'goal_xy_yaw': [round(v, 3) for v in goal],
        'ok': r['ok'],
        'elapsed_sim_s': r.get('elapsed_sim_s'),
        'truth_xy_m_yaw_deg': [round(tr[0], 3), round(tr[1], 3),
                               round(math.degrees(tr[2]) % 360, 1)],
        'map_base_xy_m_yaw_deg': [round(mp[0], 3), round(mp[1], 3),
                                  round(math.degrees(mp[2]) % 360, 1)] if mp else None,
        'odom_xy_m_yaw_deg': [round(od[0], 3), round(od[1], 3),
                              round(math.degrees(od[2]) % 360, 1)] if od else None,
        'goal_err_truth_m': round(math.hypot(tr[0] - goal[0], tr[1] - goal[1]), 3),
        'goal_yaw_err_truth_deg': round(math.degrees(wrap(tr[2] - goal[2])), 2),
        'map_vs_truth_m': round(math.hypot(mp[0] - tr[0], mp[1] - tr[1]), 3) if mp else None,
        'map_vs_truth_yaw_deg': round(math.degrees(wrap(mp[2] - tr[2])), 2) if mp else None,
        'odom_vs_truth_m': round(math.hypot(od[0] - tr[0], od[1] - tr[1]), 3) if od else None,
        'plan': plan,
    }
    rows.append(rec)
    print(json.dumps(rec, ensure_ascii=False), flush=True)

out = '/tmp/amr_probe/nav_rounds.json'
with open(out, 'w') as f:
    json.dump({'goals': {'A': list(A), 'B': list(B)}, 'rounds': rows}, f,
              ensure_ascii=False, indent=1)
print('wrote', out, 'total_sim_s', round(n.sim_t - t_start, 1))
ex.shutdown()
rclpy.shutdown()
