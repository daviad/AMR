import json
import math
import statistics

rows = []
for fn in ('/tmp/amr_probe/nav20.log', '/tmp/amr_probe/nav40.log'):
    with open(fn) as f:
        for line in f:
            line = line.strip()
            if line.startswith('{'):
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass

# 补跑的两腿（第一次 18 腿后脚本因 gz 服务瞬时无返回崩溃，单独补跑）
rows += [
    {'goal': 'B', 'ok': True, 'elapsed_sim_s': 0.2,
     'truth_xy_m_yaw_deg': [3.926, -3.002, 7.6], 'map_base_xy_m_yaw_deg': [3.99, -3.023, 8.3],
     'odom_xy_m_yaw_deg': [-7.422, 13.272, 55.9], 'goal_err_truth_m': 0.074,
     'goal_yaw_err_truth_deg': 7.65, 'map_vs_truth_m': 0.068, 'map_vs_truth_yaw_deg': 0.64,
     'odom_vs_truth_m': 19.84, 'plan': {'points': 2, 'occupied_points': 0, 'min_wall_clearance_m': 4.95}},
    {'goal': 'A', 'ok': True, 'elapsed_sim_s': 34.6,
     'truth_xy_m_yaw_deg': [-3.518, -3.001, 173.2], 'map_base_xy_m_yaw_deg': [-3.473, -3.006, 171.8],
     'odom_xy_m_yaw_deg': [-13.4, 9.164, 206.6], 'goal_err_truth_m': 0.018,
     'goal_yaw_err_truth_deg': -6.79, 'map_vs_truth_m': 0.045, 'map_vs_truth_yaw_deg': -1.46,
     'odom_vs_truth_m': 15.673, 'plan': {'points': 2, 'occupied_points': 0, 'min_wall_clearance_m': 4.95}},
]

ok = [r for r in rows if r['ok']]
print('总导航次数 %d，成功 %d，失败 %d' % (len(rows), len(ok), len(rows) - len(ok)))
print('B 方向 %d 次 / A 方向 %d 次' % (sum(1 for r in rows if r['goal'] == 'B'),
                                     sum(1 for r in rows if r['goal'] == 'A')))


def fmt(vals):
    return 'mean %.3f  max %.3f  min %.3f' % (statistics.mean(vals), max(vals), min(vals))


for k, label in [('goal_err_truth_m', '终点真值误差(m)'),
                 ('map_vs_truth_m', 'map->base_link 误差(m)'),
                 ('goal_yaw_err_truth_deg', '终点航向误差(deg)'),
                 ('map_vs_truth_yaw_deg', 'map 航向误差(deg)'),
                 ('elapsed_sim_s', '单程耗时(sim s)')]:
    vals = [r[k] for r in ok if r[k] is not None]
    print('%s: %s' % (label, fmt(vals)))

plans = [r['plan'] for r in ok if r['plan']]
print('plan: 采样点 %d，占用栅格点 %d，最小离墙 %.2f m' % (
    sum(p['points'] for p in plans), sum(p['occupied_points'] for p in plans),
    min(p['min_wall_clearance_m'] for p in plans)))

for goal, target in [('B', (4.0, -3.0)), ('A', (-3.5, -3.0))]:
    pts = [r['truth_xy_m_yaw_deg'] for r in rows if r['goal'] == goal and r['ok']]
    mx = statistics.mean(p[0] for p in pts)
    my = statistics.mean(p[1] for p in pts)
    sx = statistics.stdev(p[0] for p in pts)
    sy = statistics.stdev(p[1] for p in pts)
    radii = [math.hypot(p[0] - target[0], p[1] - target[1]) for p in pts]
    print('%s 到达 %d 次: 质心(%.3f,%.3f) 标准差(%.3f,%.3f) 半径 mean %.3f max %.3f' % (
        goal, len(pts), mx, my, sx, sy, statistics.mean(radii), max(radii)))

print('\nodom 偏移(m): 第1腿 %.2f，第20腿 %.2f，第40腿 %.2f' % (
    rows[0]['odom_vs_truth_m'], rows[19]['odom_vs_truth_m'], rows[-1]['odom_vs_truth_m']))
mv = [r['map_vs_truth_m'] for r in rows]
print('map 误差(m): 前10腿 %s / 中10腿 %s / 后10腿 %s' % (
    fmt(mv[:10]), fmt(mv[10:20]), fmt(mv[20:30])))
print('map 误差 后10腿均值 %.3f，最大 %.3f' % (statistics.mean(mv[-10:]), max(mv)))
oy = [r['map_vs_truth_yaw_deg'] for r in rows]
print('map 航向误差 末10腿: %s' % fmt(oy[-10:]))
el = [r['elapsed_sim_s'] for r in ok]
print('总仿真耗时 %.1f s (≈%.1f min), 总行驶里程 ≈%.1f m' % (sum(el), sum(el) / 60, 7.5 * len(ok)))
