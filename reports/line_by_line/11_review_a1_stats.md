# A1 复核：5 个性能统计口（`style_network_rowpipe`）

**复核对象**：工作区未提交改动，`rtl/accel_rowpipe/style_network_rowpipe.sv:137-167`（原 `assign stat_* = 32'd0` 的 5 行 → 5 个 32 位计数器 + 3 个组合 wire）。
**复核方式**：只读。用 read 工具逐个确认了端口、`style_accel` 的快照时序、`rowpipe_frame_driver` 的 FSM、SDC 的时钟分组、固件的打印口径。**未改任何源文件，未碰 `outflow` / `_b.bat` / OpenOCD。**
**Deliverable**：本文件。上一份报告 `02_rowpipe_datapath.md` 的 §7.4 有一处 counter 索引错误，在 §6 订正。

---

## 结论先行（5 条判定）

| # | 问题 | 判定 | 一句话 |
|---|---|---|---|
| 1 | 信号可用性 | ✅ **全部可用** | 11 个 AXI 握手信号 + `start` 都是模块端口（`:22,42-62`），`drv_busy` 是内部 wire（`:104`）。逐条表见 §1。 |
| 2 | 时序契约（清零会不会抹掉刚统计的值） | ✅ **不会，且余量足够** | `core_done` 单拍脉冲在"首个非 busy 拍 +1"，`stat_*` 在同一沿快照；下一个 `start` 最早也要 +5 拍（自动模式）。最坏情况（同拍）也安全，因为快照取的是沿前值。推演见 §2。 |
| 3 | 下溢 | ✅ **构造上不可能** | `cyc_rstall` 的每次自增都被 `drv_busy` 门控，与 `cyc_busy` 同清同增 ⇒ 不变式 `cyc_rstall ≤ cyc_busy` 恒成立。唯一能破坏它的是"以后把 `drv_busy` 从这个条件里删掉"。见 §3。 |
| 4 | **口径** | 🔴 **会误导，而且是"反着报"** | `read_cycles` 测的是 **AXI 反压**（AR 被拒 / R 未被收），而本设计里 `rready` 在流式读期间几乎恒 1 ⇒ **RPMS 会打印 0**；`compute_cycles = busy − 0 ≈ 整帧` ⇒ **CPMS 会打印 ≈57**。这与已知真相（算力 7.85 ms + DDR 等待 49.1 ms）**正好相反**，且会与同一行 UART 里的 profiler 数据（`B 86`）自相矛盾。见 §4，修法在 §7。 |
| 5 | 硬件代价 | 🟡 **能放下，但 97.26% 下是"拥塞风险"而非"逻辑风险"** | ≈160 FF + ≈200 LUT4 ≈ **250~320 XLR**（余量 1,668）。**好消息**：`stat_compute_cycles` 的 32 位减法器跨 `cnn_clk→core_clk`，被 `ti60f225_oob.sdc:22` 的 exclusive clock group 整段 false-path，**不会进入时序报告**。坏消息：该项目历史上"+50 XLR 就拥塞失败"。见 §5，三个省 FF 的具体做法在 §5.3。 |

---

## 1. 信号可用性（Q1）

逐个用 read 核对（不是 grep），均在 `rtl/accel_rowpipe/style_network_rowpipe.sv`：

| 信号 | 位置 | 方向/类型 | 结论 |
|---|---|---|---|
| `clk` / `rst_n` | `:20,:21` | input wire | ✅ |
| `start` | `:22` | **input wire** | ✅ 可读（模块输入端口） |
| `arvalid` | `:44` | **output wire** | ✅ 本模块输出，内部可读 |
| `arready` | `:45` | input wire | ✅ |
| `rvalid` | `:49` | input wire | ✅ |
| `rready` | `:50` | **output wire** | ✅ |
| `rlast` | `:48` | input wire | ✅ |
| `awvalid` / `awready` | `:53 / :54` | output / input | ✅ |
| `wvalid` / `wready` | `:58 / :59` | output / input | ✅ |
| `bvalid` / `bready` | `:61 / :62` | input / **output** | ✅ |
| `drv_busy` | `:104` | **内部 wire**（`wire drv_busy, drv_done, drv_error;`），由 `u_drv.busy` 驱动（`:114`） | ✅ |

**没有隐藏坑**：
- `arvalid/rready/awvalid/wvalid/bready` 是**本模块的输出**（由 `u_drv` 例化驱动，`:119-123`），在 Verilog 里读取自己的 output wire 合法（`.bready(bready)` 把内层驱动接到这根线上）。
- 这 11 个握手信号都已经是 **`cnn_clk`（148.5 MHz）域**信号——它们是 `style_axi_cdc` 网络侧的端口，CDC FIFO 的读侧指针本来就同步在 `cnn_clk`，所以新加的 3 个组合式没有引入新的跨时钟采样。
- 时序域确认：`style_accel.sv:109` `.clk(cnn_clk)`，`cnn_clk` 来自 `style_video_system.sv:61` ← `ti60f225_oob_top.v:634` `.cnn_clk(vid_clk_dvi2)`。

**唯一需要注意的写法问题**（不是错）：`wr_act` 用到了 `bresp` 之外的全部写通道信号，但**没用 `bresp`**——所以 `error` 信号对 `wr_act` 无影响，符合"活动性"语义。

---

## 2. 时序契约：清零会不会抹掉刚统计完的值（Q2）

### 2.1 三个关键信号的产生（逐个文件核对）

1. **`start`（= `core_start`）是单拍脉冲**：`style_accel.sv:95` `wire core_start=start_sync[1]!=start_seen;`，配合 `:101` `start_sync<={start_sync[0],start_toggle}; start_seen<=start_sync[1];` ⇒ `start_toggle` 翻转后延迟 2 拍出现 `start_sync[1]=1`，再 1 拍 `start_seen` 追平 ⇒ **`core_start` 恰好高 1 拍**。
2. **`done`（= `core_done`）是单拍脉冲**：`style_network_rowpipe.sv:127-131` `done_seen <= drv_done; assign done = drv_done && !done_seen;` ⇒ `drv_done` 上升沿后 1 拍产生唯一脉冲。
3. **`drv_done` 是 `rowpipe_frame_driver` 的寄存器输出**：`rowpipe_frame_driver.v:187` `S_DONE: begin busy <= 0; done <= 1; st <= S_IDLE; end`（`S_FLUSH` 在 `:185` 收到 `res_done` 后才进 `S_DONE`）。

### 2.2 逐拍推演（`T` = 最后一个 `S_FLUSH` 拍）

| 拍 | driver 状态 | `drv_busy` | `drv_done` | wrapper `done` | `stat_*` | `style_accel` 动作 |
|---|---|---|---|---|---|---|
| T | `S_FLUSH`（`res_done=1` 采到） | 1 | 0 | 0 | 累加（含 T） | — |
| T+1 | `S_DONE` | **0** | **1** | **1（脉冲）** | **已冻结** | `:103 if(core_done)` ⇒ 沿 T+1→T+2 **快照** `stat_*` |
| T+2 | `S_IDLE` | 0 | 1（保持） | 0 | 冻结 | 快照寄存器已持有终值；`job_done` 随后翻转（`:54`） |
| T+k | `S_IDLE` | 0 | 1 | 0 | 冻结 | 固件 IRQ → 读 APB `0xa8..0xb8` |
| T+m（m≫k） | `S_IDLE`→`S_RUN` | 1 | 0 | 0 | **清零** | `:154` |

**三个关键点**：

1. **计数确实包含了最后一个 busy 拍 T**：`:156` `if (drv_busy) cyc_busy <= cyc_busy+1'b1;` 在 T 的沿上把 T 统计进去，而 `drv_busy` 是在 T 的沿上才变 0（`S_DONE` 的赋值）。所以 T+1 时 `cyc_busy` 已是最终值，T+2 的快照取到它。**没有丢最后一拍**。
2. **`stat_compute_cycles` 与 `stat_read_cycles` 是同一沿的配对值**：`:103` 一行里同时快照 `stat_read_cycles`（= `cyc_rstall`）和 `stat_compute_cycles`（= `cyc_busy - cyc_rstall` 组合值），二者取自同一组沿前寄存器值 ⇒ **天然一致，不会出现"读了新的 busy、旧的 rstall"**。这一点比 `style_ddr_profiler` 强（那个需要 APB 写 `0x54[0]` 冻结才能保证一致性，见 `style_driver.c:71-73`）。
3. **最坏情况也安全**：如果 `start` 恰好和 `done` 脉冲同拍（现实不会发生），`:153` 的清零与本拍快照都在同一个沿，快照取的是沿**前**值 ⇒ 仍然是终值。**清零不抹值。**

### 2.3 下一个 `start` 到底多晚来（余量计算）

两条路径：

- **手动/APB 路径**：`pending` 在 `job_done` 时清（`style_accel.sv:64`），`job_done=done2!=done_seen` 比 `core_done` 晚 2~3 拍；固件随后读状态、写 `0x04[0]`，再经 `start_toggle→2FF` ⇒ 至少 **µs 级**（几个 CPU/APB 周期）。余量巨大。
- **自动路径（最紧）**：`:75` `if(auto_start&&auto_ready&&stream_enable)`，其中 `auto_ready=!pending&&coeff_idle`（`:36`）。`pending` 在 `job_done`（core_done 后 ~3 拍）清 ⇒ 新 `start_toggle` 最早在 core_done+4 拍，`core_start` 再晚 2~3 拍 ⇒ **`start` 最早约 core_done+6~7 拍**，而快照在 core_done+1 拍完成。**余量 ≈5 拍，够但不算宽。**

**⇒ 判定：Q2 的担心不成立。** 但建议做一件小事让它从"靠推演正确"变成"构造上正确"：把清零条件加一个限定（见 §7 的 R3），顺便解掉 §3 里那个"spurious start 截断统计"的隐患。

---

## 3. 下溢（Q3）

**结论：`cyc_rstall > cyc_busy` 在本实现里不可能出现。** 归纳证明：

1. 两者在 `rst_n`（`:151-152`）和 `start`（`:154`）**同一条件同时清 0**；
2. `cyc_rstall` 的自增条件是 `drv_busy && rd_stall`（`:157`），**是 `cyc_busy` 自增条件 `drv_busy`（`:156`）的子集**；
3. 只考虑"同时清 0 之后"的窗口：若某拍 `cyc_rstall` 增 1，则同拍 `cyc_busy` 也增 1 ⇒ 差 `cyc_busy − cyc_rstall` 不变；若 `cyc_rstall` 不增，则差不减。
4. 初值 0-0=0 ⇒ 恒有 `cyc_busy − cyc_rstall ≥ 0`。∎

**唯一能破坏它的三种改法**（供以后 review 时盯）：
- 把 `:157` 的 `drv_busy &&` 去掉（比如想统计"帧间也算"）；
- 把 `cyc_rstall` 的清零条件与 `cyc_busy` 分开（比如只在 `start` 清 rstall、在别处清 busy）；
- 引入第三个计数器时忘记保持"子集"关系。

若真发生下溢，`stat_compute_cycles` 会变成 `0xFFFFFFFF`，固件 `/148500` 打印 **28946**（ms）。**这个数值本身就是一个一眼可辨的告警**——建议固件侧加一条 `if (compute > 200) 打印 "UNDERFLOW"` 的兜底，比在 RTL 里加饱和逻辑便宜。

**顺带一个正向确认**：即使出现"帧中来了一个 spurious `start`"（`S_RUN` 里 driver 不理它，但 wrapper 会清零），不变式依然成立（两者同时清、之后同条件增），只是**本帧统计被截断**（少报，不会报错）。这也说明下溢风险与 spurious start 无关。

---

## 4. 口径是否成立（Q4，**本次复核的核心问题**）

### 4.1 每个量的物理意义（按当前实现）

| 输出 | 表达式 | 物理意义 | 在本设计中实际会测到什么 |
|---|---|---|---|
| `stat_read_cycles` | `cyc_rstall` = busy 且 `(arvalid&&!arready) \|\| (rvalid&&!rready)` | **AXI 反压**（主机想发 AR 没被接；或从机给了 R 但主机没接） | **≈0**。见 4.2 的三条论证 |
| `stat_compute_cycles` | `cyc_busy − cyc_rstall` | "busy 且读通道没被反压" | **≈整帧**（8.5 M 拍 ≈ 57 ms），其中约 49 ms 是 DDR 等待 |
| `stat_prefetch_starts` | `ar_cnt` = AR 握手次数 | **发出的读 burst 数** | **≈39,057/帧**（39,000 数据 + ~57 权重）—— **这个是对的，且极有价值（见 4.4）** |
| `stat_prefetch_completions` | `rl_cnt` = `rvalid&&rready&&rlast` | **完成的读 burst 数** | ≈`ar_cnt`（差 = 在飞 burst ≤ 3） |
| `stat_overlap_cycles` | `cyc_busy && rd_act && wr_act` | 读写"同拍都有握手" | 手写通道粒度的重叠，量级 ~10⁵，**语义与名字（overlap=预取/计算重叠）不符** |

### 4.2 为什么 `read_cycles` 会读到 ≈0（三条硬论证，全部可在源码上验证）

1. **`rvalid && !rready` 在本设计里几乎不可能成立。** `rready` 由 `rowpipe_axir_arb4` 驱动：`rowpipe_ddr_banks.v:97` `assign rready = (ast == A_R) && brv[sel];`，而 `brv[sel]` 是选中流的 `beat_ready`，其中 `rowpipe_rd_stream`（`:196`）和 `rowpipe_src_stream`（`:313`）在 burst 传输期间**恒为 1**。⇒ 在 A_R 状态下 `rready≡1`；不在 A_R 状态时 `rvalid` 也不该有 beat（仲裁器 burst 粒度持有，`:111-113`）。**唯一会真正拉低 `rready` 的是权重流 `rowpipe_wstream` 的 `take`**（`:562`：`beat_valid && (busy||rewind||(match&&req_ack))`）——即引擎在 `S_B/S_M/S_Q` 里"一个 beat 拆 4/2 拍"时（`rowpipe_engine.v:338-370`）。这部分总共 903 beat/帧，最多 ~2,700 拍。
2. **`arvalid && !arready` 几乎不可能成立。** `arready` 来自 `style_axi_cdc` 的 AR FIFO 写侧（容量 4），只有 4 个未消费 AR 才会反压；而 `rowpipe_axir_arb4` 是单 AR 在飞（`:111-113`）⇒ 稳态下深度只用到 1。
3. **真正的主导现象是"反过来"的**：读流在飞但 beat 没来（`rd_active && !rvalid`）。这在本设计里是**整个帧 86% 的时间**（单 burst 在飞 + 每 16 beat 暴露一次往返，见 `02_rowpipe_datapath.md` §7.3/§7.4）。而当前 `rd_stall` 里**没有任何一项能看见 `rvalid=0` 的情况**。

⇒ **`RPMS = read_cycles/148500` 会打印 `0`**（因为 `cyc_rstall` 远小于 148,500）。

### 4.3 于是同一行 UART 会自相矛盾

工作区里 `style_ddr_profiler` 已经恢复（`style_video_system.sv:95-101`，注释写"2026-10-27 恢复"），固件 `style_driver.c:78-90` 一次打印两组数据。上板后预计看到：

```
DDR100M T <n> AR .. DOWN .. RGAP 9 RBP .. DBP .. AW .. W .. B 86 IDLE ..  RB <n> DRB <n>  RPMS 0 CPMS 57 PF 39057 PFC 39057 OVLP <n>
```

- `B 86` 说的是"**86% 的拍在等写响应**"（counter[8]，见 §6 索引订正）；
- `RPMS 0 CPMS 57` 说的是"**DDR 等待 0 ms，算力 57 ms**"。

**两个结论互相打脸**，而且**后者恰好是错误的那一个**（真值：算力 7.85 ms、DDR 49.1 ms）。一个只看 `RPMS/CPMS` 的人会得出"我们算力不够、DDR 很闲"的结论，从而去优化 CNN 阵列——方向完全跑偏。这是本次复核**最需要修的一点**。

### 4.4 值得保留的部分：`PF`/`PFC` 是本改动的最大价值

`ar_cnt`/`rl_cnt` 是**唯一能直接验证我那份带宽账的量**：

- 我在 `02_rowpipe_datapath.md` §7.2 算出的是 **39,000 条读 burst/帧 + ~57 条权重 burst**；
- 如果板上 `PF ≈ 39,057` ⇒ 描述符解码、fmt（4/8 B/px）、每层 beat 数**全部被实测确认**，后面所有优化估算都可信；
- 如果 `PF` 打印出别的数（比如 ≈451,250 那种量级）⇒ 说明板上 bit 的描述符或带宽模型与我读的源码不一致，**必须先查这个再谈优化**；
- 另外 `PF − PFC` = 在飞 burst 数，**它直接证明"同时只有 1 个 burst 在飞"**这个结论（差 ≤3 就证实了 `want_r` 单标志的限制）。

⇒ 建议：`PF`/`PFC` 原样保留，且**上板第一件事就是看这两个数**。

### 4.5 `run` 一个诚实的边界：wrapper 层能做到什么程度

因为引擎的"想读/想写但没数据/没空间"（`rowpipe_engine.v:201-202` 的 `data_ok`、`:222` 的 `wr_now`）**没有引出到 wrapper**，所以在 wrapper 层只能做"Axi 侧分解"：

```
busy = 读等待 + 写等待 + 其余（其余 = 真算力 + 同时等读又等写的重叠拍）
```

严格的"算力"需要引擎内部信号（要改 `rowpipe_engine`/`rowpipe_frame_driver` 的端口，在 97.26% 下不划算）。但把 `read_cycles` 修成真正的"等读"、再补一个"等写"，得到的 `busy − 读等待 − 写等待` 已经是**算力的上界且通常很接近**，足够判断"算力 vs DDR"的大头。**这比现在的口径强得多。**

---

## 5. 硬件代价（Q5）

### 5.1 逐项估算（Efinity / Titanium，XLR ≈ LUT4+FF+carry 的组合体）

| 项 | 位宽 | FF | LUT4 | 说明 |
|---|---|---|---|---|
| `cyc_busy` | 32 | 32 | ~32 | 32 位自增 = 32 个 XLR（carry 在 XLR 内） |
| `cyc_rstall` | 32 | 32 | ~33 | 多加 1 个 LUT 做 `drv_busy&&rd_stall` |
| `ar_cnt` | 32 | 32 | ~32 | — |
| `rl_cnt` | 32 | 32 | ~33 | 3 输入与 |
| `cyc_ovlp` | 32 | 32 | ~35 | 3 输入与 + busy |
| 减法器 `cyc_busy-cyc_rstall` | 32 | 0 | ~33 | **组合**，见 5.2 |
| `rd_stall/rd_act/wr_act` | 3 | 0 | ~8 | — |
| **合计** | | **≈160** | **≈206** | ⇒ **≈250~320 XLR** |

参照系（`reports/ARCHITECTURE_FULL.md:6`、`reports/HANDOFF_2026-10-26.md:221-222`）：
**XLR 59,132 / 60,800 = 97.26%，余量 1,668；RAM 244/256；DSP 147/160；最小 slack +0.046~+0.097 ns。**

### 5.2 会不会推高关键路径？（**一个好消息，一个坏消息**）

**好消息：32 位减法器不会进时序报告。** `ti60f225_oob.sdc:22`：

```tcl
set_clock_groups -exclusive -group {core_clk} -group {tx_cal_clk} \
  -group {vid_clk_dvi2 hdmi_tx_slow_clk hdmi_tx_fast_clk fb} ...
```

`core_clk`（APB，100 MHz）与 `vid_clk_dvi2`（cnn_clk，148.5 MHz）**在互斥组里** ⇒ 计数器（cnn_clk）→ `prdata`（core_clk）这条路整段 false-path，**`cyc_busy-cyc_rstall` 的进位链不参与时序收敛**。同理 5 个计数器本身在 `vid_clk_dvi2` 组内按 6.734 ns 收敛，32 位自增链 ~1~2 ns，**逻辑深度不是问题**。

**坏消息（真正的风险是布线拥塞，不是逻辑）**：
- 97.26% + 250~320 XLR ⇒ **97.7% 左右**；项目自己记过账：`reports/UART_MODE_SWITCH_PLAN.md:198` "上次加消抖（+50 XLR）就导致拥塞失败"、`:91` "97.89% 时布线易拥塞，可能需要换 seed"。
- `reports/line_by_line/01_rowpipe_layer.md:470` 还指出 `rowpipe_layer` 有 **`CI=16→8` 可省 8 个 RAM 块 + 上万 FF** 的大肥肉 —— 如果这次 PnR 因为 +300 XLR 失败，**先去砍那里，不要砍观测手段**。
- 没有任何 RAM/DSP 增量（赔率好）。

### 5.3 三个"零风险省 FF"的做法（建议采纳，至少第 1 个）

| 做法 | 省 | 风险 |
|---|---|---|
| **① 删掉 `cyc_busy`，直接用 `drv_cycles`** | **32 FF + 32 LUT** | 零。已核对：`rowpipe_frame_driver.v:176,184` 的 `cycles` 只在 `S_RUN`/`S_FLUSH` 自增，而 `drv_busy` 恰好只在这两个状态为 1（`:169,187`）⇒ **`cyc_busy ≡ drv_cycles`**，本来就是重复计数。`drv_cycles` 在 wrapper 里已经有（`:106` 的 wire）。 |
| ② 位宽按需收窄：`cyc_*` 用 24 位、`ar_cnt/rl_cnt` 用 16 位 | **56 FF** | 低。一帧最大 8.54 M 拍（57.5 ms）< 2²⁴=16.78 M ✓；burst 数 39,057 < 2¹⁶ ✓。对外仍是 32 位输出（高 8/16 位补 0），APB 口径不变。 |
| ③ 把 `stat_overlap_cycles` 改用途（见 §7 R2），不新增计数器 | 0（反而 +2 FF 换掉一个弱指标） | 低，但会改变 `OVLP` 的含义，需固件同步。 |

**①+② 合起来：160 FF → 104 FF（省 56 FF + 32 LUT ≈ 90 XLR），且不动任何口径。**

---

## 6. 复核中顺带发现的三件事（含对上一份报告的订正）

### 6.1 【订正】`style_ddr_profiler` 的 counter 索引：**"等 B" 是 counter[8]，不是 counter[3]**

我在 `02_rowpipe_datapath.md` §7.4 写的 "counter[3] = `write_response && !c_bvalid`、7=读 stall、8=读气泡" **是错的**（12 项拼接的左端是 bit11、右端是 bit0，我当时按从左往右数了）。正确映射（`rtl/style/style_ddr_profiler.sv:13-17` 的拼接顺序，自 LSB 起）：

| idx | 表达式 | 含义 | 固件标签 |
|---|---|---|---|
| 0 | `1'b1` | 总拍数（100% 分母） | `T` |
| 1 | `c_arvalid && !c_arready` | cpu AR 等 ready | `AR` |
| 2 | `arvalid && !arready` | 显示侧 AR 等 ready | `DOWN` |
| **3** | `read_active && c_rready && !c_rvalid` | **读气泡**（burst 在飞、beat 没来） | `RGAP` |
| 4 | `c_rvalid && !c_rready` | cpu R 未被消费 | `RBP` |
| 5 | `v_rvalid && !v_rready` | 显示 R 未被消费 | `DBP` |
| 6 | `c_awvalid && !c_awready` | AW 等 ready | `AW` |
| 7 | `c_wvalid && !c_wready` | W 等 ready | `W` |
| **8** | `write_response && !c_bvalid` | **W 发完到 B 回来（等 B）** | `B` |
| 9 | `network_idle` | 网络空闲 | `IDLE` |
| 10 | `c_rvalid && c_rready` | cpu R beat 消费（原始计数） | `RB` |
| 11 | `v_rvalid && v_rready` | 显示 R beat 消费（原始计数） | `DRB` |

**双重佐证**：① 固件标签序列 `{" AR "," DOWN "," RGAP "," RBP "," DBP "," AW "," W "," B "," IDLE "}` 对应 `delta[1..9]`，与上表 1~9 **逐位吻合**（`style_driver.c:75,80-83`）；② TB `tests/style_ddr_profiler_tb.sv:43-45` 在"clear 期间在飞写"之后 `check(8,3)`，说明 counter[8] 才是写响应等待。

⇒ **我 §7.4 那个"49.1 ms ÷ 374,400 = 13.1 拍/beat"的算术仍然成立，只是方向对到了 counter[8] 上。** 上板读 `B` 的百分比时请按 86% 这个数去核对。

### 6.2 `style_ddr_profiler` 现在已经挂上了（我上一份报告说"没有实例化"，工作区已变）

`rtl/style/style_video_system.sv:79-106`：APB `0x54[0]`=freeze、`0x54[1]`=clear，`0x58..0x84` = 12 个计数器，`:95-101` 例化 `style_ddr_profiler`，`:102-106` 的 `prdata` 优先拦截 `0x54/0x58..0x84`、其余落回 `accel_prdata`。**与 `style_accel` 的 `0x00-0x34 / 0xa8-0xb8` 不冲突**（地址不重叠）。

⇒ 结论：**你现在有两套 DDR 观测**——profiler（100 MHz AXI 侧、12 个方向分解、按速率看）和这 5 个 `stat_*`（148.5 MHz 网络侧、按帧看绝对值）。§4.3 的矛盾就来自"两套口径不一致"。**建议以 profiler 为主、`stat_*` 只保留 PF/PFC**（见 §7）。

### 6.3 【解除】上一份报告 §8-⑪ 的"双实例化双驱动"疑点

`02_rowpipe_datapath.md` §8 第 ⑪ 条我标了"`style_accel.sv:109` 与 `:118` 同时实例化两个网络，疑似双驱动，需 Lead 复核"。**这次读到 `style_accel.sv:108-126` 的 `generate if (USE_ROW_PIPE) ... else ...`** ⇒ 只有 `USE_ROW_PIPE=1'b1`（`:3` 默认）那一支被综合，`style_network` 那支不存在。**✅ 该疑点解除，不是 bug。**（我当时只读了 grep 片段，没读 generate 包裹，属我的疏漏。）

---

## 7. 建议的最小改动清单（按性价比排序）

### R1【必做】把 `read_cycles` 换成"真的等读"，否则这条改动会把结论带反

```verilog
reg rd_active;                                   // AR 已接受、burst 未结束
always @(posedge clk or negedge rst_n)
  if (!rst_n)                  rd_active <= 1'b0;
  else if (arvalid && arready)  rd_active <= 1'b1;
  else if (rvalid && rready && rlast) rd_active <= 1'b0;
wire rd_wait = (arvalid && !arready) || (rd_active && !rvalid);   // 总线忙 + 延迟暴露
```

- 成本：**+1 FF + 2 LUT**（`rd_stall` 换成 `rd_wait` 后原逻辑基本复用）。
- 预期：`cyc_rstall` 从 ~10³ 变成 **~7.3 M**（49 ms × 148.5 MHz），`RPMS` 打印 **49** —— 与 profiler 的 `B 86`/`RGAP` 吻合。
- 与 `style_ddr_profiler` 的 counter[3]（`read_active && c_rready && !c_rvalid`）**语义完全一致**，两套观测从此可以互校。

### R2【强烈建议】把 `overlap_cycles` 换成"等写响应"（零新增计数器）

```verilog
reg wr_wait;                                     // W 已发完、B 未回（= profiler counter[8]）
always @(posedge clk or negedge rst_n)
  if (!rst_n)                          wr_wait <= 1'b0;
  else if (wvalid && wready && wlast)  wr_wait <= 1'b1;
  else if (bvalid && bready)           wr_wait <= 1'b0;
```

- 成本：**+1 FF + 2 LUT**，把现有 32 位 `cyc_ovlp` 计数器直接改用途（**零新增计数器**）。
- 收益：`compute_cycles = busy − 读等待 − 写等待` 才接近"真算力"；而且这个量正是我在 `02` 报告里算出的 49.1 ms 的直接证据链（当前写引擎单 outstanding，`wr_wait` 是精确的，不是近似）。
- 副作用：`OVLP` 字段含义变了，`style_driver.c:90` 的标签要从 `OVLP` 改成 `WW`（`style_log_ddr()` 那一行，改 1 处字符串）。

### R3【建议】清零条件加限定，解掉"帧中 spurious start 截断统计"

```verilog
end else if (start && !drv_busy) begin              // 帧首才清，帧中被打断不影响
```

- 成本：0。
- 收益：`start` 早到 / 双击 / 调试期误写 `0x04[0]` 时不会把本帧统计清零（当前会，且**静默少报**）。
- 更彻底的写法是"用 `drv_busy` 上升沿清零"，但要多 1 个 `busy` 影子寄存器，性价比不如上面这一行。

### R4【可选】省 56 FF：`cyc_busy` 删掉用 `drv_cycles` + 位宽收窄

见 §5.3 ①②。在 97.26% 的余量下，这一条能把净增量从 ~250 XLR 压到 ~160 XLR。

### R5【固件，1 行】`RPMS/CPMS` 加一个下溢兜底

`software/firmware/style_driver.c:86-87` 打印前判断 `if (app_style_compute_cycles > 200u*148500u) 打印 "UNDERFLOW"`——比在 RTL 里加饱和逻辑便宜，且能一眼看出 RTL 口径被改坏。

---

## 8. 上板后该看什么（预期数值表，用来验收这次改动）

| 字段 | 来源 | 预期值 | 判读 |
|---|---|---|---|
| `PF` | `ar_cnt` | **≈39,057**（39,000 + ~57 权重） | **最重要**：≈39,000 ⇒ 我的带宽账/描述符解码成立；差很多 ⇒ 先查描述符口径 |
| `PFC` | `rl_cnt` | ≈`PF`，差 ≤3 | 差 >3 ⇒ 有 burst 被 flush 丢弃（`rowpipe_ddr_banks.v:219-225`），说明 `need_restart` 触发频繁 |
| `RPMS`（改 R1 后） | `cyc_rstall/148500` | **≈49**（ms） | 接近 profiler 的 `RGAP`+`AR` 换算值 |
| `RPMS`（不改，现状） | 同上 | **0** | 一看到 0 就说明口径还是"反压版"，别据此下结论 |
| `CPMS`（现状） | `(cyc_busy−rstall)/148500` | **≈57** | **几乎等于整帧 ⇒ 这个数当前没有"算力"含义** |
| `CPMS`（改 R1+R2 后） | 同上 | ≈8~15 | 与已知"算力 7.85 ms"同量级才算口径对了 |
| `OVLP` | `cyc_ovlp` | ~10⁵（<1% 帧时） | 手写通道粒度重叠，别当百分比看；改 R2 后变成"等 B 拍数"（预期 ~7.3 M） |
| `DDR100M ... B` | profiler counter[8] | **~86**（%） | 与 `RPMS 49` 互相印证 |

**一句话验收**：改完 R1 后，`RPMS 49` 和 `B 86` 应当**同时**出现；如果 `RPMS 0` 而 `B 86`，说明 R1 没生效（或 `rd_active` 被 flush 提前清掉）。

---

## 附：复核边界（我**没有**做的事）

- 没有编译、没有跑仿真、没有碰 `outflow/`、`_b.bat`、OpenOCD（尊重后台构建）。
- XLR 增量是**估算**（依据 `reports/ARCHITECTURE_FULL.md:6`、`HANDOFF_2026-10-26.md:221` 的基线 + Efinity 的 XLR 结构），**不是 map 报告实测**。真值请在你这次构建的 `map.rpt` 里看 `XLR` / `FF` / `LUT4` 三行做差。
- 时序结论（减法器被 false-path）依据 `ti60f225_oob.sdc:22` 的 `set_clock_groups -exclusive`；如果构建时 SDC 有别的 `set_false_path`/分组改动，以实际报告为准。
- 固件侧的 `style_drv` 我只读到 `style_driver.c:100`（打印部分已足够判断口径），未逐行复核 UART 缓冲/字符串长度。
