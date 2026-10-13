"""训练期的 **STE 输出量化**：让网络学会"产出经得起量化的输出"。

    python -m train.quant          # 自检（见文件末尾）

## 为什么需要它

后处理的量化 LUT 修好了（`tools/toon.py::quantize_perceptual`），但对**现有网络**
硬量化仍然失败：网络输出里烤着风格图的纸纹颗粒和柔和渐变，量化把颗粒放大成
椒盐噪点。实测（`runs/final/D_ukiyoe_y`）：网络输出的平坦区 Y std 是
**0.098 ~ 0.170**（内容图同口径只有 0.0726），唯一 Y 级数 **400 ~ 465**。

**所以问题不是"后处理没调好"，是网络输出里没有可量化的平坦区。**
本模块就是让网络在**训练时**就知道"我的输出会被切成 K 级"，
从而主动把输出朝"大片平坦 + 边界锐利"的方向塑造。

## 关键设计：放在 `net` **外面**

`STEQuantize` 不出现在 `FNSNet` 里，而是在 `train.py` 的 `step_losses` 中显式调用：

    y = quant(net(x))

这是本设计最强的一条不变量——**机械成立**，不需要论证：

| 后果 | 为什么重要 |
|---|---|
| `net.state_dict()` 键集不变 | `--init` 热启动 `load_state_dict` 不报缺 key |
| `net.parameters()` 不变 | `train/parity.py` 的参数量对账不受影响 |
| 0 MAC | `num_macs` 的 hook 只挂 `nn.Conv2d`，根本看不见它 |
| 不在 `spec.json` / `golden/` 里 | 导出的网络仍是 12 层纯卷积；RTL 侧复用后处理链已规划的 LUT |

若塞进 `forward` 末尾，上面四条每一条都要重新论证，而且 `parity.py`
**只比参数量/MAC/输出尺寸——0 参 0 MAC 的层根本不会被它抓到**。
放在外面则从根上绕开了这个盲区。

## 为什么用 `enabled` 而不是 `self.training`

预览块（`train.py` 采样处）会先调 `net.eval()`。若量化跟随 `training` 标志，
预览就会**自动关掉量化**——正好是错的方向：训练中看到的图必须和部署时
看到的是同一张。否则就是 `README.md` 坑 #7「尺子拿错了」的同型错误。

## 与 RTL LUT 的数值契约

训练期量化的是网络输出的 1 通道 Y；部署期量化的是**合并色度之后** RGB 的
BT.601 Y。两者能等价，桥梁是 `merge_luma` 保 Y（`final_i = x_i·(y/Y_x)`
⇒ `Y_final = y`）。

**不需要传任何 scale 常数**：两边都是"把 [0,1] 的 Y 吸附到 K 级均匀网格"，
与绝对动态范围无关；中间的单调仿射（`--luma-match` 就是逐帧仿射）
只移动级的位置、不改变级的数量。

定标规则见 `FPGA-IMPL.md` §3.7-bis 与训练方案的「量化语义」一节：
**K（本模块的 `levels`）必须逐字等于部署期 `tools/toon.py --levels`，且 K ≤ 8。**
"""

from __future__ import annotations

import torch
import torch.nn as nn

from .data import quantize_perceptual_t, quantize_y


class STEQuantize(nn.Module):
    """直通估计器（STE）版本的 K 级量化。**无参数、无 buffer、0 MAC。**

    `forward` 返回 `yq`，但反向传播时梯度**原样穿到 `y`**：

        y + (yq - y).detach()

    `round()` 的导数是 0（几乎处处），不加 STE 的话梯度到这里就死了，
    网络学不到任何东西。
    """

    def __init__(self, levels: int = 0, levels_c: int = 0):
        """
        levels   : 亮度级数 K。**0 或 1 = 直通**（默认，保持历史行为，
                   也让 `--calibrate` 能拿它做开关对照）。
        levels_c : 三通道网络时的色度级数。0 = 跟随 `levels`。
                   Y-only 网络用不到（`to_luma` 之后色度那一半是白做的）。
        """
        super().__init__()
        # ⚠ 刻意用**普通 Python 属性**而不是 Parameter / register_buffer：
        # 这两样都会进 state_dict，破坏 --init 热启动的可加载性。
        self.levels = int(levels)
        self.levels_c = int(levels_c) or int(levels)
        self.enabled = True

    def extra_repr(self) -> str:
        return f"levels={self.levels}, levels_c={self.levels_c}, enabled={self.enabled}"

    def forward(self, y: torch.Tensor) -> torch.Tensor:
        if not self.enabled or self.levels <= 1:
            return y
        # **先 clamp 到 [0,1] 再量化**——这一步是语义对齐的关键，不是可选的。
        # 网络末端没有激活，输出可以是任意实数；不 clamp 的话 `round(y*(K-1))/(K-1)`
        # 会在 ℝ 上产出远多于 K 个级（自检实测：不 clamp 是 13 级而不是 6 级）。
        # 而部署路径上 y 一定是被 clamp 过的（`stylize.process` 的 .clamp(0,1)、
        # `match_luma`/`merge_luma` 各自结尾的 .clamp）——不 clamp 就对不上。
        # STE 下 clamp 不影响梯度（恒等穿过），所以这里只是把**前向值**钉对。
        yc = y.clamp(0.0, 1.0)
        # 通道数按张量本身判：ci=1（亮度域）走纯 Y 支路，否则走亮色度分离。
        yq = (quantize_y(yc, self.levels) if y.shape[1] == 1
              else quantize_perceptual_t(yc, levels_y=self.levels,
                                         levels_c=self.levels_c))
        return y + (yq - y).detach()


# ---------------------------------------------------------------- 自检

def _selfcheck() -> int:
    """断言量化层**没有**污染网络：结构、参数量、MAC、state_dict 全不变。

    这是 `train/parity.py` 之外的补充守卫。原因：`parity.py` 只比
    **参数量 / MAC / 输出尺寸**，一个 0 参 0 MAC 的层从它鼻子底下走过去
    它也不会响——而本设计恰恰就是"不改网络"。
    """
    import torch

    from .model import build, num_macs, num_params

    net_name = "改D-Y: 1/8ch 3res 3x3 亮度域"
    net = build(net_name)
    before = {k: v.clone() for k, v in net.state_dict().items()}
    p_before, m_before = num_params(net), num_macs(net, 64, 64)

    quant = STEQuantize(levels=6)
    net.eval()
    with torch.no_grad():
        raw = net(torch.rand(1, 1, 64, 64))
        yq = quant(raw)

    after = net.state_dict()
    fails: list[str] = []

    if set(after) != set(before):
        fails.append(f"state_dict 键集变了：+{set(after) - set(before)} "
                     f"-{set(before) - set(after)}")
    for k in before:
        if k in after and not torch.equal(after[k], before[k]):
            fails.append(f"state_dict[{k!r}] 的值被改了")
    if num_params(net) != p_before:
        fails.append(f"参数量变了：{p_before} → {num_params(net)}")
    if num_macs(net, 64, 64) != m_before:
        fails.append(f"MAC 变了：{m_before} → {num_macs(net, 64, 64)}")

    # 量化确实生效（不是静默直通）
    lv = torch.unique(torch.round(yq * 5)).numel()
    if lv > 6:
        fails.append(f"量化没生效：输出有 {lv} 个 Y 级（应 ≤ 6）")

    # STE：梯度必须穿过量化器
    y = torch.rand(1, 1, 32, 32, requires_grad=True)
    STEQuantize(levels=6)(y).sum().backward()
    if y.grad is None or float(y.grad.abs().sum()) == 0:
        fails.append("STE 失效：梯度没有穿过量化器")

    # 直通开关
    off = STEQuantize(levels=0)
    if not torch.equal(off(raw), raw):
        fails.append("levels=0 没有直通")

    print("=" * 64)
    print("STEQuantize 自检")
    print("=" * 64)
    print(f"  网络            {net_name}")
    print(f"  参数量          {p_before:,}（不变）")
    print(f"  MAC@64x64       {m_before:,}（不变）")
    print(f"  state_dict      {len(before)} 个键，值逐位未变")
    print(f"  量化            {lv} 个 Y 级（K=6）")
    print(f"  STE 梯度        {'穿过' if (y.grad is not None and float(y.grad.abs().sum()) > 0) else '断了'}")
    print()
    if fails:
        for f in fails:
            print(f"  [FAIL] {f}")
        return 1
    print("  自检通过 —— 量化层没有污染网络。")
    return 0


if __name__ == "__main__":
    raise SystemExit(_selfcheck())
