# 任务 1 交付：仲裁参数 A/B 编译完成

> 日期：2026-10-20
> 改动：`URGENT_OVERRIDES_FAIRNESS` 从硬编码 `1'b1` 改为参数
> 状态：**两个 bit 均已编译成功，等待上板对比**

---

## 一、改动内容（2 个文件，可回滚）

### 1. `rtl/style/style_video_system.sv`

**新增参数**（默认值 = 原行为）：

```verilog
module style_video_system #(parameter bit DISPLAY_BUFFER=1'b1,ADAPTIVE_READ=1'b1,
                            parameter bit URGENT_OVERRIDES_FAIRNESS=1'b1)(
```

**实例化处**：
```verilog
axi_shared_ddr_2m #(... .URGENT_OVERRIDES_FAIRNESS(URGENT_OVERRIDES_FAIRNESS) ...) bridge(...)
```

### 2. `rtl/ti60f225_oob_top.v`

**单行 A/B 开关**：
```verilog
// A/B knob for the CNN/display read arbiter.  1'b1 = original, 1'b0 = fair round-robin
localparam bit STYLE_UOF = 1'b1;      // <- 只需改这一个字面量
style_video_system #(.URGENT_OVERRIDES_FAIRNESS(STYLE_UOF)) style_demo(
```

---

## 二、A/B 编译结果

| 变体 | bit 大小 | SHA256(前16) | **XLR** | 最紧 setup slack |
|---|---|---|---|---|
| **UOF=1**（原行为） | 3,173,082 B | `d912f167adea4f61` | **55,718（91.64%）** | **0.273 ns** |
| **UOF=0**（公平轮转） | 3,184,320 B | `eec61eef42799d03` | **55,857（91.87%）** | **0.364 ns** |

### 关键验证：默认值不改行为

| 对比 | UOF=1（参数化） | v3（原始硬编码） |
|---|---|---|
| bit 大小 | 3,173,082 B | **3,173,082 B** |
| **XLR** | **55,718** | **55,718** |

**→ 参数化在默认值下完全不改变综合结果。**（SHA 不同是 bitstream 时间戳/种子导致，非逻辑差异）

### 代价与收益

| 项 | UOF=1 → UOF=0 |
|---|---|
| XLR | **+139**（55,718 → 55,857，+0.23pp） |
| **最紧时序** | **+0.091 ns（反而更好）** |
| 代价评价 | **可接受**（有 4,943 XLR 余量） |

---

## 三、预期效果（来自 iverilog 实测，**未上板验证**）

**仲裁器单元测试**（`work/ivtest/arb_tb.sv`）：

| 显示 urgent 占空比 | UOF=1 CNN 份额 | UOF=0 CNN 份额 | 改善 |
|---|---|---|---|
| 30% | 36% | 46% | **+10pp** |
| 50% | **25%** | **44%** | **+19pp** |
| 70% | 15% | 41% | **+26pp** |

**对上板的影响推演**（未验证）：

| 项 | 当前 | 预期 |
|---|---|---|
| `AR` 等待 | 35% | 降至 ~20% |
| `RPMS` 读相位 | 41 ms | ~32 ms |
| `MS` 单次推理 | 83 ms | **~74 ms** |
| NN fps | 11 | **~13** |

---

## 四、上板验证清单（板子恢复后执行）

| # | 检查项 | 判据 |
|---|---|---|
| 1 | 烧 UOF=0 bit + v3 固件 | `finished with JTAG programming` + `running` |
| 2 | 启动自检 | `STYLE INT8 RGB self-test PASS` |
| 3 | **`AR` 遥测** | 应从 35% 降至 ~20% |
| 4 | **`RPMS`** | 应从 41 ms 降至 ~32 ms |
| 5 | **`NN` fps** | 应从 11 升至 ~13 |
| 6 | **`UF`（欠载）** | ⚠️ **必须仍为低值**（这是主要风险） |
| 7 | `DISP` | 应保持 60 |
| 8 | 画面 | 无撕裂/闪烁 |

**回滚方法**：把 `STYLE_UOF` 改回 `1'b1` 重编，或直接烧 `outflow_uof1/ti60f225_oob.bit`。

---

## 五、⚠️ 主要风险：显示欠载

`UOF=0` 取消了显示 urgent 对公平轮转的override，**显示读可能在极端情况下拿不到带宽**。

**判断依据**：
- 仿真中 `DBP`（显示读反压）= 0，说明显示 FIFO 从不反压 —— 这是**好迹象**
- 但仿真物理 DDR 延迟是理想化的

**若上板 `UF` 明显上升 → 立即回滚 UOF=1。**

---

## 六、诚实边界

| 项 | 状态 |
|---|---|
| 参数化改动语法正确 | ✅ iverilog 编译通过 |
| **默认值不改综合结果** | ✅ **XLR 完全一致（55,718）** |
| UOF=0 bit 编译成功 | ✅ 3,184,320 B |
| XLR 代价 | ✅ 实测 +139 |
| 时序未劣化 | ✅ 实测 **+0.091 ns** |
| 仲裁带宽改善 | ✅ iverilog 实测 +19pp（50% duty） |
| **上板帧率收益** | ❌ **未验证** |
| **上板欠载风险** | ❌ **未验证** ⚠️ |
| 当前板子状态 | ❌ **断开**（JTAG 无设备） |

---

## 七、当前文件状态

| 文件 | 状态 |
|---|---|
| `rtl/ti60f225_oob_top.v` | **`STYLE_UOF = 1'b0`**（当前为 UOF=0 版本） |
| `outflow_uof1/ti60f225_oob.bit` | UOF=1 基线（可回滚） |
| `outflow_uof0/ti60f225_oob.bit` | **UOF=0 待验证版** |
| `outflow_v3/ti60f225_oob.bit` | 原始 v3（改参数前，可用于对照） |

**固件**：仍为 `reports/ink/firmware/soc_video_app_v3.bin`（无需改动，仲裁在 RTL 侧）
