"""用 AnimeGANv2 当"教师"，给蒸馏训练生成目标图。

    python -m tools.teacher --limit 5            # 先看效果
    python -m tools.teacher --limit 800          # 正式生成训练集

## 为什么要这么做

我们的改D 只有 **17K 参数**，风格迁移用的是 **Gram 损失**——它只匹配
颜色/纹理的**低阶统计量**，学不到"怎么画"。米山舞和浮世绘两次都栽在这上面。

**AnimeGANv2 有 2.14M 参数**（是改D 的 126 倍），它产出的才是真正的
「平涂色块 + 干净线条」。**我们跑不动它，但可以让它当老师**：
它在 PC 上生成目标图，改D 去学**它的输出**——而不是学 Gram 统计量。

    教师负责"怎么画"，学生负责"复现"

## ⚠ 2026-09-28 结论：整条蒸馏线已放弃

教师图本身没问题（AnimeGANv2 出的确实是"平涂＋描边"），**问题在学生**：
17K 参数表达不了那种具体画法，12K 步后仍然是糊的橄榄黄。
`runs/D_distill*` 已归档进 `runs/_intermediate/`。**别再重新生成教师图了**——
`data/teacher_paprika/`（250MB）留着不再用。详见 `../README.md` 已知的坑第 8 条。

## ⚠ 期望管理（保留原文）

**126 倍压缩是硬赌。**改D 大概能保住调色板和大致构图，
**线条多半还是学不出来**（17K 参数表达不了线条）。
如果这一版仍然不像，那就说明 17K 这条路到头了——
下一步只能砍掉 720p30、把网络放大 8 倍。

权重来源：`bryandlee/animegan2-pytorch` 的 `weights/paprika.pt`（GitHub 直连，
HuggingFace 在本机被墙）。模型定义也来自同一个仓库。
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

import torch
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from train.data import DATA, to_batch  # noqa: E402
from train.train import pick_device  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
AG2_DEF = Path(r"C:\Users\ZHAOJI~1\AppData\Local\Temp\ag2.py")  # 从 GitHub 下的模型定义
WEIGHTS = ROOT / "models" / "animegan2_paprika.pt"


def load_teacher(device: torch.device):
    """载入 AnimeGANv2 生成器。

    模型定义是从 GitHub 单独下的（`model.py`），不 import 那个仓库——
    避免引入它的一堆依赖。`importlib` 按路径加载即可。
    """
    if not AG2_DEF.exists():
        raise FileNotFoundError(
            f"缺模型定义 {AG2_DEF}\n"
            "重新下：curl -sSL -o %TEMP%/ag2.py "
            "https://raw.githubusercontent.com/bryandlee/animegan2-pytorch/main/model.py")
    spec = importlib.util.spec_from_file_location("ag2", AG2_DEF)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    net = mod.Generator()
    net.load_state_dict(torch.load(WEIGHTS, map_location="cpu"))
    return net.to(device).eval()


def main() -> int:
    ap = argparse.ArgumentParser(description="AnimeGANv2 教师模型生成目标图")
    ap.add_argument("--input", type=Path, default=DATA / "content")
    ap.add_argument("--out", type=Path, default=DATA / "teacher_paprika")
    ap.add_argument("--limit", type=int, default=5)
    ap.add_argument("--size", type=int, default=512, help="网络按 256 训练，但 512 更清晰")
    args = ap.parse_args()

    device = pick_device()
    net = load_teacher(device)
    args.out.mkdir(parents=True, exist_ok=True)

    files = sorted(f for f in args.input.iterdir()
                   if f.suffix.lower() in {".jpg", ".jpeg", ".png"})[: args.limit]
    for f in files:
        img = Image.open(f).convert("RGB").resize((args.size, args.size), Image.BICUBIC)
        x = to_batch(img).to(device)
        with torch.no_grad():
            y = net(x)
        out = y[0].permute(1, 2, 0).clamp(0, 1).cpu().numpy()
        Image.fromarray((out * 255).astype("uint8")).save(args.out / f"{f.stem}.png")
        print(f"  {f.name} -> {args.out / (f.stem + '.png')}")

    print(f"\n完成 {len(files)} 张，输出在 {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
