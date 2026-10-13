"""蒸馏训练：让改D 学 AnimeGANv2 的输出，而不是学 Gram 统计量。

    python -m train.distill --tag D_distill --steps 4000

## 为什么换目标

原来的训练用 **Gram 损失**——它匹配的是颜色/纹理的**低阶统计量**，
**学不到"怎么画"**。米山舞和浮世绘两次都栽在这儿：输出的永远是"纹理"，不是"线稿"。

**AnimeGANv2（2.14M 参数）产出的才是真正的「平涂 + 描边」。** 我们跑不动它，
但可以在 PC 上用它生成目标图，让改D **直接学它的输出**：

    教师负责"怎么画"，学生负责"复现"

目标图在 `data/teacher_paprika/`（`tools/teacher.py` 生成）。

## ⚠ 2026-09-28 结论：这条线已放弃，别再跑

`D_distill`（4K 步）和 `D_distill_long`（12K 步）都跑完了，**赌输了**：
12K 步的输出仍然是糊掉的橄榄黄，既没有干净边缘也没有笔触。
**17K 参数学"统计量"够，学"具体画法"不够**——教师给的是高维目标，
学生根本表达不了，训多久都只是逼近它的调色板。

要给这条线机会，前提是**把网络放大约 8 倍**，而那意味着放弃 720p30。
决策记录见 `runs/README.md` 与 `../README.md` 已知的坑第 8 条。

**真正修掉"出滤镜不出笔触"的是 `train.py --gram-centered`，不是蒸馏。**

## ⚠ 期望管理（保留原文）

**126 倍压缩是硬赌。** 学生大概能保住调色板和大致构图，
**线条多半还是学不出来**——17K 参数表达不了线条。
如果这版仍然不像，说明 17K 这条路到头了，
下一步只能砍掉 720p30、把网络放大 8 倍。
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import torch
import torch.nn.functional as F
from PIL import Image
from torch.utils.data import DataLoader, Dataset

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from train.data import DATA, is_y_only, to_tensor  # noqa: E402
from train.model import build, num_params  # noqa: E402
from train.train import RUNS, pick_device, save_png  # noqa: E402

TEACHER = DATA / "teacher_paprika"


class Pairs(Dataset):
    """(内容图, 教师输出) 成对，随机裁同一块。

    ⚠ **必须裁同一块**——教师输出是内容图经网络得到的，两者空间上严格对齐，
    裁错了就是让网络学"错位的映射"，会训出一团糊。
    """

    def __init__(self, crop: int = 256, size: int = 512, steps: int = 10 ** 9, seed: int = 0):
        self.crop, self.size, self.steps = crop, size, steps
        self.rng = torch.Generator().manual_seed(seed)
        self.files = sorted(f for f in TEACHER.iterdir() if f.suffix == ".png")

    def __len__(self) -> int:
        return self.steps

    def __getitem__(self, _):
        for _try in range(8):
            f = self.files[torch.randint(len(self.files), (1,), generator=self.rng).item()]
            src = DATA / "content" / f"{f.stem}.jpg"
            if not src.exists():
                continue
            a = Image.open(src).convert("RGB").resize((self.size, self.size), Image.BICUBIC)
            b = Image.open(f).convert("RGB")
            if b.size != (self.size, self.size):
                b = b.resize((self.size, self.size), Image.BICUBIC)
            x = torch.randint(0, self.size - self.crop + 1, (2,), generator=self.rng)
            y = torch.randint(0, self.size - self.crop + 1, (2,), generator=self.rng)
            box = (x[0].item(), y[0].item(), x[0].item() + self.crop, y[0].item() + self.crop)
            return to_tensor(a.crop(box)), to_tensor(b.crop(box))
        raise RuntimeError("找不到配对数据，先跑 python -m tools.teacher")


def main() -> int:
    ap = argparse.ArgumentParser(description="蒸馏：学 AnimeGANv2 的输出")
    ap.add_argument("--net", default="改D: 1/8ch 3res 3x3")
    ap.add_argument("--tag", default="D_distill")
    ap.add_argument("--steps", type=int, default=4000)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--crop", type=int, default=256)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--loss", choices=("l1", "mse"), default="l1")
    ap.add_argument("--sample-every", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    device = pick_device()
    outdir = RUNS / args.tag
    outdir.mkdir(parents=True, exist_ok=True)

    net = build(args.net, in_affine=True).to(device)
    ds = Pairs(crop=args.crop, seed=args.seed)
    loader = DataLoader(ds, batch_size=args.batch, num_workers=0, drop_last=True)
    it = iter(loader)
    opt = torch.optim.Adam(net.parameters(), lr=args.lr)

    ref_x, ref_y = next(iter(DataLoader(ds, batch_size=1, num_workers=0)))
    ref_x, ref_y = ref_x.to(device), ref_y.to(device)
    save_png(ref_x, outdir / "ref_content.png")
    save_png(ref_y, outdir / "ref_teacher.png")

    print(f"网络 {args.net} ({num_params(net):,} 参数)")
    print(f"目标 {len(ds.files)} 张教师输出（{TEACHER}）")
    print(f"设备 {device}   输出 {outdir}")

    # ⚠ 教师（AnimeGANv2）固定是 3 通道。学生如果是**亮度域**网络（改D-Y），
    # "该学教师的什么"没有定义过——是学教师的 Y？还是先把教师的色度也搬过来？
    # 这里**明确拒绝**，而不是让它跑出一个没人验证过的东西。
    if is_y_only(net):
        print("蒸馏的学生是亮度域网络（ci=1），但教师是 3 通道的 AnimeGANv2。"
              "「亮度域学生该学教师的哪个分量」没有定义过，拒绝执行。"
              "（这条线本身也已在文件头标记为放弃。）")
        return 2

    t0 = time.time()
    for step in range(1, args.steps + 1):
        x, t = next(it)
        x, t = x.to(device), t.to(device)
        y = net(x)
        # 网络输出可能比输入大几像素（编码器 ceil、解码器定长 ×2），裁回输入尺寸
        y = y[:, :, :t.shape[2], :t.shape[3]]
        loss = F.l1_loss(y, t) if args.loss == "l1" else F.mse_loss(y, t)

        opt.zero_grad(set_to_none=True)
        loss.backward()
        opt.step()

        if step % 50 == 0 or step == 1:
            sps = step / max(time.time() - t0, 1e-9)
            print(f"step {step:>5}/{args.steps}  {args.loss} {loss.item():.5f}  "
                  f"| {sps:.1f} step/s  {time.time()-t0:.0f}s", flush=True)

        if step % args.sample_every == 0 or step == args.steps:
            net.eval()
            with torch.no_grad():
                save_png(net(ref_x), outdir / f"step_{step:05d}.png")
                save_png(torch.cat([ref_x, ref_y, net(ref_x)], dim=3),
                         outdir / f"cmp_{step:05d}.png")
            net.train()
            torch.save({"step": step, "args": vars(args), "state_dict": net.state_dict()},
                       outdir / "net.pt")

    print(f"\n完成，用时 {time.time()-t0:.0f}s，权重 {outdir/'net.pt'}")
    print(f"对照图（内容|教师|学生）见 {outdir}/cmp_{args.steps:05d}.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
