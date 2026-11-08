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

rows = rows[:20]


def fmt(vals):
    return 'mean %.3f  max %.3f  min %.3f' % (statistics.mean(vals), max(vals), min(vals))


ok = [r for r in rows if r['ok']]
print('20 次导航：成功 %d，失败 %d' % (len(ok), len(rows) - len(ok)))
for k, label in [('goal_err_truth_m', '终点真值误差(m)'),
                 ('map_vs_truth_m', 'map->base_link 误差(m)'),
                 ('goal_yaw_err_truth_deg', '终点航向误差(deg)'),
                 ('map_vs_truth_yaw_deg', 'map 航向误差(deg)'),
                 ('elapsed_sim_s', '单程耗时(sim s)')]:
    print('%s: %s' % (label, fmt([r[k] for r in ok if r[k] is not None])))
for goal, target in [('B', (4.0, -3.0)), ('A', (-3.5, -3.0))]:
    pts = [r['truth_xy_m_yaw_deg'] for r in rows if r['goal'] == goal and r['ok']]
    mx = statistics.mean(p[0] for p in pts)
    my = statistics.mean(p[1] for p in pts)
    sx = statistics.stdev(p[0] for p in pts)
    sy = statistics.stdev(p[1] for p in pts)
    radii = [math.hypot(p[0] - target[0], p[1] - target[1]) for p in pts]
    print('%s 到达 %d 次: 质心(%.3f,%.3f) std(%.3f,%.3f) 半径 mean %.3f max %.3f' % (
        goal, len(pts), mx, my, sx, sy, statistics.mean(radii), max(radii)))
print('odom 偏移(m): 第1腿 %.2f，第10腿 %.2f，第20腿 %.2f' % (
    rows[0]['odom_vs_truth_m'], rows[9]['odom_vs_truth_m'], rows[-1]['odom_vs_truth_m']))
plans = [r['plan'] for r in ok if r['plan']]
print('plan: 采样点 %d，占用 %d，min clearance %.2f' % (
    sum(p['points'] for p in plans), sum(p['occupied_points'] for p in plans),
    min(p['min_wall_clearance_m'] for p in plans)))
print('总仿真耗时 %.1f s' % sum(r['elapsed_sim_s'] for r in ok))
