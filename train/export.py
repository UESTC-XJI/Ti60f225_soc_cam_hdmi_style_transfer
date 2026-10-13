"""把折叠+量化后的网络导出成 RTL 能直接吃的东西。

产物（默认 `runs/<tag>/deploy/`）：

    spec.json        逐层结构与量化参数：形状、核、stride、权重偏移/长度、
                     per-channel weight scale、激活 scale、int32 累加器最坏值
    weights.hex      全部 int8 权重按层序拼接，每行一个字节（$readmemh 友好）
    weights.json     每层在 weights.hex 里的偏移/长度，避免 RTL 侧硬编码
    golden.json      一张固定输入的逐层期望值索引
    golden/*.hex     input / L<i>_in（uint8 量化输入）/ L<i>_acc（int32 累加器）

**累加器是精确整数**：最坏情况 (ci·k·k)·255·127，最大的层也只有 ~9.3e6，
在 float32 能精确表示的整数范围（2^24 ≈ 1.67e7）之内，所以用 float 算不会失真。

**一个必须提前告诉 RTL 的约束**：残差相加要求两个分支处在同一量化 scale 上。
本导出没有强制这件事（Python 侧是浮点相加），RTL 实现时必须让恒等通路和
卷积通路共用同一条 scale，否则加法没有意义。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np  # noqa: E402
import torch  # noqa: E402
import torch.nn as nn  # noqa: E402
import torch.nn.functional as F  # noqa: E402

from train.data import (DATA, is_y_only, net_input, to_batch)  # noqa: E402
from train.deploy import (  # noqa: E402
    QMAX_A, QMAX_W, calibrate_activations, collect_in_stats, eval_images,
    fake_quant, fold_in, int32_bound, weight_scales,
)
from train.model import build  # noqa: E402
from train.stylize import fit  # noqa: E402
from train.train import pick_device  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


MANIFEST_NAME = "manifest.json"
"""完整性清单文件名。**自己不在清单里**（否则哈希自指）。"""


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_manifest(outdir: Path) -> dict:
    """对 `deploy/` 里除 `manifest.json` 外的每个文件算 sha256，写成清单。

    ## 为什么需要

    交接物是**跨机器、跨介质**传的（U 盘、网盘、比赛提交系统）。`spec.json` 和
    `weights.hex` 只要差一个字节，RTL 那边合出来的就是另一个网络，而**逐层 golden
    比对不会告诉你"传坏了"**——它只会报某几层对不上，让人去查 RTL。

    清单把「传输出错」和「实现出错」分开：先验哈希，哈希不过就别看 RTL。

    ⚠ 这是**完整性**校验，不是**真实性**校验：能改文件的人也能改清单。
    防的是传输损坏，不是防篡改。
    """
    files = {}
    for p in sorted(outdir.rglob("*")):
        if p.is_file() and p.name != MANIFEST_NAME:
            files[p.relative_to(outdir).as_posix()] = {
                "sha256": _sha256(p),
                "bytes": int(p.stat().st_size),
            }
    man = {
        "algorithm": "sha256",
        "note": "对 deploy/ 下每个文件的 sha256。manifest.json 自己不列入。"
                "用途是区分「传输出错」与「RTL 实现出错」——先过哈希再看 golden。",
        "file_count": len(files),
        "files": files,
    }
    (outdir / MANIFEST_NAME).write_text(
        json.dumps(man, ensure_ascii=False, indent=2), encoding="utf-8")
    return man


def _hex_lines(values: np.ndarray, width: int) -> str:
    """按 numpy 整数数组写 hex：width=2 -> int8/uint8，width=8 -> int32。"""
    if width == 2:
        vals = values.astype(np.int64) & 0xFF          # 二补码取低 8 位
        return "".join(f"{v:02x}\n" for v in vals.ravel())
    vals = values.astype(np.int64) & 0xFFFFFFFF        # int32 同样按二补码
    return "".join(f"{v:08x}\n" for v in vals.ravel())


def integer_records(net: nn.Module, w_scales: dict, a_scales: dict, x: torch.Tensor):
    """跑一遍整数流水线，dump 每层的 (量化输入, 整数累加器, 量化输出)。

    输入输出都用整数存，RTL testbench 可以逐层、逐元素比对，
    不像只对最终图像那样出了错也不知道错在哪一层。
    """
    order = [n for n, m in net.named_modules() if isinstance(m, nn.Conv2d)]
    # 每层输出的再量化刻度 = 下一个卷积的激活刻度；最后一层没有后继，沿用自己
    nxt = {order[i]: a_scales[order[i + 1]] for i in range(len(order) - 1)}
    recs: dict[str, dict] = {}

    pre_hooks, fwd_hooks = [], []

    def make_pre(key):
        sa, qlo, qhi = a_scales[key]
        def hook(_m, inp, sa=sa, qlo=qlo, qhi=qhi):
            q = torch.round(inp[0] / sa).clamp(qlo, qhi)
            recs.setdefault(key, {})["q_in"] = q
            return (q * sa,)
        return hook

    def make_fwd(key):
        sa, qlo, qhi = a_scales[key]
        s_out, _, _ = nxt.get(key, a_scales[key])
        def hook(mod, _inp, _out):
            q_in = recs[key]["q_in"].detach().double()
            q_w = torch.round(mod.weight.detach() / w_scales[key].view(-1, 1, 1, 1)
                              ).clamp(-QMAX_W, QMAX_W).double()
            # ⚠ 必须把模块自己的 stride/padding/dilation/groups 传进去。
            # 之前写的是裸 `F.conv2d(q_in, q_w)`（stride 默认 1、padding 默认 0），
            # 对**下采样层**（enc2/enc3，stride=2）算出来的是错形状、错值。
            acc = F.conv2d(q_in, q_w, stride=mod.stride, padding=mod.padding,
                           dilation=mod.dilation, groups=mod.groups)   # 无偏置，纯整数累加
            b = mod.bias.detach().double().view(1, -1, 1, 1)
            # ⚠ 逐通道 scale 的 view 必须是 **(1, C, 1, 1)**，不是 (C, 1, 1, 1)。
            # 写成 `view(-1,1,1,1)` 时 `acc * step` 会广播成 (C, C, H, W)——
            # 累加器被复制 C 份，golden 直接是错的（且看不出错，只是文件大了 C 倍）。
            step = (sa * w_scales[key].view(1, -1, 1, 1)).double()
            acc = acc + torch.round(b / step)
            out_f = acc * step
            # 有符号层（残差相加之后）不能再套 ReLU——那正是之前把风格打没的原因
            if qlo < 0:
                q_out = torch.round(out_f / s_out).clamp(-QMAX_W, QMAX_W)
            else:
                q_out = torch.round(torch.relu(out_f) / s_out).clamp(0, QMAX_A)
            recs[key].update(acc=acc, q_out=q_out, s_out=s_out)
        return hook

    for key in order:
        for name, mod in net.named_modules():
            if name == key:
                pre_hooks.append(mod.register_forward_pre_hook(make_pre(key)))
                fwd_hooks.append(mod.register_forward_hook(make_fwd(key)))
    with torch.no_grad():
        net(x)
    for h in pre_hooks + fwd_hooks:
        h.remove()
    return order, recs


GOLDEN_SIDE = 64
"""golden 用的测试输入边长。必须能被 4 整除。"""


def golden_input(net, device, side: int = GOLDEN_SIDE):
    """给 **golden** 用的固定小输入：从第一张内容图**中心裁一块 `side×side`**。

    ## 为什么要小

    原来 golden 用的是整张 426x640（`eval_images(1, 640)`），
    单份 `golden/` **74~82 MB**，交接给 RTL 太重。

    改成 64x64 后从 **74~82 MB 降到 1.15 MB**，而**校验效力不变**——
    逐层比对是逐元素的，和特征图多大无关（`tools/check_deploy.py` 两种尺寸都 12/12）。
    **实测 64 下"有符号层"的负累加器占 21~48%**，符号量化路径确实被测到，
    不是退化成"全正数所以随便过"。想要更接近真实分布可以 `--golden-side 128`（5 MB）。

    ## 两个约束

    1. **边长必须能被 4 整除**：编码器 stride=2 用 ceil、解码器固定 ×2，
       不是 4 的倍数时输出会比输入大 1~2 像素（见 `FPGA-IMPL.md` §1.5）。
    2. **太小不会有尺寸问题，但会没内容**：这个架构 pad→conv 保尺寸、两级 stride=2
       被两级 ×2 补回，**任何 4 的倍数都尺寸守恒**（实测 8x8 也能往返）。
       所以真正的判据不是尺寸，是**累加器不能是常数**——
       `export_all` 会逐层查 std，有一层是常数就报错，免得交出去一个"通过也证明不了什么"的 golden。

    用**中心裁方块**而不是 `fit` 缩放：`fit` 是等比缩最长边，
    竖图会得到 128x85 这种非 4 倍数的尺寸。
    """
    from PIL import Image
    side = int(side)
    if side % 4:
        raise ValueError(f"golden 边长必须是 4 的倍数，给了 {side}")
    f = sorted((DATA / "content").glob("*.jpg"))[0]
    img = Image.open(f).convert("RGB")
    w, h = img.size
    sw = min(w, h)
    left, top = (w - sw) // 2, (h - sw) // 2
    img = img.crop((left, top, left + sw, top + sw)).resize((side, side), Image.BICUBIC)
    return net_input(to_batch(img).to(device), net)


def _neg_frac(recs: dict, order) -> float:
    """整网负累加器占比 —— 用来判断这组向量到底有没有走到符号路径。

    全 0 或全正的话，`activation_signed` 那几层的负数分支一次都没被验证过，
    交出去的"12/12 通过"是虚的。
    """
    tot = neg = 0
    for n in order:
        a = recs[n]["acc"]
        tot += int(a.numel())
        neg += int((a < 0).sum())
    return neg / max(tot, 1)


def _dump_case(gdir: Path, order, recs: dict, x: torch.Tensor, a_scales: dict) -> dict:
    """把一遍整数前向的逐层记录写成 `<gdir>/{input,L*_in,L*_acc}.hex` + 索引。

    根目录的 golden 和各组定向向量共用这段，保证结构完全一致
    （`check_deploy.py` 因此可以用同一套逻辑验所有向量）。
    """
    gdir.mkdir(parents=True, exist_ok=True)
    a0, lo0, hi0 = a_scales[order[0]]
    q_in0 = torch.round(x / a0).clamp(lo0, hi0).to(torch.int64).cpu().numpy()
    (gdir / "input.hex").write_text(_hex_lines(q_in0, 2), encoding="utf-8", newline="\n")

    index = {"input": {"file": "input.hex", "shape": list(x.shape),
                       "quant_scale": float(a0), "qrange": [int(lo0), int(hi0)],
                       "layout": "NCHW，行主序"},
             "caveat": "每层的 _in.hex / _acc.hex 是**该次卷积**的精确整数输入与累加器，"
                       "可直接逐元素比对。_out 的再量化刻度取的是模块顺序上的下一个卷积；"
                       "残差相加处两分支必须共用同一 scale，这一约束不在本 golden 里体现。",
             "layers": []}
    for i, key in enumerate(order):
        r = recs[key]
        stem = f"L{i:02d}_{key.replace('.', '_')}"
        (gdir / f"{stem}_in.hex").write_text(
            _hex_lines(r["q_in"].to(torch.int64).cpu().numpy(), 2),
            encoding="utf-8", newline="\n")
        (gdir / f"{stem}_acc.hex").write_text(
            _hex_lines(r["acc"].to(torch.int64).cpu().numpy(), 8),
            encoding="utf-8", newline="\n")
        index["layers"].append({
            "index": i, "name": key,
            "in_file": f"{stem}_in.hex", "acc_file": f"{stem}_acc.hex",
            "in_scale": float(a_scales[key][0]), "out_scale": float(r["s_out"]),
            "in_qrange": [int(a_scales[key][1]), int(a_scales[key][2])],
            "in_shape": list(r["q_in"].shape), "acc_shape": list(r["acc"].shape),
        })
    return index


def vector_cases(net, side: int) -> dict:
    """除内容图以外的**定向**测试向量：零值 / 极值 / 边界 / 随机。

    WBS 3.6 要的是这四类，不是"再多几张图"。各自打什么：

    | 向量 | 打什么 |
    |---|---|
    | `zeros` | 偏置通路。累加器应恒等于量化偏置，接错线立刻现形 |
    | `ones` | 上界饱和。输入踩到 qrange 上沿，考验 `clamp` 而不只是 `round` |
    | `checker` | 空间极值 + 符号翻转。相邻像素 0/1 交替，最能把有符号层的负数分支逼出来 |
    | `random` | 通用性。固定种子，可复现 |

    返回的是**已经过 `net_input` 处理**的张量（通道数按网络取：
    RGB 网络是 3，亮度域网络是 1），直接就是第一个卷积看到的东西。
    """
    c = int(net_input(torch.zeros(1, 3, 4, 4), net).shape[1])
    side = int(side)
    g = torch.Generator(device="cpu").manual_seed(1234)

    chk = ((torch.arange(side).view(-1, 1) + torch.arange(side).view(1, -1)) % 2
           ).to(torch.float32).view(1, 1, side, side).expand(1, c, side, side)
    return {
        "zeros":   torch.zeros(1, c, side, side),
        "ones":    torch.ones(1, c, side, side),
        "checker": chk.contiguous().clone(),
        "random":  torch.rand(1, c, side, side, generator=g),
    }


def export_all(net, w_scales, a_scales, outdir: Path, first, tag: str,
               net_name: str) -> None:
    """导出 `net`（已折叠、已量化的部署网络）和它实际用的那套 scale。

    `w_scales` 必须**传进来**而不是这里重算：重算的话导出的是另一套量化刻度，
    和刚测过画质的那只网络就不是同一个东西了——spec 里写的和实际跑的对不上。
    """
    outdir = Path(outdir)
    (outdir / "golden").mkdir(parents=True, exist_ok=True)

    # ⚠ 输入通道数**按网络自己取**：亮度域网络（改D-Y）是 ci=1。
    # 写死 3 的话 spec.json 会让 RTL 那边按 RGB 喂，直接对不上。
    first = net_input(first, net)
    bounds = {n: (v, b) for n, v, b in int32_bound(net)}
    per_tensor = all(float(s.max() - s.min()) < 1e-12 for s in w_scales.values())

    spec = {
        "tag": tag, "net": net_name,
        "input": {"shape": [1, int(first.shape[1]), int(first.shape[-2]),
                            int(first.shape[-1])],
                  "note": ("单通道亮度 Y [0,1]（BT.601），色度不经网络、部署端原样接回"
                           if int(first.shape[1]) == 1 else "RGB [0,1]")
                          + "；边长需为 4 的倍数（编码器 ceil、解码器 x2 不对称）",
                  "channels": int(first.shape[1])},
        "quant": {"weight": "int8 对称，" + ("逐张量 per-tensor" if per_tensor
                                             else "逐输出通道 per-channel"),
                  "activation": "uint8 非对称，ReLU 后非负故 zero-point 恒为 0",
                  "accumulator": "int32"},
        "constraint": "残差相加的两条分支必须共用同一条激活 scale",
        "layers": [],
    }
    hex_chunks, bias_chunks, offset, bias_off = [], [], 0, 0
    for name, mod in net.named_modules():
        if not isinstance(mod, nn.Conv2d):
            continue
        w = torch.round(mod.weight.detach() / w_scales[name].view(-1, 1, 1, 1)).clamp(
            -QMAX_W, QMAX_W).to(torch.int8).cpu().numpy()
        nbytes = int(w.size)
        worst, bits = bounds[name]
        spec["layers"].append({
            "name": name, "type": "conv",
            "k": mod.kernel_size[0], "stride": mod.stride[0],
            "cin": mod.in_channels, "cout": mod.out_channels,
            "weight_offset": offset, "weight_count": nbytes,
            "weight_layout": "cout x cin x k x k，行主序",
            "weight_scale": [float(s) for s in w_scales[name].cpu()],
            "bias_offset": bias_off, "bias_count": mod.out_channels,
            "bias_quant": "int32，值 = round(b / (activation_scale_in * weight_scale))",
            "activation_scale_in": float(a_scales[name][0]),
            "activation_signed": bool(a_scales[name][1] < 0),
            "activation_qrange": [int(a_scales[name][1]), int(a_scales[name][2])],
            "int32_worst": int(worst), "int32_bits": int(bits),
        })
        # 卷积核翻转 180°：硬件做的是相关（correlation），PyTorch 做的也是相关，
        # 所以这里**不翻**。留一行说明，免得 RTL 那边照搬教科书的"卷积要翻转"。
        hex_chunks.append(_hex_lines(w, 2))
        offset += nbytes

        # 折叠后的偏置：量化到 int32，刻度与累加器一致（s_a · s_w）
        # ⚠ **逐输出通道**：原来只取 w_scales[name][0]，逐通道 scale 不相等时偏置就会错。
        # 必须和 `integer_records` 里的 `step` 同构，否则硬件按 spec 算出来的和 golden 对不上。
        step = float(a_scales[name][0]) * w_scales[name].double().view(-1)
        b_int = torch.round(mod.bias.detach().double() / step).to(torch.int64).cpu().numpy()
        bias_chunks.append(_hex_lines(b_int, 8))
        bias_off += int(b_int.size)
    spec["weight_total_bytes"] = offset
    spec["bias_total_count"] = bias_off

    (outdir / "spec.json").write_text(json.dumps(spec, ensure_ascii=False, indent=2),
                                      encoding="utf-8")
    # newline="\n"：Windows 上默认会把 \n 翻成 CRLF，$readmemh 会多读到 \r
    (outdir / "weights.hex").write_text("".join(hex_chunks), encoding="utf-8", newline="\n")
    # 偏置单独一个文件：位宽不同（int32 vs int8），混在一个 hex 里没法直接 $readmemh
    (outdir / "biases.hex").write_text("".join(bias_chunks), encoding="utf-8", newline="\n")
    (outdir / "weights.json").write_text(json.dumps(
        {"total_bytes": offset,
         "layers": [{"name": L["name"], "offset": L["weight_offset"],
                     "count": L["weight_count"]} for L in spec["layers"]]},
        ensure_ascii=False, indent=2), encoding="utf-8")

    # ---- golden 向量 ----
    order, recs = integer_records(net, w_scales, a_scales, first)
    # ---- 守卫：golden 得是**有用**的 ----
    # ⚠ 先纠正一个我差点写进文档的错误说法：**"图太小会导致输出尺寸对不上"是错的**。
    # 这个架构 pad→conv 保尺寸、两级 stride=2 被两级 ×2 补回，**任何 4 的倍数都尺寸守恒**
    # （实测 8x8 也能正常往返）。所以尺寸检查挡不住"太小"，得换判据。
    _in_hw = (int(first.shape[-2]), int(first.shape[-1]))
    _acc_last = recs[order[-1]]["acc"]
    _out_hw = (int(_acc_last.shape[-2]), int(_acc_last.shape[-1]))
    if _in_hw != _out_hw:
        raise SystemExit(f"golden 输入 {_in_hw} 与最后一层输出 {_out_hw} 对不上，"
                         f"边长必须是 4 的倍数")
    # 真正的判据：**每一层的累加器都不能是常数**。全零/全同值说明输入没激发出东西，
    # 这样的 golden 交出去，RTL 那边"通过"了也什么都证明不了。
    _flat = [n for n in order
             if float(recs[n]["acc"].float().std()) < 1e-6]
    if _flat:
        raise SystemExit(f"这些层的累加器是常数：{_flat} —— golden 没有激发网络，"
                         f"换张更有内容的测试图（或 --golden-side 调大）")
    print(f"  golden 输入 {_in_hw[1]}x{_in_hw[0]}，12 层累加器均非退化")

    index = _dump_case(outdir / "golden", order, recs, first, a_scales)
    (outdir / "golden" / "golden.json").write_text(
        json.dumps(index, ensure_ascii=False, indent=2), encoding="utf-8")

    # ---- 定向测试向量（WBS 3.6：随机 / 零值 / 极值 / 边界）----
    # 只有"一张内容图"的话，RTL 那边过得了 12/12 也可能是因为
    # 所有累加器都落在中间值区间，饱和路径、零值通路、符号翻转一次都没走到。
    extra = []
    for name, xt in vector_cases(net, first.shape[-1]).items():
        xt = xt.to(first.device)
        o2, r2 = integer_records(net, w_scales, a_scales, xt)
        flat2 = [n for n in o2 if float(r2[n]["acc"].float().std()) < 1e-6]
        if flat2:
            print(f"  ⚠ 向量 {name}: 这些层累加器是常数 {flat2}（覆盖力弱，仍导出）")
        cdir = outdir / "golden" / "cases" / name
        cdir.mkdir(parents=True, exist_ok=True)
        cidx = _dump_case(cdir, o2, r2, xt, a_scales)
        (cdir / "golden.json").write_text(
            json.dumps(cidx, ensure_ascii=False, indent=2), encoding="utf-8")
        extra.append({"name": name, "dir": f"cases/{name}",
                      "input_file": "cases/" + name + "/input.hex",
                      "shape": list(cidx["input"]["shape"]),
                      "degenerate_layers": flat2})
        print(f"  向量 {name:<8} {tuple(xt.shape)} 负累加器占比 "
              f"{_neg_frac(r2, o2):.0%}")
    index["cases"] = extra
    index["cases_note"] = ("`cases/<名>/` 是**定向**向量：zeros=全零（测偏置通路）、"
                           "ones=全 1（上界饱和）、checker=棋盘 0/1（空间极值、符号翻转）、"
                           "random=固定种子均匀随机。每份结构与根目录的 golden 相同。")
    (outdir / "golden" / "golden.json").write_text(
        json.dumps(index, ensure_ascii=False, indent=2), encoding="utf-8")

    kb = offset / 1024
    print(f"\n导出到 {outdir}")
    print(f"  权重 {offset:,} 字节（{kb:.1f}KB，int8）  spec.json {len(spec['layers'])} 层")
    print(f"  golden：input + {len(order)} 层的 in/acc，共 {len(order) * 2 + 1} 个 hex"
          f"（外加 {len(extra)} 组定向向量）")

    man = write_manifest(outdir)
    print(f"  manifest.json：{man['file_count']} 个文件的 sha256")

    # **导出后立刻独立自检**：从写出去的 hex 反着读回来重算，和 golden 逐元素比。
    # 这一步是必须的——golden 是导出这一遍跑出来的，再拿它跟自己比是循环的。
    # 2026-09-29 就是靠它抓出两个真 bug（stride 没传、逐通道 scale 广播错），
    # 而这两个 bug 在**之前所有** deploy/ 交接物里都存在，且从外部完全看不出来。
    from tools.check_deploy import check as _check_deploy
    if _check_deploy(outdir) != 0:
        raise SystemExit("交接物自检**失败** —— 上面的 golden 不可交付，别拿去给 RTL")


def main() -> int:
    ap = argparse.ArgumentParser(description="导出 RTL 交接物")
    ap.add_argument("--ckpt", type=Path, required=True)
    ap.add_argument("--calib", type=int, default=48)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--golden-side", type=int, default=GOLDEN_SIDE,
                    help="golden 测试输入的边长（4 的倍数）。越小交接物越轻")
    args = ap.parse_args()

    ckpt = args.ckpt / "net.pt" if args.ckpt.is_dir() else args.ckpt
    device = pick_device()
    blob = torch.load(ckpt, map_location=device, weights_only=False)
    net = build(blob["args"]["net"], in_affine=blob["args"].get("in_affine", True)).to(device)
    net.load_state_dict(blob["state_dict"])
    net.eval()

    calib = [t.to(device) for t in eval_images(args.calib, 256)]
    folded = fold_in(net, collect_in_stats(net, calib, device))
    a_scales = calibrate_activations(folded, calib)
    ws = weight_scales(folded, per_channel=False)

    first = golden_input(net, device, args.golden_side)

    export_all(fake_quant(folded, ws, a_scales), ws, a_scales,
               args.out or (ckpt.parent / "deploy"),
               first, ckpt.parent.name, blob["args"]["net"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
