#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_check.py —— 构建裁决器：把 "PASS" 之外的真相也查出来

为什么需要它（2026-10-27 的教训）：
  Efinity 的 `pnr : PASS` 只代表"跑完了"，**不代表能用**。今天实测过一个构建：
      pnr : PASS
      但 vid_clk_dvi2 (rowpipe 所在的 148.5MHz 域) setup slack = -0.710 ns
  这种构建烧上去就是随机出错图，而且不会有任何报错。

  另外面积到 99% 之后布线是**概率性**的：
      60,267 (99.12%) PASS     60,193 (99.00%) FAIL
      60,165 (98.96%) PASS(时序坏)   60,147 (98.93%) FAIL x2
  所以"上一次能过"不能作为证据。

它做什么：
  1. 解析 build.log 的四个阶段结果
  2. 解析 place.rpt 的资源占用
  3. 解析 timing.rpt，**逐时钟对列出最差 slack，并红旗标出负值**
  4. 给出裁决：USABLE / TIMING_FAIL / ROUTE_FAIL / BUILD_FAIL
  5. 退出码非 0 表示不可用（可直接用在脚本里）

用法：
  python tools/build_check.py                     # 检查当前 outflow/
  python tools/build_check.py --build             # 先跑 _b.bat 再检查
  python tools/build_check.py --xlr-limit 98.9    # 面积超过 98.9% 就警告（默认 99.0）

依赖：仅标准库
"""

import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "outflow")
LOG = os.path.join(ROOT, "build.log")
PLACE = os.path.join(OUT, "ti60f225_oob.place.rpt")
TIMING = os.path.join(OUT, "ti60f225_oob.timing.rpt")

# rowpipe 所在域，改动 datapath 时最该盯它
WATCH_DOMAINS = ["vid_clk_dvi2", "core_clk"]


def parse_stages():
    if not os.path.exists(LOG):
        return None
    txt = open(LOG, encoding="utf-8", errors="ignore").read()
    stages = {}
    for name in ("map", "interface", "pnr", "pgm"):
        m = re.search(r"\b%s\s*:\s*(PASS|FAIL)" % name, txt)
        stages[name] = m.group(1) if m else "?"
    return stages


def parse_area():
    if not os.path.exists(PLACE):
        return None
    txt = open(PLACE, encoding="utf-8", errors="ignore").read()
    out = {}
    for key, pat in (("XLR", r"XLRs:\s*(\d+)\s*/\s*(\d+)\s*\(([\d.]+)%\)"),
                     ("RAM", r"Memory Blocks:\s*(\d+)\s*/\s*(\d+)\s*\(([\d.]+)%\)"),
                     ("DSP", r"DSP Blocks:\s*(\d+)\s*/\s*(\d+)\s*\(([\d.]+)%\)")):
        m = re.search(pat, txt)
        if m:
            out[key] = (int(m.group(1)), int(m.group(2)), float(m.group(3)))
    return out or None


def _slack_table(lines, header):
    """从 timing.rpt 的某个小节里抽出 (launch, capture, constraint, slack) 列表。"""
    start = None
    for i, l in enumerate(lines):
        if header in l:
            start = i
            break
    if start is None:
        return []
    rows = []
    for l in lines[start + 1: start + 60]:
        if not l.strip():
            break
        m = re.match(r"\s*(\S+)\s+(\S+)\s+([\d.]+)\s+(-?[\d.]+)\s+\(", l)
        if m:
            rows.append((m.group(1), m.group(2), float(m.group(3)), float(m.group(4))))
    return rows


def parse_timing():
    if not os.path.exists(TIMING):
        return "missing"
    lines = open(TIMING, encoding="utf-8", errors="ignore").read().splitlines()
    setup = _slack_table(lines, "Setup (Max) Clock Relationship")
    hold = _slack_table(lines, "Hold (Min) Clock Relationship")
    if not setup and not hold:
        return None          # 文件在但解析不出行 —— 报告格式变了
    return {"setup": setup, "hold": hold}


def fmt_rows(rows, n=4):
    out = []
    for launch, capture, cons, slack in sorted(rows, key=lambda r: r[3])[:n]:
        flag = "  <-- 负值!" if slack < 0 else ""
        out.append("    %-20s -> %-20s 约束 %6.3f  slack %+7.3f%s"
                   % (launch, capture, cons, slack, flag))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="构建裁决器：区分 PASS 与真正可用")
    ap.add_argument("--build", action="store_true", help="先跑一次 _b.bat 再检查")
    ap.add_argument("--xlr-limit", type=float, default=99.0,
                    help="面积告警阈值（百分数，默认 99.0）")
    ap.add_argument("--show", type=int, default=4, help="每类时序各列几条（默认 4）")
    args = ap.parse_args(argv)

    if args.build:
        print("== 构建中（约 12~15 分钟）==")
        bat = os.path.join(ROOT, "_b.bat")
        rc = subprocess.call(["cmd", "/c", bat], cwd=ROOT,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print("  _b.bat 退出码 %d" % rc)

    stages = parse_stages()
    area = parse_area()
    timing = parse_timing()

    print()
    print("=" * 66)
    print("阶段")
    if stages:
        for k in ("map", "interface", "pnr", "pgm"):
            print("  %-10s %s" % (k, stages.get(k, "?")))
    else:
        print("  找不到 build.log —— 还没构建过？")

    print()
    print("面积")
    slow_area = False
    if area:
        for k in ("XLR", "RAM", "DSP"):
            if k not in area:
                continue
            used, total, pct = area[k]
            warn = ""
            if k == "XLR" and pct >= args.xlr_limit:
                warn = "  <-- 接近布线天花板，成功与否是概率性的"
                slow_area = True
            print("  %-4s %6d / %-6d (%5.2f%%)%s" % (k, used, total, pct, warn))
    else:
        print("  找不到 place.rpt（map 阶段就挂了？）")

    print()
    print("时序")
    bad_timing = []
    if timing:
        if timing["setup"]:
            print("  setup 最差:")
            for l in fmt_rows(timing["setup"], args.show):
                print(l)
            bad_timing += [r for r in timing["setup"] if r[3] < 0]
        else:
            print("  setup: 无数据")
        if timing["hold"]:
            print("  hold 最差:")
            for l in fmt_rows(timing["hold"], args.show):
                print(l)
            bad_timing += [r for r in timing["hold"] if r[3] < 0]
        else:
            print("  hold: 无数据")

        print()
        print("关注域（改动 datapath 时最该看）")
        for dm in WATCH_DOMAINS:
            hit = [r for r in timing["setup"] if r[0] == dm and r[1] == dm]
            if hit:
                s = hit[0][3]
                print("  %-16s %+7.3f ns  %s" % (dm, s, "OK" if s > 0 else "** 负值 **"))
    elif timing == "missing":
        print("  找不到 outflow/ti60f225_oob.timing.rpt（布线失败时不会生成）")
    else:
        print("  timing.rpt 存在但解析不出时钟对 —— 报告格式可能变了，请检查 _slack_table")

    # ---------------- 裁决 ----------------
    verdict = "USABLE"
    reason = ""
    if not stages or any(v != "PASS" for v in stages.values()):
        verdict, reason = "BUILD_FAIL", "阶段未全部 PASS"
    elif not timing:
        verdict, reason = "ROUTE_FAIL", "无 timing.rpt（布线未完成）"
    elif bad_timing:
        verdict = "TIMING_FAIL"
        worst = min(bad_timing, key=lambda r: r[3])
        reason = "存在负 slack，最差 %s->%s %+.3f ns" % (worst[0], worst[1], worst[3])

    print()
    print("=" * 66)
    print("裁决：%s" % verdict)
    if reason:
        print("  原因：%s" % reason)
    if verdict == "USABLE" and slow_area:
        print("  ⚠ 但面积已过 %.1f%%，下次改动很可能布不通（实测 99%% 附近是概率性的）" % args.xlr_limit)
    if verdict == "USABLE":
        bit = os.path.join(OUT, "ti60f225_oob.bit")
        if os.path.exists(bit):
            print("  bit: %s (%d B)" % (bit, os.path.getsize(bit)))
    print("=" * 66)
    return 0 if verdict == "USABLE" else 1


if __name__ == "__main__":
    sys.exit(main())
