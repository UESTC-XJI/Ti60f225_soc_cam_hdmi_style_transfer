# 风格迁移框架选型评估

> 评估日期：2026-10-13
> 评估对象：四种 fast-neural-style 类方案 vs 本项目（Ti60F225 风格迁移 Demo）
> 方法：全部结论均来自对本仓库代码与产物的**实测核查**，非文献推测。

---

## 0. 结论摘要

| 候选方案 | 外部评分 | 本评估 | 核心理由 |
|---|---|---|---|
| `pytorch/examples/fast_neural_style` | ★★★ | **★★** | 架构同源，但 9×9 卷积 RTL 不支持；ONNX 中间层对本项目无用 |
| `yakhyo/fast-neural-style-transfer` | ★★★ | **★★** | 同样 9×9；ONNX→INT8 量化格式与本项目定点格式不兼容 |
| `floydhub/fast-style-transfer`（TensorFlow） | ★★ | **★** | 生态不同 + 同样 9×9；量化文档面向移动端 |
| TFLite style_transfer + 量化博文 | ★★★ | **★★★（仅方法）** | 量化思路可借鉴；但描述中的部署事实与本项目不符 |

**总体建议：不更换框架。** 当前 `Student` 已是 fast-neural-style 的轻量同源实现，换框架不解决根本问题，反而引入新的资源需求（RAM 已零余量）。

---

## 1. 必须先纠正的三处事实错误

外部评估表中包含三处与实测不符的描述，这些会直接误导技术决策。

### 1.1 错误：权重体积「16,920 B」

| 项 | 声称 | **实测** | 来源 |
|---|---|---|---|
| INT8 权重 | 16,920 B | **11,056 B** | `ml/style_transfer/artifacts/integer/model.bin` |
| 系数 ROM 镜像 | — | 24,576 B | `.../integer/coeff.bin` |
| 固件权重头 | — | 76,953 B | `software/firmware/style_weights.h` |
| FP32 checkpoint | — | 200,123 B | `.../student_qat.pt` |

**「16920」的真实来源**：它是 `reports/style_demo/data_v2/manifest.json` 中一段 SHA256 哈希的**巧合子串**：

```
"rgb_sha256": "0f31e8d062cafc217a151ca169208fe5fcbdf0cf0ee673d7221374d23f948b3c",
                                    ^^^^^
```

全仓库搜索 `16920` 只有这一处命中。**它不是任何权重文件的体积。**

### 1.2 错误：权重「放 DDR3、切换重载权重」

实测的权重存放与更新机制是**两个位置**，都不在 DDR3：

```
① FPGA 初始化 ROM
   rtl/style/model/coeff.hex  --$readmemh-->  编译进 bitstream
   生成器：ml/style_transfer/export.py

② CPU 固件（开机经 APB 下载，覆盖 ROM）
   software/firmware/style_weights.h  -->  编译进 ELF
   来源：tools/prepare_style_firmware.py（原样复制 ① 的产物）
   下载：software/firmware/style_driver.c 逐字写 APB（STYLE_BASE = 0xf8100200）
```

**没有运行时从 DDR3 重载权重切换风格的机制。** 搜索 `ddr.*weight` / `weight.*ddr` / `reload` / `switch.*style` 均无匹配。

**实际切风格的成本**：重新编译 bitstream，或重新编译 ELF。

### 1.3 遗漏：RTL 只支持 1×1 和 3×3 卷积

这是最关键的遗漏。核查 `rtl/style/style_row_core.sv`：

```verilog
input wire kernel3, depthwise, stride2, upsample2, use_residual, do_relu, ...
reg [191:0] patch[0:8], patch_skip;      // 9 槽 = 恰好一个 3×3 邻域
virtual_x = ... + (kernel3 ? column-1 : 0);
red_groups <= depthwise ? 1 : kernel3 ? 3 : (input_channels+11)/12;
```

- `kernel3` 是**布尔信号**，只区分 3×3 与 1×1
- `patch[0:8]` 是 9 个 192-bit 槽，正好容纳一个 3×3 邻域
- **没有 5×5 / 7×7 / 9×9 的代码路径**

`graph.json` 实测也印证：23 层中 kernel 只出现 **1 和 3**。

而 **Johnson 架构的核心正是 9×9 头尾卷积**（大感受野捕捉整体色调）。这是四种候选方案共同的、无法绕开的障碍。

---

## 2. 逐路径分析

### 2.1 `pytorch/examples/fast_neural_style`（官方）——★★

**架构对比**（Johnson 的 TransformerNet vs 本项目 Student）：

| 阶段 | Johnson TransformerNet | 本项目 Student |
|---|---|---|
| 头部 | **Conv 9×9** + InstanceNorm + ReLU | Conv 3×3 s2（无大核） |
| 下采样 | 2× Conv3×3 s2 | 2×（3×3 s2 + DWConv3×3 s2） |
| 主体 | 5× ResidualBlock(ngf×4) | 4× block[3×3,1×1,3×3,1×1] |
| 上采样 | 2× ConvTranspose/Upsample | 2× nearest 2× |
| 尾部 | **Conv 9×9** → Tanh | Conv 1×1（无 Tanh） |
| 归一化 | InstanceNorm | BatchNorm（QAT 冻结） |

**同源之处**：都是 encoder → residual → decoder 的拓扑。这是候选方案中最接近的。

**三处不兼容**：

| 项 | 问题 | 后果 |
|---|---|---|
| **9×9 头尾卷积** | RTL 不支持 | 需堆叠 3×3 替代（改变感受野），或扩展 RTL 到 9 行行缓冲 |
| **InstanceNorm** | 本项目用 BatchNorm + QAT 冻结 | 导出链的 BN 折叠逻辑需重写 |
| **Tanh 输出** | 本项目是手工定点（M16/B32/shift8） | 输出层量化方式不同 |

**「转 ONNX 有官方教程」这条对本项目无效**。核查 `ml/style_transfer/export.py`：

```python
ck = torch.load(a.checkpoint, map_location='cpu', weights_only=False)
model = Student(); model.load_state_dict(ck['model']); model.eval()
# 手工对称量化
w = away(wf / ws[:,None,None,None]).clip(-127,127).astype(np.int8)
# 手工折叠 BN 到 affine
factor = gain * ws * m.in_scale / m.out_scale
mi = int(away(f * (1<<r))); bi = int(away(b * (1<<r)))
assert bound < (1<<63)
```

导出链**直接读 PyTorch state_dict，手工折叠 BN，写定点 coeff.hex**。ONNX 是多余的中间层，引入它只会增加转换误差。

### 2.2 `yakhyo/fast-neural-style-transfer`——★★

**它提供的**：现成 ONNX + PyTorch 权重。

**两个问题**：

1. **同样基于 Johnson 架构（9×9）** —— 与 2.1 相同的 RTL 障碍
2. **「ONNX→INT8」与本项目量化格式不兼容**

本项目的量化**不是标准 INT8 量化**，而是特定定点格式：

| 项 | 本项目 | 标准 ONNX INT8 量化 |
|---|---|---|
| 权重 | int8 对称，per-output-channel scale | int8 + scale/zero_point |
| 乘子 | **M16**（16-bit 定点） | float scale |
| 偏置 | **B32**（32-bit 整数） | int32 |
| 缩放 | **shift 右移**（每通道独立 r） | float 反量化 |
| 精度要求 | **整数精确**（有算术边界证明） | 允许近似 |

标准量化工具产出的是**通用格式**，与本项目的 **M16/B32/shift8** 完全不同。要走这条路必须**重写导出器**——工作量超过直接改进现有管线。

### 2.3 `floydhub/fast-style-transfer`（TensorFlow）——★

**排除理由**：

1. **TensorFlow 生态** —— 本项目是 PyTorch，无交集
2. **同样是 9×9 Johnson 架构** —— 相同的 RTL 障碍
3. **量化→TFLite 文档面向移动端 ARM** —— 不是 FPGA

这条路径**没有任何可复用部分**。

### 2.4 TFLite style_transfer + 量化博文——★★★（仅方法层面）

**唯一值得借鉴的路径**，但要区分「方法」与「部署描述」。

✅ **可借鉴的（方法层面）**：

post-training INT8 量化流程 —— 这与本项目 `calibrate.py` 做的**本质相同**：

```python
# calibrate.py 实际实现
maxima[i] = max(maxima[i], output.abs().max().item())    # 逐层收集最大值
scales = [2**ceil(log2(max(m,1e-5)/127)) for m in maxima] # 定 activation scale
# 残差层用统一的 common scale
for i in (2,6,10,14,18): scales[i] = common
```

**可参考的改进点**：
- TFLite 的校准集选择策略（分层采样、覆盖典型场景）
- 量化误差的逐层诊断方法
- 已实现部分：`calibrate.py` 输出 FP32 / global_1_32 / global_1_16 / global_1_8 / global_1_4 / calibrated 六种候选的 MSE + PSNR 对比

❌ **与实测不符的（部署描述）**：见 §1.1、§1.2。

---

## 3. 真正的硬约束：资源已到极限

无论选哪条路径，都撞同一面墙。

### 3.1 实测资源占用

来源：`reports/style_demo/release_display_deadline/manifest.json`

| 资源 | 使用 | 容量 | 占用率 | 余量 |
|---|---|---|---|---|
| **RAM** | 256 | 256 | **100%** | **0** |
| XLR | 57,870 | 60,800 | 95.2% | 2,930 |
| DSP | 140 | 160 | 87.5% | 20 |

### 3.2 各配置的参数量对比

以 Johnson TransformerNet（5 残差块）为例：

| 配置 | 参数量 | INT8 体积 | vs 当前 Student |
|---|---|---|---|
| **当前 Student（部署）** | **8,251** | **11,056 B** | 1× |
| Johnson ngf=16 | 423,299 | 0.42 MB | **51.3×** |
| Johnson ngf=32 | 1,676,035 | 1.68 MB | 203.1× |
| Johnson ngf=64 | 6,669,827 | 6.67 MB | 808.4× |
| Johnson ngf=128 | 26,610,691 | 26.6 MB | 3225.2× |

> **参数量核查说明**：`Student` 的 8,251 参数与 `docs/STYLE_DEMO_IMPLEMENTATION.md` 记录一致，
> 并已用 PyTorch 实测确认（`sum(p.numel() for p in Student().parameters())`）。
> 分层实测：enc 560 / res 7,104 / dec 587。
> 注意 `model.py` 的 `Layer` 用 `bias=not bn` —— 带 BatchNorm 的层卷积无 bias；
> 而 Johnson 用 InstanceNorm，按官方 `networks.py` 的规则 `use_bias=True`（有 bias）。

**即使缩到最小的 ngf=16，参数量也是当前的 51.3 倍。**

### 3.3 9×9 卷积的额外 RAM 开销

权重只是问题的一半。**9×9 卷积需要 9 行行缓冲**：

```
当前 3×3：patch[0:8] = 9 槽（3 行 × 3 列）
9×9 需要：9 行 × 9 列 = 81 个采样点
        => 行缓冲深度从 3 行增加到 9 行，RAM 开销 ×3
```

而 `style_row_core.sv` 中三个行缓冲（`row0lo/hi`、`row1lo/hi`、`row2lo/hi`）合计约占 **100 块 RAM 中的大部分**。翻三倍意味着 **RAM 需求远超 256 上限**。

**结论：换框架不解决根本问题，反而制造更大的资源缺口。**

---

## 4. 当前架构的真实定位

需要澄清一个常见误解：**当前 Student 并不是"简化版 Johnson"，而是针对硬件约束重新设计的定点网络。**

| 维度 | 当前 Student | Johnson |
|---|---|---|
| 参数量 | 8,251 | 423,299（最小配置 ngf=16） |
| 卷积核 | 1×1, 3×3（含 depthwise） | 9×9, 3×3 |
| 归一化 | BatchNorm（QAT 冻结，可折叠） | InstanceNorm |
| 量化 | QAT + 显式 BN 折叠 + 定点导出 | 无（FP32） |
| 输出 | 定点 u8 | Tanh → [-1,1] |
| 计算分辨率 | 160×120（4× 降采样） | 任意（通常全分辨率） |
| 实测帧率 | 9–10 fps | — |

**关键差异**：当前网络的 **1×1 + 3×3 + depthwise** 组合是为「96 路 MAC 引擎 + 24 bank 系数 ROM」量身定制的。Johnson 的 9×9 无法映射到这个引擎上。

---

## 5. 建议

### 5.1 不换框架

三个理由：

1. **架构同源** —— 当前 Student 已是 encoder-res-decoder 拓扑，换过去无本质收益
2. **9×9 是硬障碍** —— RTL 不支持，扩展需大量 RAM
3. **RAM 零余量** —— 任何放大都装不下

### 5.2 真正值得做的事

| 方向 | 做法 | 收益 | 代价 |
|---|---|---|---|
| **提高训练分辨率** | `train.py:32` 的 `image_tensor(size=256)` → 512 | 训练内部 64×64 → 128×128，更接近推理的 160×120 | 显存 ~7GB，batch 降到 4–6 |
| **加大蒸馏权重** | `--distill-weight` 5 → 10~20 | 强化对高分辨率教师的模仿 | 无额外资源 |
| **降低 TV 权重** | `.03` → `.01~.02`（需参数化） | 保住浮世绘的平涂边界 | 需改代码 |
| **借鉴量化方法** | 参考 TFLite 的校准集选择策略 | 改善 INT8 精度 | 无额外资源 |
| **在预算内调架构** | channels=24→32, blocks=4→3 | 略增表达力 | ⚠️ 受 RAM 限制 |

### 5.3 若确实需要更强的风格能力

必须**先做资源回收**，路径见 `docs/RESOURCE_OPTIMIZATION_PLAN.md`（作者的 P1/P2/P3 方案）：

| 方案 | 内容 | 预期回收 |
|---|---|---|
| P1 | 统计/字符数组映射到 BRAM | 部分 LUT → RAM |
| P2 | 关闭自动视频 Debugger | ~1,467 XLR + 1 存储块 |
| P3 | 只保留 RAW10 解包 | — |

**回收 RAM 之后**，才谈得上考虑更大的网络或 9×9 支持。

---

## 6. 附录：核查方法

本评估的所有数字均可复现：

| 断言 | 核查方式 |
|---|---|
| 权重体积 11,056 B | `(Get-Item ml\style_transfer\artifacts\integer\model.bin).Length` |
| 「16920」是哈希子串 | `Select-String -Pattern '16920' -Path reports\style_demo\data_v2\manifest.json` |
| RTL 只支持 1×1/3×3 | `Select-String -Path rtl\style\style_row_core.sv -Pattern 'kernel3'` |
| graph.json 只有 kernel 1/3 | 解析 `rtl/style/model/graph.json` 的 `layers[].kernel` |
| 无 DDR3 重载机制 | `Select-String -Path software\firmware\*.c -Pattern 'ddr.*weight|reload'` |
| 导出链不经 ONNX | `Select-String -Path ml\style_transfer\export.py -Pattern 'import'` |
| 资源占用 256/256 | `reports/style_demo/release_display_deadline/manifest.json` → `resources` |
| 参数量对比 | 按 `networks.py` / `model.py` 拓扑纯算术推算 |

---

## 附：相关文档

| 文档 | 内容 |
|---|---|
| `STAR_STYLE_TRAINING_PLAN.md` | 星空风格训练计划（含尺度分析） |
| `UKIYOE_TRAINING_PLAN.md` | 浮世绘风格训练计划 |
| `docs/STYLE_DEMO_IMPLEMENTATION.md` | 当前实现的权威说明 |
| `docs/RESOURCE_OPTIMIZATION_PLAN.md` | 作者的资源回收方案 |
| `pytorch-CycleGAN-and-pix2pix-阅读笔记.md` | CycleGAN/pix2pix 框架阅读笔记 |
| `ml/style_transfer/README.md` | 训练/导出管线的原始记录 |
