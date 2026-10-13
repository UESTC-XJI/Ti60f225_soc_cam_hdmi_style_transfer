"""设计空间探索：扫描候选架构 × 赛题指标，输出可行性总表。

用法：
    python -m tools.explore            # 用默认的 200MHz / 65% 利用率
    python -m tools.explore --detail   # 额外打印每个架构的逐层明细
    python -m tools.explore --sweep-clock   # 对时钟/利用率做敏感度分析
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from stnet import (  # noqa: E402
    BASIC,
    HIGH,
    DEFAULT_BUDGET,
    DEFAULT_TIMING,
    Timing,
    analyze,
    budget_after,
    candidate_factories,
    sweep,
)


def main() -> None:
    ap = argparse.ArgumentParser(description="风格迁移网络 FPGA 设计空间探索")
    ap.add_argument("--detail", action="store_true", help="打印每个架构的逐层明细")
    ap.add_argument("--sweep-clock", action="store_true", help="对时钟/利用率做敏感度分析")
    ap.add_argument("--riscv-cores", type=int, default=3, choices=[1, 3],
                    help="RISC-V 软核数量，1 核能给加速器省下不少资源")
    args = ap.parse_args()

    budget = budget_after(use_riscv_cores=args.riscv_cores)
    timing = DEFAULT_TIMING
    factories = candidate_factories()

    print("=" * 84)
    print("风格迁移加速器 · 设计空间探索")
    print("=" * 84)
    print(f"加速器资源预算 : {budget}")
    print(f"算力天花板     : {timing.describe(budget.dsp)}")
    print("（未扣除基础设施 IP 时芯片总资源：62,016 LE / 256 BRAM / 160 DSP）")
    print(f"（RISC-V 软核数：{args.riscv_cores}）")

    print(sweep(factories, [BASIC, HIGH], budget, timing))

    if args.detail:
        print("\n" + "=" * 84)
        print("逐层明细 @ 640x480")
        print("=" * 84)
        for name, make in factories.items():
            spec = make(BASIC.height, BASIC.width)
            print(f"\n{spec.name}")
            print(spec.layer_table())
            print(analyze(spec, BASIC, budget, timing).detail())

    if args.sweep_clock:
        print("\n" + "=" * 84)
        print("敏感度分析：结论对时序假设有多敏感")
        print("=" * 84)
        assume = [
            ("悲观 150MHz/55%（不打包 INT8）", Timing(150e6, 0.55, 1)),
            ("保守 175MHz/60%（不打包）", Timing(175e6, 0.60, 1)),
            ("基准 200MHz/65% Dual", Timing(200e6, 0.65, 2)),
            ("乐观 250MHz/75% Dual", Timing(250e6, 0.75, 2)),
        ]
        hdr = f"{'架构 (720p30)':<28}" + "".join(f"{n:>24}" for n, _ in assume)
        print(hdr)
        print("-" * len(hdr))
        for name, make in factories.items():
            spec = make(HIGH.height, HIGH.width)
            row = f"{name:<28}"
            for _, tm in assume:
                r = analyze(spec, HIGH, budget, tm)
                row += f"{r.max_fps:>18.1f}fps {'OK' if r.compute_ok else 'NG':<5}"
            print(row)


if __name__ == "__main__":
    main()
