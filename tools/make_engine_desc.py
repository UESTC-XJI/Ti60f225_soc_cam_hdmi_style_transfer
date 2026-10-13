"""给 net_engine 的整网测试台生成**逐层描述符表**。

    python -m tools.make_engine_desc D_sw1e5 -o ../hw/epilogue/vectors/D_sw1e5

产出 `engine_layers.hex`：每层一行，32 个十六进制字符 = 16 字节（**高位字节在前**）。
TB 用 `$readmemh` 读进 `reg [127:0] dline[0:11]`，逐字节取。

## 为什么单独一个脚本，而不是塞进 make_requant

`layers.json` / `requant.json` 已经有两层的信息，但**都不是引擎要的形式**：

- `layers.json` 的 `hin/win` 是**已 pad**的边长（L0 是 66），而引擎的 bank 存**未 pad**
  张量、自己反射 —— 引擎要的是 `hin - 2`。
- 引擎的 bank **乒乓**（src/dst）、恒等支读哪块（res_bank）、
  恒等支**在哪个域**（res_unsigned）—— 这三个是**接线**决定的，两边都没有。

放在这里算，`make_requant` 不用动（它只产出"向量"，不管接线）。

## 字节布局（byte 0 = 最低 8 位 = 行尾两个十六进制字符）

    0  cin              5-7  hout(hi,lo)      11  up
    1  cout             8-9  wout(hi,lo)      12  res
    2-3 hin(hi,lo)      10   stride           13  res_unsigned
    4-5 win(hi,lo)                            14  src_bank
                                              15  dst_bank | (res_bank<<1)

## 三个"接线"判据（都从 `net_chain.py` 抄的，不是拍脑袋）

1. **上采样**：`hin == 2*上一层 hout + 2` —— `net_chain.py:147` 的判据
   （dec1/dec2 是"**先 ×2 再 pad**"；引擎那边 = 先 `refl` 再 `>>1`）。
2. **恒等支 = 残差块的输入** = **c1 的输入** = 第 `i-2` 层的输出 —— `net_chain.py:172-176`
   的坑。所以 `res_bank` = 第 `i-2` 层的 `dst_bank`。
3. **恒等支的域**：恒等支是第 `i-2` 层写的，域 = 第 `i-1` 层的输入域
   （`in_signed`）。**无符号**的那些在 bank 里是 `q ^ 0x80`（偏移域），
   读出来要反异或；有符号的是原样补码。这和 tap 那侧的偏移是**同一件事**，
   只是 tap 把修正折进了 `b'`，恒等支折不了（它乘的是 `mid` 不是 `mq`），
   所以必须显式给一个位。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="net_engine 逐层描述符表")
    ap.add_argument("tag")
    ap.add_argument("-o", "--out", type=Path, required=True)
    args = ap.parse_args()

    outdir = args.out
    layers = json.loads((outdir / "layers.json").read_text(encoding="utf-8"))["layers"]
    req = json.loads((outdir / "requant.json").read_text(encoding="utf-8"))["layers"]
    assert len(layers) == len(req), "layers.json 与 requant.json 层数不一致"

    dst = [0] * len(layers)
    rows, table = [], []
    for i, (L, R) in enumerate(zip(layers, req)):
        cin, cout = int(L["cin"]), int(L["cout"])
        # 引擎要**未 pad** 的边长：bank 存未 pad 张量，反射填充由引擎自己做
        hin, win = int(L["hin"]) - 2, int(L["win"]) - 2
        hout, wout = int(L["hout"]), int(L["wout"])
        stride = int(L["stride"])
        # 上采样：net_chain.py:147 的判据
        up = 1 if (i > 0 and int(L["hin"]) == 2 * int(layers[i - 1]["hout"]) + 2) else 0
        res = bool(R["residual"])
        # 恒等支 = 残差块的输入 = 第 i-2 层的输出
        res_unsigned = int(not layers[i - 1]["in_signed"]) if res else 0
        res_bank = dst[i - 2] if res else 0
        src = 0 if i == 0 else dst[i - 1]
        dst[i] = 1 - src

        b = [cin, cout, (hin >> 8) & 0xFF, hin & 0xFF, (win >> 8) & 0xFF, win & 0xFF,
             (hout >> 8) & 0xFF, hout & 0xFF, (wout >> 8) & 0xFF, wout & 0xFF,
             stride, up, int(res), res_unsigned, src, dst[i] | (res_bank << 1)]
        rows.append("".join(f"{v:02x}" for v in reversed(b)))   # 高位字节在前
        table.append((i, R["name"], cin, cout, hin, win, hout, wout, stride, up, res,
                      res_unsigned, src, dst[i], res_bank))

    (outdir / "engine_layers.hex").write_text("\n".join(rows) + "\n",
                                              encoding="utf-8", newline="\n")
    print(f"{outdir}/engine_layers.hex")
    print(f"{'L':>2} {'name':<16} {'cin':>3}{'cout':>5} {'hin':>4}{'win':>4} "
          f"{'hout':>4}{'wout':>4} {'st':>2} {'up':>2} {'res':>3} {'rsU':>3} "
          f"{'src':>3}{'dst':>3} {'resB':>4}")
    for t in table:
        i, name, cin, cout, hin, win, hout, wout, stride, up, res, rsu, src, d, rb = t
        print(f"{i:>2} {name:<16} {cin:>3}{cout:>5} {hin:>4}{win:>4} {hout:>4}{wout:>4} "
              f"{stride:>2} {up:>2} {int(res):>3} {rsu:>3} {src:>3}{d:>3} {rb:>4}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
