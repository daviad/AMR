#!/usr/bin/env python3
"""场景 e：AMCL 重定位；场景 f：多点巡检连续 3 圈。

e1: 故意把初始位姿给错 (+0.6 m, +0.4 m, +20°)，看能否靠激光重定位收敛，再继续导航。
e2: lifecycle 重启 AMCL（deactivate -> activate），重新给正确初始位姿，再导航。
f : 4 点巡检路线连续 3 圈，每点记录真值 / map->base_link / 终点误差。
速度：Nav2 参数写死 0.3 m/s / 0.5 rad/s。
输出：/tmp/amr_probe/scenario_ef.json
"""
import json
import math
import subprocess
import threading
import time

import rclpy
from geometry_msgs.msg import PoseWithCovarianceStamped
from nav2_msgs.action import NavigateToPose
from nav_msgs.msg import OccupancyGrid
from rclpy.action import ActionClient
from rclpy.executors import MultiThreadedExecutor
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
from rosgraph_msgs.msg import Clock
from tf2_ros import Buffer, TransformListener


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
    raise RuntimeError('truth unavailable')


POINTS = [(-3.8, -2.6, 0.0), (0.0, 2.5, 0.0), (2.0, 3.0, 0.0), (3.6, -2.6, 0.0)]
LAPS = 3


class S(Node):
    def __init__(self):
        super().__init__('scenario_ef')
        self.cli = ActionClient(self, NavigateToPose, 'navigate_to_pose')
        self.tf = Buffer()
        self.listener = TransformListener(self.tf, self)
        self.pub = self.create_publisher(PoseWithCovarianceStamped, '/initialpose', 10)
        self.map = None
        self.create_subscription(OccupancyGrid, '/map', lambda m: setattr(self, 'map', m),
                                 QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL,
                                            reliability=ReliabilityPolicy.RELIABLE))
        self.t = 0.0
        self.create_subscription(Clock, '/clock',
                                 lambda m: setattr(self, 't', m.clock.sec + m.clock.nanosec * 1e-9),
                                 20)

    def map_pose(self):
        try:
            tr = self.tf.lookup_transform('map', 'base_link', rclpy.time.Time())
            p = tr.transform.translation
            return (p.x, p.y, yaw_of(tr.transform.rotation))
        except Exception:
            return None

    def err(self):
        tr = truth_pose()
        mp = self.map_pose()
        if mp is None:
            return None
        return (round(math.hypot(mp[0] - tr[0], mp[1] - tr[1]), 3),
                round(math.degrees(wrap(mp[2] - tr[2])), 2))

    def pen(self, truth):
        """真值车心所在栅格值与最近障碍距离（客观"穿墙"判据）。"""
        if self.map is None:
            return None, None
        info = self.map.info
        c = int((truth[0] - info.origin.position.x) / info.resolution)
        r = int((truth[1] - info.origin.position.y) / info.resolution)
        if not (0 <= c < info.width and 0 <= r < info.height):
            return None, None
        v = self.map.data[r * info.width + c]
        best = 41
        for dr in range(-40, 41):
            for dc in range(-40, 41):
                rr, cc = r + dr, c + dc
                if 0 <= rr < info.height and 0 <= cc < info.width:
                    if self.map.data[rr * info.width + cc] >= 65:
                        d = max(abs(dr), abs(dc))
                        if d < best:
                            best = d
        return int(v), round(best * info.resolution, 3)

    def set_initial(self, x, y, yaw, cov_xy=0.25, cov_yaw=0.07):
        m = PoseWithCovarianceStamped()
        m.header.frame_id = 'map'
        m.header.stamp = self.get_clock().now().to_msg()
        m.pose.pose.position.x = x
        m.pose.pose.position.y = y
        m.pose.pose.orientation.z = math.sin(yaw / 2)
        m.pose.pose.orientation.w = math.cos(yaw / 2)
        m.pose.covariance[0] = cov_xy
        m.pose.covariance[7] = cov_xy
        m.pose.covariance[35] = cov_yaw
        for _ in range(3):
            self.pub.publish(m)
            time.sleep(0.3)

    def goto(self, goal, timeout=120.0, sample=False):
        g = NavigateToPose.Goal()
        g.pose.header.frame_id = 'map'
        g.pose.header.stamp = self.get_clock().now().to_msg()
        g.pose.pose.position.x = goal[0]
        g.pose.pose.position.y = goal[1]
        g.pose.pose.orientation.z = math.sin(goal[2] / 2)
        g.pose.pose.orientation.w = math.cos(goal[2] / 2)
        t0 = self.t
        f = self.cli.send_goal_async(g)
        while not f.done():
            time.sleep(0.1)
        h = f.result()
        if not h.accepted:
            return {'ok': False, 'reason': 'rejected', 'elapsed': 0, 'samples': []}
        rf = h.get_result_async()
        samples = []
        while not rf.done() and self.t - t0 < timeout:
            time.sleep(0.5)
            if sample:
                tr = truth_pose()
                mp = self.map_pose()
                cellv, clear = self.pen(tr)
                rec = [round(self.t - t0, 1)]
                if mp:
                    rec += [round(math.hypot(mp[0] - tr[0], mp[1] - tr[1]), 3),
                            round(math.degrees(wrap(mp[2] - tr[2])), 2)]
                else:
                    rec += [None, None]
                rec += [cellv, clear]
                samples.append(rec)
        el = round(self.t - t0, 1)
        if not rf.done():
            h.cancel_goal_async()
            return {'ok': False, 'reason': 'timeout', 'elapsed': el, 'samples': samples}
        return {'ok': rf.result().status == 4, 'status': int(rf.result().status),
                'elapsed': el, 'samples': samples}


rclpy.init()
s = S()
ex = MultiThreadedExecutor()
ex.add_node(s)
threading.Thread(target=ex.spin, daemon=True).start()
while s.t == 0.0:
    time.sleep(0.2)
while s.map_pose() is None:
    time.sleep(0.2)
s.cli.wait_for_server(timeout_sec=10.0)

out = {'e1': {}, 'e2': {}, 'f': []}

# ---------- e1: 错误初始位姿 ----------
tr = truth_pose()
out['e1']['truth_before'] = [round(tr[0], 3), round(tr[1], 3), round(math.degrees(tr[2]) % 360, 1)]
s.set_initial(tr[0] + 0.6, tr[1] + 0.4, tr[2] + math.radians(20))
time.sleep(3.0)
out['e1']['err_after_bad_init'] = s.err()
r = s.goto((0.0, 0.0, 0.0), timeout=120.0, sample=True)
tr = truth_pose()
out['e1']['nav'] = {'ok': r['ok'], 'elapsed': r['elapsed'],
                    'goal_err_truth': round(math.hypot(tr[0], tr[1]), 3),
                    'err_end': s.err(),
                    'samples': r['samples']}
print(json.dumps({'e1': out['e1']}, ensure_ascii=False), flush=True)

# ---------- e2: lifecycle 重启 AMCL ----------
subprocess.run(['ros2', 'lifecycle', 'set', '/amcl', 'deactivate'],
               capture_output=True, text=True)
time.sleep(2.0)
out['e2']['deactivate_ok'] = True
subprocess.run(['ros2', 'lifecycle', 'set', '/amcl', 'activate'],
               capture_output=True, text=True)
time.sleep(3.0)
tr = truth_pose()
s.set_initial(tr[0], tr[1], tr[2], cov_xy=0.01, cov_yaw=0.01)
time.sleep(2.0)
out['e2']['err_after_restart'] = s.err()
r = s.goto((-3.5, -3.0, math.pi), timeout=120.0, sample=True)
tr = truth_pose()
out['e2']['nav'] = {'ok': r['ok'], 'elapsed': r['elapsed'],
                    'goal_err_truth': round(math.hypot(tr[0] + 3.5, tr[1] + 3.0), 3),
                    'err_end': s.err(),
                    'samples': r['samples']}
print(json.dumps({'e2': out['e2']}, ensure_ascii=False), flush=True)

# ---------- f: 4 点巡检 3 圈 ----------
for lap in range(LAPS):
    for i, pt in enumerate(POINTS, 1):
        r = s.goto(pt, timeout=120.0, sample=True)
        tr = truth_pose()
        cells = [x[3] for x in r['samples'] if x[3] is not None]
        clears = [x[4] for x in r['samples'] if x[4] is not None]
        rec = {'lap': lap + 1, 'point': i, 'xy': [pt[0], pt[1]],
               'ok': r['ok'], 'elapsed': r['elapsed'],
               'truth': [round(tr[0], 3), round(tr[1], 3), round(math.degrees(tr[2]) % 360, 1)],
               'goal_err_truth': round(math.hypot(tr[0] - pt[0], tr[1] - pt[1]), 3),
               'map_err': s.err(),
               'pen_events': sum(1 for v in cells if v >= 65),
               'min_clearance_m': min(clears) if clears else None,
               'max_map_err_on_leg': max((x[1] for x in r['samples'] if x[1] is not None), default=None)}
        out['f'].append(rec)
        print(json.dumps(rec, ensure_ascii=False), flush=True)

with open('/tmp/amr_probe/scenario_ef.json', 'w') as fh:
    json.dump(out, fh, ensure_ascii=False, indent=1)
print('done')
ex.shutdown()
rclpy.shutdown()
