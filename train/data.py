"""训练数据加载：内容图随机裁剪 + 风格图预处理。"""

from __future__ import annotations

import random
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torch.utils.data import Dataset

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"


class ContentCrops(Dataset):
    """从内容图里随机裁 crop x crop 的块。

    风格迁移是自编码任务：target 就是输入本身，
    所以不需要配对数据，返回的图既是网络的输入，也是内容损失的目标。

    `steps` 不是数据集大小而是"一个 epoch 取多少次"——样本每次重新随机裁剪，
    本质是无限的，用长度来控制训练轮数（同时也是 `len()` 的返回值）。
    """

    def __init__(self, crop: int = 256, steps: int = 1000, seed: int = 0):
        self.files = sorted((DATA / "content").glob("*.jpg"))
        if not self.files:
            raise FileNotFoundError(
                f"{DATA / 'content'} 下没有内容图，先跑 python -m train.fetch_data"
            )
        self.crop, self.steps, self.seed = crop, steps, seed

    def __len__(self) -> int:
        return self.steps

    def __getitem__(self, i: int) -> torch.Tensor:
        # 由 (seed, i) 派生出每步独立的随机数：同一次训练可复现，不同 step 又不重样。
        # 注意 Python 3.14 的 random.seed() 不再接受元组，只能喂标量，所以手工混一下。
        rng = random.Random(self.seed * 1_000_003 + i)
        for _ in range(10):  # COCO 里有极少数小图，太小就换一张
            img = Image.open(self.files[rng.randrange(len(self.files))]).convert("RGB")
            if min(img.size) >= self.crop:
                break
        else:
            img = img.resize((self.crop, self.crop), Image.BICUBIC)

        x = rng.randrange(img.width - self.crop + 1)
        y = rng.randrange(img.height - self.crop + 1)
        img = img.crop((x, y, x + self.crop, y + self.crop))
        if rng.random() < 0.5:
            img = img.transpose(Image.FLIP_LEFT_RIGHT)

        return to_tensor(img)


def to_tensor(img: Image.Image) -> torch.Tensor:
    """PIL RGB -> [3,H,W] 的 float，范围 [0,1]。

    **不带 batch 维**：作为 Dataset 的返回值时 DataLoader 会自己叠一维，
    这里再 unsqueeze 就会变成 5D，然后卷积层报
    "Padding size 4 is not supported for 5D input tensor"。需要单张成批用 `to_batch`。
    """
    t = torch.from_numpy(np.asarray(img, dtype="float32").copy())
    return t.permute(2, 0, 1) / 255.0


def to_batch(img: Image.Image) -> torch.Tensor:
    """PIL RGB -> [1,3,H,W]，供直接喂网络用。"""
    return to_tensor(img).unsqueeze(0)


def load_style(path: Path, size: int = 256, random_crop: bool = False,
               rng: "random.Random | None" = None) -> torch.Tensor:
    """把风格图缩到固定尺寸。

    Gram 统计与风格图的原始分辨率无关，缩小只省显存；
    但要先按短边等比缩放再裁剪，直接 resize 成正方形会把画拉变形，
    拉变形会改变笔触的方向性，风格就学歪了。

    random_crop：
        False（默认）—— 取**中心** 256×256。单张风格图时的传统做法。
        True  —— 在缩放后的图上**随机**裁一块。多图训练时必须开，
                 否则每张图都只贡献中心那一小块，44 张等于 44 个中心。

    注意：**中心裁剪会让一张 4000×4000 的图只贡献 256×256 的信息**。
    风格图越是有多种构图，随机裁切越重要。
    """
    img = Image.open(path).convert("RGB")
    scale = size / min(img.size)
    img = img.resize((max(size, round(img.width * scale)),
                      max(size, round(img.height * scale))), Image.BICUBIC)
    if random_crop:
        r = rng or random
        left = r.randint(0, img.width - size)
        top = r.randint(0, img.height - size)
    else:
        left, top = (img.width - size) // 2, (img.height - size) // 2
    return to_batch(img.crop((left, top, left + size, top + size)))


def to_luma(x: torch.Tensor) -> torch.Tensor:
    """[B,3,H,W] → [B,1,H,W]：取出亮度通道。

    权重用 **BT.601**（0.299/0.587/0.114），因为 MIPI/HDMI 视频通路默认就是这个口径，
    训练和硬件对得上。换 BT.709 数字会差一点，但两边必须一致。
    """
    w = torch.tensor((0.299, 0.587, 0.114), dtype=x.dtype, device=x.device)
    return (x * w.view(1, 3, 1, 1)).sum(1, keepdim=True)


def is_y_only(net) -> bool:
    """这个网络是不是**亮度域**（`ci == 1`）——"喂什么进去"只在这一个地方判断。

    ⚠ **不要再在各处写 `torch.zeros(1, 3, h, w)` 或直接 `net(to_batch(img))`。**
    亮度域网络（`改D-Y`）的 `ci=co=1`，喂 3 通道会直接报通道数不匹配；
    更坏的情况是被广播成"以为能跑"，出来的东西没人对过。
    实测踩过：`train/parity.py` 一直是崩的（`stnet` 缺 `改D-Y` 键），
    而 `deploy.py` / `export.py` / `stylize.py` 的 3 通道硬编码**没有任何测试覆盖**，
    因为它们只在"跑一次部署"时才被执行到。
    """
    return int(getattr(net, "ci", 3)) == 1


def net_input(x3: torch.Tensor, net) -> torch.Tensor:
    """`[B,3,H,W]` 的 RGB → **这个网络要的输入**（亮度域网络给 `[B,1,H,W]`）。"""
    return to_luma(x3) if is_y_only(net) else x3


def net_output_rgb(y: torch.Tensor, x3: torch.Tensor, net) -> torch.Tensor:
    """网络的输出 → **可保存/可比的 RGB**。

    亮度域网络只吐亮度，颜色要**从内容图原样接回**（`merge_luma` 保 Y：
    `final_i = x_i·(y/Y_x) ⇒ Y_final = y`，实测 `max|ΔY|` 均值 0.0002）。
    非亮度域网络原样返回。
    """
    return merge_luma(y, x3) if is_y_only(net) else y


def quantize_y(y: torch.Tensor, levels: int) -> torch.Tensor:
    """[B,1,H,W] 亮度的 K 级均匀量化。**无参数、逐像素、无行缓冲。**

    ⚠ **表达式必须逐字等于 `tools/toon.py::quantize_perceptual` 的 Y 支路**
    （`np.round(y*(K-1))/(K-1)`）——那是 RTL 后处理 LUT 的规格。
    **改一个必须改另一个。** 镜像关系同 `train/model.py` ↔ `stnet/archs.py`。
    """
    if levels <= 1:
        return y
    return torch.round(y * (levels - 1)) / (levels - 1)


def quantize_perceptual_t(t: torch.Tensor, *, levels_y: int, levels_c: int) -> torch.Tensor:
    """[B,3,H,W] 的**亮度/色度分离**量化（`tools/toon.py` 那个的 torch 孪生）。

    **为什么不能在 RGB 逐通道量化**：N 级逐通道 round 其实是 **N³ 色**，
    亮度仍连续——6 级 → 216 色，16 级亮度口径下有效色阶仍是 16，等于没量化。
    实测记录见 `tools/toon.py::quantize_perceptual` 的 docstring。

    硬件上是两次 3×3 矩阵 + 两次查表，逐像素；`round(x*(K-1))/(K-1)`
    本身就是小 LUT（K=4~8 做 ROM，K 取 2 的幂时用移位+截断）。

    ⚠ **改一个必须改另一个**（与 `tools/toon.py` 逐行同构）。
    """
    if levels_y <= 1 and levels_c <= 1:
        return t
    r, g, b = t[:, 0:1], t[:, 1:2], t[:, 2:3]
    y = 0.299 * r + 0.587 * g + 0.114 * b
    cb = (b - y) / 1.772 + 0.5          # 归一化到 0~1
    cr = (r - y) / 1.402 + 0.5
    if levels_y > 1:
        y = torch.round(y * (levels_y - 1)) / (levels_y - 1)
    if levels_c > 1:
        cb = torch.round(cb * (levels_c - 1)) / (levels_c - 1)
        cr = torch.round(cr * (levels_c - 1)) / (levels_c - 1)
    cb, cr = (cb - 0.5) * 1.772, (cr - 0.5) * 1.402
    r2 = y + 1.402 * cr
    b2 = y + 1.772 * cb
    g2 = (y - 0.299 * r2 - 0.114 * b2) / 0.587
    return torch.cat([r2, g2, b2], dim=1).clamp(0.0, 1.0)


def merge_luma(y: torch.Tensor, x: torch.Tensor) -> torch.Tensor:
    """把内容图 `x` 的**色度**接回风格化的**亮度** `y` 上。

        y: [B,1,H,W] 网络输出（只含亮度纹理）
        x: [B,3,H,W] 原始内容图（色度来源）

    做法是按亮度比例缩放 RGB：`x · (y / luma(x))`。
    这在数学上等价于"转 YUV → 只换 Y → 转回 RGB"，
    但不需要真的做两次色彩空间转换，而且**色度比例严格保留**。

    这就是亮度域路线的全部魔法：**颜色不是被"匹配"出来的，是原样搬过来的**，
    网络根本没有机会改它。
    """
    return (x * (y / to_luma(x).clamp_min(1e-3))).clamp(0.0, 1.0)


def match_luma(y: torch.Tensor, x: torch.Tensor) -> torch.Tensor:
    """把网络输出的**亮度统计**对齐到内容图（保均值、保动态范围）。

    **为什么需要**：普通 Gram 的二阶矩 `E[ffᵀ]` 里，`E[f]E[f]ᵀ` 那一项是 DC
    分量（≈整体亮度）。实测：

        风格图《神奈川冲浪里》 Y 均值 0.757（大半是米白纸底）
        内容图（COCO）         Y 均值 0.445
        改D-Y 网络输出         Y 均值 **0.734** ← 几乎精确匹配了风格图

    后果是**黑场从 0.05 被抬到 0.29、整体亮度翻倍**，画面像蒙了一层白膜。
    内容损失（`relu3_3`）对整体亮度几乎不敏感，**拦不住它**——
    这和当初"输出变成色调偏移"是同一个机制，只是这次发生在亮度通道上。

    硬件代价：逐帧 2 个累加器（求和、平方和）+ 一次线性映射，和 α 矩阵同量级。
    ⚠ 逐帧统计会引入帧间闪烁，演示时若抖动可改成冻结常数。
    """
    xl = to_luma(x)
    return ((y - y.mean()) / y.std().clamp_min(1e-5) * xl.std() + xl.mean()).clamp(0.0, 1.0)


def color_stats(t: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    """[B,3,H,W] 的 RGB 均值与协方差（按全部像素统计，不分局部）。

    输入可以是单张 [1,3,H,W]，也可以是一批——批量时统计量在 batch 上合并，
    这正是"内容图集的整体颜色分布"。
    """
    f = t.reshape(3, -1).double()
    mu = f.mean(dim=1)
    d = f - mu[:, None]
    cov = d @ d.T / max(f.shape[1] - 1, 1)
    return mu, cov


def _sqrtm(m: torch.Tensor, eps: float = 1e-6) -> torch.Tensor:
    """对称半正定矩阵的平方根（特征分解，3×3 够快）。"""
    w, v = torch.linalg.eigh(m)
    return (v * w.clamp_min(eps).sqrt()) @ v.T


def match_color(style: torch.Tensor, mu_c: torch.Tensor, cov_c: torch.Tensor,
                mode: str = "std", clamp: bool = True) -> torch.Tensor:
    """把**风格图**的颜色分布搬运到内容图那一侧。

        x' = A (x − μ_s) + μ_c

    **为什么这条能治"不失真"**：`Gram = 协方差 + μμᵀ`，那个 μμᵀ 项是 DC 分量
    （≈全局色调）。优化器最省力的下降方向就是匹配它——于是输出变成一层"色调偏移"，
    内容结构被牺牲。本工程实测：`style × 1e5` 下风格项是内容项的 179 倍，
    输出是一团红色，SSIM 0.23。

    **把风格图的颜色统计先搬到内容图那一侧之后，风格项就只剩纹理可学**——
    色调不再是它的活儿，也就不再需要用"牺牲结构"去换。

    mode —— **这一档是数值稳定性问题，必须显式选**：
      "mean" —— 只搬均值，`A = I`。**最稳**，等价于消掉 Gram 里的 μμᵀ 项本身。
      "std"  —— 均值 + 逐通道标准差（对角阵）。**默认**。能去掉大部分配色信息，
                又不碰通道间的相关性，所以不会放大噪声。
      "full" —— Gatys 原始口径 `A = cov_c^(1/2)·cov_s^(−1/2)`，连通道相关性一起搬。
                ⚠ **实测会炸**：这个方法要求风格图的 RGB 协方差满秩，而单色调的画
                （《神奈川冲浪里》基本只有蓝＋白）协方差接近**奇异**，
                `cov_s^(−1/2)` 在近零特征方向上被放大到发散。
                本工程实测结果：均值对上了（0.431 vs 内容 0.420），
                但整张图变成绿紫黄红的乱色块。**除非风格图配色本身就满秩，别用。**

    注意作用范围：**只改送给 VGG 的那张风格图**，不改内容图，不改网络，
    推理期零代价。

    `clamp`：仿射变换会把像素推出 [0,1]，不夹会污染后续的 Gram 统计。
    """
    mu_s, cov_s = color_stats(style)
    f = style.reshape(3, -1).double()
    if mode == "mean":
        A = torch.eye(3, dtype=f.dtype, device=f.device)
    elif mode == "std":
        sd_c = cov_c.diagonal().clamp_min(1e-12).sqrt()
        sd_s = cov_s.diagonal().clamp_min(1e-12).sqrt()
        A = torch.diag(sd_c / sd_s)
    elif mode == "full":
        A = _sqrtm(cov_c) @ torch.linalg.inv(_sqrtm(cov_s))
    else:
        raise ValueError(f"未知的 color-match 模式: {mode}")
    out = (A @ (f - mu_s[:, None]) + mu_c[:, None]).reshape_as(style).float()
    return out.clamp(0.0, 1.0) if clamp else out


def transfer_matrix(mu_src, cov_src, mu_dst, cov_dst, mode: str = "std"):
    """求把 `src` 颜色分布映射到 `dst` 的仿射 (M, b)：x' = M x + b。

    用 **std 模式**（对角阵）而不是完整协方差：完整协方差要求 `cov_src` 满秩，
    而单色调的画（浮世绘基本只有蓝＋白）接近奇异，`cov^(−1/2)` 会发散——
    实测直接炸成绿紫黄红的乱色块。对角阵没有这个问题。
    """
    if mode == "mean":
        M = torch.eye(3, dtype=mu_src.dtype, device=mu_src.device)
    elif mode == "std":
        sd_d = cov_dst.diagonal().clamp_min(1e-12).sqrt()
        sd_s = cov_src.diagonal().clamp_min(1e-12).sqrt()
        M = torch.diag(sd_d / sd_s)
    else:
        raise ValueError(f"未知模式 {mode!r}（只支持 mean / std）")
    return M, mu_dst - M @ mu_src


def blend_chroma(x: torch.Tensor, M: torch.Tensor, b: torch.Tensor,
                 alpha: float) -> torch.Tensor:
    """把颜色按 α 比例推向目标色域：x' = ((1−α)I + αM)·x + αb。

    **整条色彩混合就是逐像素 3×3 矩阵 + 偏置，等价于一个 1×1 卷积**——
    加速器本来就在做卷积，硬件代价接近零。矩阵可离线算好存成常数。
    """
    eye = torch.eye(3, dtype=M.dtype, device=M.device)
    # color_stats 内部用 double 求逆更稳，这里回到图像的 dtype
    Mb = ((1.0 - alpha) * eye + alpha * M).to(x.dtype)
    bb = (alpha * b).to(x.dtype)
    f = x[0].permute(1, 2, 0)                     # [H,W,3]
    out = f @ Mb.T + bb
    return out.permute(2, 0, 1).unsqueeze(0).clamp(0.0, 1.0)


def resolve_style_pool(spec: str) -> list[Path]:
    """把 --style 参数解析成一**组**风格图。

    支持三种写法：
        1. 目录        —— 取目录下所有图片（多图风格，本项目的推荐用法）
        2. 通配符      —— 如 "ukiyoe_*.jpg"
        3. 短名/文件   —— 退回单图模式（`data/styles/<名>.jpg` 或直接路径）

    返回按文件名排序的列表，保证可复现。
    """
    p = Path(spec)
    exts = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}

    if p.is_dir():
        files = sorted(f for f in p.iterdir() if f.suffix.lower() in exts)
        if not files:
            raise FileNotFoundError(f"目录里没有图片：{p}")
        return files

    if any(ch in spec for ch in "*?["):
        files = sorted(Path().glob(spec)) if not Path(spec).is_absolute() \
            else sorted(Path(spec).parent.glob(Path(spec).name))
        files = [f for f in files if f.suffix.lower() in exts]
        if not files:
            raise FileNotFoundError(f"通配符没匹配到图片：{spec}")
        return files

    # 单图：沿用原来的解析（短名 -> data/styles/<名>.jpg）
    if p.exists():
        return [p]
    cand = DATA / "styles" / f"{spec}.jpg"
    if cand.exists():
        return [cand]
    raise FileNotFoundError(
        f"找不到风格图 {spec!r}，现有：{[q.stem for q in style_paths()]}")


def style_paths() -> list[Path]:
    return sorted((DATA / "styles").glob("*.jpg"))
