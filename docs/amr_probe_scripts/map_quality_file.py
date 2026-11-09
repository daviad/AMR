#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""map_quality_file.py —— 对静态地图文件（pgm+yaml）做与 map_quality.py 相同口径的质量评估

用法：python3 map_quality_file.py <map.yaml> [输出json]
指标：画布/分辨率/占用率/未知率、逐墙覆盖率、墙厚中位数、双层墙（重影）比例、
      伪占用、混淆矩阵（召回/精确/IoU）
墙/障碍几何以 indoor.world 为准（与 map_quality.py 一致）。
"""
import json
import math
import re
import sys

BOXES = [
    (-2.0, 2.0, 0.5, 0.5, 0.0),
    (2.5, -1.5, 0.5, 0.5, 0.3),
    (2.5, 0.0, 0.6, 0.6, 0.0),
    (2.5, 1.2, 0.5, 0.5, 0.0),
    (2.5, -1.2, 0.5, 0.5, 0.0),
    (-4.7, -3.4, 0.2, 0.4, 0.0),
]
CYLINDERS = [(3.0, 2.5, 0.25), (-1.0, -2.5, 0.25)]
WALLS = [
    ('wall_north', 'x', 4.0, -5.1, 5.1, (0, 1)),
    ('wall_south', 'x', -4.0, -5.1, 5.1, (0, 1)),
    ('wall_east', 'y', 5.0, -4.1, 4.1, (1, 0)),
    ('wall_west', 'y', -5.0, -4.1, 4.1, (1, 0)),
    ('partition_v1', 'y', 1.0, 0.5, 4.0, (1, 0)),
    ('partition_h1', 'x', 0.0, -5.0, -2.0, (0, 1)),
]
WALL_HALF_T = 0.05


def in_box(x, y, cx, cy, sx, sy, yaw):
    ca, sa = math.cos(-yaw), math.sin(-yaw)
    dx, dy = x - cx, y - cy
    lx = ca * dx - sa * dy
    ly = sa * dx + ca * dy
    return abs(lx) <= sx / 2 + 1e-9 and abs(ly) <= sy / 2 + 1e-9


def truth_occ(x, y):
    for cx, cy, sx, sy, yaw in BOXES:
        if in_box(x, y, cx, cy, sx, sy, yaw):
            return True
    for cx, cy, r in CYLINDERS:
        if math.hypot(x - cx, y - cy) <= r + 1e-9:
            return True
    for name, axis, fixed, lo, hi, nrm in WALLS:
        if axis == 'x':
            if lo - 1e-9 <= x <= hi + 1e-9 and abs(y - fixed) <= WALL_HALF_T + 1e-9:
                return True
        else:
            if lo - 1e-9 <= y <= hi + 1e-9 and abs(x - fixed) <= WALL_HALF_T + 1e-9:
                return True
    return False


def load_yaml(path):
    d = {}
    for line in open(path):
        if ':' not in line:
            continue
        k, v = line.split(':', 1)
        d[k.strip()] = v.strip()
    d['resolution'] = float(d['resolution'])
    d['origin'] = [float(t) for t in d['origin'].strip('[] ').split(',')]
    d['occupied_thresh'] = float(d.get('occupied_thresh', 0.65))
    d['free_thresh'] = float(d.get('free_thresh', 0.196))
    d['negate'] = int(d.get('negate', 0))
    return d


def load_pgm(path):
    """解析 P5 二值 PGM，返回 (w,h,maxval,像素行优先 list)。"""
    with open(path, 'rb') as f:
        raw = f.read()
    m = re.match(rb'P5\s+(?:#[^\n]*\n\s*)*(\d+)\s+(?:#[^\n]*\n\s*)*(\d+)\s+'
                 rb'(?:#[^\n]*\n\s*)*(\d+)\s', raw, re.S)
    w, h, maxv = int(m.group(1)), int(m.group(2)), int(m.group(3))
    return w, h, maxv, list(raw[m.end():m.end() + w * h])


def main():
    ypath = sys.argv[1]
    outpath = sys.argv[2] if len(sys.argv) > 2 else None
    y = load_yaml(ypath)
    pgm = ypath.rsplit('/', 1)[0] + '/' + y['image']
    w, h, maxv, pix = load_pgm(pgm)
    res = y['resolution']
    ox, oy = y['origin'][0], y['origin'][1]
    occ_thr = 255 * (1.0 - y['occupied_thresh'])
    free_thr = 255 * (1.0 - y['free_thresh'])

    def cell_at(x, yy):
        c = int((x - ox) / res)
        r = int((yy - oy) / res)
        if 0 <= c < w and 0 <= r < h:
            p = pix[(h - 1 - r) * w + c]
            if p <= occ_thr:
                return 65
            if p >= free_thr:
                return 0
            return -1
        return None

    occ = free = unk = 0
    for r in range(h):
        for c in range(w):
            v = cell_at(ox + c * res, oy + r * res)
            if v is None or v < 0:
                unk += 1
            elif v >= 65:
                occ += 1
            else:
                free += 1

    wall_stats = []
    thick_samples = []
    double_samples = []
    for name, axis, fixed, lo, hi, nrm in WALLS:
        n_probe = n_cov = 0
        n = int((hi - lo) / 0.05) + 1
        for i in range(2, n - 2):
            s = lo + i * 0.05
            px, py = (s, fixed) if axis == 'x' else (fixed, s)
            covered = False
            for off in [j * 0.05 for j in range(-3, 4)]:
                v = cell_at(px + nrm[0] * off, py + nrm[1] * off)
                if v is not None and v >= 65:
                    covered = True
                    break
            n_probe += 1
            n_cov += 1 if covered else 0
            runs = []
            cur = 0
            for j in range(-7, 8):
                off = j * 0.05
                v = cell_at(px + nrm[0] * off, py + nrm[1] * off)
                if v is not None and v >= 65:
                    cur += 1
                else:
                    if cur:
                        runs.append(cur)
                    cur = 0
            if cur:
                runs.append(cur)
            if len(runs) == 1:
                thick_samples.append(runs[0] * res)
            elif len(runs) >= 2:
                double_samples.append(max(runs) * res)
        wall_stats.append({'name': name, 'probes': n_probe, 'covered': n_cov,
                           'coverage_pct': round(100.0 * n_cov / max(1, n_probe), 1)})

    thick_sorted = sorted(thick_samples)
    thick_med = thick_sorted[len(thick_sorted) // 2] if thick_sorted else None
    n_all = len(thick_samples) + len(double_samples)

    tp = fp = fn = tn = 0
    for r in range(h):
        yy = oy + r * res
        for c in range(w):
            x = ox + c * res
            p = pix[(h - 1 - r) * w + c]
            if p <= occ_thr:
                o = True
            elif p >= free_thr:
                o = False
            else:
                continue  # 未知像素不参与（与 map_quality.py 口径一致）
            t = truth_occ(x, yy)
            if t and o:
                tp += 1
            elif o and not t:
                fp += 1
            elif t and not o:
                fn += 1
            else:
                tn += 1

    fp_strict = free_strict = 0
    for r in range(h):
        yy = oy + r * res
        for c in range(w):
            x = ox + c * res
            v = pix[(h - 1 - r) * w + c]
            if v < 0 or v >= free_thr or truth_occ(x, yy):
                continue
            far = True
            for ddx in (-0.12, 0, 0.12):
                for ddy in (-0.12, 0, 0.12):
                    if truth_occ(x + ddx, yy + ddy):
                        far = False
                        break
                if not far:
                    break
            if far:
                free_strict += 1
                if v <= occ_thr:
                    fp_strict += 1

    out = {
        'file': ypath,
        'map': {'width': w, 'height': h, 'resolution': res,
                'origin': [round(ox, 3), round(oy, 3)],
                'span_m': [round(w * res, 2), round(h * res, 2)]},
        'counts': {'occupied': occ, 'free': free, 'unknown': unk,
                   'total': w * h,
                   'occ_ratio_pct': round(100.0 * occ / (w * h), 2),
                   'unknown_ratio_pct': round(100.0 * unk / (w * h), 2)},
        'walls': wall_stats,
        'wall_coverage_overall_pct': round(
            100.0 * sum(x['covered'] for x in wall_stats) /
            max(1, sum(x['probes'] for x in wall_stats)), 1),
        'wall_thickness_median_m': round(thick_med, 3) if thick_med else None,
        'wall_thickness_samples': len(thick_samples),
        'double_layer_samples': len(double_samples),
        'double_layer_pct': round(100.0 * len(double_samples) / max(1, n_all), 1),
        'confusion': {'tp': tp, 'fp': fp, 'fn': fn, 'tn': tn,
                      'recall_pct': round(100.0 * tp / max(1, tp + fn), 2),
                      'precision_pct': round(100.0 * tp / max(1, tp + fp), 2),
                      'iou_pct': round(100.0 * tp / max(1, tp + fp + fn), 2)},
        'false_occ_strict': {'cells': fp_strict, 'free_strict_cells': free_strict,
                             'pct': round(100.0 * fp_strict / max(1, free_strict), 3)},
    }
    print(json.dumps(out, ensure_ascii=False, indent=1))
    if outpath:
        json.dump(out, open(outpath, 'w'), ensure_ascii=False, indent=1)


main()
