# Track1 构建前面积/时序预算审计（只读）

> 审计人：rowpipe-layer（第三方审计，未改任何文件、未构建）
> 审计时间：2026-10-27 11:23 → 11:50
> **审计对象版本（重要）**：`rowpipe_ddr_banks.v` 在我审计期间被 T1 作者**实时改写**（860 → 909 → 946 → 967 → 988 行，mtime 11:44:39）。
> 本报告最终按 **mtime 11:44:39 / 11:42:10 / 11:30:11 / 11:27:41 / 11:28:55** 这一版的 `git diff` 逐行数资源：
> ```
> rowpipe_ddr_banks.v                | 260 +++++++++------
> soc_video_ddr_integration.sv       |  23 ++-
> style_axi_cdc.sv                   |  17 ++-
> style_video_system.sv              |  19 ++-
> ti60f225_oob_top.v                 |  12 ++-
> 5 files changed, 252 insertions(+), 79 deletions(-)
> ```
> 基线（未改动）状态用 `git stash` 前后的 `outflow/` 实测报告核对，**不是估算**。

---

## 0. 结论先行（三句话）

1. **当前这版默认配置几乎不花面积**：① posted-B 已开（MAX_B_OUT=4）、② 多 burst **重构但默认关闭**（MAX_RD_INFLIGHT=1）、③ CDC 加深 **已砍**（CMD_LOG_DEPTH=2）、④ 外层桥 urgency 已开。合计 **+0~+100 XLR**（预算 1,013）⇒ **可以构建**。
2. **③ 是唯一会突破余量的一项**，单项 **+600~1,250 XLR**（60%~120% 的余量），且与上次失败的 profiler（+902 XLR / 拥塞 2.54）同一量级 ⇒ **必须永久保持 CMD_LOG_DEPTH=2**。作者已经这么做了，本报告只是把它钉成硬约束。
3. **② 的 RAM 推断风险：不存在。** 基线实测 `u_rd0` = **7 块 RAM + 19 FF**、`u_rd1` = 7 块 + 20 FF ⇒ 128 bit × 64 深的数组**已经是块 RAM**，DEPTH=256 不会掉成 32,768 FF。真正的雷不在 RAM，而在 **T1.2 引入的两个功能风险**（§6）。

---

## 1. 预算的度量基准（先把尺子校准）

从 `outflow/ti60f225_oob.map.rpt` 的 Resource Summary 与 `hier_util.rpt` 头行实测反推，**XLR 的构成为**：

```
XLR = EFX_LUT4 34,741 + EFX_ADD 12,620 + EFX_SRL8 1,167 + EFX_FF 25,140 − 被 LUT/adder 吸附的 FF 13,883
    = 59,785 ≈ 59,787 ✓   （误差 2，来自 0.5 取整）
其中 xlr_lut4_and_ff 11,521 + xlr_adder_and_ff 2,362 = 13,883 = 与 LUT/ADDER 共用同一 XLR 的 FF
```

**⇒ 预算公式（本报告统一用它）**：**1 个 LUT4 = 1 XLR，1 个 1-bit 加法器 = 1 XLR，1 个 SRL8 = 1 XLR，1 个 FF = 1 XLR；但能与 LUT/adder 同址打包的 FF 不额外占 XLR（基线吸附率 13,883/25,140 = 55%）。**
⇒ 保守估计用 `ΔXLR ≈ ΔFF + ΔLUT4`，乐观估计用 `ΔXLR ≈ max(ΔFF, ΔLUT4) + 0.45×min(...)`。本报告给区间。

**当前资源（实测，`hier_util.rpt` 首行）**

| 资源 | 已用 | 上限 | 余量 |
|---|---|---|---|
| **XLR** | **59,787** | **60,800** | **1,013（1.67%）** |
| MEM（RAM 块） | 244（EFX_RAM10 240 + EFX_DPRAM10 4） | 256 | 12 |
| DSP | 147（DSP48 145 + DSP24 2） | 160 | 13 |
| FF（EFX_FF） | 25,140 | — | — |
| LUT4 | 34,741 | — | — |

**关键子模块实测基线**（后面每一项的 Δ 都相对这些数字）

| 实例 | 模块 | XLR | MEM | FF | 说明 |
|---|---|---|---|---|---|
| `u_bank` | rowpipe_ddr_banks | 2,837.5（自身 843.5） | 30 | 172 | 本报告 ①② 的落点 |
| `u_rd0` | rowpipe_rd_stream | **616** | **7** | **19** | ② 的主战场 |
| `u_rd1` | rowpipe_rd_stream | **465** | **7** | **20** | ② 的主战场 |
| `u_src` | rowpipe_src_stream | 488 | 7 | 98 | ② 未改（见 §6.2） |
| `u_wr` | rowpipe_wr_engine | **213.5** | 9 | 31 | ① 的落点 |
| `u_arb` | rowpipe_axir_arb4 | **81.5** | 0 | 2 | ② 附带改了仲裁器 |
| `cdc/ar` | style_async_fifo W40/LD2 | **232.5** | **0** | **115** | ③ 的落点（**不是 RAM，是寄存器堆**） |
| `cdc/aw` | style_async_fifo W40/LD2 | **201** | **0** | **116** | ③ 的落点 |
| `bridge` | axi_shared_ddr_2m（外层） | **365** | 0 | 3 | ④ 的落点 |

---

## 2. 审计项 ①：写引擎 posted-B（`rowpipe_wr_engine`）

### 2.1 实际改法（已落地，不是提案）
`rowpipe_ddr_banks.v:485-553`。`W_IDLE→W_ADDR→W_DATA→W_RESP` 四态改为 **三态**（删 `W_RESP`），`bready` 由寄存器改成**常 1**，
新增 `reg [2:0] b_out`（未回 B 计数，`MAX_B_OUT=4`，`LIMIT` 硬钳到 1..8）与 `reg b_virt_flag`，`pop` 从
`(st==W_RESP)&&bvalid` 改成 `(st==W_DATA)&&wready`，`idle` 加入 `b_out==0`。

⚠️ **与 Lead 描述的差异**：Lead 说"上限 2~3"，实际代码是 **MAX_B_OUT = 4**（AXI4 同 ID 允许 16，4 安全）。

### 2.2 三条估计（逐条数字化的推导）

| 项 | 估计 | 推导 |
|---|---|---|
| **FF** | **+3** | `b_out[2:0]` +3；`b_virt_flag` +1；`bready` 由 reg 变常量 **−1** ⇒ +3 |
| **LUT4** | **+20~25** | `b_ok=(b_out<4)` 是 `!b_out[2]` ⇒ **0 LUT**；`idle` 多一个 3 输入 NOR +1；`b_out` 三路加/减（±1 与保持）≈ 12；`b_virt_flag` 更新 + 不一致检测 ≈ 4；`error` 粘滞多 3 个置位条件 +3；`pop` 复用 `b_inc`（同式，+0）；删掉 `W_RESP` 的 `bvalid` 分支 −3 |
| **RAM 块** | **0** | `amem/dmem/vmem` 深度未变（DEPTH=32） |
| **XLR 合计** | **+23~28** | 占余量 **2.3~2.8%** |

### 2.3 时序风险
**低。** 关键路径**变短**：状态从 4 个减到 3 个，`W_DATA` 直接回 `W_IDLE`；新增的 `b_out` 是一个 3 位 ±1 计数器，挂在 `clk` 上
（`u_bank` 全体在 **cnn_clk = vid_clk_dvi2 = 148.5 MHz**，见 §5）。
唯一需要注意的路径：`idle = (count==0)&&(st==W_IDLE)&&(b_out==0)` 送到 `rowpipe_frame_driver` 的层末同步——这一路是 **10 位 count 比较 + 状态 + 3 位计数**，形状与改动前相同（只多一个 3-NOR），可接受。

### 2.4 功能正确性（顺带核了）
- `wr_idle`（= `count==0 && st==W_IDLE && b_out==0`）保证层末真的落盘，**排在飞 B 是正确的**（否则下一层读到旧数据）。
- `b_out` 下溢保护 + `b_dec && b_out==0` 置 `error` 粘滞，避免了 clear 后迟到的 `bvalid` 让 3 位计数回绕成 7 永久堵死 AW（这个坑他们踩过并写了注释）。
- `b_virt_flag` 的"组内 virt 相同"依赖引擎每层末等 `wr_idle`，我在 `rowpipe_engine.v:418` 确认了 `(pix>=out_total_r)&&mem_wr_idle` 的门 —— **成立**。

---

## 3. 审计项 ②：读流多 burst + 仲裁器 append（T1.2）

### 3.1 实际改法（比 Lead 描述的大：**仲裁器也改了**）
`rowpipe_ddr_banks.v`：
- `rowpipe_axir_arb4` 新增 `MAX_INFLIGHT` 参数、`reg [2:0] ob`、`ar_more/ar_fire/ar_add/ar_last/ob_n`、**`ack0..ack3` 输出**，`arvalid` 从 `(ast==A_AR)` 变成 `(ast==A_AR)||ar_more`。
- `rowpipe_rd_stream` 新增 `MAX_INFLIGHT` 参数与 `ar_ack` 输入；**`want_addr/want_len` 从寄存器变成组合 wire**（删了 40 个 FF）；删 `want_r`、`cur_len1`；新增 `bursts_out[1:0]`；`count/inflight` 改 `CNTW=10`；**`IDXW` 用 `clogb2(DEPTH)` 自动推导**；`next_fetch` 从"beat_last 推进"改成"**ar_ack 推进**"。
- 例化处：`.DEPTH(DEPTH) .MAXB(MAXB) .MAX_INFLIGHT(MAX_RD_INFLIGHT)`，`ack1→rd0_ar`、`ack2→rd1_ar`，`ack0()/ack3()` 悬空（u_src/u_wstream 未改）。

### 3.2 当前默认值是"全关"（这点最重要）
`rowpipe_ddr_banks` 的包装参数（`:710-713`）**默认 = 改动前行为**：
```verilog
parameter integer DEPTH = 64, MAXB = 16, MAX_RD_INFLIGHT = 1, MAX_B_OUT = 4
```
且 `rowpipe_frame_driver.v:130` 的 `u_bank` 例化**没有覆盖任何参数** ⇒ **实际进综合的是 K=1 / MAXB=16 / DEPTH=64**。
K=1 时 `ar_more ≡ 0`（`ob<K` 在 A_R 态恒假）⇒ **仲裁器的 append 通路被常数折叠掉**，只有 `ob` 计数器和退出条件留下。

### 3.3 三条估计（当前默认配置：K=1，DEPTH=64，MAXB=16）

| 项 | 估计 | 推导 |
|---|---|---|
| **FF（每个 rd_stream）** | **−43** | 删 `want_addr[31:0]` −32、`want_len[7:0]` −8、`want_r` −1、`cur_len1[7:0]` −8；加 `bursts_out[1:0]` +2、`count` 8→10 +2、`inflight` 8→10 +2、`IDXW` 6→6 +0 |
| **FF（仲裁器）** | **+3** | `ob[2:0]` |
| **LUT4（每个 rd_stream）** | **+25~35** | `want` 由"1 根线"变成 `(bursts_out<K)&&free_ok&&!need_restart` ≈ +6；`free_ok` 的 10+10 加法与比较 ≈ +6；`inflight` 三路增减（10 位）≈ +15；`bursts_out` 双路 ≈ +4；`cur_valid` 10 位版本 +4；**删掉** `want_r` 的置/清与 `cur_len1` 的装载 mux ≈ −10 |
| **LUT4（仲裁器）** | **+12~15** | `ob<1` 比较 1、`ob_n` 3 位加减 6、退出条件 `ar_last&&(ob_n==0)` 4、`arvalid` OR 1 |
| **RAM 块** | **0**（DEPTH=64 不变） | — |
| **XLR 合计** | **−20 ~ +5** | 两条流的 −86 FF 抵消了新增 LUT ⇒ **基本免费，甚至略省** |

### 3.4 打开参数阶梯后的增量（这才是 Lead 该看的预算）

| 阶梯 | 改动 | ΔFF | ΔLUT4 | ΔRAM | **ΔXLR** |
|---|---|---|---|---|---|
| **C：长 burst** `MAXB=64, DEPTH=256` | 两条流 | +4（IDXW 6→8 ×2） | +10~15（比较器加宽） | **+0~6** | **+15~20** |
| **D：读并发** `MAX_RD_INFLIGHT=2` | 两流 + 仲裁器 | +0 | +10~20（`ar_more` 变活：`wv[sel]` 4:1 mux + `ob<K`） | 0 | **+10~20** |
| **C+D 全开** | | +4 | +20~35 | +0~6 | **+25~55** |

⇒ **② 从"重构"到"全开"总共只花 55 XLR 上限（占余量 5.4%）**，RAM 最多 +6 块（244→250/256，仍留 6 块）。

### 3.5 时序风险：**本组最高，但可控**
- `arvalid` 从"纯寄存器输出"变成 `(ast==A_AR)||((ast==A_R)&&(ob<K)&&wv[sel])` ⇒ 多 **1~2 级 LUT**，且 `wv[sel]` 是 4:1 mux（选客户端 want）。
  这条路径在 **vid_clk_dvi2（6.734 ns）** 域，该域基线 setup slack **+0.407 ns**（见 §5）。
  t16ff 每级 LUT4+布线约 0.10~0.14 ns ⇒ 2 级约 **0.20~0.28 ns**，吃掉 vid 域余量的 **50~70%**，但**不动全局最差路径**。
- 只有打开 **D** 才会出现这条路径；K=1 时被折叠 ⇒ **当前配置零风险**。

---

## 4. 审计项 ③：CDC 命令 FIFO `LOG_DEPTH(2)→(4)` —— **建议否决（作者已按 2 落地）**

### 4.1 关键事实：它**不是 RAM**，是寄存器堆
`style_async_fifo.sv:27` 的 generate 判据 `if (LOG_DEPTH<=4 && WIDTH<=45)` 选中 **small_storage** 分支（FF + 变量下标读 mux）。
实测证据：`cdc/ar` = **232.5 XLR / 0 MEM / 115 FF**，`cdc/aw` = **201 XLR / 0 MEM / 116 FF** ⇒ 确认走寄存器路径。
（对照：`cdc/r` WIDTH=131 → ram_storage → 84 XLR / **7 MEM**；`cdc/w` WIDTH=145 → 8 MEM。）

### 4.2 三条估计（LOG_DEPTH 2→4，即 4 项 → 16 项）

| 项 | 估计（**每个**命令 FIFO） | 推导 |
|---|---|---|
| **FF** | **+240~480** | 数据存储 40 bit × (16−4) = **+480 原始**；实测 LD2 的 115 FF 里理论应为 160(存储)+40(out_data)+28(指针/同步)+1 ≈ 229 ⇒ **约 50% 的位被常数折叠**（地址高位/arlen 恒定），按同比例折算 ⇒ +240；上限 +480 |
| **LUT4** | **+90~150** | 读 mux 4:1→16:1：40 bit × (+3 LUT/bit) = +120（折叠掉的那半 ⇒ +60）；写入口令 4→16 项解码 +16~24；指针/格雷码 3→5 位 +8 |
| **RAM 块** | **0** | 仍是寄存器堆。**⚠ 注意：若有人把它调到 LOG_DEPTH=5，会翻到 `ram_storage` 分支，而该分支是"异步读"`assign read_word=mem[...]`，Efinity 推不出 BRAM，会掉进 logic memory ⇒ 灾难。上限必须钉在 4。** |
| **XLR 合计** | **ar+aw 合计 +600 ~ +1,250** | 中心估计 ≈ **+750~900** |

### 4.3 判定：**否决**
- **占余量 60%~120%**：中心估计就吃掉 3/4 的 1,013，上限直接击穿。
- **量级对标**：上次 12 个 profiler 计数器 = **+902 XLR** 就把 XLR 顶到 99.82%，PnR 在布线阶段 `could not resolve congestion`（峰值 2.54）。③ 与那次**同一量级**，且其中 480+ FF 是**分散的触发器**，布线更零碎，拥塞风险不比 profiler 低。
- **收益不成立**：本体需求只是"K=2 个 AR 在飞"，**4 深的队列本来就够**（2 个在飞 + 2 个缓冲）；CX 侧 100 MHz vs 环侧 148.5 MHz 的 1.5× 速率差由 `bursts_out<K` 节流，不靠 FIFO 深度。
- **作者已采纳**：现在 `style_axi_cdc.sv` 的 `CMD_LOG_DEPTH` 默认 2、注释里写明"16×40=640 FF/通道，高 960 FF 不值得花掉 1,013 里的 960"，且 `style_accel.sv:127` 的 `style_axi_cdc cdc(.*,...)` **没有覆盖该参数** ⇒ **③ 实际 = 0 XLR**。本报告把它升级为**硬约束**：构建前请 `grep CMD_LOG_DEPTH`，确认为 2。

---

## 5. 审计项 ④：外层桥 urgency（`DYNAMIC_VIDEO_READ(1)` + `video_read_urgent`）

### 5.1 会不会把被优化掉的逻辑重新引入？——**会，但很小（+2 FF）**
`axi_shared_ddr_2m.sv` 里受 `DYNAMIC_VIDEO_READ` 门控的只有三处：
- `:51-52` `choose_vid_r` 的 DYNAMIC 分支（两个比较 + 一个 AND + 嵌套三目）
- `:93-96` `video_read_streak` 计数器（`STREAK_W = $clog2(MAX_VIDEO_BURSTS+1) = $clog2(4) = 2` bit）
- `:72` 的 `!(RESERVE_URGENT_READ && video_read_urgent)` —— **参数仍是 0，保持折叠** ✓

参数 =0 时 `video_read_streak` 是"只写不读"的死寄存器 → 被优化掉；=1 时重新引入 **2 FF + 约 10~12 LUT4**。

### 5.2 三条估计（含外围改动）

| 位置 | ΔFF | ΔLUT4 | ΔRAM | 说明 |
|---|---|---|---|---|
| `axi_shared_ddr_2m`（外层 bridge） | +2 | +10~12 | 0 | streak 计数 + `choose_vid_r` 分支 |
| `style_video_system.sv` | +1 | 0 | 0 | 新增 `display_read_urgent_q`（打一拍断开组合路径，注释写明是为 `arready` 锥） |
| `soc_video_ddr_integration.sv` | 0 | 0 | 0 | 只加端口 + 参数 |
| `ti60f225_oob_top.v` | 0 | 0 | 0 | 纯连线（`style_read_urgent`） |
| **合计** | **+3** | **+10~12** | 0 | **+13~15 XLR** |

### 5.3 时序风险：**最低**
外部桥在 **core_clk（10 ns）** 域，基线 setup slack **+2.326 ns**（最宽松的域）；`video_read_urgent` 已在 `style_demo` 里打了一拍（同域 core_clk，无需 CDC），
`arready` 锥只多一个 AND。风险≈0。

### 5.4 一个语义提醒（不是面积问题）
`URGENT_OVERRIDES_FAIRNESS=0` 保持 ⇒ urgent 时视频读最多连赢 `MAX_VIDEO_BURSTS=3` 次，CPU 每 4 次必得 1 次。**这是"有界优先"不是"绝对优先"**，符合注释；不会饿死 CPU。

---

## 6. ② 的 RAM 推断风险判定（Lead 点名的最重要一条）

### 6.1 判定：**DEPTH=256 不会落成 FF，风险不存在**
**证据链（三条，互相独立）**：
1. **实测**：基线构建的 `hier_util.rpt` 里 `u_rd0` = **7 MEM 块 / 19 FF**，`u_rd1` = 7 MEM / 20 FF，`u_src` = 7 MEM / 98 FF。
   128 bit × 64 深的数组**已经在块 RAM 里**（若落 FF 会是 8,192 FF/流，实测只有 19~98 ⇒ 差 2~3 个数量级）。
2. **模式未变**：新代码 `rowpipe_ddr_banks.v:314-317` 仍是**两个独立 always**——写口 `always @(posedge clk) if(be) mem[wr_idx]<=beat_data;`，读口 `always @(posedge clk) cur_data<=mem[ridx_n];`（寄存读）。
   文件里 261-263 行的注释（"存/读合在同一个 always 里 Efinity 不认 RAM 模板，实测单流 8,447 FF"）**描述的正是反面教材**，而这版代码没有踩它。
3. **深度不改变模板**：RAM 推断只与"端口结构 + 地址宽度 + 是否寄存读"有关，与深度无关；256 深仍在 EFX_RAM10 的单块/多块可达范围内（基线用 7 块服务 128 bit 宽度 ⇒ 单块只贡献 ≈18 bit 宽，说明工具选的是 ≥512 深的窄宽模式，**256 深通常 0 额外块**）。

**⇒ 否决意见不成立；② 的 DEPTH 改动可以放行。**

### 6.2 RAM 块数量的三种可能（给 Lead 的决策区间）
| 情形 | DEPTH 64→256 的 RAM Δ | 依据 |
|---|---|---|
| 乐观（最可能） | **+0 块** | 基线 128 bit 用 7 块 ⇒ 单块 ≈18 bit 宽，模式深度 ≥512 ⇒ 256 深同模式即可 |
| 保守（作者的估值） | **+3 块/流 = +6** | 作者注释："256 每流 +3 块 RAM（244→250/256）" |
| 悲观 | +6/流 = +12 | 需要 15 块以上的窄模式，超出 12 块余量 |

**RAM 余量 12 块，三种情形里只有"悲观"会破；而基线实测已在 7 块/流，悲观情形与实测矛盾 ⇒ 实际可视为 +0~6。** 建议构建后用 `map.rpt` 的 `EFX_RAM10` 计数与 `hier_util.rpt` 的 `u_rd0` MEM 列直接对账。

### 6.3 `IDXW = 6` 这颗雷：**已经被作者拆除**
Lead 担心的"`localparam IDXW = 6; // DEPTH=64` 改 256 会越界 + `count` 是 `reg[7:0]` 装不下 256"，现在的代码是：
```verilog
function integer clogb2; ... endfunction
localparam integer IDXW = clogb2(DEPTH);   // 64→6, 128→7, 256→8 ✓
localparam integer CNTW = 10;              // count/inflight 位宽（DEPTH ≤ 512 都够）
```
我验证了 `clogb2`：64→6 ✓、128→7 ✓、256→8 ✓（clogb2 初值 1、循环 `(1<<i)<value` 时 `clogb2=i+1`，对 2 的幂正确）。
**⇒ 位宽自动推导，不再需要手改。** 剩余雷区见 §7。

### 6.4 真正的风险转移到了"功能"（这两条比面积更值得看）
**⑥-1【新引入，K=2 时是 AXI 协议违规】`arvalid` 组合依赖客户端 `want`。**
`ar_more = (ast==A_R) && (ob<K) && wv[sel]`，其中 `wv[sel]` = 客户端 `want` = `(bursts_out<K) && free_ok && !need_restart` —— **纯组合**。
若 `free_ok` 在 AR 握手中间从 1 翻到 0（`count` 随 beat 堆积变化 / 或 `need_restart` 抖动），`arvalid` 会在 `arready` 之前撤销 ⇒
**AXI4 要求 ARVALID 一旦拉高必须保持到 ARREADY** ⇒ 协议违规，表现为"偶发丢 burst / 后半张图错位"。
K=1 时该路径被折叠 ⇒ **当前无风险**；**打开 D（MAX_RD_INFLIGHT=2）之前必须修**：把 `want`（或 `fetch_byte`+`bst_beats`）在 AR 握手期间用寄存器锁存。

**⑥-2【更严重】`u_src` / `u_wstream` 没改，却会被 append 逻辑重复发 AR。**
`u_arb` 的 `ack0()`（u_src）、`ack3()`（u_wstream）**悬空**，这两个客户的 `want_addr/want_len` 仍是"beat_last 才更新"的寄存器（`rowpipe_src_stream` 保持旧实现）。
K=2 时 `ar_more` 只判 `ob<K` 与 `wv[sel]`，**不区分客户** ⇒ 当前客户若是 u_src，它整条 burst 期间 `want` 恒 1 ⇒ **立刻再 append 一条同地址 AR**（`next_fetch` 不推进，因为是寄存器且只在 beat_last 更新）⇒ **同一 burst 被读两遍**：FIFO 里数据翻倍、`count` 与实际错位、`inflight` 记账在 submodule 与 arbiter 之间失配。
⇒ **打开 D 之前必须**：(a) 把 u_src/u_wstream 也改成 `ar_ack` 推进 `next_fetch`，或 (b) 给 `rowpipe_axir_arb4` 加 per-client 的 `MAX_INFLIGHT` 掩码（只允许 client1/client2 append）。
这是我这次审计发现的**最高优先级功能缺陷**（不影响当前默认配置，但会毁掉 step D 的实测）。

---

## 7. 位宽雷区清单（改参数后必须同步的每一项）

`rowpipe_rd_stream` 已自动推导为主，但仍有 5 处是**手工常量**：

| # | 位置 | 现状 | 危险条件 | 症状 |
|---|---|---|---|---|
| 1 | `:190` `localparam CNTW = 10` | 写死 10 | `DEPTH > 512`（count 或 inflight 需 11 位） | 计数回绕 ⇒ `free_ok` 误真 ⇒ **FIFO 溢出、静默错数据** |
| 2 | `:188` `MAXB_E = (MAXB*2 > DEPTH) ? DEPTH/2 : MAXB` | 硬钳 | `MAXB > DEPTH/2` | 被钳后 burst 变短（功能对、带宽降）；**这条保护是对的，别删** |
| 3 | `:189` `localparam [8:0] MAXB9 = MAXB_E[8:0]` | 9 位 | `MAXB > 511` | 截断；AXI4 上限 256 ⇒ 实际不可达，但别改成 10 位以下 |
| 4 | `:184` `IDXW = clogb2(DEPTH)` | 自动 | **`DEPTH` 不是 2 的幂** | `mem[0:DEPTH-1]` 但 `wr_idx` 按 `2^IDXW` 回绕 ⇒ **越界写/读**（当前 64/128/256 都是 2 的幂 ✓） |
| 5 | `:262` `want_len = bst_beats[7:0] - 1` | 8 位 | `MAXB > 256` | 截断；AXI4 `arlen=AWLEN-1`，256 beat 需 8 位 ✓ 刚好够 |
| 6 | `rowpipe_wr_engine:483` `IDXW = 5  // DEPTH=32` | 写死 5 | 改 `rowpipe_wr_engine` 的 DEPTH | 同类越界（**这次没改它，列出来防止下次踩**） |
| 7 | `style_async_fifo.sv:27` `LOG_DEPTH<=4 && WIDTH<=45` | 分支判据 | `CMD_LOG_DEPTH ≥ 5` | 翻到 `ram_storage` 的**异步读**分支 ⇒ 推不出 BRAM ⇒ 掉 logic memory（灾难） |
| 8 | `rowpipe_ddr_banks:495` `LIMIT = clamp(MAX_B_OUT,1,8)` | 钳 8 | `MAX_B_OUT > 8` | 被钳（`b_out` 只有 3 位，8 是上限；AXI 同 ID 允许 16，但本设计 8 足够） |

---

## 8. 时序风险排序（对照基线 slack）

**基线实测（`timing.rpt` 的 Clock Relationship Summary）**

| 域 | 周期 | **Setup slack** | **Hold slack** |
|---|---|---|---|
| **tx_cal_clk_90edge → 自身** | 2.500 ns | **+0.133（全局最差）** | +0.097 |
| rx_cal_clk → 自身 | 2.500 | +0.470 | **+0.026（全局最差）** |
| sdram_clk → 自身 | 2.500 | +0.452 | +0.074 |
| **vid_clk_dvi2 → 自身** | **6.734（148.5 MHz）** | **+0.407** | +0.030 |
| **core_clk → 自身** | **10.000（100 MHz）** | **+2.326** | +0.028 |

**关键结论**：Lead 引用的 `setup +0.133 / hold +0.026` **全部落在 DDR3 PHY 校准域（tx_cal_clk_90edge / rx_cal_clk，400 MHz）**，
而**本次 4 项改动一行都不在那些域里**（已验证 `style_accel.sv:109` → `style_network_rowpipe network(.clk(cnn_clk))`，
`u_bank/u_rd*/u_arb/u_wr` 全在 **cnn_clk = vid_clk_dvi2**；`bridge` 在 **core_clk**）。
⇒ **全局最差路径不会被这 4 项推动**，真正的预算域是 `vid_clk_dvi2` 的 **+0.407 ns**。

| 排序 | 项 | 受力域 | 预计吃掉 | 风险 |
|---|---|---|---|---|
| **1** | **② 打开 D（K=2）** | vid（+0.407） | +1~2 LUT：**0.20~0.28 ns（50~70%）** | **中**（不动全局最差，但 vid 域会紧张；且 `arvalid` 组合化还带协议风险） |
| 2 | ② 打开 C（DEPTH=256/MAXB=64） | vid | 计数/比较加宽，+1 级：0.10~0.14 ns（25~35%） | 低 |
| 3 | ③（若仍要做 LD=4） | vid（`out_data` 的 16:1 mux） | +2~3 级：0.25~0.40 ns（60~100%） | **高**（另有面积否决） |
| 4 | ① posted-B | vid | 路径反而变短 | 极低 |
| 5 | ④ urgency | core（+2.326） | +1 级 AND：0.10 ns（4%） | 极低 |

---

## 9. 合计预算与门限（Lead 要的组合结论）

| 配置 | ΔFF | ΔLUT4 | ΔRAM | **ΔXLR** | 占余量 | 判定 |
|---|---|---|---|---|---|---|
| **当前这版（①③④ + ②重构，默认全关）** | **−80** | **+45~65** | **0** | **+0 ~ +60（中心 +20）** | **≤6%** | ✅ **可以构建** |
| 打开 C（长 burst） | +4 | +10~15 | +0~6 | +15~20 | 2% | ✅ |
| 打开 D（读并发 2） | +0 | +10~20 | 0 | +10~20 | 2% | ✅ 但先修 §6.4 |
| **C+D 全开** | +4 | +20~35 | +0~6 | **+25~55** | **5.4%** | ✅ |
| **再加 ③（ar/aw LD=4）** | **+480~960** | **+180~300** | 0 | **+600~1,250** | **59%~123%** | ❌ **否决** |
| （参照）上次 profiler 12 计数 | — | — | — | **+902** | 89% | ❌ 实测布线失败（拥塞 2.54） |

**门限答案**
- **①+②+④ 全开 = +25~55 XLR（最多 6 块 RAM）** ⇒ 余量 1,013 → **约 960 仍富余**，**一项都不用砍**。
- **③ 一项就会突破**（中心估计 750~900，上限 1,250）。**必须保持 CMD_LOG_DEPTH=2。**
- 危险阈值参考：**+900 XLR 附近就是上次布线失败的位置**。⇒ 任何单项或组合超过 **+400（40%）** 都应先单独构建验证，不要叠加。

---

## 10. 构建前 checklist（给 Lead，按优先级）

1. **`grep -r "CMD_LOG_DEPTH" rtl/` 必须只有 1 处定义 + 2 处使用，例化处不得覆盖为 3/4**。若被改成 ≥5 会额外触发 `ram_storage` 异步读（§7 #7）。
2. **确认 `rowpipe_frame_driver.v:130` 的 `u_bank` 没有意外覆盖 `MAX_RD_INFLIGHT>1`** —— 现在没有（全默认），这是当前面积安全的**唯一原因**。
3. **`u_arb` 的 `.ack0()` / `.ack3()` 悬空是已知隐患**（§6.4-②）：只要 `MAX_RD_INFLIGHT=1` 就无影响；开 D 之前必须补 u_src/u_wstream 或加 per-client 掩码。
4. 构建后立即用 `hier_util.rpt` 对账三处：`u_rd0/u_rd1` 的 MEM 列（应仍为 7，若变 13 说明 RAM 模式变了）、`bridge` 的 XLR（应 ≈380）、`cdc/ar`（应仍是 232.5，若变大说明 LOG_DEPTH 被改了）。
5. `u_wr` 的 XLR 应从 213.5 → **≈240**；超过 300 说明 `MAX_B_OUT` 被调到 8 以上。

---

## 11. 与 Lead 描述的三处出入（以源码为准）

| Lead 的描述 | 源码事实 |
|---|---|
| ① "`reg [2:0] b_out` 计数未回 B，**上限 2~3**" | 实际 `MAX_B_OUT = 4`（`rowpipe_ddr_banks.v:451`、包装默认 `:713`），且带 `LIMIT` 硬钳 1..8 |
| ② "`want_r` 单标志 → `inflight_bursts`（K=2）；`MAXB` 16→64；`DEPTH` 64→256" | 全部已**参数化但默认不变**（`MAX_RD_INFLIGHT=1 / MAXB=16 / DEPTH=64`）；另外**仲裁器也被改了**（`ob` 计数 + `ack0..3`），且 `want_addr/want_len` 从寄存器改成组合（−40 FF） |
| ③ "`LOG_DEPTH(2)→(4)`" | **已改为 `CMD_LOG_DEPTH` 参数、默认仍 2**（作者已自行否决），`style_accel.sv:127` 例化未覆盖 |
| ④ "加 `DYNAMIC_VIDEO_READ(1)` + 接 `video_read_urgent`" | 与源码一致；另在 `style_video_system` 加了一拍寄存器（+1 FF）专门断开 `arready` 组合锥 |

---

## 12. 一句话给 Lead

**可以构建：当前这版（①③④ + ②重构）只花 +0~60 XLR（≤6% 余量）、0 块 RAM，时序最差路径在 DDR PHY 域且不受影响；② 的 RAM 推断已被基线实测证明安全（u_rd0 = 7 块 RAM / 19 FF）。唯一必须永久砍掉的是 ③（+600~1,250 XLR），作者已用 `CMD_LOG_DEPTH=2` 默认值实现；真正要在打开 step D 之前修的是两个功能缺陷（`arvalid` 组合依赖 `want` 的 AXI 协议风险、u_src/u_wstream 会被重复 append AR），不是面积。**
