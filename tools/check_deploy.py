"""**独立校验 `deploy/` 交接物** —— 不 import PyTorch，纯按 `spec.json` 解码 hex 重算。

    python -m tools.check_deploy runs/final/D_wc_g15/deploy
    python -m tools.check_deploy runs/final/D_sw1e5/deploy

## 为什么要有这个

`train/export.py` 生成 `weights.hex` / `biases.hex` / `golden/` 之后，**没有任何东西验过它们**。
自检是循环的：golden 是导出时那一遍跑出来的，再拿它跟同一遍比当然相等。

这个脚本**从 hex 反着读回来**，按 `spec.json` 里的偏移量、层序、layout 自己重算一遍
整数卷积，再和 `golden/L*_acc.hex` 逐元素比。**这正是 RTL testbench 要做的事**——
它验的是交接物本身自洽（hex 编码、偏移、`cout×cin×k×k` 行主序、逐通道 scale、
偏置量化刻度），而不是"PyTorch 自己和自己一致"。

## 验什么 / 不验什么

**验**：每一层 `acc = conv(q_in, q_w) + round(b / (s_a · s_w))` 与 golden 逐元素相等。

**不验**：层**之间**的连接关系（残差相加走哪条路、`_out` 的再量化接哪个 scale）。
那些在 `golden.json` 的 `caveat` 里写明了不在 golden 覆盖范围内——
`q_in` 是真实前向里流进来的张量，本脚本把它当**已知输入**用。
⇒ **它证明"给定输入，硬件算得对"，不证明"图的接线对"。** 后者要靠 RTL 侧的整图仿真。

## 一个坑

`weights.hex` / `biases.hex` 是**两个文件**（int8 和 int32 位宽不同，混一起没法 `$readmemh`），
各自有独立偏移。层记录里的 `weight_offset` / `bias_offset` 是**各自文件内**的偏移。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

MANIFEST_NAME = "manifest.json"


def verify_manifest(deploy_dir: Path) -> int:
    """按 `manifest.json` 逐文件验 sha256。

    **先跑这个再看 golden**：哈希不过说明文件在传输/复制过程中坏了，
    这时候去查 RTL 是白费功夫——错的根本不是 RTL。

    没有 manifest 时返回 0 但打印警告（老包兼容），不算失败。
    """
    mf = deploy_dir / MANIFEST_NAME
    if not mf.is_file():
        print(f"  ⚠ 没有 {MANIFEST_NAME}，跳过完整性校验（旧包格式）")
        return 0
    man = json.loads(mf.read_text(encoding="utf-8"))
    bad, missing = [], []
    for rel, rec in sorted(man["files"].items()):
        p = deploy_dir / rel
        if not p.is_file():
            missing.append(rel)
            continue
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != rec["sha256"]:
            bad.append(rel)
    listed = set(man["files"])
    on_disk = {p.relative_to(deploy_dir).as_posix()
               for p in deploy_dir.rglob("*")
               if p.is_file() and p.name != MANIFEST_NAME}
    extra = sorted(on_disk - listed)
    if bad or missing:
        print(f"  [FAIL] manifest 校验失败：{len(bad)} 个哈希不符，{len(missing)} 个缺失")
        for r in bad[:10]:
            print(f"    hash 不符: {r}")
        for r in missing[:10]:
            print(f"    缺失:     {r}")
        return 1
    if extra:
        print(f"  ⚠ manifest 外多出 {len(extra)} 个文件（未报错）：{extra[:5]}")
    print(f"  [OK] manifest：{len(listed)} 个文件 sha256 全对")
    return 0


def read_hex(path: Path, signed_bytes: bool, width: int) -> np.ndarray:
    """读 `$readmemh` 风格的一行一值 hex。

    `width=2` → 8 位（`signed_bytes` 决定按 int8 还是 uint8 解释）；
    `width=8` → 32 位二补码。
    """
    vals = [int(line, 16) for line in path.read_text(encoding="utf-8").split() if line]
    a = np.array(vals, dtype=np.int64)
    if width == 2:
        a = a & 0xFF
        # ⚠ 别用 `a.view(np.int8)`：a 是 int64，view 会**按字节重解释**，
        # 元素数直接翻 8 倍。必须走 astype 换元素类型。
        return np.where(a >= 128, a - 256, a) if signed_bytes else a
    a = a & 0xFFFFFFFF
    return np.where(a >= 2 ** 31, a - 2 ** 32, a)


def correlate(x: np.ndarray, w: np.ndarray, stride: int) -> np.ndarray:
    """整数相关（= PyTorch `conv2d` 的语义，**核不翻转**）。

    x: [cin,H,W]（int64）  w: [cout,cin,k,k]（int64）  →  [cout,Hout,Wout]（int64）
    """
    cout, cin, k, _ = w.shape
    _, h, wd = x.shape
    ho = (h - k) // stride + 1
    wo = (wd - k) // stride + 1
    # [cin, ho, wo, k, k]
    win = np.lib.stride_tricks.sliding_window_view(x, (k, k), axis=(1, 2))[:, ::stride, ::stride]
    win = win[:, :ho, :wo]
    return np.einsum("chwkl,ockl->ohw", win, w, optimize=True)


def _check_case(spec, w_all, b_all, cdir: Path, gj: dict, verbose: bool,
                label: str) -> int:
    """验一组向量：每层 `acc = conv(q_in, q_w) + round(b/(s_a·s_w))` 与 golden 逐元素比。"""
    bad = []
    for L, g in zip(spec["layers"], gj["layers"]):
        assert L["name"] == g["name"], f"层序对不上：{L['name']} vs {g['name']}"
        cin, cout = int(L["cin"]), int(L["cout"])
        k = int(L["k"])
        stride = int(L["stride"])

        q_in = read_hex(cdir / g["in_file"], L["activation_signed"], 2)
        q_in = q_in.reshape(tuple(g["in_shape"])).astype(np.int64)[0]      # 去 batch
        acc_ref = read_hex(cdir / g["acc_file"], signed_bytes=True, width=8)

        off, cnt = int(L["weight_offset"]), int(L["weight_count"])
        w = w_all[off:off + cnt].reshape(cout, cin, k, k)
        bo, bc = int(L["bias_offset"]), int(L["bias_count"])
        b_int = b_all[bo:bo + bc]

        acc = correlate(q_in, w, stride) + b_int.reshape(-1, 1, 1)
        shape_ok = list(acc.shape) == list(g["acc_shape"])[1:]
        eq = shape_ok and np.array_equal(acc.ravel(), acc_ref.ravel())
        if not eq:
            bad.append((g["index"], L["name"], list(acc.shape), list(g["acc_shape"])))
        if verbose or not eq:
            print(f"  [{label}] L{g['index']:02d} {L['name']:<26} k{k} s{stride} "
                  f"{cin}->{cout}  shape {'ok' if shape_ok else 'MISMATCH'}  "
                  f"acc {'==' if eq else '!='} golden")

    n = len(spec["layers"])
    if bad:
        print(f"  [FAIL] {label}: {len(bad)}/{n} 层对不上")
        for i, name, got, want in bad:
            print(f"    L{i:02d} {name}: acc 形状 {got}，golden 记 {want}")
        return 1
    print(f"  [OK] {label}: {n}/{n} 层整数累加器与 golden 逐元素一致")
    return 0


def check(deploy_dir: Path, verbose: bool = False) -> int:
    spec = json.loads((deploy_dir / "spec.json").read_text(encoding="utf-8"))
    gdir = deploy_dir / "golden"
    gj = json.loads((gdir / "golden.json").read_text(encoding="utf-8"))

    print(f"{deploy_dir}")
    rc = verify_manifest(deploy_dir)

    w_all = read_hex(deploy_dir / "weights.hex", signed_bytes=True, width=2)
    b_all = read_hex(deploy_dir / "biases.hex", signed_bytes=True, width=8)
    actual_w_bytes = int(spec.get("weight_total_bytes", len(w_all)))
    print(f"  input  {spec['input']['shape']}  channels {spec['input'].get('channels', '?')}")
    print(f"  权重 {len(w_all)} 字节（spec 记 {actual_w_bytes}）  偏置 {len(b_all)} 个 int32")
    assert len(w_all) == actual_w_bytes, "weights.hex 长度与 spec.weight_total_bytes 不符"
    assert len(b_all) == int(spec["bias_total_count"]), "biases.hex 长度与 spec 不符"

    # input.hex 应当等于第 0 层的 _in.hex（同一个张量）
    q_in0 = read_hex(gdir / "input.hex", spec["layers"][0]["activation_signed"], 2)
    l0_in = read_hex(gdir / gj["layers"][0]["in_file"],
                     gj["layers"][0]["in_qrange"][0] < 0, 2)
    # input.hex 是**网络输入**（未 pad），L00_in 是**第一个卷积的输入**（可能已被首层的
    # ReflectionPad 撑大）。两者相等**只在首层无 pad 时成立**，不能当判据——
    # `改D` 的首层是 `enc1.pad: ReflectionPad2d(1)`，426x640 → 428x642 是正常的。
    same_input = q_in0.shape == l0_in.shape and np.array_equal(q_in0, l0_in)
    if q_in0.shape != l0_in.shape:
        rel = "尺寸不同（网络输入未 pad、首层卷积输入已 pad）——本模型首层有 ReflectionPad，正常"
    else:
        rel = "一致" if same_input else "形状相同但值不同（可疑）"
    print(f"  input.hex {q_in0.shape} vs L00_in.hex {l0_in.shape}: {rel}")

    rc |= _check_case(spec, w_all, b_all, gdir, gj, verbose, "内容图")

    # 定向向量（随机/零值/极值/边界）。没有它们的话，内容图这一组
    # 12/12 通过也可能是"所有累加器都在中间值区间"，饱和和符号路径根本没走到。
    cases = gj.get("cases", [])
    if not cases:
        print("  ⚠ golden.json 里没有 cases —— 只有一张内容图（WBS 3.6 要求定向向量）")
    for c in cases:
        cdir = gdir / "cases" / c["name"]
        cj = json.loads((cdir / "golden.json").read_text(encoding="utf-8"))
        rc |= _check_case(spec, w_all, b_all, cdir, cj, verbose, f"向量 {c['name']}")

    ncase = 1 + len(cases)
    if rc == 0:
        print(f"\n[OK] {ncase} 组向量全部逐元素一致")
    return rc


def main() -> int:
    # Windows 控制台默认 GBK，ⓘ/⚠ 这类字符会直接抛 UnicodeEncodeError
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="独立校验 deploy/ 交接物（不 import PyTorch）")
    ap.add_argument("dirs", nargs="+", type=Path, help="一个或多个 deploy/ 目录")
    ap.add_argument("-v", "--verbose", action="store_true", help="逐层打印")
    args = ap.parse_args()
    rc = 0
    for i, d in enumerate(args.dirs):
        if i:
            print()
        rc |= check(d, args.verbose)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
