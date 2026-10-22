# 分工方案：本工作区训练 + 初步验证；上板用新架构

> 日期：2026-10-20
> 结论：**可行，且比整体迁移更干净**（零 RTL 改动、零冲突）

---

## 一、方案

| 环节 | 在哪做 | 用什么 |
|---|---|---|
| **训练** | **本工作区** | 我们的 `tools/analysis/_train_v2.py`（含 v2–v6 全部损失项） |
| **初步验证**（浮点/整数对拍、指标） | **本工作区** | `ml/style_transfer/evaluate.py` + `integer.py` |
| **上板**（编译/烧录/串口） | **新架构** | `feature/resource_optimize` 的完整工程 |
| **模型交付** | 本工作区 → 新架构 | **只交付 8 个模型文件** |

**核心**：新架构**不接收**我们的 RTL 改动，**只接收训练产物**。

---

## 二、为什么可行：三项条件全部验证通过

### 条件 1：产物格式兼容 ✅

| 文件 | 我们 | 远端 | 兼容 |
|---|---|---|---|
| `model.bin` | 11,056 B | 11,056 B | ✅ **同尺寸同格式** |
| `coeff.bin` | 24,576 B | 24,576 B | ✅ |
| `coeff.hex` | 49,664 B | 49,664 B | ✅ |
| `graph.json` | 10,011 B | 10,061 B | ✅ **字段完全一致** |
| `program.hex` / `.vh` | 966 / 1,915 B | 966 / 1,915 B | ✅ **同格式** |

### 条件 2：新架构**不需要**我们的 RTL 改动 ✅

**关键发现**：新架构的 `program.py` 与 `style_network.sv` 是**自洽的一对**：

| 侧 | 实现 |
|---|---|
| `ml/style_transfer/program.py`（远端，33 行） | **硬编码 23 层拓扑**（`pairs`/`inlevels`/`outlevels`），**无 bit132** |
| `rtl/style/style_network.sv`（远端） | `dst = layer_index==22 ? result_address : ...`，**固定 23 层** |

**两侧都假定 23 层 → 互相匹配，不需要我们的 `is_last`。**

**对比我们的版本**（145 行 `program.py` + `is_last`）是为了支持**可变层数**（head 或其它层数可追加）。
**既然新架构固定 23 层，我们的 is_last 就是多余的。**

### 条件 3：`program.py` 能消费我们的模型 ✅

| 检查 | 结果 |
|---|---|
| 我们的 `graph.json` 层数 | **23**（与远端相同） |
| `program.py` 所需字段 | `ci`/`co`/`kernel`/`dw`/`stride`/`upsample`/`residual`/`relu`/`weight_base`/`norm_base`/`name` |
| 我们的字段缺失 | **无 ✓** |
| 双方 layer0 键 | **完全一致（17 个键全同）** |

### 附：描述符逐位对比（**决定性证据**）

对比我们与远端的 `program.vh`：

```
我们 23 条 / 远端 23 条
层 22 差异: XOR = 0x10000000000000000000000000000000
完全相同的描述符: 22/23
```

**`XOR = 2^132`** —— 唯一差异就是 **bit132（我们的 is_last）**。
**其余 22 个描述符逐位相同 → 拓扑完全等价。**

---

## 三、交付物清单（本工作区 → 新架构）

### 必交付：8 个模型文件

```
rtl/style/model/model.bin          11,056 B
rtl/style/model/coeff.bin          24,576 B
rtl/style/model/coeff.hex          49,664 B
rtl/style/model/graph.json         （我们的）
rtl/style/model/program.hex        （在新架构重新生成，或直接给）
rtl/style/model/program.vh         （同上）
rtl/style/model/program.json       （同上）
rtl/style/model/style_weights.h    76,953 B
```

### ⚠️ 关键：`program.*` 建议在**新架构重新生成**

因为新架构的 `program.py` 会：
- 用**它的**固定 `pairs`/`inlevels`/`outlevels`
- **不写 bit132**

若直接搬我们的 `program.vh`（含 bit132），而新架构的 `style_network.sv` **不读** bit132 →
**无害**（该位被忽略），但**指标不一致**。

**推荐做法**：只交付 `graph.json` / `model.bin` / `coeff.bin`，
在**新架构**跑它的 `program.py` 生成 `program.*` 与 `style_weights.h`。

```bash
# 在新架构执行
python ml/style_transfer/program.py --model <我们导出的目录> --out rtl/style/model
```

### 不交付（避免回退）

| 内容 | 原因 |
|---|---|
| 我们的 `rtl/style/style_network.sv` | 新架构有自己的（含 prefetch） |
| 我们的 `rtl/style/style_display.sv` | 新架构有自己的（且我们的单面板版更优，但若上板用新架构则不动它） |
| 我们的 `tools/analysis/*` | 只在本工作区用 |
| 我们的 `ml/style_transfer/program.py` | 新架构有自己的 |

---

## 四、⚠️ 一个必须注意的取舍

### 单面板 vs 双面板

| | 显示模式 | DRB（实板实测） |
|---|---|---|
| **我们的** | 单面板 640 | **4,695,168** |
| **新架构的** | 双面板 1280 | 9,392,768 |

**若上板完全用新架构，显示读流量会翻倍（DRB ×2）。**

新架构自己的注释就说明了双面板「doubled the DDR read traffic」。

**两个选择**：
| 选项 | 含义 |
|---|---|
| **A. 上板也用我们的单面板** | 需把我们的 `style_display.sv` 也带过去（**这是唯一值得携带的 RTL**） |
| **B. 完全用新架构** | 接受 DRB 翻倍（但新架构可能已有其它优化补偿） |

**建议**：**只额外携带 `style_display.sv`**（1 个文件），因为它的收益**已实板实测**（−50% DRB）。
其余 RTL 全部用新架构的。

---

## 五、工作流

```
本工作区                         新架构
────────                         ────────
① 训练（_train_v2.py）
   产出 checkpoint (.pt)
        │
② 初步验证
   - 整数/浮点对拍 (integer.py)
   - 指标评估 (evaluate.py)
   - 导出 (export.py → graph.json/model.bin/coeff.bin)
        │
        └──── 交付 8 个文件 ────► ③ 生成 program.*
                                   python ml/style_transfer/program.py
                                        │
                                   ④ 编译 + 烧录 + 串口验证
                                        │
                                   ⑤ 实板遥测（RPMS/CPMS/DRB/UF）
                                        │
        ◄──── 反馈结果 ────────────────┘
        （若帧率/画质不达标 -> 回① 重训）
```

---

## 六、结论

| 问题 | 答案 |
|---|---|
| **方案可行吗？** | ✅ **可行，且比整体迁移更干净** |
| **训练能留本工作区？** | ✅ 训练是纯 PyTorch，与架构无关 |
| **新架构能直接用我们的模型？** | ✅ **格式兼容、字段一致、拓扑等价** |
| **需要带去我们的 RTL 吗？** | ◐ **只需 1 个**（`style_display.sv`，因实板实测 −50% DRB） |
| **is_last 还需要吗？** | ❌ **不需要**（新架构固定 23 层，两侧自洽） |
| **冲突点** | ✅ **零冲突** |

**一句话**：**本工作区专心训练与初步验证；交付 `graph.json` + `model.bin` + `coeff.bin`，
在新架构重新生成 `program.*` 并上板。唯一建议额外携带的文件是 `style_display.sv`。**

---

## 七、诚实边界

| 项 | 状态 |
|---|---|
| 产物格式兼容 | ✅ **逐位核实**（22/23 描述符相同，唯一差异 = bit132） |
| graph.json 字段一致 | ✅ **逐键核实（17 键全同）** |
| 新架构两侧自洽（23 层） | ✅ 实测（program.py + style_network.sv 都用 22） |
| 零 RTL 冲突 | ✅ 实测 |
| **交付后能否编译通过** | ❌ **未验证** |
| **交付后实板帧率/画质** | ❌ **未验证** |
| **新架构 program.py 对 head 层的处理** | ❌ 未验证（它硬编码 23 层，若模型层数不同会出错） |
