"""后处理链的硬件代价评估（720p30）。

    python -m tools.postproc_cost

> ⚠ **本脚本的滤波模型已被 `tools/blur_mem.py` 修正，两处结论不同，以那份为准。**
>
> 本脚本假设"3 级级联盒滤波的存储 = 3 个列累加器"，**这是错的**——
> 滑动求和还要减掉出窗的那一行，那行必须以行缓冲留着，正确量级是 **H 行**。
> 而且 3 级盒是串联的，行缓冲相加，**比直接型高斯还贵**。
>
> 正确结论：**全分辨率做要 84.5KB，装不下；降采样是前提，不是优化。**
> 见 `FPGA-IMPL.md` §3.7「更正二」。本脚本保留作对照。

只算**片上存储**（行缓冲/状态表），不算组合逻辑——后处理全是简单算子，
逻辑量相比网络可以忽略；真正会挤爆预算的是行缓冲。

## 两条路线的差别

**线条来源决定成本**，这是最大的一个分叉：

    edge   —— 内容侧做两尺度 Sobel+NMS 抓边缘。跟真实结构走，但
              **和色块边界对不齐**（两套独立分割），且要两份高斯 + Sobel/NMS。
    region —— **线条直接用色块分区自己的边界**。天然对齐（线条就是色块的交界），
              硬件上只要比较相邻标签。**省掉两个内容侧高斯和全部边缘检测。**

## 两个通用前提

 1. **模糊必须用 3 级级联盒滤波，不能用直接型高斯**。σ=2.5 的 17-tap
    垂直滤波要留 16 行 RGB，720p 下就是 60KB。盒滤波用滑动求和，
    **垂直方向每列只要一个累加器，不需要多行缓冲**。
    注意：状态量与**核宽无关**，只与列数有关，所以 σ 多大都一样贵。

 2. **区域取色可以流式做**：跨帧维护一张分区颜色表，
    `输出色 = 表[标签]`，`表[标签] ← 表[标签]×(1−α) + 像素色×α`。
    状态仅 3.2KB，不需要帧缓存，而且分区颜色跨帧收敛 → **减少视频闪烁**。
"""

W, H, FPS = 1280, 720, 30


def kb(n_bytes: float) -> float:
    return n_bytes / 1024.0


def box3(n_cols: int, channels: int) -> float:
    """3 级级联盒滤波的状态：每级 = 每列一个 16bit 累加器（字节）。"""
    return 3 * n_cols * channels * 2


def cost(lines: str = "region", edge_down: int = 1) -> dict[str, float]:
    """返回各项开销（KB）。lines ∈ {edge, region}；edge_down 只对 edge 路线有意义。"""
    row_rgb = W * 3
    row_g = W
    d2 = edge_down ** 2

    items: dict[str, float] = {}

    # ① 分区取色：内容先模糊再量化成标签（颜色侧）
    items["内容模糊 σ=4（灰度，3 级盒）"] = kb(box3(W, 1))

    if lines == "region":
        # ② 线条分区：另一套更粗的模糊 + 量化。硬件上只要**一行标签延迟**
        #    就能和右/下邻居比较——比 Sobel/NMS 便宜一个数量级
        items["内容模糊 σ=8（灰度，3 级盒）"] = kb(box3(W, 1))
        items["分区标签延迟（1 行 × 5bit）"] = kb(W * 5 / 8)
    else:
        # ② 边缘检测路线：两个尺度的高斯 + Sobel/NMS 的行缓冲
        items["内容模糊 σ=3（灰度，3 级盒）"] = kb(box3(W, 1)) / d2
        items["内容模糊 σ=7（灰度，3 级盒）"] = kb(box3(W, 1)) / d2
        items["Sobel/NMS 细尺度（2 行灰度）"] = kb(2 * row_g) / d2
        items["Sobel/NMS 粗尺度（2 行灰度）"] = kb(2 * row_g) / d2

    # ③ 通用项
    items["中值 3×3（2 行 RGB）"] = kb(2 * row_rgb)
    items["区域颜色表（216 区 × RGB32+计数）"] = kb(216 * (3 * 4 + 3))
    return items


def main() -> int:
    print(f"基准：720p30 = {W}x{H}@{FPS} → {W*H*FPS/1e6:.1f} M pixel/s")
    print(f"一行 RGB = {kb(W*3):.2f} KB ｜ 一行灰度 = {kb(W):.2f} KB")
    print()

    print("── 方案 A：直接型高斯（不可取，仅作对照）")
    a = (17 - 1) * W * 3 + (19 - 1) * W
    print(f"   输出 σ=2.5 留 16 行 RGB + 内容 σ=3 留 18 行灰度 = {kb(a):.1f} KB"
          f"（占 1 核预算 {kb(a)/215*100:.0f}%）")
    print()

    print("── 方案 B：级联盒滤波 + 分区线条（推荐）")
    for name, v in cost("region").items():
        print(f"   {name:34s} {v:6.1f} KB")
    tot_r = sum(cost("region").values())
    print(f"   {'合计':34s} {tot_r:6.1f} KB")
    print()

    print("── 方案 C：级联盒滤波 + 边缘检测线条（对照，见 §1.6 取舍）")
    for name, v in cost("edge", 1).items():
        print(f"   {name:34s} {v:6.1f} KB")
    tot_e = sum(cost("edge", 1).values())
    print(f"   {'合计（d=1）':34s} {tot_e:6.1f} KB")
    print(f"   边缘检测降采样 d=2 时合计 {sum(cost('edge',2).values()):.1f} KB"
          f"（省 {tot_e-sum(cost('edge',2).values()):.1f}，但线条位置变粗）")
    print()

    print("── 1 核预算对比（215.0 KB，实测口径）")
    for label, net in (("做完共享", 154.2), ("不做共享", 184.2)):
        for tag, post in (("region线条", tot_r), ("edge线条 d=1", tot_e)):
            s = net + post
            mark = "OK " if s <= 215 else "NG "
            note = f"余 {215-s:.1f}" if s <= 215 else f"超 {s-215:.1f}"
            print(f"   网络({label}) {net:6.1f} + {tag:14s} {post:5.1f}"
                  f" = {s:6.1f} KB  [{mark}{note}]")
    print()
    print("(结论) 分区线条比边缘检测省约 %.0f KB，且与色块天然对齐；" % (tot_e - tot_r))
    print("       「行缓冲/残差共享」仍是硬前提——不做的话两种线条都超预算。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
