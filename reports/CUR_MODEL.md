# 当前模型结论（CUR_MODEL）

> 最后更新：2026-10-22
> 本文是**模型侧的唯一权威结论**。训练历史见 `reports/archive/ink_training_v1_v6/`。

---

## 一、可上板模型（唯一 1 个）

| 模型 | 参数 | QAT | 数据集 | 状态 |
|---|---|---|---|---|
| **`ink/student_v3`** | 8,251 | ✅ True | `data_museum` | ✅ **板上运行中**（ch24） |

**板上的 bit 必须与固件系数配对**：
- bit：`outflow_panelsw2`
- 固件：`demo/reports/ink/firmware/soc_video_app_v3.bin`（MD5 `1db2f458a94ce7436b1851644000b6f7`）

---

## 二、剪枝尝试结果（两个都失败）

### 2.1 ch12（失败）

| 项 | 值 |
|---|---|
| 参数 | 3,717（3.6 KB，−55%） |
| MAC | 103.7M（−49.2%） |
| 训练 | 5000 步，loss 4.592，QAT ✅ |
| **量化 PSNR** | **35.68 dB** ✅（标定正常） |
| **上板** | ❌ **自检失败，网络输出恒为零**（`0x00808080` 中性灰） |

**排查结论**（详见 [CH12_FULL_DIAGNOSIS.md](ink/CH12_FULL_DIAGNOSIS.md)）：

| 已排除项 | 结论 |
|---|---|
| 通道分组 / 行对齐 / 写打包 / 3×3 约束 / depthwise 边界 / 系数槽容量 / norm 溢出 / 输入字节序 / 系数结构 | **全部正确** |
| 板上 APB 寄存器（16 个） | 版本✅、系数 6144/6144 装载✅、`last_cycles=30,818`（32×24 合理）✅ |
| **失败点** | 推理正常完成，但**输出像素与固件 expected 不符（返回 -6）** |

**关键结构差异**：ch12 的 1×1 层 `red_groups = ceil(12/12) = 1`，而 ch24 是 2 —— **ch12 是唯一 `red_groups=1` 的模型**。

### 2.2 ch16（第一次失败，第一次用错配方）

| 项 | 值 | 判定 |
|---|---|---|
| 参数 | 5,289（5.2 KB） | ✅ |
| 训练 | 5000 步，loss 4.853，QAT ✅ | ✅ |
| **激活 max** | **3.2 – 954.3** | ❌ **比健康模型大 40 倍** |
| **量化 PSNR** | **9.15 dB** | ❌ **不可用** |

**根因**：⚠️ **我用了错误的训练配方**（照抄 ch12 的错配方）。

---

## 三、⭐ 训练配方教训（重要）

**必须用 `student_v3` 的 config 作为配方基准，不能用 ch12 的。**

| 参数 | **student_v3（正确）** | 我用的错误值 |
|---|---|---|
| **size** | **512** | 256 |
| **qat_after** | **3000** | 3500 |
| **distill_weight** | **30** | 5 |
| **identity_weight** | **10.0** | **0（缺失）** |
| **grain_weight** | **550** | **0（缺失）** |
| **tone_weight** | **300** | **0（缺失）** |
| **quantile_weight** | **0.3** | **0（缺失）** |
| **cast_weight** | **1.0** | **0（缺失）** |
| content_weight | **0.7** | 1 |
| contrast_ratio | **0.65** | 0.86 |
| tv_weight | **0.0** | 0.03 |

**共 33 项参数不同，5 个关键约束全部缺失。**

### 判据：健康模型的激活 max 必须 < 25

| 模型 | 激活 max | 量化 PSNR |
|---|---|---|
| ch12 | 1.1–16.2 | 35.68 dB ✅ |
| ukiyoe v15 (ch24) | 1.4–23.4 | 34.4 dB ✅ |
| ukiyoe v3 (ch24) | 1.4–16.6 | 33.8 dB ✅ |
| **ch16（错配方）** | **3.2–954.3** | **9.15 dB** ❌ |

**→ 训练后第一件事：查 `calib_*/scales.json` 的 `maxima`，> 25 即配方有问题。**

---

## 四、RTL 的模型硬约束（训新模型必查）

| 项 | 约束 | 说明 |
|---|---|---|
| **3×3 非 depthwise** | **ci 必须 == 3** | 只有 layer 0 符合；其他 3×3 必须 depthwise |
| **1×1 pointwise** | `ci <= 24`, `co <= 32` | |
| **通道分组** | `co_groups = ceil(co/8)` | 最后一组不满 8 时靠边界置零 |
| **red_groups** | `dw?1 : k3?3 : ceil(ci/12)` | |
| **层数** | 23 层拓扑 | `program.py` 按 `graph.json` 生成 |
| **系数槽** | 256 槽（每槽 24 词） | ch24 用 86 槽 |

### ⚠️ ch12 的教训

`red_groups=1`（ci=12）与 ch24 的 2 不同 —— **这是 ch12 唯一的结构差异，是后续排查重点**。

---

## 五、当前进行中

| 项 | 状态 |
|---|---|
| **`student_ch16b`** | ⏳ **训练中**（正确配方，512×512，5000 步） |
| 预计时长 | **约 5.2 小时**（3.74 s/step） |
| 输出 | `reports/ink/student_ch16b` |

---

## 六、导出流程（已验证可用）

```bash
# 1) 标定
python ml/style_transfer/calibrate.py \
  --checkpoint <ckpt>.pt --manifest <manifest>.json --out reports/ink/calib_X

# 2) 检查 maxima < 25（关键！）
python -c "import json;d=json.load(open('reports/ink/calib_X/scales.json'));print(max(d['maxima']))"

# 3) 导出
python ml/style_transfer/export.py --checkpoint <ckpt>.pt --out reports/ink/export_X

# 4) 生成 RTL
python ml/style_transfer/program.py --model reports/ink/export_X --out <目标目录>
```

**⚠️ 两个已知坑**：

| 坑 | 说明 |
|---|---|
| **`calibrate.py` 曾硬编码 `Student()` 和层索引** | 已修：改为从 config 重建 + 动态推导索引 |
| **固件必须与 RTL 同源** | `style_weights.h` 需从 `rtl/style/model/coeff.bin` 生成；`style_selftest.h` 需从同一 export 的整数 oracle 生成 |

**验证同源的方法**：
```bash
# 权重：固件 vs RTL coeff.bin 应 6144/6144 匹配
# 自检：固件 expected vs IntegerNetwork(export) 应 768/768 匹配
```

---

## 七、固件编译（工具链已装）

**工具链**：`D:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin`（GCC 13.4.0）

**⚠️ Python 的 subprocess 包装会让该工具链崩溃（exit 0xC0000409）**，必须用 bash 脚本直接调用：
```bash
bash tools/build_firmware.sh
```

**⚠️ 编译目标是 `demo/software/firmware/`**（不是新架构目录！两者是不同文件）。

**可复现性判据**：ch24 固件重编后 MD5 应为 `1db2f458a94ce7436b1851644000b6f7`。

---

## 八、相关报告（未归档）

| 文件 | 内容 |
|---|---|
| [CH12_FULL_DIAGNOSIS.md](ink/CH12_FULL_DIAGNOSIS.md) | ch12 全面排查（RTL 逐项验证 + APB 解码） |
| [MODEL_SWITCH_VALIDATION.md](ink/MODEL_SWITCH_VALIDATION.md) | 模型切换离线验证 |
| [PARAM_SIZE_ANALYSIS.md](ink/PARAM_SIZE_ANALYSIS.md) | 参数量分析（为何 500KB 限制） |
