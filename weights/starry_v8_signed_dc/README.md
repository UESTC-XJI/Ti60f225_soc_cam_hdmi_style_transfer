# starry_v8_signed_dc —— 板侧固化 DC 的权重

**源**：`demo/reports/rowpipe/export_starry_v8_signed/`（模型侧导出，XOR `0x7296f3e8`）
**只改了 3 个 word**：L11 的逐通道 bias。权重、M、Q 头一个字节没动。

| 项 | 原厂 | 本文 |
|---|---|---|
| L11 bias R/G/B | 18384 / 33691 / 51360 | **1911 / 15991 / 31181** |
| XOR | `0x7296f3e8` | **`0x7296bfce`** |

## DC 标定

风格参考图：`starry_night.jpg`

| | R | G | B | B−R |
|---|---|---|---|---|
| 参考图（0-255） | 76.4 | 92.4 | 110.4 | +34.0 |
| 目标 q（=均值−128） | -52 | -36 | -18 | +34 |
| **实测达成** | **-52.0** | **-36.1** | **-18.2** | **+33.8** |

**方法**：目标 q = 参考图通道均值 − 128；`Δbias = Δq × 2^shift / M`。
不要"三通道归零"——那会把原厂正确的色彩平衡抹成中性灰（2026-10-27 踩过）。

- 实测 σ RGB：`34.0,37.7,61.9`
- 实测贴轨：`0.5%`

## 怎么用

```bash
# 构建固件（会打印 XOR 与末层约定）
bash tools/build_firmware.sh weights/starry_v8_signed_dc/rowpipe_weights.h

# 或直接写 DDR（更快，不重烧）
python tools/style_probe.py weights weights/starry_v8_signed_dc/rowpipe_blob.bin
```

## 注意

这是**板侧固化变体**，不是模型侧的正式导出。模型侧若重导同名风格，应以他们的新版本为准。
DC 是「每个风格 × 每个场景」的组合——换场景可能需要重新标定。
