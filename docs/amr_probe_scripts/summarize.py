#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""summarize.py —— 汇总 spin5_A/B/C.json 的逐段数据（统计口径：全部 5 次，不做过滤）

用法: python3 summarize.py /tmp/amr_probe
输出: 每个 group 的 180/360 聚合（mean/std/min/max）+ 逐次原值 + 直线标定
"""
import json
import math
import os
import sys

BASE = sys.argv[1] if len(sys.argv) > 1 else "/tmp/amr_probe"
KEYS = ("odom_over_cmd", "truth_over_odom", "amcl_over_truth",
        "truth_over_cmd", "wheel_over_cmd")


def agg(vals):
    vals = [v for v in vals if v is not None]
    if not vals:
        return None
    n = len(vals)
    mean = sum(vals) / n
    std = math.sqrt(sum((v - mean) ** 2 for v in vals) / n) if n > 1 else 0.0
    return (n, mean, std, min(vals), max(vals))


for g in ("A", "B", "C"):
    p = os.path.join(BASE, "spin5_%s.json" % g)
    if not os.path.exists(p):
        print("MISSING", p)
        continue
    d = json.load(open(p))
    print("=" * 78)
    print("GROUP %s  (file=%s)" % (g, p))
    for deg in (180, 360):
        rows = [r for r in d["rows"] if abs(r["cmd_deg"]) == deg]
        print("  %d deg  n=%d" % (deg, len(rows)))
        for k in KEYS:
            a = agg([r.get(k) for r in rows])
            if a is None:
                print("    %-16s no data" % k)
                continue
            n, mean, std, lo, hi = a
            print("    %-16s mean=%.4f std=%.4f min=%.4f max=%.4f" % (k, mean, std, lo, hi))
        print("    raw truth/odom  : %s" % " / ".join(
            "%.4f" % r["truth_over_odom"] for r in rows))
        print("    raw amcl/truth  : %s" % " / ".join(
            "%.4f" % r["amcl_over_truth"] for r in rows))
        print("    raw odom/cmd    : %s" % " / ".join(
            "%.4f" % r["odom_over_cmd"] for r in rows))
        print("    truth deg       : %s" % " / ".join(
            "%.2f" % r["truth_deg"] for r in rows))
        print("    odom  deg       : %s" % " / ".join(
            "%.2f" % r["odom_deg"] for r in rows))
        print("    amcl  deg       : %s" % " / ".join(
            "%.2f" % r["amcl_deg"] for r in rows))
        print("    scan_min        : %s" % " / ".join(
            "%.3f" % r["scan_min_after"] for r in rows))
    print("  line calibration")
    for r in d["line"]:
        print("    cmd=%+.1f m  odom=%.4f truth=%s  odom/truth=%s  scan_min=%.3f"
              % (r["cmd_m"], r["odom_m"], r["truth_m"], r["odom_over_truth"], r["scan_min"]))
