"""行缓冲读带宽的设计空间探索。

    python -m tools.bandwidth              # 改D @720p30
    python -m tools.bandwidth --target 640x480 --fps 15

**为什么需要这个工具**：PE 阵列的映射方式（输出通道 × 输入通道 × 空间并行）
决定了每拍要从行缓冲取出多少数据。而"能取多少"是硬件的硬约束——
BRAM 的读端口位宽是有限的。

初版方案里我写过"96 字节/拍"，那是按 ci_par=4 粗估的。实际扫下来发现
**某些层的需求远不止**，而且存在一个不受映射方式影响的量（见下面推导），
所以必须逐层算准。

推导：8 个输出像素并行、3×3 卷积、stride=1 时，
每拍要推进 8 个像素的窗口，每个输入通道、每一行要取 8 个新字节。
3 行里 2 行来自行缓冲（BRAM），1 行来自上一层的数据流。

    行缓冲读 = pix_par × (k-1) × ci_par   字节/拍
    数据流   = pix_par × 1     × ci_par   字节/拍

关键：`pix_par × ci_par = LANES / co_par`，而 `co_par ≤ co`。
**所以 co 小的层（比如 out 的 3），无论怎么映射，读带宽都被顶得很高。**
这是本工具要暴露的核心结论。
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from stnet import DEFAULT_BUDGET, Timing  # noqa: E402
from stnet.hw import BASIC, HIGH  # noqa: E402
from stnet.spec import CONV  # noqa: E402

LANES = 256          # PE 阵列规模（MAC）
TIMING = Timing(clk_hz=250e6, utilization=0.75, mac_per_dsp=2)


# 空间并行取 2 的幂：地址生成、掩码、对齐都简单得多，硬件上基本是硬要求。
# 不限制的话搜索会挑出 pix=13 这种"数学最优但没法实现"的解。
PIX_SET = (1, 2, 4, 8, 16)


def mappings(layer, lanes: int, max_pix: int):
    """枚举该层所有可行的 (co_par, ci_par, pix_par) 映射。"""
    for co_par in range(1, min(layer.co, lanes) + 1):
        for ci_par in range(1, min(layer.ci, lanes // co_par) + 1):
            max_p = lanes // (co_par * ci_par)
            for pix_par in PIX_SET:
                if pix_par <= min(max_p, max_pix):
                    yield co_par, ci_par, pix_par


def cycles_of(layer, m) -> int:
    co_par, ci_par, pix_par = m
    s = layer.stride
    n = layer.hout * layer.wout
    # stride>1 时，相邻输出像素之间隔 s 个输入像素，空间并行不会减少总窗口数
    return (math.ceil(layer.co / co_par) * math.ceil(layer.ci / ci_par)
            * layer.k * layer.k * math.ceil(n / pix_par))


def bytes_of(layer, m) -> tuple[float, float]:
    """(行缓冲读字节/拍, 数据流字节/拍) —— **按"换像素组时回填窗口"算**。

    这是本工具第二版修正的地方，也是整份验证的关键假设。

    错误模型（第一版）：以为每个 tap 都要重读行缓冲 —— 算出来 800 字节/拍，
    需要 320 块 BRAM，根本不可能。

    正确模型：3×3 的窗口放在**寄存器**里，9 个 tap 从同一个窗口里选，
    只有在"整组像素往前挪 pix_par 个"时才需要回填新数据。所以：

        每组的字节数 = (k-1) 行 x pix_par x s 个新像素 x ci_par 通道   （来自 BRAM）
        每组的周期数 = co_tiles x ci_tiles x k^2                      （9 个 tap 共用窗口）

    **"窗口必须在寄存器里"因此不是优化，是硬性要求**——这条得写进 RTL 规格。

    注：co_tiles 若 >1，窗口会被重读。所以映射要尽量让 co_par = co（本设计的
    最优映射都满足），否则带宽要乘 co_tiles。
    """
    co_par, ci_par, pix_par = m
    s = layer.stride
    co_tiles = math.ceil(layer.co / co_par)
    ci_tiles = math.ceil(layer.ci / ci_par)
    new_cols = pix_par * s                          # 窗口每前进一组，新进的列数
    bram_per_group = (layer.k - 1) * new_cols * ci_par * co_tiles
    stream_per_group = 1 * new_cols * ci_par * co_tiles
    cycles_per_group = co_tiles * ci_tiles * layer.k * layer.k
    return (bram_per_group / cycles_per_group,
            stream_per_group / cycles_per_group)


# Ti60 每块 10-Kbit BRAM 最多配成 512x20（简单双口），即每拍最多读 20 bit。
# 真双口是 1024x10 x2 端口 = 同样 20 bit。级联不改变"每块 20 bit/拍"这个比例。
BRAM_BITS_PER_CYCLE = 20
BRAM_BYTES = 1280            # 10 Kbit = 1280 字节


def bram_cost(layer, m, verbose=False):
    """该层需要的 BRAM 块数 = max(存储需要, 读带宽需要)。

    注意这两者是**同一块 BRAM 提供的**：一块 BRAM 既占存储，又贡献 20 bit/拍的读带宽。
    所以取 max 而不是相加。
    """
    lb = layer.linebuf_bytes
    store = math.ceil(lb / BRAM_BYTES) if lb else 0
    bram_bw, _ = bytes_of(layer, m)
    bw = math.ceil(bram_bw * 8 / BRAM_BITS_PER_CYCLE)
    return max(store, bw), store, bw


def pick(spec, max_pix: int, slack: float):
    """在"每层周期 ≤ slack × 该层周期下界"的约束下，逐层选行缓冲读带宽最小的映射。

    先卡周期再省带宽 —— 反过来会全选 pix_par=1（带宽最低但周期爆掉），
    这正是本工具第一版写错的地方。
    """
    rows = []
    for l in spec.layers:
        if l.kind != CONV:
            continue
        ms = list(mappings(l, LANES, max_pix))
        cmin = min(cycles_of(l, m) for m in ms)
        # slack < 1 表示这个空间并行上限根本达不到目标帧率，退回周期最优解
        budget = cmin * max(slack, 1.0)
        cand = [m for m in ms if cycles_of(l, m) <= budget]
        # 同带宽时取周期更小的，免得白留余量
        m = min(cand, key=lambda m: (sum(bytes_of(l, m)), cycles_of(l, m)))
        b, st = bytes_of(l, m)
        rows.append((l, m, b, st, cycles_of(l, m), cmin))
    return rows


def analyze(spec, target, fps: float, max_pix: int, verbose: bool = True):
    budget_cycles = int(TIMING.clk_hz / fps)
    rows0 = pick(spec, max_pix, 1.0)
    total_min = sum(r[4] for r in rows0)
    slack = budget_cycles / total_min

    if verbose:
        print(f"网络 {spec.name} @ {target.name}")
        print(f"时钟 {TIMING.clk_hz / 1e6:.0f}MHz，目标 {fps:g}fps，"
              f"周期预算 {budget_cycles:,} 拍")
        print(f"周期下界（只追周期）{total_min:,} 拍，占预算 "
              f"{100 * total_min / budget_cycles:.0f}% -> 可用余量 {slack:.2f}x")
        print()

    rows = pick(spec, max_pix, slack)
    if verbose:
        print(f"{'层':<10}{'ci->co':>8}{'输出':>11}{'映射 co×ci×pix':>16}"
              f"{'拍':>12}{'行缓冲读':>10}{'数据流':>9}{'BRAM':>7}")
        print("-" * 88)
        tot_bram = 0
        for l, m, b, st, c, cmin in rows:
            need, store, bw = bram_cost(l, m)
            tot_bram += need
            print(f"{l.name:<10}{f'{l.ci}->{l.co}':>8}{f'{l.hout}x{l.wout}':>11}"
                  f"{f'{m[0]}x{m[1]}x{m[2]}':>16}{c:>12,}"
                  f"{b:>9.1f}{st:>9.1f}{need:>7}")
        total_c = sum(r[4] for r in rows)
        peak_row = max(rows, key=lambda r: r[2])
        peak_bw = peak_row[2]
        print("-" * 88)
        print(f"{'合计':<10}{'':>8}{'':>11}{'':>16}{total_c:>12,}"
              f"{'':>9}{'':>9}{tot_bram:>7}")
        print(f"\n总周期 {total_c:,} / 预算 {budget_cycles:,} -> "
              f"{TIMING.clk_hz / total_c:.1f} fps "
              f"[{'OK' if total_c <= budget_cycles else 'FAIL'}]")
        print(f"峰值行缓冲读 {peak_bw:.1f} 字节/拍 @ {peak_row[0].name}"
              f"（= {peak_bw * 8:.0f} bit，需 {math.ceil(peak_bw * 8 / BRAM_BITS_PER_CYCLE)}"
              f" 块 BRAM 的读端口）")

        print(f"\nBRAM 预算（各层行缓冲独立、全流水同时工作，所以要**相加**）：")
        print(f"  行缓冲合计 {tot_bram} 块 / 加速器可用 91 块 "
              f"-> {'装得下，余 %d 块' % (91 - tot_bram) if tot_bram <= 91 else '超 %d 块' % (tot_bram - 91)}")
        print(f"  （每块 1.25KB，{tot_bram} 块 = {tot_bram * 1.25:.1f}KB）")
        peak_need, peak_store, peak_bw_bram = bram_cost(peak_row[0], peak_row[1])
        print(f"  最吃 BRAM 的层：{peak_row[0].name} 需要 {peak_need} 块"
              f"（存储 {peak_store} / 带宽 {peak_bw_bram}）")
    return rows, sum(r[4] for r in rows), max(r[2] for r in rows)


def main() -> int:
    ap = argparse.ArgumentParser(description="行缓冲读带宽设计空间探索")
    ap.add_argument("--net", default="改D: 1/8ch 3res 3x3")
    ap.add_argument("--target", default="720p30", choices=["720p30", "640x480"])
    ap.add_argument("--max-pix", type=int, default=16, help="空间并行上限")
    ap.add_argument("--lanes", type=int, default=256)
    args = ap.parse_args()

    global LANES
    LANES = args.lanes
    tgt, fps = (HIGH, 30) if args.target == "720p30" else (BASIC, 15)

    from stnet import candidate_factories
    spec = candidate_factories()[args.net](tgt.height, tgt.width)
    analyze(spec, tgt, fps, args.max_pix)

    print("\n" + "=" * 90)
    print("空间并行上限的影响（上限越小 -> 带宽越低，但周期越多）")
    print("=" * 90)
    print(f"{'上限':<6}{'峰值读所在层/映射':>24}{'行缓冲读':>10}{'数据流':>8}"
          f"{'合计B/拍':>10}{'总周期':>13}{'fps':>8}")
    for mx in (2, 4, 8, 16, 32):
        rows0 = pick(spec, mx, 1.0)
        slack = int(TIMING.clk_hz / fps) / sum(r[4] for r in rows0)
        rows = pick(spec, mx, slack)
        pk = max(rows, key=lambda r: r[2] + r[3])
        tc = sum(r[4] for r in rows)
        got = TIMING.clk_hz / tc
        print(f"{mx:<6}{f'{pk[0].name} {pk[1][0]}x{pk[1][1]}x{pk[1][2]}':>24}"
              f"{pk[2]:>10.1f}{pk[3]:>8.1f}{pk[2] + pk[3]:>10.1f}{tc:>13,}{got:>8.1f}"
              f"{'  OK' if got >= fps else '  NG'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
