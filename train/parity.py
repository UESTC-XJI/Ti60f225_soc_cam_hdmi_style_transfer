"""对账：PyTorch 实现 vs stnet 成本模型。

成本模型是整个架构决策的依据。一旦 `train/model.py` 实现的网络和
`stnet/archs.py` 描述的网络不是同一个东西，ARCH-DECISION.md 里所有数字就都失效了，
而且这种错误在训练日志里完全看不出来（loss 照样下降）。

所以这里逐项比：参数量、各输入尺寸下的 MAC、输出空间尺寸。
名字直接复用 `candidate_factories()` 的键，避免两边各起一套名导致对错人。

    python -m train.parity
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from stnet import candidate_factories  # noqa: E402
from stnet.spec import NetSpec  # noqa: E402
from train.model import BUILDERS, build, norm_params, num_macs, num_params  # noqa: E402

SIZES = [(480, 640), (720, 1280)]


def check(name: str) -> list[str]:
    """返回该网络的失败项；空列表表示对账通过。"""
    fails: list[str] = []
    net = build(name)
    factories = candidate_factories()

    # 只比卷积部分：成本模型算的是 ci*co*k*k + co，不含 IN 的 affine。
    # IN 的那部分单独报，见 main()——它可折叠，不是额外硬件开销。
    conv_params = num_params(net) - norm_params(net)

    for h, w in SIZES:
        spec: NetSpec = factories[name](h, w)

        got_p, want_p = conv_params, spec.params
        if got_p != want_p:
            fails.append(f"@{h}x{w} 卷积参数量 {got_p:,} != 成本模型 {want_p:,}")

        got_m, want_m = num_macs(net, h, w), spec.macs_per_frame
        if got_m != want_m:
            rel = abs(got_m - want_m) / max(want_m, 1)
            fails.append(f"@{h}x{w} MAC {got_m:,} != 成本模型 {want_m:,}（差 {rel:.2%}）")

        # 输出空间尺寸：网络末端必须落在输入同尺寸（风格迁移是 image-to-image）
        # ⚠ 通道数按网络自身取，**不能写死 3**——亮度域网络（改D-Y）是 ci=1。
        import torch
        cin = getattr(net, "ci", 3)
        with torch.no_grad():
            out = net(torch.zeros(1, cin, h, w))
        if tuple(out.shape[-2:]) != (h, w):
            fails.append(f"@{h}x{w} 输出尺寸 {tuple(out.shape[-2:])} != 输入尺寸")

    return fails


def main() -> int:
    print("=" * 76)
    print("PyTorch 实现 <-> stnet 成本模型 对账")
    print("=" * 76)
    bad = 0
    for name in BUILDERS:
        fails = check(name)
        net = build(name)
        nn_p = norm_params(net)
        status = "OK" if not fails else "MISMATCH"
        print(f"\n{name:<26} 卷积 {num_params(net) - nn_p:>9,} + IN affine {nn_p:>4,} "
              f"= {num_params(net):>9,} 参数  [{status}]")
        for f in fails:
            print(f"    !! {f}")
        bad += len(fails)
    print()
    print("对账通过" if bad == 0 else f"对账失败：{bad} 项不一致——先修这个再训练")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
