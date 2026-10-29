#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
freeze_dc.py —— 把板侧调好的 DC（L11 逐通道 bias）固化成一个新的权重变体

为什么需要它：
  DC 存在权重 blob 的 L11 bias 三个 word 里（word 3560~3562 -> DDR 0x06F037A0/A4/A8）。
  用 style_probe 在 DDR 上调好之后，那个改动是**易失的**——重烧固件就被原厂 blob
  覆盖回去。要让它"跟着风格走"，必须写回权重文件本身。

它做什么：
  读一个模型侧导出的 blob，只替换 3 个 bias word，其余（权重/M/mid/Q 头）逐字不动，
  生成 `weights/<name>_dc/` 下的 rowpipe_weights.h + rowpipe_blob.bin + README.md，
  并重算 XOR。

用法：
  python tools/freeze_dc.py starry_v8_signed 1911 15991 31181 \
      --ref "starry_night.jpg" --ref-mean 76.4,92.4,110.4 \
      --meas -52.0,-36.1,-18.2 --sigma 34.0,37.7,61.9 --clip 0.5

  # 只看不写
  python tools/freeze_dc.py starry_v8_signed 1911 15991 31181 --dry-run
"""

import argparse
import functools
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXPORT_ROOT = os.path.join(os.path.dirname(ROOT), "demo", "reports", "rowpipe")
WORDS = 3612
BIAS_WORD = 3560        # L11 bias 的 3 个 word：3560/3561/3562
Q_WORD = 3608


def s32(u):
    return u - (1 << 32) if u & 0x80000000 else u


def u32(v):
    return v & 0xFFFFFFFF


def xor_of(words):
    return functools.reduce(lambda a, x: a ^ x, words, 0)


def find_export(name):
    """在模型的导出目录里找 blob。支持 export_<name>/ 和普通路径。"""
    cands = [os.path.join(EXPORT_ROOT, "export_" + name, "rowpipe_blob.bin"),
             os.path.join(EXPORT_ROOT, name, "rowpipe_blob.bin"),
             name]
    for c in cands:
        if os.path.isfile(c):
            return c
    raise SystemExit("找不到 blob：试过\n  " + "\n  ".join(cands))


def write_header(path, words, xor, note, before, after):
    lines = ["/* rowpipe cap8 DDR blob: 903 beats = 14448 bytes */",
             "/* %s */" % note,
             "/* 2026-10-27 板侧 DC 固化：L11 bias %s -> %s（权重/M/Q 头均未改） */"
             % (before, after),
             "static const unsigned int rowpipe_weights[%d] = {" % len(words)]
    for i in range(0, len(words), 4):
        lines.append("  " + "".join("0x%08xu," % x for x in words[i:i + 4]))
    lines += ["};",
              "#define ROWPIPE_WEIGHT_WORDS %du" % len(words),
              "#define ROWPIPE_WEIGHT_XOR 0x%08xu" % xor]
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description="把板侧调好的 L11 DC 固化成一个权重变体")
    ap.add_argument("source", help="模型侧导出的风格名（如 starry_v8_signed）或 blob 路径")
    ap.add_argument("bias", nargs=3, type=int, help="要固化的 L11 bias R G B（int32）")
    ap.add_argument("--ref", default="", help="DC 标定用的风格参考图文件名")
    ap.add_argument("--ref-mean", default="", help="参考图的 RGB 均值，如 76.4,92.4,110.4")
    ap.add_argument("--meas", default="", help="修正后实测的 q 域均值，如 -52.0,-36.1,-18.2")
    ap.add_argument("--sigma", default="", help="修正后实测的 RGB sigma")
    ap.add_argument("--clip", default="", help="修正后实测的贴轨百分比")
    ap.add_argument("--note", default="", help="额外备注")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    src = find_export(args.source)
    blob = open(src, "rb").read()
    if len(blob) != WORDS * 4:
        raise SystemExit("blob 大小不对：%d（应为 %d）" % (len(blob), WORDS * 4))
    words = list(struct.unpack("<%dI" % WORDS, blob))

    before = [s32(words[BIAS_WORD + k]) for k in range(3)]
    for k in range(3):
        words[BIAS_WORD + k] = u32(args.bias[k])
    newblob = struct.pack("<%dI" % WORDS, *words)
    xor = xor_of(words)

    base = os.path.basename(os.path.dirname(src)) or os.path.basename(src)
    base = base.replace("export_", "")
    name = base + "_dc"
    out = os.path.join(ROOT, "weights", name)

    print("源：%s" % src)
    print("  变体名  %s" % name)
    print("  bias    %s -> %s" % (before, list(args.bias)))
    print("  XOR     0x%08x -> 0x%08x" % (xor_of(list(struct.unpack("<%dI" % WORDS, blob))), xor))
    print("  Q 头    0x%08X（未改，shift=%d）" % (words[Q_WORD], words[Q_WORD] & 0x3F))
    print("  M       %s（未改）" % [s32(words[3576 + 2 * k]) for k in range(3)])
    if args.dry_run:
        print("\n--dry-run：不写文件")
        return 0

    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, "rowpipe_blob.bin"), "wb").write(newblob)
    write_header(os.path.join(out, "rowpipe_weights.h"), words, xor,
                 "源：" + os.path.basename(src) + ("  " + args.note if args.note else ""),
                 before, list(args.bias))

    # README
    rows = []
    if args.ref_mean:
        rm = [float(x) for x in args.ref_mean.split(",")]
        rows.append("| 参考图（0-255） | %.1f | %.1f | %.1f | %+.1f |"
                    % (rm[0], rm[1], rm[2], rm[2] - rm[0]))
        rows.append("| 目标 q（=均值−128） | %.0f | %.0f | %.0f | %+.0f |"
                    % (rm[0] - 128, rm[1] - 128, rm[2] - 128, (rm[2] - 128) - (rm[0] - 128)))
    if args.meas:
        mm = [float(x) for x in args.meas.split(",")]
        rows.append("| **实测达成** | **%+.1f** | **%+.1f** | **%+.1f** | **%+.1f** |"
                    % (mm[0], mm[1], mm[2], mm[2] - mm[0]))
    extra = ""
    if args.sigma:
        extra += "\n- 实测 σ RGB：`%s`" % args.sigma
    if args.clip:
        extra += "\n- 实测贴轨：`%s%%`" % args.clip

    readme = f"""# {name} —— 板侧固化 DC 的权重

**源**：`demo/reports/rowpipe/export_{base}/`（模型侧导出，XOR `0x{xor_of(list(struct.unpack('<{0}I'.format(WORDS), blob))):08x}`）
**只改了 3 个 word**：L11 的逐通道 bias。权重、M、Q 头一个字节没动。

| 项 | 原厂 | 本文 |
|---|---|---|
| L11 bias R/G/B | {' / '.join(str(x) for x in before)} | **{' / '.join(str(x) for x in args.bias)}** |
| XOR | `0x{xor_of(list(struct.unpack('<{0}I'.format(WORDS), blob))):08x}` | **`0x{xor:08x}`** |

## DC 标定

风格参考图：`{args.ref or '（未指定）'}`

| | R | G | B | B−R |
|---|---|---|---|---|
{chr(10).join(rows) if rows else '| （本次未记录参考图数据） | | | | |'}

**方法**：目标 q = 参考图通道均值 − 128；`Δbias = Δq × 2^shift / M`。
不要"三通道归零"——那会把原厂正确的色彩平衡抹成中性灰（2026-10-27 踩过）。
{extra}

## 怎么用

```bash
# 构建固件（会打印 XOR 与末层约定）
bash tools/build_firmware.sh weights/{name}/rowpipe_weights.h

# 或直接写 DDR（更快，不重烧）
python tools/style_probe.py weights weights/{name}/rowpipe_blob.bin
```

## 注意

这是**板侧固化变体**，不是模型侧的正式导出。模型侧若重导同名风格，应以他们的新版本为准。
DC 是「每个风格 × 每个场景」的组合——换场景可能需要重新标定。
"""
    with open(os.path.join(out, "README.md"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(readme)

    print("\n已写出 %s/" % out)
    for f in sorted(os.listdir(out)):
        print("  %-22s %d B" % (f, os.path.getsize(os.path.join(out, f))))
    print("\n构建：bash tools/build_firmware.sh weights/%s/rowpipe_weights.h" % name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
