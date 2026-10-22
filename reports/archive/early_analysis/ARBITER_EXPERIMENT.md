# 仲裁参数实验（iverilog 实测，不上板）

> 日期：2026-10-20
> 方式：**iverilog 14.0 单元测试**（`work/ivtest/arb_tb.sv`）
> 对象：`rtl/soc_integration/axi_shared_ddr_2m.sv`
> 前提：CNN 与显示**同时持续**请求；DDR 立即返回（不成为瓶颈）；固定跑 100k 周期

---

## 一、实验设计

驱动 `video_read_urgent` 按指定占空比翻转，测 CNN / 显示各获得多少 AR 授权。

**对比两个参数**：

| 参数 | 新架构实际值 | 备选 |
|---|---|---|
| `URGENT_OVERRIDES_FAIRNESS` | **1** | **0** |
| `MAX_VIDEO_BURSTS` | 3 | 3 |
| `DYNAMIC_VIDEO_READ` | 1 | 1 |
| `VIDEO_READ_PRIORITY` | 0 | 0 |

---

## 二、实测结果

### `URGENT_OVERRIDES_FAIRNESS=1`（**新架构当前配置**）

| 显示 urgent 占空比 | CNN 授权 | 显示授权 | **CNN 份额** |
|---|---|---|---|
| 0% | 16,667 | 16,666 | **50%** |
| 30% | 12,000 | 21,333 | **36%** |
| 50% | 8,666 | 24,667 | **25%** |
| 70% | 5,000 | 28,333 | **15%** |
| **100%** | **0** | 33,333 | **0%** ⚠️ |

### `URGENT_OVERRIDES_FAIRNESS=0`（**备选**）

| 显示 urgent 占空比 | CNN 授权 | 显示授权 | **CNN 份额** |
|---|---|---|---|
| 0% | 16,667 | 16,666 | **50%** |
| 30% | 12,000 | 14,000 | **46%** |
| 50% | 8,999 | 11,000 | **44%** |
| 70% | 5,000 | 7,000 | **41%** |
| 100% | 0 | 3 | 0% ⚠️ |

---

## 三、关键发现

### 1. `UOF=1` 时 CNN 份额随 urgent 占空比**线性崩塌**

| urgent | UOF=1 | UOF=0 | 差异 |
|---|---|---|---|
| 30% | **36%** | **46%** | **+10pp** |
| 50% | **25%** | **44%** | **+19pp** |
| 70% | **15%** | **41%** | **+26pp** |

**`UOF=0` 时 CNN 份额几乎被锁在 41–50%**，不随 urgent 崩塌。
**`UOF=1` 时 CNN 份额 = 50% − urgent 占空比**（线性关系）。

### 2. 这正是板上 `AR 等待 35–46%` 的机制

**仿真已经量化**：只要显示 urgent 占空比在中高水平，`UOF=1` 就会让 CNN 拿到极少带宽。
与远端仿真 `AR = 45.9%`、板上 `AR = 35%` **方向完全一致**。

### 3. `urgent = 100%` 时两者都饿死（0%）

说明 **`RESERVE_URGENT_READ=1` 并未真正为 CNN 保留带宽**，
或在「双侧持续请求」场景下其保留机制失效。
→ **这是第二个可修的缺陷**，但目前没有板上证据表明 urgent 会到 100%。

---

## 四、关键待查：`read_urgent` 的真实占空比

**仿真表明「urgent 占空比」是唯一的决定变量，而它由 `style_display.sv` 决定**：

```verilog
assign read_urgent = display_valid && (state!=IDLE || req_valid)
                   && (pixel_level<384 || row_age>=1600 || req_valid);
```

**三个条件任一为真即 urgent**：

| 条件 | 含义 | 预估占空比 |
|---|---|---|
| `req_valid` | **每次有行请求都 urgent** | **高** |
| `pixel_level < 384` | FIFO（512 深）水位低于 75% | **高** |
| `row_age >= 1600` | 行请求等 16 µs | 低 |

**⚠️ 前两个条件都可能让 urgent 长期为 1** —— 这正是下一步必须量的。

---

## 五、建议的改法（按风险排序）

| # | 改动 | 依据 | 风险 |
|---|---|---|---|
| **1** | **`URGENT_OVERRIDES_FAIRNESS` 1 → 0** | 实测 CNN 份额 25%→44%（urgent 50% 时） | **极低**（单参数） |
| **2** | 收紧 `read_urgent` 的 `req_valid` 条件 | 去掉「每次请求都 urgent」 | 低（但可能增加欠载） |
| **3** | 降低 `pixel_level` 阈值（384→256） | 减少 urgent 触发 | 低 |
| **4** | 修 `RESERVE_URGENT_READ` 失效 | urgent=100% 时 CNN 得 0 | 中 |

**推荐先做 #1** —— 单参数、实测有 +19pp 的 CNN 带宽改善、且不改变显示路径逻辑。

---

## 六、诚实边界

| 项 | 状态 |
|---|---|
| iverilog 14.0 已装 | ✅ 实测（`C:/iverilog`） |
| 仲裁器可独立仿真 | ✅ 编译 + 运行通过 |
| **UOF=1 vs 0 的带宽差** | ✅ **实测（+10~26pp）** |
| urgent 占空比是决定变量 | ✅ 实测（线性关系） |
| 与板上 AR 35% 方向一致 | ✅ |
| **`read_urgent` 的真实占空比** | ❌ **未测量**（需上板或全系统仿真） |
| **改 UOF=0 后的实际帧率收益** | ❌ **未验证**（需上板） |
| **UOF=0 是否会导致显示欠载** | ❌ **未验证** ⚠️ |
| `RESERVE_URGENT_READ` 为何失效 | ❌ 未定位 |

---

## 七、复现命令

```bash
# 编译（UOF=1 / UOF=0 两个变体）
C:/iverilog/bin/iverilog.exe -g2012 -Parb_tb.UOF=1 -o work/ivtest/arb_1.vvp \
  -s arb_tb work/ivtest/arb_tb.sv rtl/soc_integration/axi_shared_ddr_2m.sv

# 运行（显示 urgent 占空比 50%）
C:/iverilog/bin/vvp.exe work/ivtest/arb_1.vvp +URGENT=50
```
