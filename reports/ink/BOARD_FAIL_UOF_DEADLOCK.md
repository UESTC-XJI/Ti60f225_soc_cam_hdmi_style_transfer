# ⚠️ 上板验证结果：两个配置均失败，根因是 UOF=0 死锁

> 日期：2026-10-21
> 结论：**`URGENT_OVERRIDES_FAIRNESS=0` 导致仲裁器死锁，与 burst 长度无关**
> 板子：**已回滚 v3，正常运行**

---

## 一、两个失败组（都有实测）

### 失败组 1：`outflow_final2`（BM=240 + UOF=0）

| 指标 | 值 |
|---|---|
| `NN` | **0 fps** |
| `MS` | 47 ms |
| **`AR`** | **100%** |
| **`RB`** | **0** |
| **`DRB`** | **0** |
| **`UF`** | **1,508,675** |

### 失败组 2：`outflow_uof0`（BM=32 + UOF=0）

| 指标 | 值 |
|---|---|
| `NN` | **0 fps** |
| `MS` | 53 ms |
| **`AR`** | **100%** |
| **`RB`** | **0** |
| **`DRB`** | **0** |
| **`UF`** | **1,625,983** |

### 关键对比

| bit | burst | UOF | 结果 |
|---|---|---|---|
| **`outflow_v3`** | **32** | **1** | ✅ **正常（83 ms, 11 fps）** |
| `outflow_uof0` | **32** | **0** | ❌ **失败** |
| `outflow_final2` | 240 | 0 | ❌ 失败 |

**→ burst=32 在 v3 里可用；换成 UOF=0 就失败。**
**→ 故障根因是 `UOF=0`，不是 burst！**

---

## 二、根因：`RESERVE_URGENT_READ` 与 `UOF=0` 的相互作用导致死锁

### RTL 证据（`axi_shared_ddr_2m.sv:72`）

```verilog
cpu_arready = allow_access && !rd_busy && cpu_arvalid && !choose_vid_r
              && !(RESERVE_URGENT_READ && video_read_urgent);
```

### 已知配置

| 参数 | 值 |
|---|---|
| `ADAPTIVE_READ` | **1** |
| `RESERVE_URGENT_READ` | **= ADAPTIVE_READ = 1** |
| `URGENT_OVERRIDES_FAIRNESS` | 0（失败配置）/ 1（v3） |
| `MAX_VIDEO_BURSTS` | 3 |

### 死锁链

```
① 显示 FIFO 空 → video_read_urgent = 1（长期有效）
        ↓
② (RESERVE_URGENT_READ=1 && urgent=1) → cpu_arready ≡ 0
   → CNN 永远拿不到 ARREADY  【实测 AR=100% ✓】
        ↓
③ UOF=0 时，choose_vid_r 取决于 video_read_streak：
   - streak < 3  → choose_vid_r = 1（显示优先）
   - streak >= 3 → choose_vid_r = 0（强制 CNN）
        ↓
④ 但 streak>=3 时：
   choose_vid_r = 0 → cpu_arready 需要 !choose_vid_r ✓
                      但还要 !(RESERVE && urgent) ✗ ← 仍为 0！
   → CNN 依然拿不到
        ↓
⑤ 而 vid_arready = ... && choose_vid_r，streak>=3 时 choose_vid_r=0
   → 显示也拿不到
        ↓
⑥ 【双方都拿不到 ARREADY → 彻底死锁】
```

**v3（UOF=1）为什么正常**：
- `URGENT_OVERRIDES_FAIRNESS=1` → urgent 时 `choose_vid_r` 恒为 1
- 显示总能读到 → FIFO 不空 → `video_read_urgent` 最终会撤销
- 然后 CNN 才能读到

**→ `UOF=1` 是这套仲裁逻辑能工作的【必要条件】，不是可选的优化项。**

---

## 三、这是一个重要的认识修正

| 我此前的判断 | 实际情况 |
|---|---|
| 「`UOF=1→0` 可让 CNN 带宽 25%→44%（iverilog 实测）」 | ✅ 单元测试确实如此 |
| **「这是单参数优化」** | ❌ **错：这是功能前提，关掉就死锁** |
| iverilog 参数实验显示 UOF=0 更好 | ⚠️ **实验只测了仲裁器单元，没测完整系统** |

**为什么单元测试没发现**：
我的 `arb_tb.sv` 只驱动 `cpu_arvalid`/`vid_arvalid` 和 `video_read_urgent`，
**没有模拟 `RESERVE_URGENT_READ` 与 streak 的完整交互**，也没测 `allow_access`/`rd_busy`。

---

## 四、回滚已确认

| 指标 | 失败组 | **回滚后** | 基线 |
|---|---|---|---|
| `NN` | 0 | **11** | 11 ✅ |
| `MS` | 53 | **83** | 83 ✅ |
| `AR` | 100 | **36** | 36 ✅ |
| `DRB` | 0 | **9,385,184** | 9,385,408 ✅ |
| `UF` | 1,625,983 | **低值** | ✅ |

---

## 五、所有 bit 的验证状态（最终盘点）

| bit | XLR | 配置 | 上板验证 |
|---|---|---|---|
| **`outflow_v3`** | 55,718 | BM=32 + UOF=1 | ✅ **正常（基线）** |
| **`outflow_uof0`** | 55,857 | BM=32 + **UOF=0** | ❌ **失败（死锁）** |
| **`outflow_final2`** | 55,587 | BM=240 + **UOF=0** | ❌ **失败（死锁）** |
| `outflow_uof1` | 55,718 | BM=32 + UOF=1 | ⏸ 与 v3 等价，无需验证 |
| `outflow_burst` | 56,128 | BM=256 + UOF=0 | ⏸ 必然失败（同 UOF=0） |
| `outflow_ram4` | 55,857 | 4-bank 未接线 | ⏸ 废弃 |
| `outflow_dirA` | 55,993 | 3×3 预取 | ⏸ 已回滚废弃 |
| `outflow_remote` | 55,718 | 远端原模型 | ⏸ 非性能对照 |
| `outflow_ukiyoe` | 55,718 | 浮世绘 v15 | ⏸ 不同风格 |

**结论：所有值得验证的 bit 都已验证完毕（3 个），全部有结论。**

---

## 六、下一步：只剩一个未测维度

### 已排除

| 优化 | 状态 |
|---|---|
| **UOF=0** | ❌ **死锁，不可用** |
| burst 240/256 | ❌ 与 UOF=0 混测，**但需单独重测** |
| PAD_PITCH | ❌ 依赖长 burst |
| prefetch 扩 3×3 | ❌ 零收益 |
| 加 MAC | ❌ RAM 不足 |

### ⚠️ 关键：burst 的失败可能与 UOF=0 混淆

**两个失败组都有 UOF=0**，所以**无法确定 burst=240 是否单独可用**。

**正确的实验**：`BM=240 + UOF=1`（保持不变 UOF，只改 burst）

| 待测配置 | 目的 |
|---|---|
| **`BM=240 + UOF=1`** | **分离 burst 的影响** ← **这是唯一还有意义的测试** |

若这个能跑通 → burst 优化有效，可保留
若这个也失败 → burst 确实不可用

**这需要重新编译一个 bit（约 12 分钟）。**

---

## 七、诚实边界

| 项 | 状态 |
|---|---|
| **UOF=0 导致死锁** | ✅ **实板实测 + RTL 代码推演** |
| 死锁机制 | ✅ **`RESERVE_URGENT_READ` + streak 交互** |
| 回滚成功 | ✅ 实测 |
| **burst=240 是否单独可用** | ❌ **未知（与 UOF=0 混测）** |
| 「UOF 是单参数优化」 | ❌ **已证伪，它是功能前提** |
| 仲裁器单元测试的局限 | ✅ 已识别（未覆盖完整交互） |
