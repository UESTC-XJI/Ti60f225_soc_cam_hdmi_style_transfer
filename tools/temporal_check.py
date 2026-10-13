"""**合成视频序列，验证逐帧统计量的时间行为**。

    python -m tools.temporal_check                 # 默认 4 段 x 20 帧
    python -m tools.temporal_check --frames 30

## 为什么要合成

`tools/toon.py::TemporalStat` 的自检（`--self-check`）只验了**数学**：
阶跃响应和抖动抑制。但真实视频里的问题不是数学，是**逐帧统计量本身长什么样**——
一段推镜之后 Y 均值怎么漂，切镜头时跳多大。这些用 `np.full()` 造不出来。

这里用内容图**合成**一段有"推镜 + 切镜头"的序列，**逐帧真跑网络**取统计量，
再走 `TemporalStat`，量三件事：

| 量什么 | 为什么 |
|---|---|
| 推镜期间**增益的逐帧抖动量** | 抖 = 画面亮度在泵，就是用户能看见的"闪" |
| 切镜头后**收敛到新场景要几帧** | IIR 时间常数 ≈10 帧，不加检测会错半秒以上 |
| 平滑前后**增益的动态范围**是否被压掉 | 过度平滑会把"该跟着内容变"的部分也抹了 |

## 实测结论（2026-09-29，`runs/D_wc_g15`）

**① 原型的"统计量很稳"是 InstanceNorm 给的假象。**
网络里有 IN，逐图归一化会把全局亮度变化直接抹掉——曝光压 3 倍，输出 Y 均值几乎不动。
**部署时 IN 被折叠成定值，那份稳定性就没了。** 必须用 `--deployed` 测折叠网络：

| | 原型（IN 活的） | 折叠后（部署版） |
|---|---|---|
| Y 均值范围 | 0.409~0.450 | **0.111~0.355** |
| 跨帧 std | 0.0133 | **0.0866**（6.5 倍） |
| 支点逐帧抖动（不平滑） | 0.00153 | **0.00788** |

**② 不加切镜头检测会错半秒以上。** 合成一次曝光剧变（`--stress 0.35`）后，
纯 IIR 要 **13~29 帧**才收敛（30fps 下 **0.43~0.97 秒**增益是错的）；
加了检测器，大跳变 **1 帧**恢复。

**③ `cut_thr` 取 0.10。** 折叠网络的切镜头跳变实测 0.244——原来的默认 0.25 **刚好漏检**。
0.10~0.15 都能工作；场景内逐帧抖动只有 0.0079，0.10 是它的 13 倍，不会误触发。

## ⚠ 这验不了什么

- **不是上板**。没有真实传感器噪声、没有编码/传输抖动、没有真实运镜轨迹。
- **不验观感**。"增益抖多少算看得见"这件事合成序列答不了——**上板才算数**。
- 合成推镜是**匀速平移**，真实手持会有抖动和高频运动，那是更难的情况。

⇒ 结论只能写成"**在合成序列上**，X 成立"。**别写成"不闪了"**。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np  # noqa: E402
import torch  # noqa: E402
from PIL import Image  # noqa: E402

from train.data import DATA, net_input, to_luma  # noqa: E402
from train.stylize import load_net  # noqa: E402
from train.train import pick_device  # noqa: E402
from tools.toon import auto_contrast_params  # noqa: E402


def spread_clips(net, device, n: int, probe: int = 40):
    """挑 n 个镜头，使**网络输出 Y 均值**的跨度最大。

    ⚠ 不能按内容图的亮度挑。第一版按 `ImageStat.mean` 排，挑出来 4 张内容亮度差很多，
    但过完网络 + `luma_match` 之后输出 Y 均值只差 **0.057** ——
    "硬切"根本没硬起来，切镜头检测一次都没触发。
    **判据要挑在被测的那个量上，不能挑在它的上游。**
    """
    from train.data import to_batch
    fs = sorted((DATA / "content").glob("*.jpg"))[:: max(1, len(list((DATA / "content").glob("*.jpg"))) // probe)]
    stats = []
    with torch.no_grad():
        for f in fs:
            im = Image.open(f).convert("RGB").resize((128, 128), Image.BICUBIC)
            x3 = to_batch(im).to(device)
            y = net(net_input(x3, net)).clamp(0, 1)
            g = y[:, 0:1] if y.shape[1] == 1 else to_luma(y)
            stats.append((float(g.mean()), f))
    stats.sort()
    if n == 1:
        return [stats[len(stats) // 2][1]], stats
    idx = [round(i * (len(stats) - 1) / (n - 1)) for i in range(n)]
    return [stats[i][1] for i in idx], stats


def apply_exposure(im: Image.Image, gain: float) -> Image.Image:
    """模拟一次**剧烈的曝光/光照变化**（例如从室内走到室外）。

    为什么要造：实测整个内容集过完网络后 Y 均值只在 **0.401~0.442**（跨度 0.04），
    真实切镜头几乎不改变统计量 —— **语料里根本没有"剧烈跳变"这种情形**，
    不造一个出来就验不到切镜头检测到底有没有用。
    造出来的要**明确标注是合成的**，不能当成真实场景的结论。
    """
    if abs(gain - 1.0) < 1e-6:
        return im
    a = np.asarray(im, dtype=np.float32) * gain
    return Image.fromarray(np.clip(a, 0, 255).astype("uint8"))


def make_sequence(files, frames_per_clip: int, crop: int, pan: int,
                  stress: float = 1.0):
    """合成序列：每段从**降采样前**的大图上匀速平移取 `crop×crop` 的窗口。

    返回 [(clip_index, frame_index_in_clip, PIL.Image)]。
    段与段之间是**硬切**——这正是 IIR 平滑最容易出错的时刻。
    """
    from train.data import to_batch
    seq = []
    for ci, f in enumerate(files):
        # 后半段镜头整体乘一个曝光增益，造一次大跳变
        g = stress if (stress != 1.0 and ci >= len(files) // 2) else 1.0
        img = Image.open(f).convert("RGB")
        w, h = img.size
        big = min(w, h)
        left0, top0 = (w - big) // 2, (h - big) // 2
        big_img = img.crop((left0, top0, left0 + big, top0 + big))
        # 窗口在 big_img 里从左到右匀速滑 pan 像素，再滑回来
        for i in range(frames_per_clip):
            t = i / max(frames_per_clip - 1, 1)
            off = int(round(np.sin(t * np.pi) * pan))
            x0 = max(0, min(big - crop, off))
            y0 = max(0, min(big - crop, (big - crop) // 3))
            seq.append((ci, i, apply_exposure(
                big_img.crop((x0, y0, x0 + crop, y0 + crop)), g)))
    return seq


def main() -> int:
    # Windows 控制台默认 GBK，中文/符号会 UnicodeEncodeError 把整个工具打断。
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="合成序列验证逐帧统计量的时间行为")
    ap.add_argument("--ckpt", type=Path, default=Path("runs/D_wc_g15"))
    ap.add_argument("--clips", type=int, default=4, help="几个镜头（每段之间是硬切）")
    ap.add_argument("--frames", type=int, default=20, help="每个镜头多少帧")
    ap.add_argument("--crop", type=int, default=256)
    ap.add_argument("--pan", type=int, default=96, help="平移幅度（像素）")
    ap.add_argument("--alpha", type=float, default=0.9, help="IIR 系数")
    ap.add_argument("--cut-thr", type=float, default=0.10,
                    help="切镜头判定阈值（scale=1.0 时就是绝对量）")
    ap.add_argument("--deployed", action="store_true",
                    help="用**折叠后**的部署网络（默认用带 IN 的原型）。"
                         "两者统计量的稳定性完全不同——IN 会把全局亮度变化归一化掉")
    ap.add_argument("--stress", type=float, default=1.0,
                    help="给后半段镜头整体乘的**合成**曝光增益（如 0.35）——"
                         "用来造出语料里没有的剧烈跳变，专门验切镜头检测")
    args = ap.parse_args()

    device = pick_device()
    ckpt = args.ckpt / "net.pt" if args.ckpt.is_dir() else args.ckpt
    if args.deployed:
        # **必须也测折叠后的网络**。原型里 IN 是活的，会逐图归一化，
        # 把全局亮度变化直接抹掉（实测曝光 x0.35，网络输出 Y 均值几乎不动）——
        # 于是"统计量很稳"是 IN 给的假象。**部署时 IN 被折叠成定值，那份稳定性就没了。**
        from train.deploy import load_deploy_net
        dep = (args.ckpt / "deploy" / "net_deploy.pt") if args.ckpt.is_dir() else args.ckpt
        net, _ = load_deploy_net(dep, device)
        print(f"[已折叠] {dep}")
    else:
        net, _ = load_net(ckpt, device)
        print(f"[原型 IN 活的] {ckpt}")

    # ⚠ **必须挑亮度跨度大的镜头**。第一版随手取了 `content` 的前三张，
    # 它们的 Y 均值只差 0.023 —— "硬切"根本不硬，切镜头检测一次都没触发，
    # 于是量出来的是"检测没用"，而不是"检测没用对"。**测试场景要先验证它真的够难。**
    files, allstats = spread_clips(net, device, args.clips)
    print(f"候选 {len(allstats)} 张，网络输出 Y 均值 {allstats[0][0]:.3f}~{allstats[-1][0]:.3f}")
    seq = make_sequence(files, args.frames, args.crop, args.pan, args.stress)
    print(f"序列 {len(seq)} 帧 = {args.clips} 个镜头 x {args.frames} 帧"
          f"（镜头之间硬切），crop {args.crop}, pan {args.pan}")
    print(f"镜头（按亮度挑的）：{', '.join(f.stem[-6:] for f in files)}")

    # ---- 逐帧真跑网络，取统计量 ----
    mu, sd = [], []
    with torch.no_grad():
        for ci, fi, im in seq:
            from train.data import to_batch
            x3 = to_batch(im).to(device)
            y = net(net_input(x3, net)).clamp(0, 1)
            g = y[:, 0:1] if y.shape[1] == 1 else to_luma(y)
            mu.append(float(g.mean()))
            sd.append(float(g.std()))
    mu, sd = np.array(mu), np.array(sd)
    print(f"\n原始逐帧统计：  Y 均值 {mu.min():.3f}~{mu.max():.3f}（跨帧 std {mu.std():.4f}）"
          f"  Y 标准差 {sd.min():.3f}~{sd.max():.3f}")

    # ---- 走 TemporalStat ----
    from tools.toon import TemporalStat
    sc = float(np.median(sd) + 1e-6)

    def run(alpha, cut, scale=1.0):
        """scale=1.0：均值/标准差本身就在 [0,1]，阈值按**绝对量**给才可解释。"""
        tm = TemporalStat(alpha=alpha, cut_thr=cut, scale=scale)
        ts = TemporalStat(alpha=alpha, cut_thr=cut, scale=scale)
        ks, pv = [], []
        for i in range(len(mu)):
            m = tm(mu[i])
            s = ts(sd[i])
            # 和 auto_contrast_params 里同一套公式（pivot 模式）
            p_hi = m + 1.3 * s
            k = min(1.5, max(1.0 - m, 1e-4) / max(p_hi - m, 1e-4))
            ks.append(max(k, 0.8))
            pv.append(m)
        return np.array(ks), np.array(pv), tm.resets

    k_raw, pv_raw, _ = run(alpha=0.0, cut=1e9)          # 不平滑
    k_iir, pv_iir, r_iir = run(args.alpha, 1e9)         # 只 IIR
    k_ok, pv_ok, r_ok = run(args.alpha, args.cut_thr)   # IIR + 切镜头检测
    if float(np.ptp(k_raw)) < 1e-9:
        print("  [注意] 本序列上 k 恒为常数（上界保护一直没触发），"
              "所以 k 的抖动列没有信息量，看支点那列。")

    def jitter(a):
        return float(np.abs(np.diff(a)).mean())

    print(f"\n{'方案':<22}{'k 逐帧抖动':>12}{'支点逐帧抖动':>14}{'切镜头判定':>12}")
    for lb, k, pv, r in [("不平滑", k_raw, pv_raw, 0),
                         (f"IIR a={args.alpha} 无检测", k_iir, pv_iir, r_iir),
                         (f"IIR a={args.alpha}+检测", k_ok, pv_ok, r_ok)]:
        print(f"  {lb:<20}{jitter(k):>12.5f}{jitter(pv):>14.5f}{r:>12}")

    # ---- 切镜头后收敛要几帧 ----
    print(f"\n切镜头后支点收敛到新场景 2% 以内要几帧：")
    for lb, pv in [("不平滑", pv_raw), ("IIR 无检测", pv_iir), ("IIR+检测", pv_ok)]:
        lags = []
        for c in range(1, args.clips):
            i0 = c * args.frames
            j = next((j for j in range(i0, min(i0 + 40, len(pv)))
                      if abs(pv[j] - pv_raw[j]) < 0.02 * max(abs(pv_raw[j]), 1e-6)), None)
            lags.append("未收敛" if j is None else str(j - i0 + 1))
        print(f"  {lb:<12} {lags}")

    print(f"\n⚠ 合成序列只能验到这：**匀速平移 + 硬切**。"
          f"\n  真实手持的抖动、传感器噪声、编码抖动都不在内；"
          f"\n  「增益抖多少算看得见」也答不了 —— **上板才算**。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
