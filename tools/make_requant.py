"""逐层"收尾"算子的定点参数 + 定点参考实现（WBS 4.2 / 计划阶段 2）。

    python -m tools.make_requant D_sw1e5 -o ../hw/epilogue/vectors/D_sw1e5

卷积核出 int32 累加器之后，要经过 **再量化 + ReLU + 残差相加** 才变成下一层的输入：

    浮点：q = clamp( round( relu?(acc · s_a · s_w + x · s_x) / s_out ) )
    定点：q = clamp( RHE( relu?(acc)·M_q + relu?(x)·M_id , shift ) )

`M_q / 2^shift ≈ s_a·s_w / s_out`、`M_id / 2^shift ≈ s_x / s_out`（`x` 是残差块的恒等支）。

## ⚠ 三个必须按"下一层"取、不能按"本层"取的东西

1. **ReLU 要不要做** —— 模型里 ReLU 是显式的（`y = relu(conv(x))`），
   有 ReLU 的层后面**必然**跟一个无符号层；反过来，下一层是**有符号**的
   （残差相加之后）就说明这一层后面没 ReLU。所以判据是**下一层的 qrange 是否有符号**。
   按本层的 qrange 判的话，`res.*.c2` 和 `out` 会被**错误地做 ReLU**。
2. **饱和范围** —— 链上真正把值夹住的是下一层的 pre-hook，用的是下一层的 qrange。
3. **s_out** —— 也是下一层的激活 scale（`golden.json` 的 `out_scale` 就是这个）。

## ⚠ RHE 必须是**四舍六入五成双**

`torch.round` 用 half-to-even。写成四舍五入（`.5` 一律进位），落在 `.5` 上的像素会
**系统性偏 1**。参考实现和 RTL 必须同一条式子。

## ⚠ 靶子：RTL == 本文件的定点参考（逐位），**不是** == PyTorch

`golden` 的 `_acc` 是**量化域**的累加器（用 int8 权重算的），模型前向里的 `y` 是**真浮点
卷积**（用原浮点权重）。两者差一个权重量化残差：再量化时它没翻转舍入，**残差相加会把它
放大**（实测 res.0 块：不加恒等支 2487/4096 不符，加了降到 300）。所以判据只能是
"RTL == 定点参考"；和模型的偏差另行统计，喂给阶段 4 的 PSNR。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent

RES_RE = re.compile(r"^res\.(\d+)\.c2\.conv$")


def _read_hex(path: Path, signed_bytes: bool, width: int) -> np.ndarray:
    vals = [int(line, 16) for line in path.read_text(encoding="utf-8").split() if line]
    a = np.array(vals, dtype=np.int64)
    if width == 2:
        a = a & 0xFF
        return np.where(a >= 128, a - 256, a) if signed_bytes else a
    a = a & 0xFFFFFFFF
    return np.where(a >= 2 ** 31, a - 2 ** 32, a)


def rhe_shift(n: np.ndarray, shift: int) -> np.ndarray:
    """四舍六入五成双的算术右移 —— RTL 必须实现成一模一样。

        q = (n + 2^(shift-1) - 1 + ((n >> shift) & 1)) >> shift
    """
    if shift <= 0:
        return n.copy()
    half = np.int64(1) << np.int64(shift - 1)
    return (n + half - np.int64(1) + ((n >> shift) & np.int64(1))) >> shift


def pick_shift(ratios: list[np.ndarray], m_bits: int = 31) -> int:
    """给一组 ratio 选**公共** shift（残差两支必须同一分母，才能"先加后舍"一次）。"""
    lim = (1 << (m_bits - 1)) - 1
    rmax = max(float(np.max(np.abs(r))) for r in ratios)
    shift = 62
    while shift > 0 and rmax * (2.0 ** shift) > lim:
        shift -= 1
    return shift


def fixed_ref(acc: np.ndarray, mq: np.ndarray, ident: np.ndarray | None,
              mid: np.ndarray, shift: int, relu: bool,
              qlo: int, qhi: int) -> np.ndarray:
    """定点收尾的**参考实现**：`clamp(RHE(relu?(acc)·M_q + relu?(x)·M_id, shift))`。

    两支**先加后舍**（只舍入一次）—— 和模型 `round((x+y)/s_out)` 的形状一致。
    """
    a = acc.astype(np.int64)
    if relu:
        a = np.maximum(a, np.int64(0))
    p = a * mq.reshape(-1, 1, 1)
    if ident is not None:
        xi = ident.astype(np.int64)
        if relu:
            xi = np.maximum(xi, np.int64(0))
        p = p + xi * mid.reshape(-1, 1, 1)
    return np.clip(rhe_shift(p, shift).reshape(acc.shape), qlo, qhi)


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="逐层收尾算子的定点参数")
    ap.add_argument("tag")
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("--deploy", type=Path, default=None)
    args = ap.parse_args()

    deploy = args.deploy or (ROOT.parent / "deliverable" / args.tag / "deploy")
    spec = json.loads((deploy / "spec.json").read_text(encoding="utf-8"))
    gdir = deploy / "golden"
    gj = json.loads((gdir / "golden.json").read_text(encoding="utf-8"))
    layers, gl = spec["layers"], gj["layers"]
    outdir = args.out
    outdir.mkdir(parents=True, exist_ok=True)

    table = []
    for i, (L, g) in enumerate(zip(layers, gl)):
        cout = int(L["cout"]); cin = int(L["cin"])
        hout, wout = int(g["acc_shape"][2]), int(g["acc_shape"][3])
        # ---- 全部按**下一层**取 ----
        if i + 1 < len(layers):
            nxt, gn = layers[i + 1], gl[i + 1]
            s_out = float(gn["out_scale"]) if False else float(nxt["activation_scale_in"])
            qlo, qhi = int(nxt["activation_qrange"][0]), int(nxt["activation_qrange"][1])
            relu = (qlo >= 0)
        else:                                  # 最后一层没有下一层，用自己
            s_out = float(g["out_scale"])
            qlo, qhi = int(L["activation_qrange"][0]), int(L["activation_qrange"][1])
            relu = False
        # ⚠ 上一行的 s_out 必须等于本层的 out_scale（同一个量），对不上就是取错了层
        assert abs(float(g["out_scale"]) - s_out) < 1e-12, \
            f"L{i}: out_scale 与下一层的 in_scale 不一致，取层取错了"

        acc = _read_hex(gdir / g["acc_file"], True, 8).reshape(cout, hout, wout)
        w = np.array(L["weight_scale"], dtype=np.float64)
        sa = float(L["activation_scale_in"])

        # ---- 残差恒等支（只有 res.<k>.c2 有）----
        m = RES_RE.match(g["name"])
        ident = None
        if m:
            k = int(m.group(1))
            c1 = layers[i - 1]                       # 同一块的 c1
            g1 = gl[i - 1]
            h1, w1 = int(g1["in_shape"][2]), int(g1["in_shape"][3])
            xpad = _read_hex(gdir / g1["in_file"], c1["activation_signed"], 2
                             ).reshape(int(c1["cin"]), h1, w1)
            ident = xpad[:, 1:1 + hout, 1:1 + wout]  # 裁掉 pad=1
            sx = float(c1["activation_scale_in"])
            ratio_q = sa * w / s_out
            ratio_i = np.full(cout, sx / s_out)
        else:
            ratio_q = sa * w / s_out
            ratio_i = np.zeros(cout)

        shift = pick_shift([ratio_q, ratio_i])
        mq = np.round(ratio_q * (2.0 ** shift)).astype(np.int64)
        mi = np.round(ratio_i * (2.0 ** shift)).astype(np.int64)

        q = fixed_ref(acc, mq, ident, mi, shift, relu, qlo, qhi)

        # ---- 输出（位宽不同必须分文件：$readmemh 按元素宽度解析）----
        cout, cin = int(L["cout"]), int(L["cin"])
        (outdir / f"L{i}.qm").write_text(
            "".join(f"{int(v) & 0xFFFFFFFF:08x}\n" for v in
                    list(mq) + [0] * (16 - len(mq))
                    + list(mi) + [0] * (16 - len(mi)))
            + "".join(f"{int(v) & 0xFFFFFFFF:08x}\n" for v in acc.ravel())
            # ⚠ 恒等支存 **int32**，不存 int8。符号逐层不同：
            #   res.0 的恒等支来自 enc3（无符号 0..255），
            #   res.1/res.2 的来自上一个残差块（**有符号，可为负**）。
            #   存成 8 位无符号的话负值会变 127+，加进去直接饱和到 +127。
            + "".join(f"{int(v) & 0xFFFFFFFF:08x}\n"
                      for v in (ident.ravel() if ident is not None else [])),
            encoding="utf-8", newline="\n")
        idfile = outdir / f"L{i}.qi"        # 旧格式，别再产出
        if idfile.exists():
            idfile.unlink()
        # ---- 给整网引擎（net_engine）的配套：权重/偏置/本层输入 ----
        # `.w` 128 位 —— cin*9 行，每行 cout 个字节（和 conv3x3_core 的 wrow 同布局）
        # `.b` 32 位  —— 16 个偏置（超出 cout 补 0）
        # 层 0 的输入另外拷一份 `L0_in.hex`（= golden 的 input.hex，**未 pad**）。
        #   ⚠ 不能用 make_rtl_vectors 的 `L0.mem` —— 那里面是**已 pad** 的 66x66，
        #     而 net_engine 的 bank 存未 pad 张量、自己反射。张冠李戴会整体错 1 像素。
        # 真正的 int8 权重（**不是** w —— 上面那个 w 是 weight_scale 尺度）
        # ⚠ 偏置用 **b'**（= golden acc 的头 cout 个），不是 biases.hex。
        #   biases.hex 是原始的 round(b/(sa·sw))；核心的 tap 走的是**偏移域**
        #   （t' = t-128），配的偏置必须是 b + 128·Σw。两者差 128·Σw
        #   （实测 L0：0x8ad vs 0x0aad，差正好 0x200）。
        wi = _read_hex(deploy / "weights.hex", True, 2)[
            int(L["weight_offset"]):int(L["weight_offset"]) + int(L["weight_count"])]
        wi = wi.reshape(cout, cin, 3, 3).astype(np.int64)
        # b' = round(b/(sa·sw)) + 128·Σw_int         （只有偏移域才加修正项）
        # ⚠ 别去 golden 的 `*_acc.hex` 里拿 —— 那个文件**没有偏置前缀**，
        #   第一个数就是累加器（实测 -7298），拿它当偏置会静默全错。
        b0 = _read_hex(deploy / "biases.hex", True, 8)[
            int(L["bias_offset"]):int(L["bias_offset"]) + int(L["bias_count"])]
        # ⚠ 判据是**本层输入的符号性**（= spec 的 activation_signed / tap_offset），
        #   **不是** qlo（那是**输出**域，用于决定 ReLU 和饱和）。
        #   两者在 6 层上错位：L4/L6/L8 输出有符号但输入无符号（该加没加），
        #   L5/L7/L9 输出无符号但输入有符号（不该加却加了）。
        #   物理含义：核心的 tap 按 int8 读 bank，bank 里的字是"上一层写回时按
        #   **上一层输出域**异或过的"；输入无符号才需要 +128·Σw 修正。
        in_unsigned = not bool(L["activation_signed"])
        corr = 128 * wi.sum(axis=(1, 2, 3)) if in_unsigned else np.zeros(cout, dtype=np.int64)
        b = b0 + corr
        wrows = []
        for ci in range(cin):
            for kk in range(9):
                row = [int(wi[c, ci, kk // 3, kk % 3]) & 0xFF if c < cout else 0
                       for c in range(16)]
                wrows.append(row[::-1])          # 低位是 cout 0
        (outdir / f"L{i}.w").write_text(
            "".join("".join(f"{b:02x}" for b in r) + "\n" for r in wrows),
            encoding="utf-8", newline="\n")
        (outdir / f"L{i}.b").write_text(
            "".join(f"{int(v) & 0xFFFFFFFF:08x}\n" for v in
                    [int(x) for x in b] + [0] * (16 - len(b))),
            encoding="utf-8", newline="\n")
        # `.br` = **未修正**的偏置 b（= biases.hex 那份）。
        # 输入层（层 0）的 bank 直接存 q，不需要偏移修正，所以取这份。
        (outdir / f"L{i}.br").write_text(
            "".join(f"{int(v) & 0xFFFFFFFF:08x}\n" for v in
                    [int(x) for x in b0] + [0] * (16 - len(b0))),
            encoding="utf-8", newline="\n")
        if i == 0:
            (outdir / "L0_in.hex").write_text(
                (gdir / "input.hex").read_text(encoding="utf-8"),
                encoding="utf-8", newline="\n")

        # 头 10 字节：cout cin shift qlo qhi hout_hi hout_lo wout_hi wout_lo has_id
        (outdir / f"L{i}.qo").write_text(
            "".join(f"{v & 0xFF:02x}\n" for v in
                    [cout, cin, shift, qlo & 0xFF, qhi & 0xFF,
                     (hout >> 8) & 0xFF, hout & 0xFF, (wout >> 8) & 0xFF, wout & 0xFF,
                     1 if ident is not None else 0])
            + "".join(f"{int(v) & 0xFF:02x}\n" for v in q.ravel()),
            encoding="utf-8", newline="\n")

        # ---- 和"浮点链"的偏差（早预警，喂阶段 4 的 PSNR）----
        fq = acc.astype(np.float64) * (sa * w)[:, None, None]
        if ident is not None:
            fq = fq + ident.astype(np.float64) * float(layers[i - 1]["activation_scale_in"])
        if relu:
            fq = np.maximum(fq, 0.0)
        qf = np.clip(np.round(fq / s_out), qlo, qhi).astype(np.int64)
        n_diff = int((q != qf).sum()); maxd = int(np.abs(q - qf).max()) if q.size else 0

        table.append({"index": i, "name": g["name"], "cout": cout, "cin": cin,
                      "shift": shift, "relu": bool(relu), "qlo": qlo, "qhi": qhi,
                      "residual": ident is not None,
                      "mq": [int(v) for v in mq], "mid": [int(v) for v in mi],
                      "vs_float_diff": n_diff, "vs_float_total": int(q.size),
                      "vs_float_maxd": maxd})
        print(f"  L{i:02d} {g['name']:<16} shift={shift:>2} relu={int(relu)} "
              f"qr=({qlo:>4},{qhi:>3}) {'残差 ' if ident is not None else '     '}"
              f"vs 浮点 {n_diff}/{q.size}")

    (outdir / "requant.json").write_text(json.dumps(
        {"tag": args.tag, "net": spec["net"], "layers": table},
        ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n{outdir}: {len(table)} 层（含残差恒等支）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
