# 方向 A 实现结果：3×3 预取已实现，但**实测零收益**

> 日期：2026-10-21
> 方法：iverilog 探针 A/B（NBANKS=3 vs NBANKS=4，H=8）
> 结论：**预取确实扩展到 3×3 层（15→23 次），但总周期完全没变**

---

## 一、实现内容

### 1. `style_row_core.sv`：新增第 4 个行 bank

```verilog
module style_row_core #(
  parameter integer MAX_WIDTH=640,
  parameter integer NBANKS=3,          // 新增
  parameter COEFF_FILE="...")
row0lo/row1lo/row2lo/row3lo   // 第4个 bank
read3                          // 第4个读寄存器
choose_row: if(NBANKS>=4) 支持 sel=3
```

### 2. `style_network.sv`：扩展 prefetch 到 3×3 层

```verilog
parameter integer NBANKS=4;              // 默认 4
reg [NBANKS-1:0] cache_valid;
reg [9:0] cache_y[0:NBANKS-1];
for(i=0;i<NBANKS;i=i+1) ... // 命中查找

// prefetch 条件从
//   !kernel3 && !residual && !stride2 && !up2
// 改为
//   !residual && !stride2 && !up2 && prefetch_bank_ok
// 3x3 层：预取 physical row y+2 到 spare_bank
```

**spare_bank 计算**：找 4 个 bank 中未被 {y-1,y,y+1} 占用的那个。

---

## 二、A/B 实测结果（H=8 探针）

| 指标 | NBANKS=3 | **NBANKS=4** | 变化 |
|---|---|---|---|
| MAP | 256 | 256 | 0 |
| **READWAIT** | 24,370 | **24,370** | **0** |
| SKIPWAIT | 3,936 | 3,936 | 0 |
| RUN | 64 | 64 | 0 |
| WAITROW | 77,765 | 77,765 | 0 |
| **TOTAL** | **106,399** | **106,399** | **0** |
| **prefetch starts** | **15** | **23** | **+8** |
| prefetch completions | 0 | 0 | 0 |

### 关键观察

**prefetch 确实扩展了**（15 → 23 次，+8 正好是 3×3 层的数量）
**但总周期一字未变（106,399 → 106,399）**

---

## 三、为什么零收益

### 原因：瓶颈不在 3×3 层的读等待

**时序分析**：

| 层类型 | 每行流程 |
|---|---|
| 1×1（原已有 prefetch） | MAP → RUN(启动 core+write **和** prefetch) → WAITROW |
| **3×3（新增 prefetch）** | 同样变成 RUN 时预取 y+2 |

**但 WAITROW 的时长由 `max(core, write, prefetch_read)` 决定。**

实测显示：**已有的 core/write 时间已经足够长，能完全覆盖 prefetch 的读延迟**。

**即**：
```
原 3×3 层: MAP → READWAIT(等读) → RUN(等 core/write)
新 3×3 层: MAP → RUN(等 core/write，读并行)
```

理论上前者 = 读时间 + core时间，后者 = max(读, core)。
**若 core > 读，则完全没差别。**

**实测证明了这一点**：`READWAIT` 和其他状态计数**完全不变**。

### 更深层：为什么 READWAIT 没减少

因为 **3×3 层的读发生在 `MAP` 阶段（行还没到齐）**，而不是 `RUN` 阶段。
新增的 prefetch 只在 `RUN` 时预取 y+2 —— 但 y+1 行仍要等 `MAP` 的 READWAIT。

**所以真正的瓶颈是：3×3 层在 MAP 阶段要等 3 个行陆续到达。**

---

## 四、这个方向的正确结论

| 项 | 结论 |
|---|---|
| 实现是否成功 | ✅ 是（prefetch 15→23，语法/仿真都通过） |
| **是否有收益** | ❌ **零收益** |
| 原因 | 3×3 层的读在 MAP 阶段，不在 RUN 阶段 |
| 需要的改动 | 应是**跨行预取**（y+2 在 y-1 时就预取），不只是 y+2 在 y 时 |

---

## 五、是否保留这个改动？

### 支持保留
- 实现完整、无错误
- `NBANKS=3` 可完全还原原行为
- 为未来「跨行预取」打下基础

### 反对保留
- **零收益，白白增加 XLR 和 4-bank 的面积**
- 增加复杂度，增大验证负担

### 我的建议

**保留代码但把默认值改回 `NBANKS=3`**，即：
- 改动留在源码里（不删除工作）
- 默认行为不变（零风险）
- 若要试验，改参数即可

**⚠️ 但需要核实 NBANKS=4 的资源代价（XLR/RAM）才能决定默认值。**

---

## 六、诚实边界

| 项 | 状态 |
|---|---|
| 3×3 预取已实现 | ✅ 语法 + 仿真通过 |
| prefetch 次数 15→23 | ✅ 探针实测 |
| **总周期零变化** | ✅ **实测（106,399 → 106,399）** |
| **零收益的根因分析** | ◐ **推断**（MAP 阶段才是瓶颈），未用逐状态探针细分验证 |
| NBANKS=4 的资源代价 | ❌ **未综合** |
| **是否有其他实现方式能获益** | ❌ **未探索**（跨行预取） |

---

## 七、下一步建议

| 优先级 | 动作 | 理由 |
|---|---|---|
| **①** | **把 NBANKS 默认改回 3** | 零收益不应默认启用 |
| **②** | **上板验证 UOF=0**（已编好） | 唯一有实测支撑的改动（+19pp 带宽） |
| ③ | 若做 3×3 真预取，需**跨行预取**（y-1 行时预取 y+2） | 当前实现时序不对 |
| ④ | 重新评估：真正瓶颈可能是 **DDR 读延迟本身**（core_busy 恒定 77,450 的结论） | 需降低延迟而非预取 |
