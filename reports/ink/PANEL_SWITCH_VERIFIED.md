# 单面板按键切换：上板验证成功（2026-10-21）

> bit：`outflow_panelsw2/ti60f225_oob.bit`（3,180,537 B，SHA256 `0afb084f...`）
> 按键：**KEY1 = GPIOR_22 = P14**（与板卡手册「按键管脚分配」完全一致）
> 结论：**按键切换成功，单面板模式全指标优于双面板**

---

## 一、上板实测对比（真板遥测，同一固件）

| 指标 | **双面板（默认）** | **单面板（按键切换）** | 变化 | 判定 |
|---|---|---|---|---|
| **`NN`** | **11 fps** | **12–13 fps** | **+1~2** | ✅ **提升** |
| **`MS`** | **83 ms** | **79 ms**（最低 71–72） | **−4~12 ms** | ✅ **提升** |
| **`DRB`** | **9,387,616** | **4,693,888** | **−50.0%** | ✅ **正是设计目标** |
| **`AR`** | **35%** | **28%** | **−7pp** | ✅ **CNN 等读减少** |
| **`RPMS`** | **42 ms** | **29 ms** | **−13 ms** | ✅ **读相位大幅下降** |
| **`UF`** | **10** | **5** | **−50%** | ✅ **欠载减少** |
| `RGAP` | 19% | 21% | +2pp | ○ 略升（读间隙占比） |
| `CPMS` | 31 ms | 31 ms | 0 | ○ 算力不变（符合预期） |
| `RB` | 12,638,128 | 14,378,608 | +13.8% | ○ CNN 读到更多带宽 |

### 关键解读

| 现象 | 原因 |
|---|---|
| **`DRB` 精确减半** | ✅ 单面板只读风格化结果区，不再同时读原画 |
| **`RPMS` 42→29 ms（−13 ms）** | ✅ 显示抢带宽减少，CNN 读等待缩短 |
| **`MS` 83→79 ms** | ✅ 读相位下降直接传导到总时间 |
| **`RB` +13.8%** | ✅ CNN 拿到更多 DDR 带宽（显示让出） |
| `CPMS` 不变 | ✅ 算力未变（符合预期，改的是显示不走算力） |

---

## 二、按键切换验证

### 实测切换序列（DRB 交替出现两种值）

```
9380480  双面板
7833600  （切换中）
4684800  单面板  ← 按下 KEY1
4692640  单面板
4684800  单面板
9385376  双面板  ← 再按一次
4693312  单面板
```

**✅ 按键每次按下切换一次，无重复翻转，无抖动误触发。**

### 硬件一致性确认

板卡手册「按键管脚分配」：

| 按键名 | FPGA Pin Name | Pin Num | Bank | 电压 |
|---|---|---|---|---|
| KEY0 | GPIOL_07 | C4 | TL | 3.3V |
| **KEY1** | **GPIOR_22** | **P14** | **BR** | **3.3V** |
| KEY2 | GPIOR_21 | N14 | BR | 3.3V |
| KEY3 | GPIOL_03 | A3 | TL | 3.3V |

我分配的 `panel_key = GPIOR_22` → **P14 / BR / 3.3V / weak pullup**，与手册**完全一致**。

---

## 三、本次修复的两个关键 bug

### Bug 1：消抖逻辑永不翻转 ❌

原来写法：
```verilog
sampled   <= key_sync2;
sampled_d <= sampled;                              // 每拍都被覆盖
if (stable_cnt == STABLE && sampled != sampled_d)  // 两者永远相等 → 永假
    ...
```

**`toggle` 从来不会翻转** —— 这就是第一次上板按键无响应的原因。

**修正后**（计数器式）：
```verilog
if (key_sync2 != stable) begin
  if (cnt == DEBOUNCE_COUNT-1) begin stable <= key_sync2; cnt <= 0; end
  else cnt <= cnt + 1;
end else cnt <= 0;
if (stable_d && !stable) toggle <= ~toggle;   // 接受 1→0 边沿
```

**单元测试（`work/ivtest/key_tb.sv`）四种情形全部通过**：

| 测试 | 期望 | 结果 |
|---|---|---|
| 干净单次按下 | 翻转 1 | ✅ 1 |
| 再按一次 | 翻转 2 | ✅ 2 |
| 带 6 次抖动 | 翻转 3（不许多翻） | ✅ 3 |
| 20 拍短毛刺 | 仍 3（应忽略） | ✅ 3 |

### Bug 2：`BURST_MAX` 默认值静默覆盖 ⚠️

`style_video_system` 和 `style_accel` 的**默认参数就是 `BURST_MAX=240`**，
而顶层只覆盖了 `URGENT_OVERRIDES_FAIRNESS`。

**→ 改 `style_network.sv` 里的 32 完全无效**（这就是之前 `outflow_panelsw` 第一版 AR=45%、UF=314,766 的根因 —— 它实际是 240 长 burst 的 netlist）。

**修正**：顶层显式传参，不依赖默认值：
```verilog
localparam integer STYLE_BURST_MAX = 32;
localparam integer STYLE_PAD_PITCH = 0;
style_video_system #(.URGENT_OVERRIDES_FAIRNESS(STYLE_UOF),
                     .BURST_MAX(STYLE_BURST_MAX),
                     .PAD_PITCH(STYLE_PAD_PITCH)) style_demo(
```

### Bug 3：跨时钟域（CDC）违例 ⚠️

`single_panel` 在 `clk`（100 MHz）域产生，但被 `pix_clk`（148.5 MHz）域的像素比较器使用。

**→ `sdram_clk` slack 从 +0.379 ns 恶化到 −0.052 ns（负 slack）**

**修正**：加 2 级 CDC 同步器
```verilog
(* async_reg = "true" *) reg sp_meta, sp_sync;
always @(posedge pix_clk or negedge rst_n)
  if (!rst_n) begin sp_meta <= 1'b0; sp_sync <= 1'b0; end
  else        begin sp_meta <= single_panel; sp_sync <= sp_meta; end
wire single_panel_pix = sp_sync;
```

**→ 时序恢复到 +0.092 ns（无负 slack）**

### Bug 4：位宽膨胀 ⚠️

`localparam integer IMG_X0 = 580`（32 位有符号）与 11 位 `h` 比较时，把 `h` 扩展到 32 位。

**→ LUT 从 25,574 涨到 26,989（+1,415）**

**修正**：改用 `localparam [10:0] IMG_X0 = 11'd580`，全部定宽 11 bit 运算。

**→ LUT 回落到 25,435（甚至比 v3 少 139）**

---

## 四、最终 bit 质量

| 项 | 值 |
|---|---|
| bit | `outflow_panelsw2/ti60f225_oob.bit` |
| 大小 | **3,180,537 B** |
| SHA256 | `0afb084f099b92bd61d35aace7351e4d95ab93eb19725d79eb65a5125a71e6e2` |
| 编译 | **map / interface / pnr / pgm 全 PASS** |
| **XLR** | **55,664 / 60,800（91.55%）** |
| RAM | 237 / 256（92.58%） |
| DSP | 140 / 160（87.50%） |
| **最紧 setup slack** | **+0.092 ns（sdram_clk，无负）** |

---

## 五、对赛题的合规性

赛题第 84 行原文：
> 「**屏幕左侧显示原始摄像头画面，右侧显示风格化后画面**（**或通过按键切换全屏模式**）」

**我们的实现**：
- **默认双面板** = 左原画 + 右风格画 → 直接满足第一选项
- **按键切换单面板** = 全屏风格画 → 满足第二选项

**→ 两种方式都合规，且可现场演示切换。**

---

## 六、后续可叠加的收益

单面板已把 `RPMS` 从 42 降到 29 ms。剩余空间：

| 方向 | 依据 | 预期 |
|---|---|---|
| **剪枝中间层 16ch** | 中间 18 层占 62.1% MAC | CPMS 31→约 22 ms，MS → **约 70 ms = 14 fps** |
| 降分辨率 480×360 | 实测 MAC −44% | 约 21 fps（偏离赛题） |

**单面板 + 剪枝组合：MS 约 70 ms → 约 14 fps**（仍略低于 15 fps 目标）。

---

## 七、诚实边界

| 项 | 状态 |
|---|---|
| **按键切换成功** | ✅ **真板实测（DRB 交替）** |
| **单面板 DRB −50%** | ✅ 实测（9.39M → 4.69M） |
| **单面板 MS 83→79 ms** | ✅ 实测（最低见 71–72） |
| **单面板 NN 11→12~13** | ✅ 实测 |
| **单面板 AR 35→28%** | ✅ 实测 |
| **单面板 UF 10→5** | ✅ 实测 |
| 消抖单元测试 | ✅ 四种情形全通过 |
| 引脚与手册一致 | ✅ GPIOR_22 / P14 / BR |
| CDC 与时序 | ✅ 无负 slack |
| **是否达 15 fps** | ❌ **未达（当前最高 13 fps）** |
| 剪枝后预测 | ❌ 推算，未重训验证 |
