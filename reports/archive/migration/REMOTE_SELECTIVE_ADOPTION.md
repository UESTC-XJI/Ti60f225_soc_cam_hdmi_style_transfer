# 从 feature/resource_optimize 选择性取用清单

> 日期：2026-10-20
> 方式：**只取需要的文件**（不动工作分支）
> 远端已导出到 `../_remote_resource_optimize/`（849 文件，只读参考）

---

## 一、核心结论：远端与我们是**互相冲突**的两条线

| 项 | 我们（HEAD `98cf693`） | 远端（`bfc5b5e`） |
|---|---|---|
| 共同祖先 | `bf47dfa`（**2026-10-06**） | 同 |
| 独有提交 | **23** | 5 |
| `tools/analysis` | **9 文件** | **0** ❌ |
| `reports/ink` | **22 文件** | **0** ❌ |

**已用 `git archive` 把远端全量导出到独立目录**，所以取文件时**完全不触碰工作区**。

---

## 二、逐文件判定（RTL 差异只有 7 个文件）

| 文件 | 差异 | 谁更新 | **建议** |
|---|---|---|---|
| **`rtl/style/style_display.sv`** | 33 行 | ✅ **我们**（单面板居中 640） | ❌ **不取**（远端是旧的 A/B 双面板 1280） |
| **`rtl/style/style_network.sv`** | 42 行 | ◐ **双向**（我们：`is_last` 标志；远端：prefetch 遥测） | ⚠️ **需人工合并** |
| **`rtl/style/style_accel.sv`** | 8 行 | ✅ 远端（prefetch 遥测寄存器） | ◐ **与 network 配套才有效** |
| **`rtl/soc_integration/osd_font8x16.sv`** | 16 行 | ✅ **远端**（ROM 4096→2048，省存储块） | ✅ **可安全取用** |
| **`rtl/isp/capture_frame_stats.sv`** | 26 行 | ✅ **远端**（位宽按边界收窄，省 LUT） | ✅ **可安全取用** |
| `rtl/soc_integration/axi_shared_ddr_2m.sv` | 34 行 | ◐ 格式/参数化 | ◐ 低价值 |
| `rtl/soc_integration/soc_video_ddr_integration.sv` | 2 行 | ◐ 删 `io_memoryClk` | ✅ 小改，可评估 |

---

## 三、关键判断：两个「我们更新」的文件**不可覆盖**

### 1. `style_display.sv` —— 远端是**旧版**

| | 显示模式 |
|---|---|
| **远端** | `image = v 145..625, h 260..1540`（**1280 宽 = A/B 双面板**） |
| **我们** | `image = v 145..625, h 580..1220`（**640 宽 = 单面板居中**） |

**远端不含 `SINGLE-PANEL` 标记。** 我们的单面板改动同时**把显示 DDR 读流量减半**
（远端注释自己说明了双面板会"doubled the DDR read traffic"）。

**若取远端版 → 显示退回双面板，DDR 读翻倍。**

### 2. `style_network.sv` —— 双向改动，冲突

| | `dst` 的判定 |
|---|---|
| **远端** | `layer_index==22 ? result_address : ...` |
| **我们** | `is_last(descriptor[132]) ? result_address : ...` |

我们的版本用**描述符位 132**（`program.py` 生成），使层数可变；
远端硬编码 `layer_index==22`。

**但远端同时新增了 prefetch 遥测（16 处）** —— 这是我们没有的功能。

**→ 必须人工合并，不能整文件覆盖。**

---

## 四、建议取用清单

### ✅ 可安全取用（2 个文件，独立且远端更新）

| 文件 | 收益 | 风险 |
|---|---|---|
| `rtl/soc_integration/osd_font8x16.sv` | 字符 ROM **4096→2048**（省存储块） | 低：未知字符走空白行，语义保留 |
| `rtl/isp/capture_frame_stats.sv` | 内部位宽按边界收窄（**省 LUT**） | 低：对外 32 位字段保留（远端报告已回归） |

### ◐ 需评估后取用（1 个）

| 文件 | 说明 |
|---|---|
| `rtl/soc_integration/soc_video_ddr_integration.sv` | 删 `io_memoryClk`（2 行）—— 但**依赖 soc.v 的 Lite 改动**，单独取可能不成立 |

### ⚠️ 不可整文件覆盖（2 个，需人工合并）

| 文件 | 原因 |
|---|---|
| `rtl/style/style_display.sv` | 远端是旧的双面板版 |
| `rtl/style/style_network.sv` | 双向改动（我们 is_last vs 远端 prefetch） |

### ❌ 不取（大件，与我们冲突）

| 项 | 原因 |
|---|---|
| `soc/efx_sapphire_soc/soc/soc.v`（1.6 MB） | 远端做了 **Lite 统一时钟**（删 DDR CDC FIFO）；我们是另一套 SoC 集成 |
| `debug_profile.wizard.json` | 远端删 la0–la3 逻辑分析仪（**诊断能力**） |
| 远端 `model.bin` / `style_weights.h` | **独立训练的 CNN 权重**，与我们 v6 无关，覆盖会破坏我们的模型 |
| 远端 `ml/style_transfer/train.py` | 与我们 `tools/analysis/_train_v2.py`（含 v2–v6 全部损失项）不同源 |

---

## 五、取用的技术方式（不触碰工作区）

```bash
# 方式 A：从已导出的目录复制（最安全，零 git 操作）
cp ../_remote_resource_optimize/rtl/soc_integration/osd_font8x16.sv rtl/soc_integration/
cp ../_remote_resource_optimize/rtl/isp/capture_frame_stats.sv rtl/isp/

# 方式 B：用 git checkout 单文件（会在暂存区留下记录）
git checkout origin/feature/resource_optimize -- <path>

# 方式 C：生成差异补丁，人工审阅后套用（推荐用于需合并的文件）
git diff HEAD origin/feature/resource_optimize -- rtl/style/style_network.sv > /tmp/network.patch
```

**推荐：安全文件用 A，需合并文件用 C（先看补丁再决定）。**

---

## 六、必须一并注意的风险

| # | 风险 | 说明 |
|---|---|---|
| 1 | **取远端 style_network 会丢 `is_last`** | 层数变回硬编码 22 |
| 2 | **取远端 style_display 会退回双面板** | DDR 读流量翻倍（与我们的优化相反） |
| 3 | **prefetch 需 network+accel 配套** | 只取 accel 的遥测寄存器没有意义 |
| 4 | **权重文件绝不可覆盖** | 远端 `model.bin` 是另一版训练结果 |
| 5 | **soc.v 类文件不要取** | 1.6 MB 且与我们的 SoC 集成冲突 |

---

## 七、诚实边界

| 项 | 状态 |
|---|---|
| 远端已安全导出 | ✅ 849 文件到 `../_remote_resource_optimize/` |
| RTL 差异已逐文件判定 | ✅ 只有 7 个文件 |
| 「我们更新」的 2 个文件已确认 | ✅ 实测（SINGLE-PANEL、descriptor[132]） |
| 「远端更新」的 2 个文件已确认 | ✅ 实测（ROM 减半、位宽收窄） |
| **取用后能否编译通过** | ❌ **未验证**（需实际 build） |
| **取用后资源收益** | ❌ **未量化**（远端报告的是它自己整套的数字） |
| 远端 prefetch 的完整价值 | ❌ 未评估（需读 3 个文件的合并效果） |
