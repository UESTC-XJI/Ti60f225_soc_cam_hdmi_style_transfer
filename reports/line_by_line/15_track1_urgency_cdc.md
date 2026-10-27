# Track 1：显示读优先级（T1.4）+ CDC 命令队列加深（T1.3）

> 改动范围（我独占写权限的 4 个文件）：
> `rtl/style/style_video_system.sv`、`rtl/style/style_axi_cdc.sv`、
> `rtl/soc_integration/soc_video_ddr_integration.sv`、`rtl/ti60f225_oob_top.v`
>
> **未跑构建**（`_b.bat` / efx_run / build_firmware.sh 均未执行）、**未碰板子/OpenOCD**、**未提交 git**。
> `rtl/accel_rowpipe/rowpipe_ddr_banks.v` 等其他队友正在改的文件**一个字节都没动**。
> `style_video_system.sv` 里 Lead 的 profiler 段（`0x54` freeze + `0x58..0x64` 五项计数）**原样保留**，我的改动全部在它之前。

---

## 一、结论摘要

| 项 | 结论 |
|---|---|
| **任务 A** | ✅ 已按 4 步全部落地：`display_read_urgent` 导成 `style_video_system` 输出端口 → 顶层 `style_read_urgent` → `soc_video_ddr_integration` 新输入端口 → 外层桥 `.video_read_urgent()` |
| **`DYNAMIC_VIDEO_READ`** | ✅ **已打开**（外层桥 `#(.DYNAMIC_VIDEO_READ(1'b1))`）。分析认为**没有 CPU 饿死风险**，见第三节的 3:1 有界性证明 |
| **未打开的** | `URGENT_OVERRIDES_FAIRNESS`=0、`RESERVE_URGENT_READ`=0、`VIDEO_READ_PRIORITY`=0 —— **按你的要求保持不动，而且我从代码证明了这三项必须保持 0**（第 3.5 节，其中两条会真的饿死 CPU） |
| **任务 B** | ✅ AR/AW `LOG_DEPTH(2)` → `(4)` 已改。⚠️ **但它落成的是 FF 寄存器堆，不是 RAM**：+960 FF，XLR 估 +120~240（第 4 节） |
| **面积（任务 A）** | **+3 FF、+约 5 LUT** —— 确实几乎不耗面积 ✅ |
| **面积（任务 B）** | **+960 FF**、XLR +120~240（估）。若构建拥塞，把两处 `4` 改回 `3` 可减半（第 6 节给了回退指引） |
| **额外加固** | 我把 `display_read_urgent` **在模块边界打了 1 拍寄存器**（+1 FF），避免把这根"显示 FIFO 比较器"出来的组合信号拉进外桥的 `arready` 组合锥——否则可能吃掉你本来只剩 0.355 ns 的 slack |
| **给 Lead 的决定点** | ① 任务 B 是否接受 +960 FF（还是改 3）；② 无论选哪个都建议在构建日志里看一眼 **FF 利用率**（你只报过 XLR，没报 FF） |

---

## 二、改动清单（逐行）

### 2.1 `rtl/style/style_video_system.sv`（109 → 122 行）

| 行 | 改动 | 说明 |
|---|---|---|
| 12-15 | **新增输出端口** `output wire display_read_urgent,` | 3 行注释 + 1 行端口。插在 `resized_frames` 之后、AXI 端口之前 |
| 44 | `wire display_read_urgent;` → `wire display_read_urgent_raw;` | 原来的内部线改名为 `_raw`（它是 `style_display.read_urgent` 的**组合**输出，`style_display.sv:75`） |
| 59 | `.read_urgent(display_read_urgent_raw)` | 只是跟着改名，行为不变 |
| 61-69 | **新增** `reg display_read_urgent_q` + 1 拍寄存 + `assign display_read_urgent=display_read_urgent_q;` | 这 1 个 FF 是本任务唯一新增的存储 |
| 82 | 内层桥 `.video_read_urgent(display_read_urgent_raw)` | **内层桥仍用原始组合电平**，时序与行为零变化（这是刻意的，见 2.5） |
| 97-118 | Lead 的 profiler 段 | **未改动** |

关键设计选择：**内层用 raw、外层用 registered**。两边差 1 拍，对"显示行截止期"（一行 17 µs @1280px/74.25MHz）完全无影响，但换来的是**外层桥 `arready` 组合路径从寄存器出发**。

### 2.2 `rtl/ti60f225_oob_top.v`（996 → 1002 行）

| 行 | 改动 |
|---|---|
| 629-633 | **新增 5 行**：注释 + `wire style_read_urgent;`，放在 `style_select` 之前 |
| 649 | `style_demo` 实例新增 `.display_read_urgent(style_read_urgent));` |
| 654 | `soc_video_inst` 实例的端口列表追加 `.video_read_urgent(style_read_urgent),` |

`style_read_urgent` 全工程只有这 3 处引用（1 声明 + 1 驱动 + 1 消费），命名没有和已有的 `fb_*`/`soc_vid_*` 冲突。

### 2.3 `rtl/soc_integration/soc_video_ddr_integration.sv`（423 → 442 行）

| 行 | 改动 |
|---|---|
| 5-7 | **新增输入端口** `input wire video_read_urgent,`（带 2 行注释）。原第 7 行（`video_read_urgent` 之外）之后的 vid_* 端口整体后移 3 行 |
| 185-202 | **重写外层桥前的注释块**：把"为什么只开 DYNAMIC_VIDEO_READ、为什么其他三个必须保持 0"写成四条就地注释（避免下一个人又把它打开） |
| 203 | `axi_shared_ddr_2m bridge(` → `axi_shared_ddr_2m #(.DYNAMIC_VIDEO_READ(1'b1)) bridge(` |
| 204 | 端口列表新增 `.video_read_urgent(video_read_urgent),` |

**这是本次唯一的"语义"改动**：外层桥从一个纯轮转仲裁器变成"有界动态优先"仲裁器。

### 2.4 `rtl/style/style_axi_cdc.sv`（25 → 30 行，只增注释）

| 行 | 改动 |
|---|---|
| 13-19 | 重写注释：说明从 4 深改到 16 深的原因，**并明确写出它落在寄存器堆路径、不是 RAM** |
| 20 | AR FIFO `.LOG_DEPTH(2)` → `.LOG_DEPTH(4)` |
| 22 | AW FIFO `.LOG_DEPTH(2)` → `.LOG_DEPTH(4)` |

数据通道（WIDTH 145/131）与 B 通道（WIDTH 2）**未动**。

### 2.5 为什么内层桥不用寄存器版本

内层桥的 `choose_vid_r` 已经吃 `display_read_urgent`（`axi_shared_ddr_2m.sv:51`），而且它在**同一个模块内、同一条仲裁锥**里，历史上能收敛（我没有实测它的 slack，但改动它就有全新的时序风险）。**把已收敛的路径留原样、只把跨模块的新路径打寄存器**，是风险最小的切法。

---

## 三、任务 A 的 AXI 语义分析（核心）

### 3.1 `video_read_urgent` 到底什么时候起作用——只看"双方同拍请求"

`axi_shared_ddr_2m.sv:49-52`：
```verilog
wire choose_vid_r = cpu_arvalid && vid_arvalid ?
    (VIDEO_READ_PRIORITY        ? 1'b1 :
     DYNAMIC_VIDEO_READ && video_read_urgent && (URGENT_OVERRIDES_FAIRNESS||streak<MAX) ? 1'b1:
     DYNAMIC_VIDEO_READ && streak>=MAX ? 1'b0 : rd_turn) : vid_arvalid;
```
- **只有 `cpu_arvalid && vid_arvalid` 同时为 1** 才走那串三目；否则 `choose_vid_r = vid_arvalid`。
  → **单方请求时永远是"谁请求谁走"**，`video_read_urgent` 完全不参与。
- 所以这一改动的效果**只出现在"CPU 和视频端口同一拍都在要读"的竞争时刻**——这恰好就是上一轮定位的痛点。

### 3.2 打开 `DYNAMIC_VIDEO_READ` 后的四分支真值表（`MAX_VIDEO_BURSTS=3`）

| `video_read_urgent` | `video_read_streak` | `choose_vid_r` | 谁拿到读授权 |
|---|---|---|---|
| 0 | 任意 <3 | `rd_turn` | 轮转 |
| 0 | ≥3 | **0** | CPU（强制让位） |
| 1 | 0/1/2 | **1** | 视频（优先） |
| 1 | ≥3 | **0** | **CPU（强制让位）** |

两条"CPU 强制让位"分支（第 2、4 行）就是**不会饿死 CPU 的结构性保证**：无论 urgent 多高，streak 一到 3 就把读授权交给 CPU。

### 3.3 3:1 有界性的逐步证明（CPU 连续请求、urgent 恒高）

`streak` 更新逻辑（`:93-96`）：`if(!cpu_arvalid||cpu_arready) streak<=0; else if(vid_arready&&streak<3) streak++;`

| 仲裁时刻 | streak | 判定 | 获授权 | 下一 streak |
|---|---|---|---|---|
| 1 | 0 | `urgent && 0<3` → 1 | 视频 | 1 |
| 2 | 1 | `urgent && 1<3` → 1 | 视频 | 2 |
| 3 | 2 | `urgent && 2<3` → 1 | 视频 | 3 |
| 4 | 3 | `urgent && 3<3`=假 → `streak>=3` → **0** | **CPU** | 0（因 `cpu_arready=1`） |
| 5 | 0 | 同第 1 行 | 视频 | 1 |

→ **稳态严格 3:1，CPU 每 4 次仲裁必得 1 次读授权（25%）** ✅

**最坏附加延迟实算**：CPU 要等的 3 笔视频读 = 3 × (512 B 突发 320 ns + DDR 读延迟 ~150 ns) ≈ **1.4 µs**。
对照：UART 115200 baud 一个字节 **87 µs**，一次 I2C 事务 ~100 µs 量级。
→ **CPU 最多损失 1.4 µs/次读，不足以让串口或 3A 停顿**（3A 走 I2C，根本不过 DDR）。

补充：`rd_busy` 期间（一笔突发在飞）所有 ready 都是 0，`streak` 保持不变，所以上面按"每次仲裁"计数是准确的。
另外 CPU 的**写**通道完全不受影响（`choose_vid_w` 用的是 `video_write_streak<8`，与本次改动无关）。

### 3.4 `DDR_ID_W=4` 时这些参数是否仍然有效——**是，完全有效**

`DDR_ID_W` 只影响 `SRC_ID_W=DDR_ID_W-1`（`:40`）和 `expected_bid/expected_rid`（`:56-57`）的位宽与比较，
**与读仲裁的任何一个分支无关**。外层桥 `DDR_ID_W=4` → `SRC_ID_W=3`，`video_read_streak` 是独立的 2 位计数器
（`STREAK_W=$clog2(3+1)=2`，`:46-47`），与外层 ID 宽度无关 ✅。

### 3.5 为什么另外三个参数**必须保持 0**（这是我从代码推出的硬约束，不是保守）

| 参数 | 若置 1 会发生什么 | 源码依据 |
|---|---|---|
| `URGENT_OVERRIDES_FAIRNESS=1` | `choose_vid_r` 变成 `DYNAMIC && urgent && (1||...)` → **绕开 streak 上限**。urgent 由 `style_display.sv:75` 生成，含 `row_age>=1600` 超时项，**可以整帧为高** → 整帧内视频读 100% 抢占，**CPU 真的被饿死** | `:51` 与 `style_display.sv:75` |
| `RESERVE_URGENT_READ=1` | 它出现在 `cpu_arready` 里：`... && !(RESERVE_URGENT_READ && video_read_urgent)`（`:72`）。注意**它不看 `vid_arvalid`** → 只要 urgent=1，**即使显示侧根本没有读请求，CPU 的 AR 也被拒**。urgent 整帧为高 → CPU 整帧发不出读 | `:72` |
| `VIDEO_READ_PRIORITY=1` | 直接 `1'b1`，**连 urgency 都不看** → 视频侧无条件优先，CPU 永久饿死 | `:50` |

→ **你的判断（只开 `DYNAMIC_VIDEO_READ`）是正确的唯一选择**；我把这三条理由写进了 RTL 注释（`:187-202`），防止后人误开。

### 3.6 死锁 / 活锁 / 组合环分析

| 检查项 | 结论 |
|---|---|
| **死锁** | 无。`choose_vid_r` 只影响"两个同时请求者谁先走"，单方请求永远放行；`rd_busy` 的清除条件（`ddr_rlast`，`:99`）与仲裁无关 |
| **活锁（谁都不被授权）** | 无。`cpu_arready` 用 `!choose_vid_r`、`vid_arready` 用 `choose_vid_r`，`choose_vid_r` 是单比特 → **两者互斥且必有一个为真**（在同一 `!rd_busy` 前提下） |
| **组合环** | 无（本次新增路径已核）。我读了 `style_display.sv:75`：`read_urgent` 依赖 `display_valid`(寄存器)、`state`(寄存器)、`req_valid`(FIFO out_valid，寄存器)、`pixel_level`(`write_level`，由寄存器 wp/rg2 组合)、`row_age`(寄存器)——**没有任何一项依赖 `arready`**。所以 `urgent → choose_vid_r → vid_arready` 不会绕回 `urgent` ✅ |
| **新增的时序路径** | `display_read_urgent_q`(FF) → 外桥 `choose_vid_r`（2-3 LUT）→ `cpu_arready/vid_arready` → SoC/内桥。**起点是 FF，不再从 style_display 的 FIFO 比较器出发** |

### 3.7 一个必须知道的"口径"（否则会误判效果）

`video_read_urgent` 是**视频端口级**的"显示需要数据"电平，而不是"当前这笔 AR 属于显示"。
内层桥把 CNN 读和显示读复用成同一个 `arvalid` 送到外层；当显示 urgent 时，**从视频端口出来的每一笔读（包括恰好轮到 CNN 的读）都会获得对外层的优先权**。

- 好处：CNN 读也跟着受益，不会因为"显示抢占"而单独受损；
- 代价：urgent 期间 CPU 被压到 25%（仍是 3:1 有界，不是饿死）。

### 3.8 预期改善的量级（说清楚，别期待过高）

单 outstanding 结构下，一笔在飞的 CPU 读（≤512 B ≈ 520 ns）是**无法被抢占**的。所以本改动的收益是：
- **改前**：显示读在外层与 CPU 按 `rd_turn` 轮转，若 CPU 恰好连续请求，显示可能连续让位多次（无上界，取决于 CPU 请求模式）。
- **改后**：显示读最多让 1 笔（在飞的那笔），下一次仲裁必得（因为 streak≤3 的优先 + CPU 让它）。

→ 期望 `VIDEO UF` 下降，但**不会归零**——因为欠载还受内层仲裁、FIFO 深度、DDR 延迟共同影响。

---

## 四、任务 B：CDC 命令队列

### 4.1 先把"深度"说准

`LOG_DEPTH(2)` **不是 2 深，是 2²=4 深**（`style_async_fifo` 的 `(1<<LOG_DEPTH)` 条目）。改到 `LOG_DEPTH(4)` = **16 深**。
你的描述（"4 深 → …"）是对的，这里只是再确认一次口径。

### 4.2 它实际落成什么——**寄存器堆（FF），不是 RAM 块**

`style_async_fifo.sv:27` 是决定性的：
```verilog
generate if(LOG_DEPTH<=4 && WIDTH<=45)begin:small_storage
  wire [(1<<LOG_DEPTH)*WIDTH-1:0] flat;      // 每条目一个 reg，读走 flat[] 动态 part-select
```
- AR/AW：`WIDTH=40 ≤45`、`LOG_DEPTH=4 ≤4` → **命中 `small_storage`** → **16 条目 × 40 bit = 640 FF/通道**。
- 对比改前：4 × 40 = 160 FF/通道。
- 数据通道（WIDTH 145/131）与 `b`（WIDTH 2 但 LOG_DEPTH 默认 4）——**数据通道走 `ram_storage` + `syn_ramstyle="block_ram"`**，本次未动 ✅。

**结论：RAM 块数量不变（0 增量），代价全在 FF 上。** 这与"40 bit × 16 深 ≈ 不占 RAM"的直觉一致，但那句话的完整版是"不占 RAM，占 640 FF/通道"。

### 4.3 面积账（诚实区间）

| 项 | 改前 | 改后 | 增量 |
|---|---|---|---|
| AR FIFO 存储 FF | 160 | 640 | **+480** |
| AW FIFO 存储 FF | 160 | 640 | **+480** |
| **FF 合计** | 320 | 1280 | **+960 FF** |
| 读 mux（XLR） | 4:1 × 40 bit ≈ 80 LUT/ch（估） | 16:1 × 40 bit ≈ 200 LUT/ch（估） | **+120/ch → +240 XLR（上界估计）** |
| RAM 块 | 0 | 0 | **0** |

**XLR 估计不确定性的来源**：`flat[rp*40 +: 40]` 是"寄存器堆 + 动态 part-select 读"，综合器可能
(a) 展开成 FF + 16:1 mux（≈ 上面的 +240 XLR 上界），或
(b) 识别为分布式 RAM/SLRAM（≈ 每通道 40 LUT 量级，即 +40~80 XLR）。
**我无法在不跑综合的前提下判定**，所以给你区间：**XLR +80 ~ +240**。

**FF 的绝对值要你自己核**：你给的是 XLR 98.33%（59,787/60,800），**没有 FF 利用率**。+960 FF 在 Ti60 上不算小，
如果 FF 利用率也已经到 90%+，这 960 个可能比 XLR 更早成为问题。

### 4.4 我的工程意见（供你决定，不擅自改你的要求）

**从功能角度：4 深（16 条目）对"2 个读 burst 在飞"是够的，甚至 2 深就够。** 理由：
- 每个在飞读 burst 只占 **1 个 AR 条目**；2 个在飞 → 队列里最多 2 条，加上正在被外桥取走的那条 = 3 条。
- 原来的 **4 条目**已经有 1.33× 余量；改到 16 条目是 5.3× 余量，属于"余量保险"而非消除瓶颈。

**所以这一改动的收益是"防止未来把在飞数加到 4 以上时踩坑"，代价是 +960 FF / +80~240 XLR。**
既然你明确要加深，我按 4 落地了；**如果你的构建在 PnR 上打嗝，第一件事就是把这两处 `4` 改回 `3`**
（8 条目 = 2 在飞的 2.7 倍余量，代价减半：+480 FF / +40~120 XLR）。我在 `style_axi_cdc.sv:13-19` 的注释里写了这句话。

---

## 五、风险表

| # | 风险 | 等级 | 分析 | 缓解 |
|---|---|---|---|---|
| R1 | **CPU 读被饿死** | 🟢 低 | 3:1 硬上界（3.3 节）；最坏 +1.4 µs/次；3A 走 I2C 不过 DDR | 已用代码注释锁死 `URGENT_OVERRIDES_FAIRNESS`/`RESERVE_URGENT_READ` 必须为 0 |
| R2 | **串口卡住** | 🟢 低 | UART 是 SoC 内 memory-mapped 外设，**不经过 DDR**；CPU 不会被 DDR 阻塞到"卡住"，最多单次读晚 1.4 µs | — |
| R3 | **CNN 吞吐下降** | 🟡 中低 | urgent 期间 CPU 让到 25%，但视频端口（含 CNN 读）拿到 75%，CNN 相对受益；写通道不受影响 | 上板看 `ARST`(index 1) 与 `NN` fps |
| R4 | **时序（新增组合路径）** | 🟢 低 | 已在模块边界打 1 FF；外桥新增逻辑 2-3 LUT | 看构建的 WNS；若 `arready` 路径变红，把 1 FF 版本改成 2 拍（不影响功能） |
| R5 | **面积（A）** | 🟢 极低 | +3 FF / +5 LUT | — |
| R6 | **面积（B）** | 🟠 中 | +960 FF / +80~240 XLR；已知 99.82% 曾因拥塞失败 | 回退到 `LOG_DEPTH(3)`（第 6 节） |
| R7 | **仿真 x 传播** | 🟢 低 | 新增端口在顶层已连；`display_read_urgent_q` 复位为 0 | 仿真若没接会看到 arready 为 x，属"未连好"的正常提示 |
| R8 | **`urgent` 口径误解** | 🟡 记录 | 是"视频端口级"而非"显示 burst 级"，见 3.7 | 已在 RTL 注释写明 |

**没有发现的**：死锁、活锁、组合环、CDC 跨域问题（新增信号 `display_read_urgent_q` 与消费它的外层桥**同在 core_clk 域**：`top:634 .clk(core_clk)` vs `top:654 .clk(core_clk)`）。

---

## 六、回退指引（如果构建报拥塞）

| 想回退什么 | 改哪里 | 操作 |
|---|---|---|
| 只回退 CDC 深度 | `rtl/style/style_axi_cdc.sv:20,22` | `4` → `3`（省一半面积）或 → `2`（完全回到改前） |
| 只回退显示优先级 | `rtl/soc_integration/soc_video_ddr_integration.sv:203` | `#(.DYNAMIC_VIDEO_READ(1'b1))` → 删除参数列表（回到默认 0；端口连接可保留，无害） |
| 完全回退 | 4 个文件的上述行 | 新增的端口/wire 保留也不会报错（未使用输出/输入只会产生 warning） |

> 注：A 的位置我专门做成"端口连接保留也安全"——`video_read_urgent` 即使变成未使用输入，也不会影响功能（默认为 0 时它本来就不参与）。

---

## 七、上板验证方案（配合你打算看的 `3A` 行与 `VIDEO UF`）

### 7.1 主判据（按优先级）

| 信号 | 来源 | 期望方向 | 判据 |
|---|---|---|---|
| **`VIDEO UF`** | `video_regs[0x14c/4]` = `status_underflow_count` | **显著下降** | 看 `DUF`（相邻两次日志的差值）而不是绝对值；连续 5 行 `DUF` 下降 ≥50% 为通过 |
| **`DUF`** | `style_driver.c:97` 自算 | 下降 | 同上 |
| **`NN` fps** | `style_submit_metrics` 的 `MONET CAP/NN` 行 | **不应明显下降** | 允许 ≤10% 下降；若跌 >20% 说明 R3 成立，需要回收优先级 |
| **`3A` 行** | `camera_3a_log`（走 I2C，不过 DDR） | **节拍不变** | 若 3A 行出现停顿/漏行，说明 CPU 真被拖慢（R1 的实测反证） |
| **`AXI`** | `video_regs[0x148/4]` = `soc_axi_error_count` | **保持 0** | 任何增长都说明 ID/B-R 映射被破坏（与本次改动无关但必须查） |

### 7.2 用新 profiler 做机制级验证（这是本轮最好的证据）

固件 DDR 日志第一行现在有 `DARST`（index 2 = 显示侧 AR 反压）与 `ARST`（index 1 = CNN 侧 AR 反压）：

| 观察 | 含义 |
|---|---|
| `DARST` **下降** | 显示读更容易拿到授权 → **本次改动生效**（主证据） |
| `ARST` **上升**（同时 `NN` fps 只小跌） | 预期内的代价：CNN 读让位给显示。合理范围：`ARST` 涨、但 `NN` fps 不超过 10% 跌幅 |
| `DARST` 与 `ARST` **都不变** | 说明竞争根本没发生（CPU 在稳态几乎不读 DDR，只有 boot 的 DDR stress 才读）→ 那 `VIDEO UF` 的根因**不在外层仲裁**，要去查内层桥/FIFO 深度/单 outstanding |
| `IDLE`(index 9) 已经接近 `T`(index 0) | 网络大部分时间空闲 → 欠载与 DDR 带宽无关，是计算/帧调度问题 |

> 提醒：`ERGAP`(index 3, 读 burst 在飞但无 beat) 与 `B` 等待……本版 profiler 只实现了 0/1/2/3/8 五项，其余读回 0，**不要按 12 项去解读日志**（`style_ddr_profiler.sv:13-18` 已写明）。

### 7.3 A/B 协议（建议照做，否则单次数据不可信）

1. 烧当前（改动前）比特流，跑 90 s，记录 6~9 行 DDR 日志的 `DUF`/`DARST`/`ARST`/`NN`——**先拿到基线**。
2. 烧新比特流，同样跑 90 s，记录同样字段。
3. 对比 `DUF` 均值、`NN` fps 均值、`DARST` 占比。
4. **只在 `AXI` 全程为 0 时才认定这次对比有效。**

### 7.4 如果 `VIDEO UF` 没降——按这个顺序排除

1. `DARST` 是否下降了？没降 → 外层竞争没发生，问题不在本改动（回到单 outstanding / FIFO 深度）。
2. `DARST` 降了但 `VIDEO UF` 没降 → 显示欠载不是"AR 拿不到"，而是"R 数据回不来"（DDR 延迟/带宽）或显示 FIFO 太浅 → 看 `ERGAP`(index 3)。
3. `IDLE` 占比很高 → 欠载与仲裁无关，是帧调度/计算侧。

---

## 八、我做的检查（可复现）

| 检查 | 方法 | 结果 |
|---|---|---|
| 端口名/位宽逐个对齐 | read 4 个文件改后全文 | `display_read_urgent`(1 位)、`video_read_urgent`(1 位) 两端一致 |
| 三处实例化是否唯一 | grep 全 `rtl/`+`tests/`+`tools/` | `style_video_system` 仅 top:638、`soc_video_ddr_integration` 仅 top:653、`style_axi_cdc` 仅 `style_accel.sv:127` → **无需改测试平台** |
| 括号/方括号/begin-end 平衡 | 去注释后计数 | 4 个文件全部平衡（273/273、63/63、261/261、593/593 等） |
| 组合环 | 读 `style_display.sv:75` 的依赖项 | 无（依赖全是寄存器/FIFO 旗标，不含 `arready`） |
| 未启用参数的必要性 | 逐条代入 `:49-52,:72` 的表达式 | 三条若启用均会饿死 CPU（3.5 节） |
| FIFO 资源落点 | 读 `style_async_fifo.sv:27-40` | AR/AW 命中 `small_storage`（FF），数据通道命中 `block_ram` |
| **未做** | 编译/综合/PnR/上板 | 按你的要求全部回避 |

**行数变化**：`style_video_system.sv` 109→122、`ti60f225_oob_top.v` 996→1002、
`soc_video_ddr_integration.sv` 423→442、`style_axi_cdc.sv` 25→30。

---

## 九、留给你的两个决定

1. **任务 B 的深度**：接受 +960 FF（当前实现），还是改 `LOG_DEPTH(3)`（+480 FF）？
   我的技术意见是 **3 就够**（2 在飞只需 2~3 条目），但既然你要求 4、且 4 是"一次到位不用再想"，我按 4 交付。
   建议先看一眼构建日志里的 **FF 利用率**——这是唯一我不知道的数字。
2. **是否需要把 `MAX_VIDEO_BURSTS` 从 3 调成 2 或 4**：3 → CPU 保底 25%；2 → 保底 33%（对 CPU 更友好、对显示略差）；
   4 → 保底 20%（显示更好、CPU 更差）。**当前先按默认 3 不动**（改动最小、上下界都合理）。
   如果上板发现 `DARST` 仍高而 `NN` fps 有余量，可以再往 4 调；如果 `NN` fps 掉了，往 2 调。
