"""后处理链的行缓冲：一次错误推导的修正，以及修正后的正确账。

    python -m tools.blur_mem

## 我原来错在哪

§3.7 初版写：**"盒滤波用滑动求和，垂直方向每列只要一个累加器，不需要多行缓冲"**。
**这是错的。**

累加器确实只要一个，但**滑动求和还要减掉"出窗"的那一行**——
那一行必须以行缓冲的形式留着，否则减不掉。正确推导：

    直接型 FIR：第 r = y+(H-1)/2 行到达时才能算 out[y]，
               窗口是 in[r-(H-1) .. r] → 留住 H-1 行
    滑动求和  ：out[y+1] = out[y] + in[y+1+(H-1)/2] − in[y-(H-1)/2]
               第 r 行到达时要减掉 in[r-H] → 留住 H 行

**两者都是 ~H 行。盒滤波省的是乘法器（3 个加减 vs 19 个乘法），不是行缓冲。**
而 3 级盒是**串联**的，各自的行缓冲相加 → 比直接型还贵。

## 修正后的结论

**全分辨率做后处理：73.8 KB，装不下**（网络 154.2 + 73.8 = 228 > 215）。

修正是**降采样**（行数按 1/D^2 缩），以及**去掉不必要的输出侧模糊**
（分区取平均已经把网络输出的排线抹平了，再模糊一次是用不上的）。
"""

W = 1280
BUDGET = 215.0     # 1 核预算实测口径
NET_SHARED = 154.2  # 做完 行缓冲/残差共享 之后的网络占用


def rows_direct(sigma: float) -> int:
    """直接型高斯需要的行缓冲行数 = (tap+1)/2，tap = 2·ceil(3σ)+1。"""
    return (2 * int(3 * sigma) + 1 + 1) // 2


def rows_box3(sigma: float) -> int:
    """3 级级联盒滤波：H = sqrt(4σ^2+1)，三级串联行数相加。"""
    h = max(1, int(round((4 * sigma * sigma + 1) ** 0.5)))
    return 3 * h


def kb(rows: int, width: int = W, ch: int = 1) -> float:
    return rows * width * ch / 1024.0


def main() -> int:
    print("=" * 78)
    print("① 全分辨率直接做：装不下")
    print("=" * 78)
    jobs = [(2.5, "输出模糊 (RGB)", 3), (3.0, "内容模糊细 (灰)", 1), (8.0, "内容模糊粗 (灰)", 1)]
    tot = 0.0
    for s, name, ch in jobs:
        rd, rb = rows_direct(s), rows_box3(s)
        tot += kb(rd, W, ch)
        print(f"   σ={s:<4} {name:<16} 直接型 {rd:>2}行 {kb(rd,W,ch):>6.1f}KB"
              f"   ｜ 3级盒 {rb:>2}行 {kb(rb,W,ch):>6.1f}KB")
    fixed = kb(2, W, 3) + kb(216 * 15 / 8 / W, W) + 3.2   # 中值 + 标签延迟 + 区域表
    fixed = kb(2, W, 3) + 3.2
    print(f"   {'通用项（中值+区域表）':<20} {fixed:>19.1f}KB")
    print(f"   {'合计（直接型）':<20} {tot+fixed:>19.1f}KB"
          f"   → 网络 {NET_SHARED} + {tot+fixed:.1f} = {NET_SHARED+tot+fixed:.1f}KB"
          f"  {'装得下' if NET_SHARED+tot+fixed<=BUDGET else '超 %.1fKB'%(NET_SHARED+tot+fixed-BUDGET)}")
    print()

    print("=" * 78)
    print("② 修正版：去掉输出模糊 + 降采样（行数按 1/D^2 缩）")
    print("=" * 78)
    print("   · 输出侧模糊**不需要**：分区取平均已经把网络输出的排线抹平了")
    print("   · 内容侧两个尺度都降采样做，尺度按比例折算（σ 在 1/D 分辨率上变成 σ/D）")
    print()
    print(f"   {'项':<26} {'D':>3} {'滤波行':>7} {'滤波KB':>8} {'降采样行':>9} {'合计KB':>8}")
    s_total = fixed
    plan = [(3.0, "内容模糊细 σ=3 (灰)", 2), (8.0, "内容模糊粗 σ=8 (灰)", 4)]
    for s, name, D in plan:
        H = rows_direct(s / D)          # 降采样后尺度变了
        filt = kb(H, W // D, 1)         # 行缓冲在低分辨率上，宽度也变窄
        ds = kb(D, W, 1)                # D×D 盒平均的垂直部分要 D 行
        s_total += filt + ds
        print(f"   {name:<26} {D:>3} {H:>7} {filt:>8.1f} {ds:>9.1f} {filt+ds:>8.1f}")
    print(f"   {'通用项（中值 2行RGB + 区域表）':<26} {'':>3} {'':>7} {'':>8} {'':>9} {fixed:>8.1f}")
    print(f"   {'合计':<26} {'':>3} {'':>7} {'':>8} {'':>9} {s_total:>8.1f}")
    tot_all = NET_SHARED + s_total
    print()
    print(f"   → 网络 {NET_SHARED} + 后处理 {s_total:.1f} = {tot_all:.1f}KB"
          f"  {'[OK] 余 %.1fKB' % (BUDGET-tot_all) if tot_all <= BUDGET else '[NG] 超 %.1fKB' % (tot_all-BUDGET)}")
    print()
    print("=" * 78)
    print("结论")
    print("=" * 78)
    print("   ① §3.7 初版的 26.4KB 是错的（按错的盒滤波模型算的）")
    print("   ② 全分辨率做要 73.8KB，**装不下**")
    print("   ③ **降采样不是可选优化，是前提** —— 大 σ 尤其要降")
    print("   ④ RTL 的行缓冲要按这个表设计，不能按初版那个数")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
