"""行流水**调度模型**：组大小 G 扫描 → 每层 jitter → 总片上预算曲线。

    python -m tools.rowpipe_sched --target 720p30
    python -m tools.rowpipe_sched --target 720p30 --mode row

## 要回答什么

`hw/rowpipe/README.md` 的表 A 给的是**纯 2 行**的行缓冲（137.5KB @720p）。
但阵列**只有一份**（资源账逼死的：12 份要 1536 DSP），所以 12 层是**成组轮流被服务**的。
两次服务之间上游还在产数据 ⇒ **每层还要多一块"抖动缓冲"**。
这个工具就是算这块有多大，以及它随 G 怎么变。

## 模型（**假设都写在这儿，不同意就改这里**）

对每层 k（映射 co_par×ci_par×pix_par 由 `tools.bandwidth` 选出）：

    P_k     = hout_k × wout_k               本层输出像素数
    C_k     = ceil(co/co_par)·ceil(ci/ci_par)·9     一组 9 步摊下来的拍数
    V_k(G)  = (G / pix_par_k) · C_k           访问本层一次（处理 G 个像素）的拍数
    T       = Σ_k (P_k / pix_par_k) · C_k    整帧总拍数（= bandwidth.py 的总周期）

**自洽的访问间隔**：本层每帧要被访问 `P_k / G` 次，摊在 T 拍里 ⇒

    W_k = T · G / P_k                        平均访问间隔（拍）

两次访问之间上游送来的像素数 = `W_k · r_k`，其中 `r_k = P_k / T` 是像素到达率（像素/拍）。
所以

    jitter_k(平均)   = W_k · r_k · ci_k = **G · ci_k 字节**

—— 和层无关，只和 G 与输入通道数有关。**总抖动 = G · Σci_k。**

**悲观口径**（`--mode worst`）：调度器一轮里把所有层各访问一次才回来，
间隔变成整轮长 `R = Σ_j V_j(G)`：

    jitter_k(悲观) = R · r_k · ci_k 字节

**整行口径**（`--mode row`，**(c) 的默认**）：回填按**整行突发**，`G_k = wout_k`。

## 还没进模型的（所以曲线是**下界**）

- resize / 原画-风格画合成的缓冲
- 行缓冲本身的双缓冲（乒乓）
- 权重 bank（16.7KB × 风格数，另外算）

## 判据

    linebuf(137.5KB) + 总抖动 + 权重(16.7KB)  ≤  加速器可用

加速器可用按 `hw/rowpipe/README.md` §E.2：**实口径 149 块 = 186.25KB**（DDR3 含 AXI 桥）。
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from stnet import candidate_factories                      # noqa: E402
from stnet.hw import BASIC, HIGH                           # noqa: E402
from stnet.spec import CONV, DW, SUBPIX                    # noqa: E402
from tools.bandwidth import LANES, pick                    # noqa: E402

BRAM_BYTES = 1280
ACCEL_BLOCKS = 149          # §E.2 实口径（DDR3 39）
ACCEL_KB = ACCEL_BLOCKS * BRAM_BYTES / 1024


def layer_rows(spec, max_pix: int):
    """逐层：(名字, ci, P_k, pix_par, C_k)；只留真正做 3x3 的层。"""
    rows = []
    for l in spec.layers:
        if l.kind not in (CONV, DW, SUBPIX) or l.k <= 1:
            continue
        # 用 bandwidth 的映射选择（slack=1 的"只追周期"口径，和它的表一致）
        ms = list(__import__("tools.bandwidth", fromlist=["mappings"]).mappings(l, LANES, max_pix))
        cmin = min(__import__("tools.bandwidth", fromlist=["cycles_of"]).cycles_of(l, m) for m in ms)
        cand = [m for m in ms
                if __import__("tools.bandwidth", fromlist=["cycles_of"]).cycles_of(l, m)
                <= cmin * 1.0001]
        m = min(cand, key=lambda m: sum(__import__("tools.bandwidth",
                 fromlist=["bytes_of"]).bytes_of(l, m)))
        co_par, ci_par, pix_par = m
        C = (math.ceil(l.co / co_par) * math.ceil(l.ci / ci_par) * l.k * l.k)
        rows.append(dict(name=l.name, ci=l.ci, P=l.hout * l.wout,
                         pix=pix_par, C=C, wout=l.wout))
    return rows


def model(rows, kwargs):
    T = sum(r["P"] / r["pix"] * r["C"] for r in rows)      # 整帧拍数
    for r in rows:
        r["V"] = lambda G, r=r: (G / r["pix"]) * r["C"]
    return T


def jitter_of(rows, G_of, mode):
    T = sum(r["P"] / r["pix"] * r["C"] for r in rows)
    if mode == "row":
        Gs = [r["wout"] for r in rows]
    else:
        Gs = [G_of] * len(rows)
    Vs = [(G / r["pix"]) * r["C"] for G, r in zip(Gs, rows)]
    R = sum(Vs)                                            # 整轮长
    tot = 0.0
    det = []
    for G, V, r in zip(Gs, Vs, rows):
        r_k = r["P"] / T                                   # 像素到达率（像素/拍）
        if mode == "worst":
            W = R
        else:                                              # average / row
            W = T * G / r["P"]
        j = W * r_k * r["ci"]                              # 字节
        tot += j
        det.append((r["name"], G, W, j))
    return T, R, tot, det


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="行流水调度模型：G 扫描")
    ap.add_argument("--net", default="改D: 1/8ch 3res 3x3")
    ap.add_argument("--target", default="720p30", choices=["720p30", "640x480"])
    ap.add_argument("--mode", default="average", choices=["average", "worst", "row"])
    ap.add_argument("--max-pix", type=int, default=16)
    args = ap.parse_args()

    tgt, fps = (HIGH, 30) if args.target == "720p30" else (BASIC, 15)
    spec = candidate_factories()[args.net](tgt.height, tgt.width)
    rows = layer_rows(spec, args.max_pix)

    lb = spec.linebuf_bytes
    wt = spec.weight_bytes_int8
    print(f"网络 {spec.name} @ {tgt.width}x{tgt.height}  ({fps}fps)   模式={args.mode}")
    print(f"行缓冲(纯2行) {lb/1024:.1f}KB + 权重 {wt/1024:.1f}KB = "
          f"{(lb+wt)/1024:.1f}KB；加速器可用 {ACCEL_KB:.2f}KB (={ACCEL_BLOCKS} 块)")
    print(f"⇒ **留给抖动的额度 = {(ACCEL_KB*1024 - lb - wt)/1024:.1f}KB**")
    print()

    Gs = [8, 16, 32, 64]
    if args.mode == "row":
        Gs = [0]                                            # 0 = 整行
    print(f"{'G(像素)':>8}{'整帧拍 T':>12}{'整轮 R':>12}{'总抖动KB':>10}"
          f"{'合计KB':>10}{'余量KB':>9}  判定")
    print("-" * 74)
    for G in Gs:
        T, R, j, det = jitter_of(rows, G if G else 0, args.mode)
        tot = (lb + wt + j) / 1024
        margin = ACCEL_KB - tot
        tag = f"{'整行' if not G else G}"
        print(f"{tag:>8}{T:>12,.0f}{R:>12,.0f}{j/1024:>10.2f}{tot:>10.2f}"
              f"{margin:>9.2f}  {'OK' if margin >= 0 else '超 %0.2fKB' % -margin}")
        if args.mode == "row" and G == 0:
            print("\n  整行模式逐层（G=wout）：")
            print(f"    {'层':<12}{'ci':>4}{'G':>7}{'W(拍)':>10}{'jitter B':>10}")
            for n, g, w, jj in det:
                print(f"    {n:<12}{dict((r['name'], r['ci']) for r in rows)[n]:>4}"
                      f"{g:>7}{w:>10,.0f}{jj:>10,.0f}")

    print()
    print("⚠ 这是**下界**：resize / 合成 / 行缓冲乒乓 / 调度最坏相位都没进模型。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
