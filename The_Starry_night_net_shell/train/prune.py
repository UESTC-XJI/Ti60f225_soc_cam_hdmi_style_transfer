"""通道剪枝：把一个大网络的权重“前缀”搬进一个更窄的同构网络。

    python -m train.prune --ckpt runs/final/D_sw1e5/net.pt \
        --net "改D: cap8 3res 3x3" --out runs/_prune_cap8
    python -m train.train --net "改D: cap8 3res 3x3" --init runs/_prune_cap8 \
        --steps 2000 --lr 5e-4 --tag D_cap8_ft

## 剪的是什么

只剪**输出通道**，而且保留每个卷积的**前 N 个通道**（通道前缀），
不做重要性排序、不重排通道：

    新卷积 W' = W[:co_new, :ci_new, :, :]

这样做是刻意的。硬件上权重按行连续摆放、总线按固定宽度取数，
通道重排（把“重要”的通道挑出来重新编号）会让部署端多一遍 gather，
省下的算力又还回去了。通道前缀则保证小网络的每一行仍是原权重的一段前缀，
换网络时下游格式、行宽、bank 布局都不用动。

代价也很明确：剪掉的通道不一定是最不重要的，所以**剪完必须微调**
（`train.train --init ...`），否则画质会明显下降。实测非重训的 1/16ch
通道前缀剪枝会出“黑底蓝边”，2K 步微调后才回到可用水平。

## 适用范围

`train.model.FNSNet` 的通道数按 `mult` / `cap` 单调缩放，天然满足
“小网络的每个通道都在大网络里存在且编号相同”。脚本会逐层检查形状，
不满足就报错而不是悄悄截断——**静默的形状裁剪是这类脚本最危险的失败模式**。
亮度域网络（ci=1）与 RGB 网络（ci=3）不能互剪，脚本也会直接拒绝。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import torch  # noqa: E402

from train.model import BUILDERS, build, num_params  # noqa: E402


def infer_in_affine(state: dict[str, torch.Tensor]) -> bool:
    """从 state_dict 判断 InstanceNorm 有没有 affine 参数。

    比读 ckpt["args"] 可靠：老 ckpt 可能没有这个字段，
    而有没有 `norm.weight` 是结构事实。
    """
    return any(k.endswith("norm.weight") for k in state)


def pick_prefix(dst: torch.Tensor, src: torch.Tensor, key: str) -> torch.Tensor:
    """取 src 的通道前缀，形状对齐 dst。

    只允许**每个维度都变小或相等**。卷积权重是 [co, ci, kh, kw]，
    因此输出和输入通道会同时取前缀；逐通道的 bias/norm 参数只有第一维。
    """
    if dst.shape == src.shape:
        return src.clone()
    if dst.dim() != src.dim():
        raise ValueError(f"{key}: 维度不同，{tuple(src.shape)} -> {tuple(dst.shape)}")
    if any(d > s for d, s in zip(dst.shape, src.shape)):
        raise ValueError(
            f"{key}: 目标形状 {tuple(dst.shape)} 比源 {tuple(src.shape)} 大，"
            "剪枝只能让通道变窄（方向反了？）")
    # **只允许通道维（前两维）变窄**。卷积核的空间尺寸必须一致——
    # 否则会悄悄把 9x9 核截成左上角 3x3，形状检查却完全通过。
    if dst.shape[2:] != src.shape[2:]:
        raise ValueError(
            f"{key}: 卷积核/空间形状必须一致，{tuple(src.shape)} -> {tuple(dst.shape)}")
    return src[tuple(slice(0, d) for d in dst.shape)].clone()


def prune_state(src_state: dict[str, torch.Tensor],
                dst_net: torch.nn.Module) -> dict[str, torch.Tensor]:
    """按 dst_net 的参数名和形状，从 src_state 取通道前缀。"""
    dst_state = dst_net.state_dict()
    out: dict[str, torch.Tensor] = {}
    missing = [k for k in dst_state if k not in src_state]
    if missing:
        raise KeyError(f"源 ckpt 缺少这些参数：{missing}")

    # enc1 直接吃图像。输入通道不同意味着 RGB 与亮度域互剪——通道前缀没有意义。
    k0 = "enc1.conv.weight"
    if k0 in dst_state and src_state[k0].shape[1] != dst_state[k0].shape[1]:
        raise ValueError(
            f"输入通道不一致：源 {src_state[k0].shape[1]}，目标 {dst_state[k0].shape[1]}。"
            "RGB 网络与亮度域网络不能互剪。")

    for k, d in dst_state.items():
        out[k] = pick_prefix(d, src_state[k], k)
    return out


def verify_forward(net: torch.nn.Module, device: torch.device) -> None:
    """跑一次前向，确认剪完的权重没有把网络弄成 NaN/Inf。

    eval() 下 InstanceNorm 用运行统计量（训练时累积的），
    这与部署/出图路径一致，也能覆盖到所有层。
    """
    net.eval()
    ci = getattr(net, "ci", 3)
    x = torch.rand(1, ci, 64, 64, device=device)
    with torch.no_grad():
        y = net(x)
    if not torch.isfinite(y).all():
        raise RuntimeError("前向输出含 NaN/Inf，剪枝结果不可用")
    print(f"自检   前向 OK，输出 {tuple(y.shape)}，范围 "
          f"[{y.min().item():.3f}, {y.max().item():.3f}]")


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser(
        description="通道前缀剪枝：从大网络 ckpt 生成同构小网络 ckpt（需随后微调）")
    ap.add_argument("--ckpt", type=Path, required=True,
                    help="源 ckpt（net.pt 或所在目录）")
    ap.add_argument("--net", default="改D: cap8 3res 3x3", choices=list(BUILDERS),
                    help="目标网络结构（决定保留多少通道）")
    ap.add_argument("--out", type=Path, required=True,
                    help="输出目录，写成 <out>/net.pt")
    ap.add_argument("--overwrite", action="store_true",
                    help="输出已存在时覆盖（默认拒绝）")
    args = ap.parse_args()

    src_path = args.ckpt / "net.pt" if args.ckpt.is_dir() else args.ckpt
    blob = torch.load(src_path, map_location="cpu", weights_only=False)
    src_state = blob["state_dict"] if isinstance(blob, dict) and "state_dict" in blob else blob
    if not isinstance(src_state, dict):
        raise TypeError(f"{src_path} 不是可识别的 ckpt（缺 state_dict）")

    if src_path.resolve() == (args.out / "net.pt").resolve():
        raise ValueError("--ckpt 与 --out 指向同一个文件，拒绝原地覆盖")

    if (args.out / "net.pt").exists() and not args.overwrite:
        raise FileExistsError(
            f"{args.out / 'net.pt'} 已存在。加 --overwrite 才会覆盖（防止误删已有实验）")

    in_affine = infer_in_affine(src_state)
    net = build(args.net, in_affine=in_affine)

    src_params = sum(v.numel() for v in src_state.values())
    print(f"源      {src_path}")
    print(f"        {src_params:,} 参数（含 InstanceNorm）")
    print(f"目标    {args.net}")
    print(f"        {num_params(net):,} 参数（含 InstanceNorm）")
    print(f"IN affine  {in_affine}")

    new_state = prune_state(src_state, net)
    net.load_state_dict(new_state)

    # 逐层打印“从多少 -> 多少”，让剪枝比例肉眼可查。
    for k, d in net.state_dict().items():
        s = src_state[k]
        if d.shape != s.shape:
            print(f"  {k:<24} {tuple(s.shape)} -> {tuple(d.shape)}")

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    verify_forward(net.to(device), device)

    args.out.mkdir(parents=True, exist_ok=True)
    src_args = dict(blob.get("args", {})) if isinstance(blob, dict) else {}
    src_args.update({"net": args.net, "in_affine": in_affine})
    torch.save({
        "step": 0,
        "args": src_args,
        "state_dict": net.state_dict(),
        "pruned_from": str(src_path),
    }, args.out / "net.pt")

    print(f"\n完成 → {args.out / 'net.pt'}")
    print("下一步必须微调，否则画质会明显下降：")
    print(f"  python -m train.train --net {args.net!r} --init {args.out} "
          "--steps 2000 --lr 5e-4 --tag <名字>")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
