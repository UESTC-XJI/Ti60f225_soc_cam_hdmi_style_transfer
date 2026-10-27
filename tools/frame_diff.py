#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
frame_diff.py —— 金帧回归：没有仿真器时，验证 RTL 改动是否"功能等价"

为什么需要它：
  动 rowpipe 的例化参数（比如 CI/CO 16→8 腾面积）时，改错的后果是
  **能编过、时序也对、但出图是坏的**，而且没有任何报错。
  当前 rowpipe 零仿真覆盖，环境里也没有 HDL 仿真器 —— 所以用板子当仿真器：
  同一场景下导两帧风格帧，逐块比对。

用法：
  # 1) 在"已知良好"的构建上抓基准（板子连着、场景尽量保持不动）
  python tools/frame_diff.py capture redsky_v5_known_good

  # 2) 改了 RTL、重烧之后，抓一帧对比
  python tools/frame_diff.py check redsky_v5_known_good

  # 3) 事后比两个已存文件（不需要板子）
  python tools/frame_diff.py --a a.bin --b b.bin

判定（等价性）：
  - 块级相关 > 0.98（把画面切成 40x30 块取均值再算相关）
  - 三通道均值差 < 2 级
  - σ 比值在 0.9 ~ 1.1
  三条都满足 → EQUIVALENT；出现平坦区/贴轨 → BROKEN；其余 → DIFFERENT

局限（必须知道）：
  1. 板子的摄像头输入**不是冻结的**，AE 会动、场景会变。所以比对前要确保
     光照稳定，且最好在同一个 AE 状态。残余差异会被 AE 噪声污染。
  2. 因此这个工具能抓**大错**（错图、通道错位、平坦区），抓不住 ±1 LSB 的细微差异。
  3. 要真正逐位对拍需要冻结输入的 TB，那是另一件事。

依赖：numpy + style_probe.py（同目录）
"""

import argparse
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from style_probe import Ocd, FRAME_BASE, SLOT_STRIDE, SLOT_COUNT, FRAME_W, FRAME_H, FRAME_BYTES  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOLDEN_DIR = os.path.join(ROOT, "_golden")

BLOCK_W, BLOCK_H = 40, 30        # 块级比对网格（640/40=16, 480/30=16）


def signed(arr):
    return arr.astype("int16").astype("float64") - 256.0 * (arr.astype("int16") >= 128)


def load_frame(path):
    d = np.fromfile(path, dtype=np.uint8)
    n = (len(d) // (FRAME_W * 4)) * (FRAME_W * 4)
    if n < FRAME_W * 4 * 8:
        raise SystemExit("%s 太小（%d B），不像完整风格帧" % (path, len(d)))
    img = d[:n].reshape(-1, FRAME_W, 4)
    q = np.stack([signed(img[:, :, i]) for i in range(3)], axis=2)
    return q


def stats(q):
    lum = q.mean(axis=2)
    return {
        "rows": int(q.shape[0]),
        "mean": [float(q[:, :, i].mean()) for i in range(3)],
        "std": [float(q[:, :, i].std()) for i in range(3)],
        "br": float(q[:, :, 2].mean() - q[:, :, 0].mean()),
        "flat": float(((q[:, :, 0] == 0) & (q[:, :, 1] == 0) & (q[:, :, 2] == 0)).mean() * 100),
        "clip": float(((q <= -127) | (q >= 127)).mean() * 100),
        "lum_std": float(lum.std()),
    }


def block_means(q):
    """切成 16x16 块取亮度均值 —— 空间结构比对用。行数不同时按较小者对齐。"""
    h = (q.shape[0] // BLOCK_H) * BLOCK_H
    w = (q.shape[1] // BLOCK_W) * BLOCK_W
    lum = q[:h, :w].mean(axis=2)
    return lum.reshape(h // BLOCK_H, BLOCK_H, w // BLOCK_W, BLOCK_W).mean(axis=(1, 3))


def compare(a, b):
    sa, sb = stats(a), stats(b)
    ma, mb = block_means(a), block_means(b)
    n = min(ma.shape[0], mb.shape[0])
    ma, mb = ma[:n], mb[:n]
    if ma.std() < 1e-6 or mb.std() < 1e-6:
        corr = float("nan")
    else:
        corr = float(np.corrcoef(ma.ravel(), mb.ravel())[0, 1])
    dmean = [abs(sa["mean"][i] - sb["mean"][i]) for i in range(3)]
    sratio = [(sb["std"][i] / sa["std"][i]) if sa["std"][i] > 1e-6 else float("nan") for i in range(3)]
    blockdiff = float(np.abs(ma - mb).max())

    print("%-14s %8s %8s %8s %8s" % ("", "R", "G", "B", "B-R"))
    print("%-14s %+8.1f %+8.1f %+8.1f %+8.1f" % ("A mean", *sa["mean"], sa["br"]))
    print("%-14s %+8.1f %+8.1f %+8.1f %+8.1f" % ("B mean", *sb["mean"], sb["br"]))
    print("%-14s %8.1f %8.1f %8.1f %8s" % ("A sigma", *sa["std"], ""))
    print("%-14s %8.1f %8.1f %8.1f %8s" % ("B sigma", *sb["std"], ""))
    print("%-14s %8.2f %8.2f %8.2f %8s" % ("|d mean|", *dmean, ""))
    print("%-14s %8.3f %8.3f %8.3f %8s" % ("sigma B/A", *sratio, ""))
    print()
    print("平坦区 A %.2f%% / B %.2f%%      贴轨 A %.2f%% / B %.2f%%" % (
        sa["flat"], sb["flat"], sa["clip"], sb["clip"]))
    print("块级相关 %.4f    块均值最大差 %.1f    (网格 %dx%d)" % (
        corr, blockdiff, ma.shape[1], ma.shape[0]))

    ok_corr = (corr > 0.98) if corr == corr else False
    ok_mean = max(dmean) < 2.0
    ok_std = all(0.9 <= r <= 1.1 for r in sratio if r == r)
    broken = (sb["flat"] - sa["flat"] > 5.0) or (sb["clip"] - sa["clip"] > 5.0)

    print()
    if broken:
        v = "BROKEN"
    elif ok_corr and ok_mean and ok_std:
        v = "EQUIVALENT"
    else:
        v = "DIFFERENT"
    print("=" * 60)
    print("裁决：%s" % v)
    print("  块级相关 > 0.98 : %s (%.4f)" % ("OK" if ok_corr else "NG", corr))
    print("  三通道均值差 < 2 : %s (%s)" % ("OK" if ok_mean else "NG",
                                            " ".join("%.1f" % d for d in dmean)))
    print("  sigma 比 0.9~1.1 : %s (%s)" % ("OK" if ok_std else "NG",
                                            " ".join("%.2f" % r for r in sratio)))
    if broken:
        print("  ⚠ 平坦区/贴轨显著增加 —— 典型的末层被 ReLU 或量程错位")
    print("=" * 60)
    return 0 if v != "BROKEN" else 1


def find_live_slot(ocd):
    """风格帧在 6 个 slot 轮转，APB 没有寄存器能报当前 slot ⇒ 探测 X 字节恒 0 的那个。"""
    for s in range(SLOT_COUNT):
        p = "_probe.bin"
        try:
            ocd.dump(FRAME_BASE + s * SLOT_STRIDE, 0x1000, p)
        except RuntimeError:
            continue
        d = np.fromfile(p, dtype=np.uint8)
        if os.path.exists(p):
            os.remove(p)
        if len(d) >= 0x1000 and (d[3::4] == 0).mean() > 0.99 and 0.3 < (d != 0).mean() < 0.98:
            return s
    return None


def capture(ocd, path):
    slot = find_live_slot(ocd)
    if slot is None:
        print("找不到有效风格帧（6 个 slot 都不像）——采集停了吗？")
        return False
    ocd.cmd("halt", timeout=10)
    ocd.dump(FRAME_BASE + slot * SLOT_STRIDE, FRAME_BYTES, path)
    ocd.cmd("resume", timeout=5)
    print("  已抓 slot%d → %s" % (slot, path))
    return True


def main(argv=None):
    ap = argparse.ArgumentParser(description="金帧回归：用板子当仿真器验证 RTL 改动")
    ap.add_argument("--a", help="对比文件 A")
    ap.add_argument("--b", help="对比文件 B")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4444)
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("capture", help="抓一帧作为基准")
    p.add_argument("name")
    p.add_argument("--note", default="", help="备注（构建号/权重 XOR 等）")
    p = sub.add_parser("check", help="抓一帧并与基准比对")
    p.add_argument("name")
    args = ap.parse_args(argv)

    if args.a and args.b:
        return compare(load_frame(args.a), load_frame(args.b))

    if not args.cmd:
        ap.print_help()
        return 2

    os.makedirs(GOLDEN_DIR, exist_ok=True)
    path = os.path.join(GOLDEN_DIR, args.name + ".bin")
    meta = os.path.join(GOLDEN_DIR, args.name + ".json")

    try:
        ocd = Ocd(args.host, args.port)
    except OSError as e:
        print("连不上 OpenOCD (%s:%d)：%s" % (args.host, args.port, e))
        return 2

    try:
        if args.cmd == "capture":
            if not capture(ocd, path):
                return 1
            with open(meta, "w", encoding="utf-8") as fh:
                json.dump({"name": args.name, "note": args.note,
                           "time": time.strftime("%Y-%m-%d %H:%M:%S")}, fh, ensure_ascii=False, indent=2)
            print("  基准已存：%s" % path)
            print("  之后改完 RTL 用：python tools/frame_diff.py check %s" % args.name)
            return 0

        if args.cmd == "check":
            if not os.path.exists(path):
                print("基准 %s 不存在，先跑 capture" % path)
                return 2
            tmp = os.path.join(GOLDEN_DIR, "_live.bin")
            if not capture(ocd, tmp):
                return 1
            return compare(load_frame(path), load_frame(tmp))
    finally:
        ocd.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
