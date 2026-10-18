# 整数 vs 浮点对比实测报告

> 执行日期：2026-10-13
> 对象：已部署的 Monet 风格迁移网络（Ti60F225 板上实际运行的那一个）
> 方法：用仓库自带的 NumPy 整数 oracle 对比 PyTorch FP32/QAT checkpoint

---

## 1. 核心结论

| 对比 | MAE | PSNR | 判读 |
|---|---|---|---|
| **整数 vs QAT** | **0.548 LSB** | **45.79 dB** | 量化误差极小，几乎不可察觉 |
| **整数 vs FP 学生** | 4.767 LSB | 32.53 dB | 含 QAT 训练偏移 |
| QAT vs FP 学生 | 4.726 LSB | 32.63 dB | QAT 本身带来的改变 |

**关键发现**：`整数 vs QAT` 的差异（0.548 LSB）远小于 `QAT vs FP`（4.726 LSB）。这说明——

> **导出链的定点化误差可以忽略；真正改变输出的是 QAT 训练本身，而不是量化。**

这与项目文档的结论一致，且验证了导出链的正确性。

---

## 2. 与项目文档记录值的对照

| 指标 | 文档记录 | 本次实测 | 差异原因 |
|---|---|---|---|
| 整数 vs QAT PSNR | 41.15 dB | **45.79 dB** | 评估集不同 |
| 整数 vs QAT MAE | 1.25 LSB | **0.548 LSB** | 同上 |
| 整数 vs FP PSNR | 33.74 dB | **32.53 dB** | 同上 |

**差异来源**：

| | 文档评估 | 本次实测 |
|---|---|---|
| 样本 | 64 张真实 test 照片（256×256） | 1 张 32×24 合成 fixture |
| 来源 | `ml/style_transfer/evaluate.py` | 固件自测向量（`style_selftest.h`） |

**两者量级与结论一致**（整数误差远小于 QAT 偏移）。本次样本更小、更"简单"，所以 PSNR 偏高。

---

## 3. 最强的验证：与固件内嵌期望值完全一致

本次跑的是**固件自测用的同一组输入**（`tools/prepare_style_firmware.py` 生成的 32×24 确定性 fixture）。

```
cross-check vs firmware embedded expectation:
  max abs diff = 0 LSB
  MAE          = 0.0000 LSB
  MSE          = 0.000000
  PSNR         = 120.00 dB
  identical    = True
```

**逐像素完全一致（0 LSB 差异）。** 这证明：

1. NumPy 整数 oracle（`integer.py`）与固件内嵌的期望值**完全对齐**
2. RTL 的定点语义（int32 累加 + int64 affine + shift）在 Python 参考实现中**被精确复现**
3. 板上 CPU 自检通过时，意味着硬件计算与这份 oracle 一致

---

## 4. 网络规格（从 graph.json 读取）

| 项 | 值 |
|---|---|
| 格式版本 | 1 |
| 舍入方式 | `nearest_ties_away_from_zero`（四舍五入，远离零） |
| 输入 | RGB uint8, q = u8 − 128 |
| 输出 | RGB uint8, u8 = q + 128 |
| 填充 | zero |
| 激活 | signed INT8；ReLU [0, 127] |
| 累加器 | **signed INT32** |
| 仿射 | **signed64(acc × M16 + B32)** 然后 round shift |
| 权重载荷 | **11,056 bytes** |
| **仿射绝对值上界** | **13,335,729,260** |
| QAT checkpoint | True |
| 层数 | 23 |

### 算术边界检查

```
maximum_affine_abs_bound = 13,335,729,260
2^34                     = 17,179,869,184
13,335,729,260 < 2^34    ✓  远小于 int64 上限（2^63−1）
```

`export.py` 内有断言 `assert bound < (1<<63)`，实测上界仅占 int64 空间的 **0.00000007%**，**无溢出风险**。

---

## 5. 逐层累加器范围（32×24 fixture 实测）

| 层 | 名称 | k | s | up | acc min | acc max |
|---|---|---|---|---|---|---|
| 0 | enc.0 | 3 | 2 | 1 | −84,700 | 70,903 |
| 1 | enc.1 | 3 | 2 | 1 | −3,073 | 7,605 |
| 2 | enc.2 | 1 | 1 | 1 | −8,590 | 8,899 |
| 3 | res.0.0 | 3 | 1 | 1 | −15,878 | 16,683 |
| 4 | res.0.1 | 1 | 1 | 1 | −14,855 | 18,955 |
| 5 | res.0.2 | 3 | 1 | 1 | −7,157 | 19,510 |
| 6 | res.0.3 | 1 | 1 | 1 | −19,607 | 13,808 |
| 7 | res.1.0 | 3 | 1 | 1 | −17,255 | 16,556 |

（共 23 层；上表为前 8 层）

**观察**：第一层 `enc.0` 的累加器范围最大（−84,700 ~ 70,903），因为它是 3×3×3 = 27 项的卷积（3 通道输入）。后续层虽然通道更多，但因为激活已量化到 int8 且权重按 per-channel scale 归一化，范围反而更小。

**最大绝对值 84,700 远小于 int32 上限（2.1×10⁹）**，余量充足。

---

## 6. 精度链路总结

```
训练阶段（浮点）
  ├─ 主计算      FP16 混合精度          train.py:116
  ├─ Gram 矩阵   强制 FP32              train.py:28
  ├─ 损失        FP32                   train.py:119
  └─ 梯度缩放    GradScaler（FP16）      train.py:105
        ↓
QAT 阶段（浮点存储 + 伪量化）
  └─ fake(): 前向用 int8 舍入，反向用 STE 直通估计   model.py:7-10
        ↓
导出阶段（纯整数）
  ├─ 权重        int8 对称量化（per-output-channel scale）
  ├─ 乘子        M16（16-bit 定点）
  ├─ 偏置        B32（32-bit 整数）
  └─ 缩放        shift 右移（每通道独立 r）
        ↓
板上推理（纯整数）
  ├─ 卷积        int32 累加
  ├─ 仿射        int64（acc × M16 + B32）
  └─ 输出        round shift → int16 截断 → int8
```

---

## 7. 对后续训练的意义

### 7.1 浮世绘训练要保留 QAT

| 环节 | 影响 |
|---|---|
| 浮点训练 | 决定风格学习质量 |
| **QAT** | **决定量化后能保留多少** ← 关键 |
| 导出 | 引入 0.548 LSB 误差（可忽略） |

**结论**：保持 `--qat-after 5500` 不变。没有 QAT，量化误差会显著增大。

### 7.2 浮世绘的特定风险：色带

浮世绘的**平涂色块**对量化特别敏感：

- 大片同色区域如果量化不准，会出现**色带（banding）**
- 浮世绘的**配色**是风格核心，量化误差直接影响色调

**建议**：
- 若出现色带，把 `--qat-after` 提前（如 4000），延长 QAT 阶段
- 用 `calibrate.py` 对比 6 种 scale 方案（它已内置：FP32 / global_1_32 / 1_16 / 1_8 / 1_4 / calibrated）

### 7.3 验证手段已就绪

本次建立的两级验证可直接复用于新模型：

| 验证 | 工具 | 判据 |
|---|---|---|
| **固件一致性** | `style_selftest.h` 对比 | **必须 0 LSB** |
| 量化误差 | 本报告方法 | 整数 vs QAT MAE < 1 LSB |
| 整数 vs FP | `evaluate.py` | PSNR > 30 dB |

---

## 8. 复现方法

```powershell
# 环境（已搭建）
#   .venv  /  Python 3.12.14  /  torch 2.11.0+cu128  /  CUDA 可用

# 整数 vs 浮点对比
.venv\Scripts\python.exe _int_vs_fp.py

# 官方完整评估（需要 test 数据集）
.venv\Scripts\python.exe ml/style_transfer/evaluate.py `
    --manifest reports/style_demo/data_v2/manifest.json `
    --fp ml/style_transfer/artifacts/student_fp.pt `
    --qat ml/style_transfer/artifacts/student_qat.pt `
    --teacher ml/style_transfer/artifacts/teacher.pt `
    --integer ml/style_transfer/artifacts/integer `
    --out reports/style_demo/evaluation_repeated --count 64
```

---

## 9. 环境状态

| 组件 | 版本 | 状态 |
|---|---|---|
| Python | 3.12.14 | ✅ |
| **torch** | **2.11.0+cu128** | ✅ **CUDA 可用** |
| CUDA runtime | 12.8 | ✅ |
| GPU | RTX 4060 Laptop 8GB | ✅ 已识别 |
| numpy | 2.5.4 | ✅ |
| Pillow | 12.3.0 | ✅ |
| sympy | 1.14.0 | ✅ |
| **torchvision** | — | ❌ **未安装**（VGG 风格指标需要） |

**torchvision 缺失的影响**：本次的 style Gram MSE 指标未能计算。它只影响**风格距离度量**，不影响：
- 整数 oracle 验证（已完成，0 LSB）
- 整数 vs 浮点对比（已完成）
- 模型训练（`train.py` 需要 VGG，所以**训练前必须补装 torchvision**）

---

## 10. 附录：核查命令

| 断言 | 命令 |
|---|---|
| 整数 oracle 与固件一致 | 本报告 §3 |
| 仿射上界 | `graph.json` → `maximum_affine_abs_bound` |
| 权重载荷 | `(Get-Item ml\style_transfer\artifacts\integer\model.bin).Length` |
| 逐层范围 | `_int_vs_fp.py` 的 trace 输出 |
| 文档记录值 | `docs/STYLE_DEMO_IMPLEMENTATION.md` |
