# starry_v7_signed_dc —— 板侧固化 DC 的星空权重

**来源**：`demo/reports/rowpipe/export_starry_v7_signed/`（模型侧导出，XOR `0x66ac227e`）
**只改了 3 个 word**（L11 的逐通道 bias），权重与 M 一个字节没动。

| 项 | 原厂 | 本文 | 依据 |
|---|---|---|---|
| L11 bias R/G/B | 22848 / 44198 / 67253 | **1975 / 21393 / 37818** | 按风格参考图的通道均值对齐 |
| M（三通道相同） | 725,612,887 | **不变** | 逐通道 M 加倍试过，撞顶 4.4%，已撤回 |
| Q 头 | `0x001FE065` | **不变** | shift 37 / qlo −127 / qhi 127 |
| XOR | `0x66ac227e` | **`0x66ad16b1`** | 重算 |

## 标定基准

风格参考图：`demo/_rowpipe_train/The_Starry_night_net_shell/data/styles/starry_night_鲜艳.jpg`

| | R | G | B | B−R |
|---|---|---|---|---|
| 参考图（0-255） | 78.3 | 101.9 | 128.5 | **+50.2** |
| 本权重产出（q 域） | −50.3 | −26.1 | +0.8 | **+51.1** |

目标 q = 参考图均值 − 128 ⇒ R −50 / G −26 / B 0。

## 板上实测（2026-10-27）

```
通道   mean    sigma   min    max   q==0
R     -50.3    26.8   -127   +127   0.2%
G     -26.1    26.7   -127   +127   1.1%
B      +0.8    55.5   -127   +127   0.1%
B-R = +51.1    平坦区 0.0%    贴轨 0.1%
```

链路：MS 50、AXI 0、DROP 0、PF == PFC。

## 已知的残留问题

**R/G 的 σ 只有 26.8/26.7，而参考图是 56.9/58.6（差一半）。**
板侧可以给 R/G 单独加倍 M 补上（σ 会到 49/52），但代价是撞顶从 0.1% 涨到 4.4%，
所以**没有固化进来**——这一条应该由模型侧在导出时把 R/G 的输出幅度加大来解。

## 怎么用

```bash
# 构建固件（脚本会打印 XOR 与末层约定）
bash tools/build_firmware.sh weights/starry_v7_signed_dc/rowpipe_weights.h

# 或直接写 DDR（更快，不重烧）
python tools/style_probe.py weights weights/starry_v7_signed_dc/rowpipe_blob.bin
```

⚠ 这是**板侧固化的变体**，不是模型侧的正式导出。模型侧若重导 starry，应以他们的新版本为准。
