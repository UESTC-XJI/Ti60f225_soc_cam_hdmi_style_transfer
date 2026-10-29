# 风格清单（canonical）

> 最后确认：2026-10-27
> 这份文件是"当前有哪些风格、哪个已被替代"的唯一权威记录。改风格 lineup 请先改这里。

---

## 当前有效风格：**3 套**

| 风格 | 中文名 | 权重目录 | 固件产物 | 权重 XOR | 状态 |
|---|---|---|---|---|---|
| **redsky** | **呐喊** | `demo/reports/rowpipe/export_redsky_v5/` | `artifacts/soc_video_app_redsky_v5.bin` | `0xcbc67865` | ✅ **当前板上运行** |
| ink | 墨 | `demo/reports/rowpipe/export_ink_v5/` | `artifacts/soc_video_app_ink_v5.bin` | `0x4a18e91c` | ✅ 有效 |
| wave | 波浪 | `demo/reports/rowpipe/export_wave_v5/` | `artifacts/soc_video_app_wave_v5.bin` | `0x58979045` | ✅ 有效 |

### 各套 v5 量化参数（模型侧导出）

| 风格 | s_out | shift | σ | clamp | p99.5 |
|---|---|---|---|---|---|
| ink | 0.005564 | 38 | 50.1 | 0.05% | +75.9 |
| wave | 0.005699 | 38 | 50.2 | 0.31% | +82.5 |
| **redsky** | 0.005383 | **37** | 50.1 | 0.03% | +95.1 |

> redsky 只能用 shift=37：σ≈50 需要 `m=4.296e-3` ⇒ `M = m×2^38 = 1.181e9`，超
> `2^30` 上限 10%，导出器自动退到 37。**这是位宽限制，不是 bug。**

---

## ⚠ 已废弃：**scream**

**`scream` 已被 `redsky` 替代，不再作为并列风格存在。**

- 废弃日期：2026-10-27（用户确认）
- 遗留物（**不要再烧板、不要再作为交付目标**）：
  - `artifacts/soc_video_app_scream_v5.bin`（XOR `0x4043c596`）
  - `artifacts/soc_video_app_scream_v4.bin` 等更早版本
  - `demo/reports/rowpipe/export_scream_v5/`、`export_scream_v4/`、`export_scream_pastel/`
- 注意：**呐喊 = redsky**，不是 scream。历史上 `scream` 曾与 redsky 并列，容易混淆。

---

## ⚠ 文件归属规则（2026-10-27 起）

**`software/firmware/rowpipe_weights.h` 是构建产物，不是源码。任何人不要手改。**

| 谁 | 写哪里 |
|---|---|
| 模型侧 | `demo/reports/rowpipe/export_<风格>/rowpipe_weights.h` ← **唯一源头** |
| 构建脚本 | `software/firmware/rowpipe_weights.h` ← 每次构建从导出目录整份复制 |
| 其他人 | 不要碰；要用哪套风格，就 `bash tools/build_firmware.sh <风格名>` |

原因：这个文件换风格时整份覆盖（3612 word + XOR 全换），两边同时写会静默撞车
——固件照常 PASS，但里面装的是别的权重。**已实测发生过多起**（10-26 两次、
10-27 15:03 一次导致四个固件权重错误）。详见
`reports/ROW_PIPE_WEIGHTS_OWNERSHIP.md`。

每次构建都会打印权重身份，例如：

```
  权重：XOR=0xcbc67865  WORDS=3612
         ^ redsky v5（呐喊）
PASS ... [weights XOR=0xcbc67865]
```

---

## 相关文档

| 文档 | 内容 |
|---|---|
| `reports/ROW_PIPE_WEIGHTS_OWNERSHIP.md` | **文件归属与换风格的规则（模型侧必读）** |
| `reports/FOR_MODEL_QUANT_CONTRACT.md` | blob 量化契约（末层必须 qlo<0） |
| `reports/FOR_MODEL_FIRMWARE_GUIDE.md` | 怎么改固件、编译、烧板、验证 |
| `reports/REPLY_TO_MODEL_v5_verified.md` | v5 上板验收记录 |
| `reports/COLOR_CHECKER_CALIB_2026-10-27.md` | 24 色卡校准与偏色定案 |
