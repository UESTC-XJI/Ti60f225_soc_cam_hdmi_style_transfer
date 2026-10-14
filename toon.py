"""赛璐璐平涂 + 漫画线条：补上 Gram 学不到的东西。

    python -m tools.toon --ckpt runs/final/D_ukiyoe --input data/content --limit 3

**为什么需要这一步**：Gram 矩阵是颜色/纹理的统计量，它丢掉了空间结构。
米山舞画风的核心是「有力线条 + 赛璐璐平涂」，这两样 Gram 都抓不住——
实测训出来的是一层斜向排线纹理，不是线条。

**分工原则（这一路试错得出的）**：

    网络负责它擅长的：调色板、明暗关系、大色块的取舍
    固定逻辑负责剩下的：平坦（量化）、线条（内容边缘）、粗细（多尺度）

把"平坦"和"线条"塞进网络里学，试过两次都失败——它们本来就不是网络该做的。

**完整管线**：

    网络输出 → 提饱和 → 提对比 → 模糊 → 量化 → 中值去斑 → 叠多尺度线条
    内容帧 ─────────────────→ 多尺度边缘 ────────────────────┘

⚠ 本文件是**效果原型**，只验证"这样做好不好看"，不追求硬件可实现性。
落到 RTL 前要单独评估：行缓冲怎么复用、多尺度边缘怎么流水。

**踩过的坑（都留了代码注释）**：
  1. 直接在原图上做 Sobel → 毛发/草地纹理全成了线，糊成一片
  2. 模糊放在"训练目标"里 → 连对比和结构一起抹掉，输出像蒙了层灰
  3. 量化不先去斑 → 排线残渣被切成碎色块
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from train.data import (  # noqa: E402
    DATA,
    blend_chroma,
    color_stats,
    load_style,
    match_luma,
    merge_luma,
    to_batch,
    to_luma,
    transfer_matrix,
)
from train.stylize import fit, load_net  # noqa: E402
from train.train import pick_device  # noqa: E402

LUMA = np.array([0.299, 0.587, 0.114], dtype=np.float32)
SOBEL_X = np.array([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]], dtype=np.float32)
SOBEL_Y = SOBEL_X.T


# ─────────────────────────────────────────────────────────────
# 基础算子（纯 numpy，不引入 scipy）
# ─────────────────────────────────────────────────────────────
def _conv3(a: np.ndarray, k: np.ndarray) -> np.ndarray:
    """3×3 卷积，边缘复制填充（不要用 np.roll——它会绕回，在边界造假边缘）。"""
    p = np.pad(a, 1, mode="edge")
    h, w = a.shape
    out = np.zeros_like(a)
    for dy in range(3):
        for dx in range(3):
            if k[dy, dx]:
                out += k[dy, dx] * p[dy:dy + h, dx:dx + w]
    return out


def _gaussian_kernel(sigma: float) -> np.ndarray:
    r = max(1, int(round(3 * sigma)))
    x = np.arange(-r, r + 1, dtype=np.float32)
    k = np.exp(-(x ** 2) / (2 * sigma ** 2))
    return k / k.sum()


def blur(rgb: np.ndarray, sigma: float) -> np.ndarray:
    """可分离高斯模糊。"""
    if sigma <= 0:
        return rgb
    k = _gaussian_kernel(sigma)
    r = len(k) // 2
    out = rgb.astype(np.float32)
    for axis in (0, 1):
        out = np.apply_along_axis(
            lambda m: np.convolve(np.pad(m, r, mode="edge"), k, mode="valid"),
            axis, out)
    return out.astype(np.float32)


def median3(rgb: np.ndarray) -> np.ndarray:
    """3×3 中值滤波。逐通道做。

    这是**去排线残渣的关键**：量化之后还散落着一些孤立的碎色块，
    中值能把它们吃掉，而**不会像模糊那样把边界一起磨圆**。
    硬件上是 9 个数排中值（~19 个比较器），比一次乘法还便宜。
    """
    h, w = rgb.shape[:2]
    p = np.pad(rgb, ((1, 1), (1, 1), (0, 0)), mode="edge")
    stack = np.stack([p[dy:dy + h, dx:dx + w] for dy in range(3) for dx in range(3)])
    return np.median(stack, axis=0).astype(np.float32)


def saturate(rgb: np.ndarray, factor: float) -> np.ndarray:
    """饱和度：`灰度 + (原色 - 灰度) × factor`。纯逐像素。

    放在量化**之前**：先提饱和再切色块，切出来的色才够艳。
    """
    if factor == 1.0:
        return rgb
    g = (rgb @ LUMA)[..., None]
    return np.clip(g + (rgb - g) * factor, 0.0, 1.0)


class TemporalStat:
    """**逐帧统计量的时间平滑**：一阶 IIR + 场景切换检测。所有逐帧统计量共用。

    ## 为什么必须有它

    只要流水线开始用**逐帧统计量**（`match_luma` 的亮度对齐、`auto_contrast_params`
    的自适应对比度），就直接继承两个问题：

    1. **帧间闪烁**——统计量逐帧抖动 ⇒ 增益逐帧抖动 ⇒ 画面亮度/对比度在抖。
    2. **场景切换**——IIR 平滑之后，切镜头时统计量要**很多帧**才追上新场景，
       这期间增益是错的（画面忽明忽暗）。α=0.9 时时间常数 ≈ 10 帧，
       **720p30 下约 0.33 秒**——肉眼很明显。

    所以两个机制缺一不可：**IIR 抑抖动 + 突变检测在切镜头时把 IIR 重置**。

        if |x_t − s_{t−1}| > cut_thr · scale:   s_t = x_t          （判为切镜头，直接跳）
        else:                                   s_t = α·s_{t−1} + (1−α)·x_t

    `cut_thr` 用 `scale` 归一，这样它不依赖输入的绝对量级
    （和 `train/data.py::match_luma` 同一个教训：阈值必须相对量级定）。

    ## 硬件代价

    **每个统计量一个寄存器**（存 `s_{t−1}`），外加一个比较器和一个乘加。
    没有行缓冲、没有 BRAM。

    ## ⚠ 原型里验不了"不闪"

    这里的单张图和视频无关——**下面的自检只验数学**（阶跃响应、抖动抑制、
    切镜头重置），**验不了上板的实际观感**。上板前不要把这条标成"已解决"。
    """

    # `cut_thr=0.10`（2026-09-29 从 0.25 改下来）：0.25 会**漏检**
    # —— 实测折叠网络的切镜头跳变是 0.244，刚好卡在阈值下面。
    # 0.10 的余量：场景内逐帧抖动实测 0.0079，阈值是它的 **13 倍**，不会误触发。
    def __init__(self, alpha: float = 0.9, cut_thr: float = 0.10, scale: float = 1.0):
        self.alpha = float(alpha)
        self.cut_thr = float(cut_thr)
        self.scale = float(scale)
        self.value: float | None = None
        self.resets = 0          # 判为切镜头的次数（上板可观测）

    def __call__(self, x: float) -> float:
        x = float(x)
        if self.value is None or abs(x - self.value) > self.cut_thr * self.scale:
            if self.value is not None:
                self.resets += 1
            self.value = x
        else:
            self.value = self.alpha * self.value + (1.0 - self.alpha) * x
        return self.value


def auto_contrast_params(rgb: np.ndarray, con: float, *, mode: str = "pivot",
                         k_scale: float = 1.3, k_floor: float = 0.8
                         ) -> tuple[float, float]:
    """从**逐帧 Y 统计量**算出"不会把内容推出 [0,1]"的对比度系数与支点。

    返回 `(k, pivot)`，用法：`contrast(rgb, k, pivot)`。

    ## 为什么需要它

    `--con` 是**固定系数 + 固定支点 0.5**，对亮且平的目标是错的。实测
    `000000076261`（雾霭天空）：Y 均值 **0.753**、标准差只有 **0.087**，
    `con 1.5` 把天空 `[0.781, 0.846]` 推到 `[0.921, 1.020]`，
    **62% 的像素被硬裁在 1.0**，渐变被削平成一块死白。

    ⚠ **试过用「软肩」修，无效**（见 `contrast()` 的 docstring）——
    数据在被推出量程之后才压缩，救不回来。**只能在推之前不推出去。**

    ## 两个旋钮

    **① `mode="pivot"`：支点从固定 0.5 改成图像自己的 Y 均值。**
    就是上面那张图：支点 0.5 离内容（0.75）太远，一放大就顶出去。
    支到均值上，`k=1.5` 时天空落在 `[0.794, 0.899]`——**不越界，渐变完整**。

    **② 上界保护**：`k ≤ (1 − pivot) / (p_hi − pivot)`，`p_hi` 用 `μ + k_scale·σ`
    代理高百分位（**不开直方图**，纯均值/方差即可，FPGA 上是两个累加器）。
    只有在"内容真的会顶出去"时才把 `k` 压下来；正常图不被动。

    ## 硬件代价：≈ 0（但有一个真代价不在资源上）

    复用 `train/data.py::match_luma` **已经在算**的逐帧累加器（求和、平方和），
    **不新增任何存储**——只是在同一组数上换个公式。

    ⚠ **真代价是逐帧统计自带的 1 帧延迟 + 帧间闪烁**（`match_luma` 的注释里
    已经标过这条风险）。硬件上必须配**一阶 IIR 时间平滑**：

        stat_t = α·stat_{t-1} + (1−α)·stat_t      α ≈ 0.9

    每个统计量只多一个寄存器。**原型是逐图的，跑不出闪烁**——
    这段的验证只能上板做，别在这边说"已解决"。
    """
    g = rgb @ LUMA
    mu = float(g.mean())
    sd = float(g.std())
    pivot = mu if mode == "pivot" else 0.5
    p_hi = mu + k_scale * sd
    room = max(1.0 - pivot, 1e-4)
    k = min(float(con), room / max(p_hi - pivot, 1e-4))
    return max(k, float(k_floor)), pivot


def contrast(rgb: np.ndarray, factor: float, pivot: float = 0.5) -> np.ndarray:
    """对比度：绕 pivot 拉开放缩。纯逐像素，一个乘一个减。

    赛璐璐的观感很依赖**明暗拉开**——不提对比的话色块会糊成一团灰。

    ## ⚠ 试过「软肩」把两端的硬 `clip` 换掉——**实测有害，已撤**（2026-09-29）

    起因是 `000000076261`（雾霭天空）被压成一块死白，我判断是硬 `clip` 削平的，
    加了个两端渐近的软肩。**控制实验（同参数、只差软肩）把它否掉了**
    （天空 Y 标准差，越大=渐变保得越好）：

    | | 天空 std | 钉在 1.0 的像素 |
    |---|---|---|
    | con 1.5 + 硬裁（原样） | 0.0133 | 62.3% |
    | con 1.5 + 软肩 0.75 | **0.0115** ❌ | **71.0%** ❌ |
    | **con 1.0（降增益）** | **0.0503** ✅ | **0.0%** ✅ |

    **为什么软肩反而更糟**：增益后天空已经是 `[0.921, 1.020]`——信息**已经被推出量程了**，
    软肩只能把这一段再压扁一次。**已经出界的数据救不回来，只能在推之前不推出去。**
    真正有效的是**按图降增益**（con 1.0 时 std 3.8 倍、零裁切）。

    ⇒ 要修这类图得做**逐帧自适应增益**（见 `train/data.py::match_luma` 的累加器，
    代价 ≈ 0，但要接受 1 帧延迟与帧间闪烁），**不是改端点形状**。
    详情记在 `FPGA-IMPL.md` §3.7-ter。

    ⚠ 我当初报"软肩让天空标准差好 4 倍"的那个数是**假的**——对照组当时还差了
    一层纸纹算子（参考组没开、实验组开了）。**只差一个变量的对照才是对照。**
    """
    if factor == 1.0:
        return rgb
    return np.clip((rgb - pivot) * factor + pivot, 0.0, 1.0)


def _integral(x: np.ndarray) -> np.ndarray:
    """积分图（前缀和），形状 (H+1, W+1, ...)，用于 O(1) 取任意矩形和。

    支持 2D（单通道）和 3D（RGB）——只在头两维补零。
    """
    c = np.cumsum(np.cumsum(x, 0), 1)
    pad = ((1, 0), (1, 0)) + ((0, 0),) * (x.ndim - 2)
    return np.pad(c, pad)


def _quad_sum(I: np.ndarray, h: int, w: int, r: int, qy: int, qx: int):
    """取以 (y,x) 为角、朝 (qy,qx) 方向张开 r 的象限矩形和，以及该矩形的像素数。

    qy=-1 → 行取 [y−r, y]；qy=+1 → 行取 [y, y+r]。x 同理。
    四个象限**互相重叠**（都含中心行/列），这是 Kuwahara 原始定义。
    """
    ys, xs = np.arange(h), np.arange(w)
    y0 = np.clip(ys + (-r if qy < 0 else 0), 0, h)
    y1 = np.clip(ys + (0 if qy < 0 else r) + 1, 0, h)
    x0 = np.clip(xs + (-r if qx < 0 else 0), 0, w)
    x1 = np.clip(xs + (0 if qx < 0 else r) + 1, 0, w)
    s = I[y1][:, x1] - I[y0][:, x1] - I[y1][:, x0] + I[y0][:, x0]
    n = (y1 - y0)[:, None] * (x1 - x0)[None, :]
    return s, n.astype(np.float32)


PAPER_WHITE = np.array([248, 244, 232], np.float32) / 255.0   # 暖纸白
COOL_PIGMENT = np.array([28, 42, 66], np.float32) / 255.0     # 冷颜料（暗部）


OCT_POW = -0.375
"""八度加权指数，**实测标定**出来的，不是推的（见 `_paper_field`）。"""


def _paper_field(h: int, w: int, *, tile: int = 0, seed: int = 0,
                 octaves: tuple[int, ...] = (1, 2, 4, 8, 16)) -> np.ndarray:
    """**1/f（粉红）频谱的纸纹场**，零均值、单位标准差。

    白噪声做盒滤波得到的是**带限白噪声**，叠在平坦区上读起来就是"砂纸/噪点"。
    真纸的凹凸是**多尺度**的：大起伏套小纤维，功率谱约 **1/f**。
    做法：把 5 个**带通**八度 `box(o) − box(2o)`（中心频率 `f ≈ 1/o`）
    各自归一到单位标准差后按 `o**OCT_POW` 加权叠加，最后再统一归一。

    ## ⚠ 两个都是实测踩出来的，别按直觉改

    **① 每个八度必须是带通，不能只用一个低通。**
    5 个低通按 `√o` 加权叠出来的径向功率谱斜率是 **−2.6**——最大那个八度（o=16）
    把频谱压得比 1/f 陡得多，出来的还是"大块斑驳"。

    **② 指数不是理论值 `√o`，是标定出来的 `−0.375`。**
    按 `P(f) ∝ 1/f ⇒ 幅度 ∝ √o` 推应该是 `+0.5`，**实测方向是反的**：
    各八度归一后自然形态已经很陡（`o⁰` 时斜率 **−1.77**），要**压**高频
    才拉回 1/f。用负指数不是笔误。

    标定表（256²、径向功率谱 log-log 斜率，目标 **−1.0**）：

    | `OCT_POW` | −0.50 | −0.375 | −0.25 | 0 | +0.50 |
    |---|---|---|---|---|---|
    | 斜率 | −0.72 | **−0.99** ✅ | −1.26 | −1.77 | −2.63 |

    三个种子实测 −0.97 / −0.98 / −0.99，稳定。

    `tile>0` 时只在 `tile²` 的块里生成再平铺 —— **FPGA 上就是这么做的**：
    LFSR 生成一次存 ROM，按坐标取模。默认 0 = 整帧生成。

    ⚠ 硬件代价：五个八度 = 十个盒滤波、最大半径 32。**别在每帧现算**——
    按上面那样做成 ROM 一次性生成，运行时只查表（这也是 `tile` 存在的理由）。
    """
    rng = np.random.default_rng(seed)
    th, tw = (int(tile), int(tile)) if tile and tile > 0 else (h, w)
    acc = np.zeros((th, tw), np.float32)
    for o in octaves:
        n = rng.random((th, tw)).astype(np.float32)
        band = _box(n, o) - _box(n, 2 * o)      # 带通：中心频率 ≈ 1/o
        acc += float(o) ** OCT_POW * _norm(band)
    acc = _norm(acc)
    if (th, tw) != (h, w):
        reps = (int(np.ceil(h / th)), int(np.ceil(w / tw)))
        acc = np.tile(acc, reps)[:h, :w]
    return acc


def wc_finish(rgb: np.ndarray, *, granule: float = 0.0, tooth: float = 0.0,
              humidity: float = 0.0, humidity_scale: int = 24, sigma: float = 3.5,
              deposit: float = 0.0, deposit_thr: float = 0.05,
              sat_mid: float = 1.0, paper_white: float = 0.0,
              shadow_tint: float = 0.0, seed: int = 0,
              model: str = "mul", tile: int = 0,
              norm_const: float = 0.0,
              verbose: bool = False) -> np.ndarray:
    """**水彩收尾**：颗粒沉淀 + 纸齿 + 湿度晕染 + 沉积边 + 色彩修正。

    全部是**确定性滤波**，无网络、无学习参数。逐像素/小窗，**FPGA 上最便宜的一类**。

    ## 五个算子

    **① 颗粒沉淀 `granule`** / **② 纸齿 `tooth`**：共用一个 **1/f 纸纹场**
    （见 `_paper_field`），**乘性**施加（`out *= 1 − w·tex`）——
    颜料往纸的低洼沉，**只会压暗，不会提亮**。权重 `w` 见下。

    **③ 湿度晕染 `humidity`**：一张**低频湿度图**（不是全图均匀模糊）控制扩散强度
    → 边界干湿不均。均匀高斯只会得到模糊照片，糊不出手绘感。

    **④ 沉积边 `deposit`**：`|DoG|` 超阈值处**乘暗** —— 颜料在色块收口处堆积出深色边。

    > ⚠ **`deposit_thr` 是最容易搞砸的一项，默认已从 0.012 改到 `0.05`。**
    > 0.012（≈3/255）听起来"很小很安全"，实测却触发 **34~45% 的像素**——
    > 那已经不是"描色块收口"，是**全图随机压暗**，用户看到的"黑色噪点"就是它。
    > 定阈值**必须先量 `|DoG|` 的分布**（`verbose=True` 会打印），别凭量级猜。
    > 实测分布（定稿档、5 张样张）：`p50 0.007~0.009`、`p90 0.033~0.055`、
    > `p95 0.044~0.078`、`p99 0.068~0.129`、`max 0.20~0.27`。
    > 落在 **p95~p99（0.05~0.10）** 才是"边缘"。


    **⑤ 色彩修正**：中调提饱和、高光透纸白、暗部偏冷颜料（而不是压成中性灰）。

    ## ⚠ 2026-09-29 晚：颗粒模型整个换掉了（这是 ① ② 的关键）

    老模型是**加性零均值白噪声**，权重 `(1−g)^1.5`（**暗部最重**）。实测后果两条：

    1. 加性 ⇒ 在暗部，±0.02 的绝对扰动占亮度 20%，**暗部炸成斑驳**；
       在亮部又完全看不见。**同一个幅度不可能同时"亮部可见"和"暗部不脏"**。
    2. 白噪声频谱 ⇒ 在平坦区读起来是**砂纸/噪点**，不是纸。

    新模型三条改动，正好一一对应：

    | 改动 | 为什么 |
    |---|---|
    | **加性 → 乘性**（只压暗） | 扰动随局部亮度缩放 ⇒ 暗部自然是小的，**暗部不再炸** |
    | **白噪声 → 1/f** | 纸是多尺度的；1/f 才读得出"纸的凹凸"而不是"传感器噪点" |
    | **门控 `(1−g)^1.5` → `4g(1−g)`** | 可见度 ∝ **颜料厚度 × 可用光**。纯黑无光可调、纯白无颜料可沉，**中间调最重**（抛物线）|

    另外两点如实记：
    - `tooth` 原来的高光权重写反了——注释说"留白处透出纸的凹凸"，
      代码却是 `(1−hi)`（**暗部最重**）。已改成高光侧。
    - `deposit` / 颗粒都做**均值归一**（`mod /= mod.mean()`）：
      原来 `deposit=0.20` 会把全图**平均压暗 5.2~7.9/255**，那正是"发霉/脏"
      的主因。归一后只留**边缘处的相对压暗**，不带整体变暗。

    ## 幅度语义变了（调参时注意）

    加性版的 `granule=0.02` 是"±0.02 绝对值"；乘性版的 `granule=0.02` 是
    "局部亮度的 2%"。两者**不可直接换算**，老参数不能照搬。

    `model="add"` 保留老模型，**只为做对照**（`runs/view_big/AB/`），不要交付。
    """
    if not any((granule, tooth, humidity, deposit)) and sat_mid == 1.0 \
            and paper_white == 0 and shadow_tint == 0:
        return rgb
    out = rgb.astype(np.float32).copy()
    g = out @ LUMA

    # 顺序：沉积边在颗粒之前。理由是 DoG 会把颗粒认成"边"，**先加颗粒会污染判据**。
    # ⚠ 2026-09-29 更正：这条当初被写成了"硬性要求/顺序反了满屏黑点"，
    # **实测站不住**——在同参数下把沉积边换到颗粒之后（并重算 g），
    # 两版平均差只有 4.6~5.8/255，肉眼是同一档颗粒，没有"黑点"。
    # 真正让画面发霉的是**颗粒幅度本身太大**，不是顺序。保留这个顺序是防御性的
    # （判据干净总没坏处），但别把它当成本操作符的关键。对照图 `runs/view_big/AB/*__order.png`。
    # ⚠ 另记一条更重要的教训：`__stylized` 是**网络原始输出**，后处理结果在 `__flat`。
    # 我当初拿 `__stylized` 做对照，四张图逐字节相同，却据此下了"顺序修好了"的结论。

    # ③ 湿度晕染
    if humidity > 0:
        rng = np.random.default_rng(seed + 7)
        h = _norm(_box(rng.random(g.shape).astype(np.float32), humidity_scale))
        wet = np.clip(humidity * (0.5 + 0.5 * np.tanh(h)), 0.0, 1.0)  # 干湿不均
        out = out * (1.0 - wet[..., None]) + _box(out, int(max(1, round(sigma)))) * wet[..., None]

    # ④ 沉积边：|DoG| 超阈处乘暗（**在颗粒之前**，免得 DoG 把颗粒认成边）
    if deposit > 0:
        dog = np.abs(_box(g, 1) - _box(g, 3))
        if verbose:
            q = (50, 80, 90, 95, 97, 99)
            print("  [沉积边] |DoG| 分布 " +
                  " ".join(f"p{v}={np.percentile(dog, v):.4f}" for v in q) +
                  f" max={dog.max():.4f}")
            print(f"           当前阈值 {deposit_thr:g} → 触发像素 "
                  f"{(dog > deposit_thr).mean() * 100:.1f}%"
                  f"   （想要「只描色块收口」就该落在几个百分点；"
                  f"三四十个百分点说明阈值太低、已经变成全图压暗了）")
        m = np.clip((dog - deposit_thr) / max(deposit_thr, 1e-9), 0.0, 1.0)
        # **均值归一**：只留边缘处的相对压暗。不归一时它会把全图平均压暗
        # 5.2~7.9/255（deposit=0.20@定稿档实测），画面"发霉"的主因就是这条。
        dmod = 1.0 - deposit * m
        out = out * (dmod / max(float(dmod.mean()), 1e-6))[..., None]

    # ① 颗粒沉淀 + ② 纸齿（**最后加重**，别让任何算子再去"检测"它）
    if granule > 0 or tooth > 0:
        rng = np.random.default_rng(seed)
        if model == "add":
            # —— 老模型：加性零均值白噪声，暗部最重。**只为对照保留**（见 docstring）——
            n = rng.random(g.shape).astype(np.float32)
            density = np.clip(1.0 - g, 0.0, 1.0) ** 1.5
            hi = np.clip((g - 0.72) / 0.28, 0.0, 1.0)
            out = out + (granule * density * _norm(_box(n, 3)))[..., None] \
                      + (tooth * (1.0 - hi) * _norm(_box(n, 1)))[..., None]
        else:
            # —— 新模型：1/f 纸纹场 × 中间调门控 × **乘性只压暗** ——
            field = _paper_field(*g.shape, tile=tile, seed=seed)
            tex = 0.5 + 0.5 * np.tanh(field * 0.5)        # [0,1]，1 = 纸的低洼（积颜料）
            # 可见度 ∝ 颜料厚度 × 可用光：纯黑无光可调、纯白无颜料可沉 ⇒ 中间调最重
            mid = np.clip(4.0 * g * (1.0 - g), 0.0, 1.0)
            hi = np.clip((g - 0.72) / 0.28, 0.0, 1.0)     # 纸齿偏高光（留白处透出凹凸）
            w = granule * mid + tooth * (0.35 + 0.65 * hi)
            mod = 1.0 - w * tex
            # 均值归一：不归一时纸纹会把整幅图压暗（那是"发霉"的主因）。
            # ⚠ 默认除的是**本帧自己的**均值 `mod.mean()` —— 它随内容逐帧变，
            # 是一个**全局增益**，而全局增益的变化在静止像素上也是可见的抖动。
            # `norm_const > 0` 时改用固定常数，用来做「逐帧均值是不是抖动来源」的对照实验。
            den = float(mod.mean()) if norm_const <= 0 else float(norm_const)
            if verbose:
                # 逐帧把它打出来：这个数**随内容变**，变化量就是全图被施加的增益抖动
                print(f"    [纸纹] mod 均值 {float(mod.mean()):.5f}"
                      f"  w 均值 {float(w.mean()):.5f}  归一化用 {den:.5f}")
            out = out * (mod / max(den, 1e-6))[..., None]

    # ⑤ 色彩修正
    if sat_mid != 1.0:
        gray = (out @ LUMA)[..., None]
        mid = 1.0 - np.abs(2.0 * g - 1.0)                 # 中间调权重
        boost = 1.0 + (sat_mid - 1.0) * mid
        out = gray + (out - gray) * boost[..., None]
    if paper_white > 0:
        hi = np.clip((g - 0.667) / 0.333, 0.0, 1.0)       # L>170/255
        w = (paper_white * hi)[..., None]
        out = out * (1.0 - w) + PAPER_WHITE * w
    if shadow_tint > 0:
        lo = np.clip((0.25 - g) / 0.25, 0.0, 1.0)
        w = (shadow_tint * lo)[..., None]
        out = out * (1.0 - w) + COOL_PIGMENT * w
    return np.clip(out, 0.0, 1.0)


def kuwahara(rgb: np.ndarray, r: int = 3, soft: float = 0.0) -> np.ndarray:
    """**Kuwahara 滤波** —— "粘稠感"的本源算子。

    ## 原理：它字面上就是在模拟粘稠液体的行为

    每个像素看它的 4 个象限（左上/右上/左下/右下，互相重叠），各算均值与方差，
    **输出方差最小那个象限的均值**——"颜料流到最均匀的方向摊开"。

    两个后果正好就是粘稠感：

    1. **区域内摊平**：平坦处四个象限方差都小，取哪个都差不多 → 颜色均匀
    2. **边界被圆化而不糊掉**：跨边的象限方差大、不会被选中，所以边缘不糊；
       但边缘**走向**会被重新组织成圆钝的块状 —— 这就是"稠"的观感

    第 2 点是它和普通模糊的本质区别：**模糊是抹掉边界，Kuwahara 是重组边界。**

    ## soft 参数

    硬 argmin 在 r 大时会出现方块状伪影（象限边界可见）。`soft>0` 时改成
    按 `exp(−v / soft)` 加权平均——退化成"平的地方融成一片、锐的地方仍挑最平的"，
    观感更连续。0 = 原始硬选择。

    ## 硬件代价

    4 个象限 × (均值 + 方差) 全走积分图（前缀和），均值/方差只需 2 张积分图
    （Σ 和 Σ²）+ 1 张 RGB 积分图。**比导向滤波的 6 个盒滤波还便宜**，
    且同样只有行缓冲、无帧缓存。见 `FPGA-IMPL.md` §3.7-bis。
    """
    if r <= 0:
        return rgb
    h, w = rgb.shape[:2]
    g = rgb @ LUMA
    Ig, Ig2, Irgb = _integral(g), _integral(g * g), _integral(rgb)

    acc = np.zeros_like(rgb)
    wsum = np.zeros((h, w, 1), np.float32)
    vmin = None
    for qy in (-1, 1):
        for qx in (-1, 1):
            sg, n = _quad_sum(Ig, h, w, r, qy, qx)
            sg2, _ = _quad_sum(Ig2, h, w, r, qy, qx)
            srgb, _ = _quad_sum(Irgb, h, w, r, qy, qx)
            m = sg / n
            var = np.maximum(sg2 / n - m * m, 0.0)          # 亮度方差：判"哪个方向最平"
            mrgb = srgb / n[..., None]
            if soft > 0:
                wt = np.exp(-var[..., None] / soft)
                acc += mrgb * wt
                wsum += wt
            else:
                take = var < vmin if vmin is not None else np.ones_like(var, bool)
                vmin = np.where(take, var, vmin) if vmin is not None else var
                acc = np.where(take[..., None], mrgb, acc)
    return np.clip(acc / wsum if soft > 0 else acc, 0.0, 1.0)


def _bilinear(img: np.ndarray, X: np.ndarray, Y: np.ndarray) -> np.ndarray:
    """按浮点坐标 (X,Y) 双线性采样 (H,W,C)。边界用 clamp。"""
    h, w = img.shape[:2]
    x0 = np.floor(X).astype(np.int32)
    y0 = np.floor(Y).astype(np.int32)
    fx, fy = (X - x0)[..., None], (Y - y0)[..., None]
    x0c, x1c = np.clip(x0, 0, w - 1), np.clip(x0 + 1, 0, w - 1)
    y0c, y1c = np.clip(y0, 0, h - 1), np.clip(y0 + 1, 0, h - 1)
    return (img[y0c, x0c] * (1 - fx) * (1 - fy) + img[y0c, x1c] * fx * (1 - fy)
            + img[y1c, x0c] * (1 - fx) * fy + img[y1c, x1c] * fx * fy)


def _down_box(img: np.ndarray, d: int) -> np.ndarray:
    """d×d 盒平均降采样（尺寸不是 d 的整数倍时裁掉边缘）。"""
    h, w = (img.shape[0] // d) * d, (img.shape[1] // d) * d
    x = img[:h, :w]
    if x.ndim == 3:
        return x.reshape(h // d, d, w // d, d, x.shape[2]).mean((1, 3))
    return x.reshape(h // d, d, w // d, d).mean((1, 3))


def _up_nn(img: np.ndarray, hw: tuple[int, int]) -> np.ndarray:
    """最近邻放大到 (h,w)。**故意用最近邻而不是双线性**——
    双线性会把 Kuwahara 好不容易切出来的**平坦块**重新插值成渐变，
    那正是它和普通模糊的区别所在。"""
    h, w = hw
    yi = (np.arange(h) * img.shape[0] // h).clip(0, img.shape[0] - 1)
    xi = (np.arange(w) * img.shape[1] // w).clip(0, img.shape[1] - 1)
    return img[yi][:, xi]


def kuwahara_aniso(rgb: np.ndarray, r: int = 4, sharp: float = 6.0,
                   tensor_r: int = 0, soft: float = 0.0,
                   coh: float = 1e-2, angles: int = 0) -> np.ndarray:
    """**各向异性 Kuwahara**（Kyprianidis et al. 2009 的简化实现）。

    ## 和各向同性的区别 —— 也是"笔触"的来源

    各向同性版对每个像素取 4 个**正方形**象限，谁方差小用谁。
    问题是正方形没有方向，所以出来的是"圆钝的块"——读起来只是**糊**。

    各向异性版多一步：先用**结构张量**估出该像素的**局部走向** θ
    （边缘朝哪边延伸），然后把采样核**沿 θ 拉长、垂直方向压扁**，
    再在四个象限里选最平的。

    结果是颜料沿结构方向被**抹开**——这就是笔触。稠颜料被人看见，
    不是因为它糊，是因为**它被抹开时留下的方向**；各向同性滤波天生没有方向。

    ## 三步

    1. **结构张量** `J = G_ρ * (∇g ⊗ ∇g)`，`_box` 当高斯用（够）
    2. **特征分解**给出主方向 θ 与各向异性度 `A = (λ₁−λ₂)/(λ₁+λ₂) ∈ [0,1]`
       —— A≈0 是平坦/杂乱处（核保持圆形），A≈1 是强边（核拉得最长）
    3. **核按 `s = 1 + A·sharp` 沿 θ 拉长、按 `1/s` 压扁**（保面积），
       双线性采样后按象限算均值/方差，选最平的

    ## 硬件代价

    结构张量 = 2 次 Sobel + 3 个盒滤波（Jxx/Jxy/Jyy 各一个）—— 和导向滤波同量级。
    采样是**固定点的双线性 gather**，`4×(r+1)²` 个点，全部并行、无帧缓存。
    比各向同性版贵，但仍在同一量级。见 `FPGA-IMPL.md` §3.7-bis。
    """
    if r <= 0:
        return rgb
    h, w = rgb.shape[:2]
    tr = tensor_r or max(2, r)

    # ---- ① 结构张量 ----
    g = rgb @ LUMA
    gx = _conv3(g, SOBEL_X)
    gy = _conv3(g, SOBEL_Y)
    Jxx = _box(gx * gx, tr)
    Jxy = _box(gx * gy, tr)
    Jyy = _box(gy * gy, tr)

    # ---- ② 特征分解 ----
    tmp = np.sqrt(np.maximum((Jxx - Jyy) ** 2 + 4.0 * Jxy * Jxy, 0.0))
    theta = 0.5 * np.arctan2(2.0 * Jxy, Jxx - Jyy)      # 主方向
    l1 = 0.5 * (Jxx + Jyy + tmp)
    l2 = 0.5 * (Jxx + Jyy - tmp)
    # ⚠ **必须用能量给各向异性加权**。在平坦区/暗部，λ₁ 和 λ₂ 都趋近 0，
    # 此时 `(λ₁−λ₂)/(λ₁+λ₂)` 是**两个噪声相除**（0/0），θ 完全随机——
    # 核会被朝随机方向拉伸，把暗部的色度搅出方格伪影（实测踩过）。
    # 乘上 `λ₁/(λ₁+coh)` 后，低能量处的 aniso → 0，核退化成圆形，伪影消失。
    coherence = (l1 - l2) / (l1 + l2 + 1e-8)            # 0=杂/平，1=强边
    aniso = coherence * (l1 / (l1 + coh))               # 按结构能量门控

    s = 1.0 + aniso * sharp                             # 沿 θ 的拉伸比
    if angles > 0:
        # **方向离散化**：把 θ 量化到 `angles` 档。
        # 这是"能不能落硬件"的关键——浮点任意角度的采样必须做双线性（4 抽头），
        # 离散成整数档之后偏移量可以查表、退化成单点采样（1 抽头），
        # 采样带宽直接降 4 倍。代价是笔触方向有台阶。
        step = np.pi / angles
        theta = np.round(theta / step) * step
    ct, st = np.cos(theta), np.sin(theta)
    ys, xs = np.meshgrid(np.arange(h, dtype=np.float32),
                         np.arange(w, dtype=np.float32), indexing="ij")

    # ---- ③ 各向异性采样 + 象限选择 ----
    acc = np.zeros_like(rgb)
    wsum = np.zeros((h, w, 1), np.float32)
    vmin = None
    for qy in (-1, 1):
        for qx in (-1, 1):
            sq = np.zeros_like(rgb)
            sq2 = np.zeros((h, w, 1), np.float32)
            cnt = 0
            for i in range(r + 1):
                for j in range(r + 1):
                    du, dv = float(qx * i), float(qy * j)
                    # 在核空间旋转到 θ、沿 θ 拉伸 s、垂直压 1/s（保面积）
                    a = ct * du + st * dv            # 沿 θ 分量
                    b = -st * du + ct * dv           # 垂直分量
                    ox = ct * (a * s) - st * (b / s)
                    oy = st * (a * s) + ct * (b / s)
                    if angles > 0:
                        # 离散方向 → 整数偏移 → 单点采样（硬件上就是查表 + 寻址）
                        v = rgb[(ys + np.round(oy)).astype(np.int32).clip(0, h - 1),
                                (xs + np.round(ox)).astype(np.int32).clip(0, w - 1)]
                    else:
                        v = _bilinear(rgb, xs + ox, ys + oy)
                    sq += v
                    sq2 += (v @ LUMA)[..., None] ** 2
                    cnt += 1
            m = sq / cnt
            v = np.maximum(sq2 / cnt - (m @ LUMA)[..., None] ** 2, 0.0)
            if soft > 0:
                wt = np.exp(-v / soft)
                acc += m * wt
                wsum += wt
            else:
                take = v < vmin if vmin is not None else np.ones_like(v, bool)
                vmin = np.where(take, v, vmin) if vmin is not None else v
                acc = np.where(take, m, acc)
    return np.clip(acc / wsum if soft > 0 else acc, 0.0, 1.0)


def structure_blend_grad(pre: np.ndarray, up: np.ndarray, r: int, thr: float) -> np.ndarray:
    """**结构感知混合（梯度版）** —— 按**局部对比度**判断"哪里是结构"。

        e = box(|∇g|, r)              ← 平滑后的梯度幅值
        w = e / (e + thr)             ← 低对比→0（保笔触），高对比→1（接回细节）

    ## 为什么方差版不够

    `var/(var+eps)` 分不清**结构**和**纹理**：绒毛、草叶的局部方差同样很高，
    于是整片绒毛都被判成"结构"、把笔触吃了——实测熊变回了照片。

    纹理和文字的区别不在方差，在**对比度**：文字是近黑压在红底上（梯度极高），
    绒毛是低对比的细密起伏（梯度中等）。所以用**梯度幅值**加权才对。
    """
    if r <= 0:
        return up
    g = pre @ LUMA
    gx = np.abs(np.diff(g, axis=1, prepend=g[:, :1]))
    gy = np.abs(np.diff(g, axis=0, prepend=g[:1, :]))
    e = _box(gx + gy, r)
    w = (e / (e + max(thr, 1e-9)))[..., None]
    return np.clip(up * (1.0 - w) + pre * w, 0.0, 1.0)


def structure_blend_step(pre: np.ndarray, up: np.ndarray, r: int, mid: float,
                         width: float = 0.6, verbose: bool = False) -> np.ndarray:
    """**陡峭软阈值版结构混合** —— 目的是把"细结构"和"纹理"真正分开。

        e = box(|∇Y|, r)                       ← 平滑后的梯度幅值（"有多强")
        w = smoothstep(mid·(1−width), mid·(1+width), e)
        out = up·(1−w) + pre·w

    ## 为什么前面的 `e/(e+thr)` 不行

    它**只渐进趋 0**：绒毛的 e≈0.5，thr 从 0.05 涨到 0.35，w 才从 0.91 降到 0.59
    —— 差得不够，实测三档看不出差别（`runs/view_big/eps_tradeoff/`）。

    用一个**窄过渡带的 smoothstep** 才能真分开：低于 `mid(1−width)` 的判为纹理
    （w→0，涂掉），高于 `mid(1+width)` 的判为结构（w→1，接回）。
    理想情况是文字的 e 落在带之上、绒毛的 e 落在带之下。

    ## ⚠ `r` 选大了会**反向**伤害稀疏细结构（2026-09-29）

    `e` 是窗口里的**平均**梯度，量的是"梯度**密度**"而不是"这里有没有边"。
    所以它对**密集**结构（铁笼、链网：单位面积里全是边）友好，
    对**稀疏细笔画**（招牌字、STOP 牌字、细轮廓）反而**吃亏**——
    梯度很强，但只占窗口很小一块，一平均就没了。

    实测（STOP 牌）：`r=6`（13x13）时文字区 `e` 中位数只有 **0.073**，
    低于阈值带下沿 0.080 ⇒ `w=0` ⇒ 文字被当成纹理、用 Kuwahara 的糊版，
    边缘呈波浪状。**这个判据一直是偏的**，只是当初是用密网/铁笼做的标定，
    那些结构恰好是它擅长的那一类，所以没暴露。

    降到 `r=2`：e 的 p99 0.261 → **0.337**、中位数 0.063 → 0.048
    （尾部抬起、中部下沉 = 稀疏强边和密集纹理真正分开了），
    文字恢复可读而笔触不变。**别只看均值判断据的好坏——要看尾部。**
    """
    if r <= 0:
        return up
    g = pre @ LUMA
    gx = np.abs(np.diff(g, axis=1, prepend=g[:, :1]))
    gy = np.abs(np.diff(g, axis=0, prepend=g[:1, :]))
    e = _box(gx + gy, r)
    lo, hi = mid * (1.0 - width), mid * (1.0 + width)
    if verbose:
        q = np.percentile(e, [10, 50, 90, 99])
        print(f"        [e 分布] p10 {q[0]:.3f}  p50 {q[1]:.3f}  p90 {q[2]:.3f}  "
              f"p99 {q[3]:.3f}   阈值带 [{lo:.3f}, {hi:.3f}]")
    t = np.clip((e - lo) / max(hi - lo, 1e-9), 0.0, 1.0)
    w = (t * t * (3.0 - 2.0 * t))[..., None]      # smoothstep
    return np.clip(up * (1.0 - w) + pre * w, 0.0, 1.0)


def structure_blend(pre: np.ndarray, up: np.ndarray, r: int, eps: float) -> np.ndarray:
    """**结构感知混合**：平坦处用 `up`（笔触），有结构处用 `pre`（原细节）。

        w = var_local / (var_local + eps)       ← 0 平坦，→1 强结构
        out = up·(1−w) + pre·w

    ## 为什么不用 `guided_filter` 做这件事

    `guided_filter` 效果一样（实测 STOP 牌的文字能接回来），但它要 **6 个盒滤波 × 3 通道**，
    全分辨率 r=6 时约 **260 KB** —— 比 Kuwahara 本身还贵，等于白省。

    这里只需要"哪里是结构"这一个判断，而判断只需要**引导图亮度的局部方差**：
    2 个盒滤波、**单通道**。r=6 时 32.5 KB，是前者的 1/8。

    `eps` 是"多强才算结构"的阈值：调大只接回强边（笔触保得更好），调小吃掉笔触。
    """
    if r <= 0:
        return up
    g = pre @ LUMA
    mg = _box(g, r)
    var = np.maximum(_box(g * g, r) - mg * mg, 0.0)
    w = (var / (var + max(eps, 1e-9)))[..., None]
    return np.clip(up * (1.0 - w) + pre * w, 0.0, 1.0)


def black_lift(rgb: np.ndarray, lift: float) -> np.ndarray:
    """**抬黑场**：把最暗处抬到 `lift`，模拟颜料透出纸白。

        out = lift + (1 − lift) · in

    `[0,1] → [lift, 1]`：黑场抬高、白场不动、中间调按比例上移。

    ## 为什么逐通道（而不是只抬亮度）

    逐通道朝白抬 = 暗部**同时又亮又淡** —— 因为每个通道都被拉向 1（白）。
    这正是水彩"薄涂"的物理：颜料稀薄处纸白透上来，颜色既浅又灰。
    若只抬亮度、保色度，暗部会变成"发亮的深色"，反而更假。

    ## 硬件代价

    一个乘加，逐像素，无行缓冲。和饱和/对比完全同量级。
    """
    if lift <= 0:
        return rgb
    return np.clip(lift + (1.0 - lift) * rgb, 0.0, 1.0)


def gradient_xy(rgb: np.ndarray, sigma: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """灰度梯度：返回 (幅值, gx, gy)。幅值已归一化到约 0~1。

    ⚠ **必须先模糊**：直接在原图上跑 Sobel 会把毛发、草地、布料纹理
    全当成线（实测踩过）。真实的漫画线条只勾**轮廓和主要结构**，
    所以要在"简化过的图"上找边缘。sigma 就是简化程度。
    """
    gray = rgb @ LUMA
    if sigma > 0:
        gray = blur(gray[:, :, None], sigma)[:, :, 0]
    gx = _conv3(gray, SOBEL_X)
    gy = _conv3(gray, SOBEL_Y)
    return np.clip(np.hypot(gx, gy) / 4.0, 0.0, 1.0), gx, gy


def nonmax_suppress(mag: np.ndarray, gx: np.ndarray, gy: np.ndarray) -> np.ndarray:
    """非极大值抑制（Canny 的关键一步）：把"带宽度"的梯度脊细化成 1 像素。

    **为什么必须要这一步**：Sobel 出来的边缘是一条有宽度的带（3 像素左右）。
    直接膨胀加粗，相邻的线会黏成一片黑块——实测就是这样糊掉的。
    NMS 之后线才是"1 像素的脊"，想多粗就膨胀几圈，粗细可控且不相连。

    做法：沿梯度方向看左右两个邻居，只有自己是局部极大才保留。
    硬件上是 8 个比较器 + 一个方向选择，也很便宜。
    """
    h, w = mag.shape
    p = np.pad(mag, 1, mode="edge")
    # 把梯度方向量化到 4 个桶：0=水平 1=/ 2=垂直 3=\
    ang = np.degrees(np.arctan2(gy, gx)) % 180.0
    bucket = ((ang + 22.5) // 45.0).astype(np.int8) % 4

    nbrs = {
        0: (p[1:h + 1, 2:w + 2], p[1:h + 1, 0:w]),    # → ←
        1: (p[2:h + 2, 2:w + 2], p[0:h, 0:w]),        # ↗ ↙
        2: (p[2:h + 2, 1:w + 1], p[0:h, 1:w + 1]),    # ↑ ↓
        3: (p[2:h + 2, 0:w], p[0:h, 2:w + 2]),        # ↘ ↖
    }
    out = mag.copy()
    for k, (a1, a2) in nbrs.items():
        m = (bucket == k) & ((mag < a1) | (mag < a2))
        out[m] = 0.0
    return out


def dilate(mask: np.ndarray, r: int) -> np.ndarray:
    """膨胀 r 圈（4 邻域）。线宽就是这么来的。"""
    out = mask
    for _ in range(r):
        p = np.pad(out, 1, mode="constant", constant_values=False)
        out = p[:-2, 1:-1] | p[2:, 1:-1] | p[1:-1, :-2] | p[1:-1, 2:] | out
    return out


def downsample(rgb: np.ndarray, d: int) -> np.ndarray:
    """d×d 盒平均降采样。

    **这本身就是一次低通滤波**——所以它不只是省资源，还直接参与"按尺度筛"。
    降采样之后，要取得同样的尺度效果，模糊核只要原来的 1/d 大。
    """
    if d <= 1:
        return rgb
    h, w = rgb.shape[:2]
    h2, w2 = (h // d) * d, (w // d) * d
    c = rgb.shape[2] if rgb.ndim == 3 else 1
    a = rgb[:h2, :w2]
    if rgb.ndim == 2:
        return a.reshape(h2 // d, d, w2 // d, d).mean(axis=(1, 3))
    return a.reshape(h2 // d, d, w2 // d, d, c).mean(axis=(1, 3))


def upsample_mask(mask: np.ndarray, shape: tuple[int, int], d: int) -> np.ndarray:
    """最近邻升采样回全分辨率。线条位置只有 d 像素的粒度。"""
    if d <= 1:
        return mask
    up = np.repeat(np.repeat(mask, d, axis=0), d, axis=1)
    h, w = shape
    out = np.zeros((h, w), dtype=bool)
    out[:min(h, up.shape[0]), :min(w, up.shape[1])] = \
        up[:min(h, up.shape[0]), :min(w, up.shape[1])]
    return out


def line_mask(content: np.ndarray, *, sigma_fine: float, sigma_coarse: float,
              t_fine: float, t_coarse: float,
              w_fine: int, w_coarse: int,
              down: int = 1) -> tuple[np.ndarray, np.ndarray]:
    """多尺度线条掩码。返回 (线条掩码, 强度图)。

    **粗细变化就靠两个尺度**：
      - 细尺度（sigma 小）：抓到细节 → 画**细线**
      - 粗尺度（sigma 大）：只剩主干轮廓 → 画**粗线**

    合成之后，轮廓处是粗线、细节处是细线——这正是漫画的用线规律
    （外轮廓重、内部结构轻）。单尺度 + 固定线宽是做不出这个效果的。

    强度图用来调制线条的深浅：轮廓线更黑，细节线略浅。
    """
    # 降采样：既省滤波器的存储，又顺带做了一次低通（本身就在"按尺度筛"）。
    # 尺度要按比例折算——原图 σ=3 在 1/4 分辨率上等价于 σ=0.75。
    src = downsample(content, down)
    sf, sc = sigma_fine / down, sigma_coarse / down

    g_fine, gx_f, gy_f = gradient_xy(src, sf)
    g_coarse, gx_c, gy_c = gradient_xy(src, sc)

    # 先 NMS 细化成 1px 脊，再按尺度加粗——不细化的话膨胀会糊成块
    n_fine = nonmax_suppress(g_fine, gx_f, gy_f)
    n_coarse = nonmax_suppress(g_coarse, gx_c, gy_c)

    # 阈值在低分辨率上判；**膨胀放在升采样之后**，
    # 这样线宽仍是全分辨率的精度（低分辨率只影响线条位置）
    m_fine_s = n_fine > t_fine
    m_coarse_s = n_coarse > t_coarse
    h, w = content.shape[:2]
    m_fine = dilate(upsample_mask(m_fine_s, (h, w), down), w_fine)
    m_coarse = dilate(upsample_mask(m_coarse_s, (h, w), down), w_coarse)

    mask = m_coarse | m_fine
    # 强度：粗尺度占主导。它也在低分辨率上算，再最近邻升采样回来。
    strength_s = np.maximum(g_coarse / max(t_coarse, 1e-6),
                            g_fine / max(t_fine, 1e-6))
    strength_s = np.clip(strength_s, 0.0, 1.0)
    if down > 1:
        strength = np.repeat(np.repeat(strength_s, down, axis=0), down, axis=1)
        strength = strength[:h, :w]
        if strength.shape != (h, w):  # 尺寸除不尽时补边
            pad = np.zeros((h, w), dtype=np.float32)
            pad[:strength.shape[0], :strength.shape[1]] = strength
            strength = pad
    else:
        strength = strength_s
    return mask, strength


_last_label: list = [None]
"""最近一次 region_colorize 用的分区标签。

线条和色块如果是两套独立的分割，就会**对不齐**（实测：熊脸颊上的线和色块错开）。
真实的赛璐璐里**线条就是色块的边界**，是同一个东西。所以让 region_colorize
把标签留在这里，线条直接从它上面取边界——天然对齐，而且不用做 Sobel/NMS。
"""


def region_boundary_mask(label: np.ndarray, w: int = 1) -> np.ndarray:
    """分区边界 = 色块之间的边。**和色块天然对齐**，这是它相对边缘检测的优势。

    硬件上比 Sobel/NMS 便宜得多：只要比较当前像素和右/下邻居的标签是否相同
    （等价于一行延迟）。**没有梯度、没有方向量化、没有非极大抑制。**
    """
    m = np.zeros(label.shape, dtype=bool)
    h_edge = label[:, :-1] != label[:, 1:]
    m[:, :-1] |= h_edge
    m[:, 1:] |= h_edge
    v_edge = label[:-1, :] != label[1:, :]
    m[:-1, :] |= v_edge
    m[1:, :] |= v_edge
    return dilate(m, w) if w > 0 else m


def _box(x: np.ndarray, r: int) -> np.ndarray:
    """半径 r 的盒滤波，用积分图实现，O(1)/像素。x 是 [H,W] 或 [H,W,C]。"""
    if r <= 0:
        return x
    pad = ((r, r), (r, r)) + (((0, 0),) if x.ndim == 3 else ())
    xp = np.pad(x, pad, mode="reflect")
    c = np.cumsum(np.cumsum(xp, axis=0), axis=1)
    c = np.pad(c, ((1, 0), (1, 0)) + (((0, 0),) if x.ndim == 3 else ()))
    H, W = x.shape[:2]
    k = 2 * r + 1
    return (c[k:k + H, k:k + W] - c[:H, k:k + W]
            - c[k:k + H, :W] + c[:H, :W]) / (k * k)


def guided_filter(guide: np.ndarray, src: np.ndarray, r: int = 8,
                  eps: float = 1e-2) -> np.ndarray:
    """导向滤波（He et al. 2010）：以 `guide` 为引导，对 `src` 做**保边平滑**。

    **为什么换掉 `region_colorize`**：那个算子是"每个分区取平均色"——
    分区内部**数学上绝对平坦**，所以分区里的**语义细节（人脸、车牌、印花）**一律被抹掉。
    用户的原话是"背景人脸、车牌文字被抹糊……观感是'糊了'而不是'画了'"。

    导向滤波的区别：**平坦区照样抹平，但边缘处跟着引导图走**。
    以**原图**为引导、网络输出为输入，就能把原图的边缘结构"接"回到平滑结果上
    ——**既保住了平涂感，又不会把该留的细节糊掉**。

    代价：3 个盒滤波 + 若干逐像素乘加，全是 O(1)/像素 的滑窗累加，
    硬件上和后处理链现有算子同量级（比高斯便宜，无乘法器密集部分）。
    """
    g = guide if guide.ndim == 3 else guide[..., None]
    p = src if src.ndim == 3 else src[..., None]
    mg, mp = _box(g, r), _box(p, r)
    cov = _box(g * p, r) - mg * mp
    var = _box(g * g, r) - mg * mg
    a = cov / (var + eps)
    b = mp - a * mg
    return _box(a, r) * g + _box(b, r)


def _norm(x: np.ndarray) -> np.ndarray:
    """零均值、单位标准差。"""
    return (x - x.mean()) / (x.std() + 1e-6)


def _gradmag(g: np.ndarray) -> np.ndarray:
    """[H,W] 的梯度幅值。"""
    ex = np.abs(np.diff(g, axis=1, prepend=g[:, :1]))
    ey = np.abs(np.diff(g, axis=0, prepend=g[:1, :]))
    return ex + ey


def watercolor(img: np.ndarray, *, edge: float = 0.0, bleed: float = 0.0,
               paper: float = 0.0, seed: int = 0) -> np.ndarray:
    """**水彩三件套**：边缘积色 + 晕染外溢 + 纸纹。

    ## 为什么需要它

    `region_colorize` 做的是"色块平涂"——本质是**赛璐璐**，不是水彩。
    而且它靠抹平细节来出效果，正好撞上"糊了 vs 画了"那条轴。
    水彩的特征**不要求色块平坦**，所以它和"保细节"不冲突：

    ## 三个算子在模拟什么

    **① 边缘积色 `edge`**（Curtis et al. 1997, *Computer-Generated Watercolor*）
    颜料在水彩纸上干燥时，随水向边界迁移，**在色块内侧留下一圈更深的边**。
    这是水彩最标志性的特征。做法：梯度幅值 → 盒滤波展宽 → **乘性**压暗
    （乘性而非减性：暗部本来就深，再减会死黑）。

    **② 晕染外溢 `bleed`**
    湿颜料会向纸面扩散，边缘外侧出现**颜色溢出**。
    做法：把模糊版按"边缘处的湿度权重"混合回去。
    ⚠ 只在高梯度处混、且半径不大——否则就退化成普通模糊，把刚保住的细节又糊掉。

    **③ 纸纹 `paper`**
    纸的凹凸在**中间调**最明显（纯黑纯白处看不出来）。
    做法：程序化噪声 × 幅值 × `1−|2·亮度−1|` 权重，**乘性**叠加。

    ## 硬件代价

    三个都是 O(1)/像素 的滑窗算子：梯度（2 次减法）、盒滤波（积分图）、
    逐像素乘加。**和后处理链现有算子同量级**。纸纹是一张固定图，
    可以存成小尺寸 BRAM 平铺，或按坐标用 LFSR 现生成。
    """
    out = img.astype(np.float32).copy()
    g = out.mean(axis=2)

    if edge > 0:
        e = _box(_gradmag(g), 2)          # 展宽成有一定宽度的边，不是一条硬线
        m = float(e.max())
        if m > 1e-6:
            out *= (1.0 - edge * (e / m)[..., None])

    if bleed > 0:
        e = _box(_gradmag(g), 3)
        m = float(e.max())
        if m > 1e-6:
            wet = (bleed * (e / m))[..., None]      # 只在边缘附近"湿"
            out = out * (1.0 - wet) + _box(out, 5) * wet

    if paper > 0:
        rng = np.random.default_rng(seed)
        r = rng.random(g.shape).astype(np.float32)
        # **多尺度**：真纸纹 = 大块的云斑（纸的厚薄不均）+ 细纤维。
        # 单一尺度的白噪声看着像"噪点"而不是"纸"——这是第一版的问题。
        coarse = _box(r, 24)                      # 云斑
        fine = _box(r, 1)                         # 纤维
        n = _norm(coarse) * 0.65 + _norm(fine) * 0.35
        n = np.clip(n, -3.0, 3.0)
        # 中间调最明显：纯黑/纯白处纸纹看不见
        out *= (1.0 + paper * (1.0 - np.abs(2.0 * g - 1.0))[..., None] * n[..., None])

    return np.clip(out, 0.0, 1.0)


def region_colorize(stylized: np.ndarray, content: np.ndarray, *,
                    region_levels: int, region_blur: float,
                    line_levels: int = 0, line_blur: float = 0.0) -> np.ndarray:
    """用**内容的分区**决定色块形状，只借网络输出的**配色**。

    **为什么不直接用量化后的网络输出**：网络输出里"烤"进了一层排线纹理，
    量化只能把它切成碎块（模糊抹平又会连形状一起糊掉，实测是这个取舍里无解的）。
    换个分工就绕开了这个问题：

        形状 ← 内容（模糊 + 量化成分区）
        颜色 ← 网络（每个分区取平均色）

    结果**数学上保证绝对平坦**——每个分区内所有像素是同一个颜色。
    这也更贴合赛璐璐的本质：**色块是沿着结构分的，不是沿着像素分的。**

    硬件上这需要"按分区求均值"，比逐像素操作重（要一份分区标签 + 累加器），
    是本文件里唯一不太好流式实现的一步——落地前要专门设计。
    """
    c = blur(content, region_blur)
    q = np.clip(np.round(c * (region_levels - 1)), 0, region_levels - 1).astype(np.int32)
    label = (q[..., 0] * region_levels + q[..., 1]) * region_levels + q[..., 2]
    flat = label.ravel()

    # 线条用**更粗**的一套分区：颜色要细节（细分区），线条只要主干（粗分区）。
    # 粗边界近似是细边界的子集，所以对齐性仍然保持。
    # 用同一套分区的话，要么线网乱（细）、要么颜色丢细节（粗），两头不讨好。
    if line_levels and line_levels < region_levels:
        cl = blur(content, line_blur)
        cq = np.clip(np.round(cl * (line_levels - 1)), 0, line_levels - 1).astype(np.int32)
        coarse = (cq[..., 0] * line_levels + cq[..., 1]) * line_levels + cq[..., 2]
    else:
        coarse = label
    _last_label[0] = coarse  # 供 region_boundary_mask 用（见下）
    n = region_levels ** 3

    counts = np.bincount(flat, minlength=n).astype(np.float32)
    out = np.empty_like(stylized)
    for ch in range(3):
        sums = np.bincount(flat, weights=stylized[..., ch].ravel().astype(np.float64),
                           minlength=n)
        mean = (sums / np.maximum(counts, 1)).astype(np.float32)
        out[..., ch] = mean[flat].reshape(label.shape)
    return out


def flatten(rgb: np.ndarray, *, sat: float, con: float, flat_blur: float,
            levels: int, med: bool, con_pivot: float = 0.5) -> np.ndarray:
    """把网络输出压成干净的赛璐璐色块。

    顺序有讲究：
        sat → con → blur → 量化 → 中值
      · 先提饱和/对比：量化会把色阶压扁，压完再提就晚了
      · blur 在量化前：把排线抹成平均色，否则会被切成碎色块
      · 中值在量化后：吃掉残留的孤立斑点，且不像模糊那样磨圆边界
    """
    out = saturate(rgb, sat)
    out = contrast(out, con, con_pivot)
    out = blur(out, flat_blur)
    if levels > 1:
        out = np.round(out * (levels - 1)) / (levels - 1)
    if med:
        out = median3(out)
    return np.clip(out, 0.0, 1.0)


def quantize_perceptual(rgb: np.ndarray, *, levels_y: int, levels_c: int) -> np.ndarray:
    """**按亮度/色度分离**量化 —— 赛璐璐色带的正确做法。

    ## 为什么不能用 `flatten()` 那套

    `flatten()` 在 **RGB 三通道各自** round 到 N 级。看着像"N 色"，
    实际是 **N³ 色**：6 级 → 最多 216 色，而**亮度仍然连续**。

    实测（2026-09-29，`python -m tools.cartoon_metrics`）：对已平滑的 cel 图
    再套 `flatten(levels=6)`，16 级亮度口径下**有效色阶仍是 16** —— 等于没量化；
    套 `levels=4` 也只降到 10。

    ⇒ 这才是"L6 没有产生任何色带"的**根因**，比"参数没生效"更深一层：
    **即使它生效了，也不出效果。** 唯一的例外是老代码走 `--flat-mode region`
    或遗留 else 分支时压根不量化，那是另一回事。

    ## 正确做法

    RGB → YCbCr（BT.601）后**分开量化**，再转回 RGB：

    | 通道 | 量化到 | 决定什么 |
    |---|---|---|
    | **Y** | `levels_y` 级 | **肉眼看到的色阶数** —— 卡通感的主来源 |
    | **Cb / Cr** | `levels_c` 级 | **限定配色板**（色相数量） |

    这样 Y 的级数才真正等于看到的色带数。

    ## 硬件代价

    两次 3×3 矩阵 + 两次查表，**逐像素、无行缓冲**。
    `round(x*(K−1))/(K−1)` 本身就是个小 LUT：K=4~8 直接做 ROM，
    或 K 取 2 的幂时用移位+截断。见 `FPGA-IMPL.md` §3.7-bis。

    ⚠ **torch 孪生在 `train/data.py::quantize_perceptual_t`，Y 支路的孪生是
    `train/data.py::quantize_y`。改一个必须改另一个**——
    训练期让网络学会"产出经得起这张 LUT 的输出"，部署期由 RTL 实现同一张表，
    两边数值必须逐位一致。镜像关系同 `train/model.py` ↔ `stnet/archs.py`。
    """
    if levels_y <= 1 and levels_c <= 1:
        return rgb
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    y = 0.299 * r + 0.587 * g + 0.114 * b
    cb = (b - y) / 1.772 + 0.5          # 归一化到 0~1
    cr = (r - y) / 1.402 + 0.5
    if levels_y > 1:
        y = np.round(y * (levels_y - 1)) / (levels_y - 1)
    if levels_c > 1:
        cb = np.round(cb * (levels_c - 1)) / (levels_c - 1)
        cr = np.round(cr * (levels_c - 1)) / (levels_c - 1)
    cb, cr = (cb - 0.5) * 1.772, (cr - 0.5) * 1.402
    r2 = y + 1.402 * cr
    b2 = y + 1.772 * cb
    g2 = (y - 0.299 * r2 - 0.114 * b2) / 0.587
    return np.clip(np.stack([r2, g2, b2], -1), 0.0, 1.0)


def line_overlay(flat: np.ndarray, content: np.ndarray, *,
                 sigma_fine: float, sigma_coarse: float,
                 t_fine: float, t_coarse: float,
                 w_fine: int, w_coarse: int, down: int = 1,
                 line_color=(0.04, 0.04, 0.07), ink: float = 1.0) -> np.ndarray:
    """把漫画线条叠到平涂色块上。

    **线色取近黑**（而不是原来的灰蓝）：赛璐璐的观感来自"色块 + 黑线"的强对比，
    线色一浅就和内部色块混在一起，分不开了。

    `ink` 控制线条的整体深浅；轮廓处更黑，细节处略浅（由强度图调制）。
    """
    mask, strength = line_mask(content, sigma_fine=sigma_fine, sigma_coarse=sigma_coarse,
                               t_fine=t_fine, t_coarse=t_coarse,
                               w_fine=w_fine, w_coarse=w_coarse, down=down)
    return ink_overlay(flat, mask, strength, ink=ink, line_color=line_color)


def xdog(rgb: np.ndarray, *, sigma: float = 1.0, k: float = 1.6, gamma: float = 0.98,
         eps: float = 0.9, phi: float = 200.0) -> np.ndarray:
    """XDoG（扩展高斯差分）——照片转墨线的经典算子，实时漫画滤镜的基础。

    出处：Winnemöller et al., "XDoG: Advanced Image Stylization with eXtended
    Difference-of-Gaussians", NPAR 2011.

    相比"Sobel + 硬阈值"的两个关键好处：

    1. **软阈值给出墨色浓淡**。`1 + tanh(φ(D−ε))` 是连续过渡，
       边缘越强越黑、越弱越淡——**这正是"线条要有粗细浓淡变化"的来源**，
       而硬阈值只有 0/1 两态，线条死板。
    2. **线条更连贯**。DoG 是带通，天然抑制孤立噪点、保留延伸的边，
       不像 Sobel 那样在纹理区炸成散点。

    硬件上很便宜：两个可分离高斯（复用盒滤波近似）+ 一次比较 + 一个 tanh 查表。
    **比现在的 Sobel + NMS + 双尺度还省。**

    返回 HxW 的"墨量"图：1 = 全黑线，0 = 无墨。
    """
    gray = rgb @ LUMA
    g1 = blur(gray[:, :, None], sigma)[:, :, 0]
    g2 = blur(gray[:, :, None], sigma * k)[:, :, 0]
    d = g1 - gamma * g2
    ink = np.where(d >= eps, 0.0, 1.0 + np.tanh(phi * (d - eps)))
    return np.clip(ink, 0.0, 1.0)


def ink_overlay(flat: np.ndarray, mask: np.ndarray, strength: np.ndarray, *,
                ink: float = 1.0, line_color=(0.04, 0.04, 0.07)) -> np.ndarray:
    """把线条掩码刷到色块上。线条深浅随强度调制（轮廓实、细节虚）。"""
    line = np.array(line_color, dtype=np.float32)
    a = np.clip(ink * (0.72 + 0.28 * strength), 0.0, 1.0)[..., None]
    out = flat.copy()
    out[mask] = (1 - a[mask]) * flat[mask] + a[mask] * line
    return np.clip(out, 0.0, 1.0)


# ─────────────────────────────────────────────────────────────
def to_np(t) -> np.ndarray:
    """(1,3,H,W) [0,1] -> (H,W,3)"""
    return t[0].permute(1, 2, 0).detach().cpu().numpy()


def to_pil(a: np.ndarray) -> Image.Image:
    return Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8))


def label_strip(imgs: list[Image.Image], labels: list[str]) -> Image.Image:
    from PIL import ImageDraw
    w, h = imgs[0].size
    bar = 22
    out = Image.new("RGB", (w * len(imgs), h + bar), (250, 250, 252))
    d = ImageDraw.Draw(out)
    for i, (im, lb) in enumerate(zip(imgs, labels)):
        out.paste(im, (i * w, bar))
        d.text((i * w + 6, 5), lb, fill=(30, 30, 40))
    return out


def main() -> int:
    # ⚠ Windows 控制台默认 GBK：帮助文本和日志里的中文/上标（如 m³）会
    # UnicodeEncodeError 直接把 `--help` 打断。所有入口都先自保一下。
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="赛璐璐平涂 + 漫画线条后处理")
    ap.add_argument("--ckpt", type=Path, default=Path("runs/final/D_ukiyoe"))
    ap.add_argument("--input", type=Path, default=DATA / "content")
    ap.add_argument("--limit", type=int, default=3)
    ap.add_argument("--max-side", type=int, default=512)
    ap.add_argument("--out", type=Path, default=Path("runs/toon_out"),
                    help="输出目录（默认 runs/toon_out；最终展示图在 runs/final/showcase/）")
    ap.add_argument("--chroma-blend", type=float, default=0.0,
                    help="**配色旋钮 α**（仅对亮度域网络有效）：0 = 全用原图颜色（最保真），"
                         "1 = 全用风格配色（风格最强、色偏最大）。"
                         "实现是逐像素 3×3 矩阵，等价于一个 1×1 卷积，硬件代价≈0。"
                         "先看 tools/chroma_sweep.py 定档位")
    ap.add_argument("--chroma-style", default="great_wave",
                    help="配色旋钮参考哪张风格图的配色（data/styles 下的短名）")
    ap.add_argument("--flat-mode", choices=("region", "guided", "none"), default="region",
                    help="展平算子。region = 分区取平均色（**天生抹细节**，人脸/车牌会被糊掉）；"
                         "guided = 导向滤波，以**原图为引导**做保边平滑——平坦区照样平，"
                         "边缘处跟着原图走；"
                         "none = 不展平（**配合 Kuwahara 用**——两者都是保边展平，"
                         "同时开是重复付费，Kuwahara 顶替 guided 可省 25KB）")
    ap.add_argument("--guided-r", type=int, default=8, help="导向滤波半径（越大越平）")
    ap.add_argument("--guided-eps", type=float, default=1e-2,
                    help="导向滤波 eps：越小越保边，越大越平滑")
    ap.add_argument("--con-stage", choices=("after", "before"), default="after",
                    help="对比度/饱和度施加在**展平之前还是之后**。"
                         "after = 历史行为；before = 放大的颗粒随后被导向滤波抹掉，"
                         "同样对比度下噪点更少（代价是展平本身在提过对比的图上做）")
    ap.add_argument("--guided-pass", type=int, default=1,
                    help="导向滤波迭代几遍。**多遍小核**比**单遍大半径**省行缓冲"
                         "（行数 ∝ 半径；遍数是串联的、不叠加），FPGA 上划算")
    ap.add_argument("--quant-space", choices=("none", "ycbcr", "rgb"), default="none",
                    help="量化域。**默认 none = 不量化**（历史行为，水彩流水线要的就是这个）。"
                         "ycbcr = 亮度/色度分离量化（能出真色带，赛璐璐用这个）；"
                         "rgb = 老的逐通道量化（6 级其实是 6³=216 色，亮度仍连续，留着做对照）。"
                         "⚠ 2026-09-29：这一项曾经默认 ycbcr，导致水彩流水线被静默量化")
    ap.add_argument("--pre-denoise", type=int, default=0,
                    help="**量化前**做几遍中值降噪。网络输出带着风格图的纸纹颗粒，"
                         "量化会把颗粒放大成色带边缘的噪点；量化后再补就晚了")
    ap.add_argument("--levels-c", type=int, default=6,
                    help="**色度**量化级数（限定配色板）。配 --levels（亮度级数）一起用。"
                         "1 = 不量化色度")

    g = ap.add_argument_group("水彩三件套（都是固定算子，硬件代价同量级）")
    g.add_argument("--wc-edge", type=float, default=0.0,
                   help="**边缘积色**强度。颜料干时向边界迁移，在色块内侧留一圈深边——"
                        "水彩最标志性的特征。建议 0.3~0.6")
    g.add_argument("--wc-bleed", type=float, default=0.0,
                   help="**晕染外溢**强度。湿颜料向纸面扩散，边缘外侧出现颜色溢出。"
                        "⚠ 只在高梯度处混、半径不大，否则退化成普通模糊。建议 0.2~0.4")
    g.add_argument("--wc-paper", type=float, default=0.0,
                   help="**纸纹**强度。纸的凹凸在中间调最明显，乘性叠加。建议 0.1~0.25")
    g.add_argument("--wc-seed", type=int, default=0, help="纸纹随机种子（固定值保证可复现）")

    g = ap.add_argument_group("水彩收尾（确定性滤波，无网络 —— FPGA 上最便宜的一类）")
    g.add_argument("--wc-granule", type=float, default=0.0,
                   help="**颗粒沉淀**：噪声 × **颜料密度**（暗部重）。"
                        "注意与旧 `--wc-paper` 的模型**相反**——旧的按中调加权、暗部为零，"
                        "做出来是'斑驳/厚涂'；这个才是'颜料沉积'。建议 0.02~0.04")
    g.add_argument("--wc-tooth", type=float, default=0.0,
                   help="**纸齿**：细纤维噪声 × 高光权重（留白处透出纸的凹凸）。建议 0.015~0.03")
    g.add_argument("--wc-humidity", type=float, default=0.0,
                   help="**湿度晕染**：一张**低频湿度图**控制扩散强度（不是全图均匀模糊）"
                        "→ 边界干湿不均才有手绘感。建议 0.10~0.32")
    g.add_argument("--wc-norm-const", type=float, default=0.0,
                   help="纸纹/颗粒的**均值归一**改用固定常数（0 = 用本帧自己的均值，默认）。"
                        "逐帧均值是一个随内容变的**全局增益**，是时域抖动的嫌疑来源之一；"
                        "这个开关用来做对照实验，不是为了画质")
    g.add_argument("--wc-humidity-scale", type=int, default=24,
                   help="湿度图的空间尺度（越大 = 越整片的湿区）")
    g.add_argument("--wc-humidity-sigma", type=float, default=3.5, help="晕染的模糊半径")
    g.add_argument("--wc-deposit", type=float, default=0.0,
                   help="**沉积边**：|DoG| 超阈处乘暗——颜料在色块收口处堆积出深色边。建议 0.2~0.35")
    g.add_argument("--wc-deposit-thr", type=float, default=0.05,
                   help="沉积边的 |DoG| 阈值。**默认 2026-09-29 从 0.012 改到 0.05** —— "
                        "0.012（≈3/255）看着像是很安全的小量级，实测却触发 "
                        "**34~45%% 的像素**，等于全图随机压暗，"
                        "用户说的「黑色噪点」就是它。"
                        "实测分布 p95≈0.044~0.078、p99≈0.068~0.129，"
                        "**落在 0.05~0.10 才叫边缘**。用 --wc-verbose 打印分布再定，别猜")
    g.add_argument("--wc-verbose", action="store_true",
                   help="打印 |DoG| 的分位数与当前阈值的触发比例——用来定 --wc-deposit-thr")
    g.add_argument("--wc-model", choices=("mul", "add"), default="mul",
                   help="颗粒/纸齿的模型。**mul（默认）= 1/f 纸纹 × 中间调门控 × 乘性只压暗**"
                        "（2026-09-29 晚重写）。add = 老模型（加性白噪声、暗部最重），"
                        "**只为对照保留**——它一提就暗部斑驳。两者**幅度语义不同，参数不可换算**")
    g.add_argument("--wc-tile", type=int, default=0,
                   help="纸纹场的平铺边长（0 = 整帧现生成，效果最好）。"
                        ">0 时只在 tile² 的块里生成再平铺 —— **FPGA 上就是这么做的**"
                        "（LFSR 生成一次存 ROM）。给个 64 可以看平铺痕迹明不明显")
    g.add_argument("--wc-sat-mid", type=float, default=1.0,
                   help="**中间调提饱和**。薄涂把饱和度腰斩（实测 0.428→0.216），"
                        "发灰发脏主要就是这一条。水彩是透明但颜料区鲜艳。建议 1.3~1.4")
    g.add_argument("--wc-paper-white", type=float, default=0.0,
                   help="**高光透纸白**：L>170 向暖白 (248,244,232) 混合，避免高光被灰化")
    g.add_argument("--wc-shadow-tint", type=float, default=0.0,
                   help="**暗部偏冷颜料**：往冷色偏，而不是压成中性灰")
    ap.add_argument("--dump-panels", action="store_true",
                    help="额外把四联图的每一格单独存成 `<stem>__<名>.png`"
                         "（供消融/对比脚本拼装，避免复制流水线逻辑）")
    ap.add_argument("--luma-match", action="store_true",
                    help="修「白膜」（仅亮度域）：把网络输出的亮度统计拉回内容图。"
                         "网络会去匹配风格图的亮度（《神奈川冲浪里》Y 均值 0.757 vs 内容 0.445），"
                         "导致黑场从 0.05 抬到 0.29、画面发灰。硬件代价 = 逐帧 2 个累加器")

    g = ap.add_argument_group("色块")
    g.add_argument("--kuwahara", type=int, default=0,
                   help="**Kuwahara 滤波半径**（0 = 关）。做'粘稠/厚涂'观感的算子："
                        "每像素取 4 个象限里**方差最小**那个的均值——等于'颜料流到最平的"
                        "方向摊开'。区域摊平、边界被**重组**成圆钝块状（不是模糊掉的）。"
                        "建议 2~5，越大越粘")
    g.add_argument("--kuwahara-aniso", type=int, default=0,
                   help="**各向异性 Kuwahara 半径**（0 = 关）。用结构张量定局部走向、把采样核"
                        "**沿走向拉长**再选最平象限——出来的才是**有方向的笔触**，"
                        "而各向同性版只是圆钝的块（读起来是糊）。建议 4~8")
    g.add_argument("--kuwahara-sharp", type=float, default=6.0,
                   help="各向异性拉伸强度。越大笔触越长；过大在弱结构处会拉出流线")
    g.add_argument("--kuwahara-down", type=int, default=1,
                   help="Kuwahara 在 1/D 分辨率上做（1 = 全分辨率）。"
                        "采样窗是全链最贵的一项（全分辨率 17 行三通道 = 63.75KB，"
                        "超预算 47.6KB），降到 D=2 只剩 1/4。"
                        "⚠ 笔触精度变成 D 像素，观感与全分辨率**有差异**")
    g.add_argument("--kuwahara-guide", type=int, default=2,
                   help="**结构混合半径**（0 = 关）。两个作用：① 把降采样抹掉的细结构从"
                        "降采样前的图接回来；② 这个半径就是判据 `e = box(|∇Y|, r)` 的窗口。"
                        "**默认 2**（2026-09-29 从 6 改下来）——窗口越大，**稀疏细结构越吃亏**："
                        "`r=6` 是 13x13 平均，STOP 牌那种细笔画梯度强但占窗面积小，"
                        "实测文字区 `e` 中位数只有 **0.073**、落在阈值带 [0.08,0.32] 下方 ⇒ "
                        "`w=0` ⇒ 文字被判成纹理，用了 Kuwahara 的糊版（边缘变波浪）。"
                        "降到 2 之后 e 的尾部 p99 从 0.261 抬到 0.337、中位数反而下降"
                        "（稀疏强边 vs 密集纹理被分开），**文字回来了，笔触没丢**，"
                        "而且行数 13→5，**更省**。")
    g.add_argument("--kuwahara-verbose", action="store_true",
                   help="打印结构判据 e 的分位数——用来**定阈值**，别靠猜")
    g.add_argument("--kuwahara-guide-width", type=float, default=0.6,
                   help="step 模式的过渡带相对宽度（±width·mid）。越小越陡")
    g.add_argument("--kuwahara-guide-mode", choices=("var", "grad", "step"), default="grad",
                   help="结构判据。grad = 按**局部对比度**（梯度幅值）——**推荐**"
                        "：方差版分不清结构与纹理，绒毛/草叶的方差同样高，"
                        "会把笔触一起吃掉（实测熊变回照片）。"
                        "var = 按局部方差（老版，保留做对照）")
    g.add_argument("--kuwahara-guide-eps", type=float, default=0.02,
                   help="结构判据的阈值 = '多强才算结构'。grad 模式下是梯度幅值阈值"
                        "（建议 0.01~0.05）；var 模式下是方差阈值。"
                        "调大只接回强边（笔触保得更好），调小吃掉笔触")
    g.add_argument("--kuwahara-angles", type=int, default=0,
                   help="把方向离散成 N 档（0 = 不做）。**带宽的关键**："
                        "浮点角度必须双线性采样（4 抽头），离散化后整数偏移可查表、"
                        "退化成单点采样，采样带宽降 4 倍（144→36 抽头/像素）。"
                        "代价是笔触方向有台阶。建议 12~16")
    g.add_argument("--kuwahara-coh", type=float, default=1e-2,
                   help="结构能量门控：λ₁/(λ₁+coh)。**必须 >0**——平坦区/暗部两个特征值"
                        "都趋近 0，此时各向异性度是 0/0 的噪声，会把暗部搅出方格伪影。"
                        "越大越保守（只在强结构处拉笔触）")
    g.add_argument("--kuwahara-soft", type=float, default=0.0,
                   help="Kuwahara 软化系数。0 = 硬选择（r 大会出方块伪影）；"
                        ">0 改成按 exp(−方差/soft) 加权。建议从 0.002 起试")
    g.add_argument("--black-lift-auto", action="store_true",
                   help="**自适应抬黑场**（默认关）。抬黑的前提是图像本来有正常黑场；"
                        "本来就全暗的输入固定抬黑会把亮暗差压掉一半（实测 035062 的雏菊糊没）。"
                        "按图像 Y 均值在 [lo, hi] 之间给权重，够亮抬满、够暗不抬。"
                        "硬件 ≈ 0（复用逐帧累加器）")
    g.add_argument("--black-lift-ref-lo", type=float, default=0.15,
                   help="自适应抬黑的 Y 均值下界（低于它完全不抬）")
    g.add_argument("--black-lift-ref-hi", type=float, default=0.45,
                   help="自适应抬黑的 Y 均值上界（高于它抬满）")
    g.add_argument("--black-lift", type=float, default=0.0,
                   help="**抬黑场**：把最暗处抬到该值（0 = 关，保持历史行为）。"
                        "`out = lift + (1−lift)·in`，黑场抬高、白场不动。"
                        "逐通道朝白抬 → 暗部同时又亮又淡，模拟颜料透出纸白。"
                        "薄涂/淡彩要开（0.1~0.25）；要厚重感就别开")
    g.add_argument("--sat", type=float, default=1.7, help="饱和度倍数")
    g.add_argument("--con", type=float, default=1.25, help="对比度倍数")
    g.add_argument("--con-auto", action="store_true",
                   help="**逐帧自适应对比度**（默认关）。用逐帧 Y 的均值/标准差把对比度系数"
                        "压到「不会把内容推出 [0,1]」的范围，并把支点从固定的 0.5 挪到图像均值。"
                        "修的是「亮且平」的输入被固定系数顶爆（实测 076261 雾霭天空 62%% 像素被裁平）。"
                        "硬件 ≈ 0（复用 luma_match 的累加器），**但继承逐帧统计的 1 帧延迟与闪烁**")
    g.add_argument("--con-auto-mode", choices=("pivot", "center"), default="pivot",
                   help="pivot = 支点挪到图像 Y 均值（**推荐**，修的就是支点离内容太远）；"
                        "center = 支点仍用 0.5，只做上界保护。留作对照")
    g.add_argument("--con-auto-kscale", type=float, default=1.3,
                   help="上界保护里 p_hi 用 mu + kscale*sigma 代理高百分位（默认 1.3 ≈ p90）")
    g.add_argument("--flat-blur", type=float, default=2.5, help="量化前的模糊半径")
    g.add_argument("--levels", type=int, default=6, help="色阶数（越小越「平」）")
    g.add_argument("--no-median", dest="med", action="store_false",
                   help="关掉量化后的中值去斑")
    g.add_argument("--region-levels", type=int, default=0,
                   help=">0 时启用「按内容分区取网络平均色」——色块绝对平坦。"
                        "值 = 内容的量化档数（越小块越大）。0 = 沿用旧的逐像素量化")
    g.add_argument("--region-blur", type=float, default=3.0,
                   help="分区前对内容模糊的程度")
    g.add_argument("--line-region-levels", type=int, default=3,
                   help="**线条**用几档分区（比 --region-levels 粗）。"
                        "颜色要细节、线条只要主干，两者粒度不同才两头兼顾")
    g.add_argument("--line-region-blur", type=float, default=8.0,
                   help="线条分区的模糊程度（越大越只留大块）")

    g = ap.add_argument_group("线条")
    g.add_argument("--sigma-fine", type=float, default=1.6, help="细尺度模糊（抓内部细节）")
    g.add_argument("--sigma-coarse", type=float, default=6.0, help="粗尺度模糊（只留主干轮廓）")
    g.add_argument("--t-fine", type=float, default=0.055, help="细尺度阈值")
    g.add_argument("--t-coarse", type=float, default=0.10, help="粗尺度阈值")
    g.add_argument("--w-fine", type=int, default=1, help="细线宽度（NMS 后膨胀圈数）")
    g.add_argument("--w-coarse", type=int, default=1,
                   help="线条宽度（膨胀圈数）。实测覆盖率：0圈 5.5%% / 1圈 10.6%% / "
                        "2圈 15.3%%（客厅）——2 圈太重，漫画线条取 1 更利落")
    g.add_argument("--edge-down", type=int, default=1,
                   help="边缘检测的降采样倍数。>1 时在 1/N 分辨率上找边缘再升采样——"
                        "**滤波器的存储按 N² 缩小**，代价是线条位置只有 N 像素粒度。"
                        "注意尺度会按比例折算：原图 σ 在低分辨率上变成 σ/N")
    g.add_argument("--ink", type=float, default=1.0, help="墨量（线条深浅）")
    g.add_argument("--xdog-sigma", type=float, default=1.0, help="XDoG 基础尺度")
    g.add_argument("--xdog-k", type=float, default=1.6, help="XDoG 尺度比")
    g.add_argument("--xdog-eps", type=float, default=0.92, help="XDoG 阈值（越大线越少）")
    g.add_argument("--xdog-phi", type=float, default=180.0, help="XDoG 软阈值陡度（越大越硬）")
    g.add_argument("--line-from", choices=("flat", "content"), default="flat",
                   help="**从哪张图上提边**。flat = 平滑+量化**之后**的图（正确做法："
                        "色块边界就是天然的线，且毛发/草叶纹理已被抹平，不会变成乱线）；"
                        "content = 原始内容图（旧行为，会把毛发草叶全提成线）")
    g.add_argument("--line-source", choices=("edge", "region", "xdog", "both", "none"),
                   default="edge",
                   help="线条从哪来。edge=内容边缘检测（跟着真实结构，但可能断续）；"
                        "region=分区边界（连续，但是等色线、可能横穿物体）；"
                        "both=两者相或；xdog=XDoG；none=不画线")
    args = ap.parse_args()

    import torch

    device = pick_device()
    ckpt = args.ckpt
    ckpt = ckpt / "net.pt" if ckpt.is_dir() else ckpt
    if not ckpt.exists():
        print(f"找不到权重 {ckpt}")
        return 1
    net, _ = load_net(ckpt, device)
    args.out.mkdir(parents=True, exist_ok=True)

    # 配色旋钮需要风格图的颜色统计——只在 α>0 时算，α=0 时完全不碰
    mu_s = cov_s = None
    if args.chroma_blend > 0:
        # 风格图可能在水彩目录里（data/styles_watercolor/），两处都找
        cands = [DATA / "styles" / f"{args.chroma_style}.jpg",
                 DATA / "styles_watercolor" / f"{args.chroma_style}.jpg"]
        sp = next((c for c in cands if c.exists()), None)
        if sp is None:
            print(f"配色参考 {args.chroma_style!r} 在 data/styles 和 styles_watercolor 里都找不到")
            return 1
        mu_s, cov_s = color_stats(load_style(sp).to(device))

    files = sorted(f for f in args.input.iterdir()
                   if f.suffix.lower() in {".jpg", ".jpeg", ".png"})[:args.limit]

    for f in files:
        img = fit(Image.open(f).convert("RGB"), args.max_side)
        x = to_batch(img).to(device)
        # 亮度域网络（ci=1）只吃 Y、只出 Y，色度必须从内容图**原样接回来**。
        # 不加这一步会直接报通道数不匹配，而不是静默出错，这里算是安全的。
        y_only = getattr(net, "ci", 3) == 1
        with torch.no_grad():
            y = net(to_luma(x) if y_only else x)
            if y_only:
                # ⚠ 合并色度前必须先对齐尺寸：网络输出可能比输入大几像素
                # （编码器 ceil、解码器定长 ×2，426 进 → 428 出，
                #  见 FPGA-IMPL.md §1.5）。不对齐的话广播直接报形状错。
                y = y[:, :, :x.shape[2], :x.shape[3]]
                if args.luma_match:
                    # 网络会把输出亮度拉到风格图的亮度上（实测 0.445 → 0.734），
                    # 黑场从 0.05 抬到 0.29，画面像蒙了层白膜。这里拉回内容图的统计量。
                    y = match_luma(y, x)
                xc = x
                if mu_s is not None:
                    # 配色旋钮：把**色度源**按 α 比例推向风格配色，亮度仍用网络的。
                    # α=0 → xc=x（原样）；α=1 → xc 完全是风格色域下的这张图。
                    M, b = transfer_matrix(*color_stats(x), mu_s, cov_s, mode="std")
                    xc = blend_chroma(x, M, b, args.chroma_blend)
                y = merge_luma(y, xc)

        content = to_np(x)
        stylized = to_np(y)
        # ⚠ 网络输出可能比输入大几像素（编码器 ceil、解码器定长 ×2，341→344，
        # 见 FPGA-IMPL.md §1.5）。不裁的话按 content 尺寸建的掩码会对不上。
        stylized = stylized[:content.shape[0], :content.shape[1]]

        # **逐帧自适应对比度**（`--con-auto`，默认关）。
        # 统计量取自**网络输出**，一帧只算一次，四个分支共用 ——
        # 硬件上这就是"一帧一组统计量"，和 `match_luma` 复用同一对累加器。
        con_k, con_p = (auto_contrast_params(stylized, args.con,
                                             mode=args.con_auto_mode,
                                             k_scale=args.con_auto_kscale)
                        if args.con_auto else (args.con, 0.5))
        if args.con_auto:
            print(f"  [自适应对比度] Y 均值 {float((stylized @ LUMA).mean()):.3f} "
                  f"标准差 {float((stylized @ LUMA).std()):.3f} "
                  f"→ k {args.con:g} → {con_k:.2f}，支点 {con_p:.3f}")

        if args.flat_mode == "none":
            # 不展平：直接拿网络输出。给"Kuwahara 顶替导向滤波"的对照用。
            flat = saturate(contrast(stylized, con_k, con_p), args.sat)
        elif args.flat_mode == "guided":
            # **保边平滑**：以原图为引导、网络输出为输入。
            # 平坦区照样抹平（保住"画"的观感），边缘处跟着原图走
            # （不把该留的语义细节糊掉）。见 guided_filter 的 docstring。
            # **对比度/饱和度放在展平之前还是之后**。
            # 它们是逐通道线性缩放，会**等比例放大颗粒**（实测平坦区 std
            # 0.217/0.270/0.320 对应 con 1.2/1.5/1.8，严格线性）。
            # 放**前面**，放大的颗粒随后被导向滤波抹掉 → 同样的对比度、更少的噪点。
            # 默认 "after" = 历史行为，不改既有流水线的语义。
            src = (saturate(contrast(stylized, con_k, con_p), args.sat)
                   if args.con_stage == "before" else stylized)
            flat = guided_filter(content, src,
                                 r=args.guided_r, eps=args.guided_eps)
            # **多遍小核**：同等平滑强度下比"单遍大半径"省行缓冲
            # （行数 ∝ 半径，遍数是串联的、不叠加），FPGA 上是划算的换法。
            for _ in range(max(0, args.guided_pass - 1)):
                flat = guided_filter(content, flat,
                                     r=args.guided_r, eps=args.guided_eps)
            if args.con_stage == "after":
                flat = saturate(contrast(flat, con_k, con_p), args.sat)
            # ⚠ 下面整块**只在量化时才跑**。
            #
            # 历史：这一支原来完全绕过 `flatten()`，所以 `--levels/--flat-blur/--med`
            # 在 guided 模式下是**死参数**（标签照印 "L6 med1" 但一个都没执行，
            # 2026-09-29 定位）。补上时**踩过一次坑**：把量化做成默认开，
            # 于是水彩流水线被静默量化成色带图——它从没要求过量化。
            # 水彩要的是柔和晕染，**量化必须是显式选择**。
            if args.quant_space != "none":
                # 量化前降噪：网络输出里烤着风格图的颗粒（水彩的纸纹、浮世绘的木纹），
                # 量化会把颗粒放大成色带边缘的椒盐。放在量化**之前**才有效——
                # 量化后再补中值只能补掉已成形的斑，补不回被切错的级。
                for _ in range(max(0, args.pre_denoise)):
                    flat = median3(flat)
                if args.quant_space == "ycbcr":
                    flat = quantize_perceptual(flat, levels_y=args.levels,
                                               levels_c=args.levels_c)
                elif args.levels > 1:
                    flat = (np.round(np.clip(flat, 0, 1) * (args.levels - 1))
                            / (args.levels - 1))
                if args.med:
                    flat = median3(flat)
            flat = np.clip(flat, 0.0, 1.0)
        elif args.region_levels > 0:
            # 分区取色：色块数学上绝对平坦。提饱和/对比放在取色**之后**——
            # 它们是逐像素的，不会破坏平坦性，放在前面反而会被平均掉。
            flat = region_colorize(stylized, content,
                                   region_levels=args.region_levels,
                                   region_blur=args.region_blur,
                                   line_levels=args.line_region_levels,
                                   line_blur=args.line_region_blur)
            flat = saturate(contrast(flat, con_k, con_p), args.sat)
            if args.med:
                flat = median3(flat)
            flat = np.clip(flat, 0.0, 1.0)
        else:
            flat = flatten(stylized, sat=args.sat, con=con_k, con_pivot=con_p,
                           flat_blur=args.flat_blur, levels=args.levels, med=args.med)
        # **Kuwahara（粘稠感）**：放在展平之后、水彩算子之前。
        # 它重组边界而不是抹边界，所以要在纸纹之前做，否则纸纹会被一起摊平。
        if args.kuwahara_aniso > 0:
            # **降采样做**：采样窗是这项最贵的成本（全分辨率 17 行三通道 = 63.75KB），
            # 在 1/D 分辨率上做，行数与宽度同时按 1/D 缩。见 `tools/pp_cost.py`。
            # ⚠ 笔触的空间精度随之变成 D 像素，观感与全分辨率版**会有差异**。
            if args.kuwahara_down > 1:
                d = args.kuwahara_down
                pre = flat                      # 降采样**前**的图：细结构（文字）还在
                small = _down_box(flat, d)
                small = kuwahara_aniso(small, r=args.kuwahara_aniso,
                                       sharp=args.kuwahara_sharp,
                                       soft=args.kuwahara_soft,
                                       coh=args.kuwahara_coh, angles=args.kuwahara_angles)
                flat = _up_nn(small, flat.shape[:2])
                if args.kuwahara_guide > 0 and args.kuwahara_guide_mode == "step":
                    flat = structure_blend_step(pre, flat, r=args.kuwahara_guide,
                                                mid=args.kuwahara_guide_eps,
                                                width=args.kuwahara_guide_width,
                                                verbose=args.kuwahara_verbose)
                elif args.kuwahara_guide > 0 and args.kuwahara_guide_mode == "grad":
                    flat = structure_blend_grad(pre, flat, r=args.kuwahara_guide,
                                                thr=args.kuwahara_guide_eps)
                elif args.kuwahara_guide > 0:
                    # **联合双边上采样**：把降采样毁掉的细结构从 `pre` 接回来。
                    #
                    # 复用链上已有的 `guided_filter` —— **零新增硬件**。
                    # 它是 `a·guide + b`，其中 `a = cov/(var+eps)`：
                    #   · 平坦处 var 小 → a≈0 → 输出 ≈ 笔触的颜色（Kuwahara 的成果保住）
                    #   · 强结构处 var 大 → a≈1 → 输出 ≈ 原图（文字/书脊接回来）
                    # **eps 就是"多强才算结构"的阈值**：调大 = 只接回更强的边，
                    # 调小 = 把更多东西当结构接回来（会开始吃掉笔触）。
                    flat = structure_blend(pre, flat, r=args.kuwahara_guide,
                                           eps=args.kuwahara_guide_eps)
            else:
                flat = kuwahara_aniso(flat, r=args.kuwahara_aniso,
                                      sharp=args.kuwahara_sharp,
                                      soft=args.kuwahara_soft,
                                      coh=args.kuwahara_coh, angles=args.kuwahara_angles)
        elif args.kuwahara > 0:
            flat = kuwahara(flat, r=args.kuwahara, soft=args.kuwahara_soft)
        # **抬黑场**：放在所有分支配色之后、水彩算子之前——
        # 这样三种 flat_mode 都吃到，且水彩的乘性边缘积色作用在已抬过的图上。
        # **自适应抬黑场**（`--black-lift-auto`，默认关）。
        # 抬黑是为了模拟「颜料透纸」，前提是图像**本来有正常的黑场**。
        # 对本来就全暗的输入（实测 `035062`：Y 中位数只有 0.047、半数像素在 0.043 以下），
        # 固定抬 0.18 等于把 `[0, 0.74]` 挤进 `[0.18, 0.79]`——**亮暗差被压掉一半**，
        # 毯子上的雏菊直接糊没（`runs/view_big/DARK/iso_000000035062.png`）。
        # 按图像自身的 Y 均值在 [lo, hi] 之间线性给权重：够亮才抬满，够暗就不抬。
        lift_k = 1.0
        if args.black_lift_auto and args.black_lift > 0:
            _mu = float((stylized @ LUMA).mean())
            lo, hi = args.black_lift_ref_lo, args.black_lift_ref_hi
            lift_k = min(1.0, max(0.0, (_mu - lo) / max(hi - lo, 1e-6)))
            print(f"  [自适应抬黑] Y 均值 {_mu:.3f} → 抬黑系数 {lift_k:.2f}"
                  f"（{args.black_lift:g} → {args.black_lift * lift_k:.3f}）")
        flat = black_lift(flat, args.black_lift * lift_k)
        # 水彩三件套：在平涂之后、线条之前。**它不靠抹平细节出效果**，
        # 所以和"保细节"不冲突——这正是它比「卡通扁平」更适合当前路线的理由。
        if args.wc_edge > 0 or args.wc_bleed > 0 or args.wc_paper > 0:
            flat = watercolor(flat, edge=args.wc_edge, bleed=args.wc_bleed,
                              paper=args.wc_paper, seed=args.wc_seed)
        # **水彩收尾**：颗粒/纸齿/湿度晕染/沉积边/色彩修正。
        # 全部确定性滤波，无网络参数。放在线条**之前**（沉积边是画面的，不是描边）。
        flat = wc_finish(flat, granule=args.wc_granule, tooth=args.wc_tooth,
                         humidity=args.wc_humidity,
                         humidity_scale=args.wc_humidity_scale,
                         sigma=args.wc_humidity_sigma,
                         deposit=args.wc_deposit, deposit_thr=args.wc_deposit_thr,
                         sat_mid=args.wc_sat_mid, paper_white=args.wc_paper_white,
                         shadow_tint=args.wc_shadow_tint, seed=args.wc_seed,
                         model=args.wc_model, tile=args.wc_tile,
                         norm_const=args.wc_norm_const,
                         verbose=args.wc_verbose)
        # 线条：各来源分别算出掩码，最后相或。三种都能单独用，也能组合。
        masks: list[np.ndarray] = []

        if args.line_source in ("region", "both"):
            lbl = _last_label[0]
            if lbl is None:
                print(f"--line-source {args.line_source} 需要 --region-levels > 0")
                return 2
            masks.append(region_boundary_mask(lbl, args.w_coarse))

        if args.line_source in ("edge", "both"):
            # **从处理后的图提边**（默认）。从 content 提会把毛发/草叶/布料
            # 纹理全变成乱线——`gradient_xy` 的 docstring 早就记过这个坑。
            edge_src = flat if args.line_from == "flat" else content
            emask, _ = line_mask(edge_src, sigma_fine=args.sigma_fine,
                                 sigma_coarse=args.sigma_coarse, t_fine=args.t_fine,
                                 t_coarse=args.t_coarse, w_fine=args.w_fine,
                                 w_coarse=args.w_coarse, down=args.edge_down)
            masks.append(emask)

        if args.line_source == "none":
            lined = flat
        elif args.line_source == "xdog":
            # XDoG 直接给"墨量图"（连续值），拿它当强度——
            # 边缘越强越黑，天然有浓淡变化，不需要额外加粗
            inkmap = xdog(content, sigma=args.xdog_sigma, k=args.xdog_k,
                          eps=args.xdog_eps, phi=args.xdog_phi)
            lined = ink_overlay(flat, inkmap > 0.03, inkmap, ink=args.ink)
        else:
            mask = masks[0] if len(masks) == 1 else np.logical_or.reduce(masks)
            # 各来源的强度语义不同，统一给常数；浓淡变化交给 §线条本身的形态
            lined = ink_overlay(flat, mask,
                                np.full(mask.shape, 1.4, dtype=np.float32), ink=args.ink)

        grid = label_strip(
            [to_pil(content), to_pil(stylized), to_pil(flat), to_pil(lined)],
            ["content", f"network ({ckpt.parent.name})",
             # ⚠ 标签必须反映**真正跑的那一支**。2026-09-29 前它无条件印
             # "L6 med1"，而 guided 分支压根不量化——标签在说谎。
             (f"flat: guided r{args.guided_r}x{args.guided_pass} "
              f"sat{args.sat} con{args.con}"
              + (f" quant[{args.quant_space}] Y{args.levels}/C{args.levels_c}"
                 if args.quant_space != "none" else " quant:off")
              if args.flat_mode == "guided"
              # ⚠ 同一个坑的第二处（2026-09-29 晚）：`--flat-mode none` 根本不调
              # `flatten()`，却照样印 `L6 med1`。改成印**真正在那条路上跑的算子**。
              else (f"cel: region{args.region_levels} blur{args.region_blur} "
                    f"sat{args.sat} con{args.con}" if args.region_levels > 0
                    else (f"cel: kuwahara{args.kuwahara_aniso}"
                          f"({args.kuwahara_sharp},1/{args.kuwahara_down},"
                          f"a{args.kuwahara_angles})"
                          f" sat{args.sat} con{args.con}"
                          + (" auto" if args.con_auto else "")
                          + (f" lift{args.black_lift:g}"
                             + ("a" if args.black_lift_auto else "")
                             if args.black_lift > 0 else "")
                          + (f" wc[{args.wc_model}]" if any(
                              (args.wc_granule, args.wc_tooth, args.wc_humidity,
                               args.wc_deposit)) else "")
                          if args.flat_mode == "none"
                          else f"cel: sat{args.sat} con{args.con} L{args.levels} "
                               f"med{int(args.med)}"))),
             f"lines[{args.line_source}]: w{args.w_coarse}"],
        )
        dst = args.out / f"toon_{f.stem}.png"
        grid.save(dst)
        print(f"{f.name} -> {dst}")

        if args.dump_panels:
            for pname, arr in (("content", content), ("stylized", stylized),
                               ("flat", flat), ("lined", lined)):
                to_pil(arr).save(args.out / f"{f.stem}__{pname}.png")

    print(f"\n完成，{len(files)} 张，输出在 {args.out}")
    return 0


def _self_check() -> int:
    """自检 —— **只验数学，不验观感**。`python -m tools.toon --self-check`

    验 `TemporalStat` 的两件事：阶跃响应（切镜头后多快追上）与抖动抑制。
    ⚠ **验不了上板的实际闪烁**（原型是逐图的，没有时间轴）。
    """
    import numpy as np
    print("=== TemporalStat 自检 ===")
    seq = np.concatenate([np.full(20, 0.20), np.full(20, 0.80)])   # 第 20 帧切镜头
    for label, a, cut in [("不平滑", 0.0, 1e9),
                          ("IIR a=0.9 无检测", 0.9, 1e9),
                          ("IIR a=0.9 + 切镜头检测", 0.9, 0.25)]:
        t = TemporalStat(alpha=a, cut_thr=cut, scale=1.0)
        out = [t(x) for x in seq]
        lag = next((i for i in range(20, 40) if abs(out[i] - 0.80) < 0.02), None)
        print(f"  {label:24s} 追上真值用了 "
              f"{('永远追不上' if lag is None else str(lag - 20 + 1) + ' 帧'):>10}"
              f"   切镜头判定 {t.resets} 次")
    rng = np.random.default_rng(0)
    noisy = 0.5 + rng.normal(0, 0.03, 120)
    raw = float(np.std(noisy))
    t = TemporalStat(alpha=0.9, cut_thr=0.25, scale=1.0)
    sm = np.array([t(x) for x in noisy])
    print(f"  抖动抑制: 原始 std {raw:.4f} -> 平滑后 {np.std(sm):.4f} "
          f"({np.std(sm) / raw * 100:.0f}%)")
    ok = np.std(sm) < raw * 0.6
    print("  [OK]" if ok else "  [FAIL] IIR 没起到抑抖动作用")
    return 0 if ok else 1


if __name__ == "__main__":
    import sys as _sys
    if "--self-check" in _sys.argv:
        raise SystemExit(_self_check())
    raise SystemExit(main())
