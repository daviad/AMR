import json
import math
import statistics

d = json.load(open('/tmp/amr_probe/scenario_ef.json'))
print('=== e1 ===')
print('坏初始位姿后误差:', d['e1']['err_after_bad_init'])
print('导航:', {k: d['e1']['nav'][k] for k in ('ok', 'elapsed', 'goal_err_truth', 'err_end')})
print('前 6 个采样 [t, map误差, 航向误差, 栅格值, 离墙]:')
for s in d['e1']['nav']['samples'][:6]:
    print(' ', s)
print('\n=== e2 ===')
print('重启后误差:', d['e2']['err_after_restart'])
print('导航:', {k: d['e2']['nav'][k] for k in ('ok', 'elapsed', 'goal_err_truth', 'err_end')})
print('前 6 个采样:')
for s in d['e2']['nav']['samples'][:6]:
    print(' ', s)

print('\n=== f ===')
for r in d['f']:
    print('lap%d P%d (%s): ok=%s %.1fs truth_err=%.3f map_err=%s pen=%d min_clear=%.2f max_map_err=%s' % (
        r['lap'], r['point'], r['xy'], r['ok'], r['elapsed'], r['goal_err_truth'],
        r['map_err'], r['pen_events'], r['min_clearance_m'], r['max_map_err_on_leg']))

ok = [r for r in d['f'] if r['ok']]
print('成功 %d / %d' % (len(ok), len(d['f'])))
print('成功腿耗时均值 %.1f s' % statistics.mean(r['elapsed'] for r in ok))
print('成功腿终点真值误差均值 %.3f 最大 %.3f' % (
    statistics.mean(r['goal_err_truth'] for r in ok), max(r['goal_err_truth'] for r in ok)))
print('成功腿 map 误差均值 %.3f 最大 %.3f' % (
    statistics.mean(r['map_err'][0] for r in ok), max(r['map_err'][0] for r in ok)))
print('穿墙事件合计 %d' % sum(r['pen_events'] for r in d['f']))
print('单腿最小离墙最小值 %.2f m' % min(r['min_clearance_m'] for r in d['f']))
