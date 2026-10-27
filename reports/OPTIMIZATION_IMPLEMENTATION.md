# rowpipe 风格迁移系统 —— 已实施优化与实现说明

> 日期：2026-10-27
> 分支：`feature/colour-calib-redsky-q`，HEAD `d711e80`（相对 `5dfaf5a` 已 11 个提交）
> 器件：Efinix Titanium Ti60F225，Efinity 2026.1
> 最近一次完整构建（`cb1b1f0`）：**XLR 60,267 / 60,800（99.12%）、RAM 244/256、DSP 147/160**
> 目的：把"做过哪些优化、每个是怎么实现的、怎么开/关"讲清楚，便于复现、A/B 与回退
> 证据来源：`git log 5dfaf5a..HEAD` 的提交正文、当前 RTL 源码、`reports/line_by_line/14~17`、`docs/DDR_READ_OPTIMIZATION.md`、`docs/DISPLAY_DEADLINE_FIX.md`、`docs/RESOURCE_OPTIMIZATION_PLAN.md`

---

## 0. 一页速览

| # | 优化 | 层次 | 实现位置 | 默认状态 | 效果 |
|---|---|---|---|---|---|
| 1 | 写引擎 posted-B | 总线事务 | `rtl/accel_rowpipe/rowpipe_ddr_banks.v`（`rowpipe_wr_engine`） | `MAX_B_OUT=4` **已开** | 帧时 58→51 ms；profile `B` 86%→15% |
| 2 | 读 burst 加长 | 总线事务 | `rtl/accel_rowpipe/rowpipe_frame_driver.v:137` | `MAXB=64, DEPTH=256` **已开** | `RGAP` 23%→12%、`AR` 6%→3%；帧时 51→50 ms |
| 3 | 读多 burst 并发 | 总线事务 | `rowpipe_ddr_banks.v` 参数 `MAX_RD_INFLIGHT` | 默认 1（**关**） | 会触发 AXI 违规，仅保留开关 |
| 4 | 外层桥显示读优先 | 仲裁 | `rtl/soc_integration/soc_video_ddr_integration.sv:203` | `DYNAMIC_VIDEO_READ=1` **已开** | 显示欠载受控；CPU 保底 25% 读授权 |
| 5 | CDC 命令队列参数化 | CDC | `rtl/style/style_axi_cdc.sv:10` | `CMD_LOG_DEPTH=2`（**未加深**） | 加深 +960 FF，当前面积不划算 |
| 6 | 网络尾巴降分辨率 | 算力 | `rtl/accel_rowpipe/style_network_rowpipe.sv:26` | `TAIL_LOWRES=1`（**工作区、未提交**） | 预期算力 −8.53 ms（−25.7%），未上板 |
| 7 | DSP DUAL 双通道复用 | 算子 | `rtl/accel_rowpipe/conv3x3_core.v:183` | 已固化 | 2 通道/DSP（上限 256 MAC/拍） |
| 8 | 存储通道 ≥ MAC 宽度 | 算子 | `conv3x3_core.v:161-166` | 已固化 | 权重推成 BRAM，FF 23k→5k |
| 9 | `ci_tiles=2` 窗口 8 通道 | 算子 | `rtl/accel_rowpipe/rowpipe_layer.v:88` | 已固化 | ci16 层重读行缓冲，省窗口存储 |
| 10 | 真 stride-2 | 算力 | `rtl/accel_rowpipe/rowpipe_engine.v:227` | 已固化 | s2 层不再"算 4 倍只写偶偶" |
| 11 | 权重 blob 走 DDR | 存储 | `rowpipe_engine.v:337`、`rowpipe_ddr_banks.v:769` | 已固化 | 权重不再常驻片内；903 beat/帧（0.1%） |
| 12 | 中间 bank 紧凑化 | 带宽 | `rowpipe_ddr_banks.v:740,893` | 已固化 | 按层选 4B/8B/16B 每像素 |
| 13 | 上采样重放 | 带宽 | `rowpipe_ddr_banks.v:210` | 已固化 | `up` 层同列读两遍的正确性保障 |
| 14 | 显示 beat 缓冲 | DDR 读 | `rtl/style/style_display_beats.sv` | 已固化 | 短任务 15.28→6.93 ms（−54.6%） |
| 15 | 显示紧急读保留 | 仲裁 | `axi_shared_ddr_2m` 的 2 个参数 | 内层已开 | 板上欠载 3458/s → 0.17/s |
| 16 | RAM 减法（去 OSD/直方图） | 面积 | `rtl/ti60f225_oob_top.v:917` | 已固化 | 换回若干 RAM 块 |
| 17 | 0-RAM FPS 叠加 | 面积 | `rtl/accel_rowpipe/fps_overlay.sv` | 已固化 | 文本栈 → 纯组合字模，0 RAM |
| 18 | SoC 资源优化 P1/P2/P3 | 面积 | BRAM 映射 / 关 Debugger / 只留 RAW10 | 已固化 | XLR 55,159→34,767（−37%） |

> 说明：1~5 是本轮（10-27）的总线/仲裁优化，6 是算力重构，7~13 是 rowpipe 落地时的算子级优化，
> 14~18 是更早几轮（10-12 前后）的 DDR 读、显示实时性与面积优化。

---

## 一、总线事务优化（Track 1）

### 1.1 先诊断：钱花在哪

优化前的一帧实测（APB `0x1c`）是 **57.5 ms / 17.4 fps**。拆账：

| 口径 | 值 | 说明 |
|---|---|---|
| 一帧 DDR 交通 | 921,600 beat = 14.75 MB | 12 层描述符逐层算（读 547,200 + 写 374,400） |
| 每 beat 实耗 | **9.3 拍** | 921,600 × 9.3 / 148.5 MHz = 57.72 ms，与实测差 0.4% |
| 物理地板 | 1.485 拍/beat | 1.6 GB/s、100 MHz AXI、16 B/beat |
| 多付占比 | **6.3 倍事务税** | 其中写侧逐 beat 等 `B` 占 76%，读侧单 burst 在飞占 54% |

写侧是病态的 **1:1 命令比**（每条 AW/W/B 只搬 16 B），读侧每条 burst 平均只有 14.03 beat。
结论：**瓶颈不是带宽也不是算力，是 AXI 事务开销**。

### 1.2 T1.1 写引擎 posted-B（单项收益最大）

**改哪里**：`rowpipe_ddr_banks.v` 里的 `rowpipe_wr_engine`（原 4 态 `W_IDLE→W_ADDR→W_DATA→W_RESP`）。

**怎么实现的**：

1. **`bready` 常态为 1**，`B` 与主 FSM 解耦：发完 `wlast` 就回 `W_IDLE`，不再进 `W_RESP` 干等。
2. 新增 `b_out`（4 位）限制未回 B 的笔数，`MAX_B_OUT` 参数钳在 1..8（默认 **4**）。
3. `virt`（虚拟/非虚拟写）改用 **4 位环形队列** `vq` + `vq_wp/vq_rp`，替代原来的单标志 `b_virt_flag`。
   - 原因：单标志依赖"层末必然排空"，而权重超时 abort 不等排空就回 `S_IDLE`，会把上一层的 virt 串到本层
     ⇒ `acked_virt` 谎报 ⇒ `result_done` 永不成立 ⇒ driver 卡死在 `S_FLUSH`（那里没有超时）。
4. `acked` / `acked_virt` **严格只在 B 回来时自增**：`result_done` 靠它判"数据真落盘"，提前到 W 握手会让 driver 提前收尾。
5. `idle` 的定义收紧为 `count==0 && st==IDLE && b_out==0`，否则层末 flush 会在数据还没落盘时放行。
6. 同拍一进一出用一次加减（`b_pend = b_out + b_inc`、`case({b_inc,b_dec})`），避免非阻塞赋值的经典覆盖坑。

**吞吐模型与实测对得上**：`拍/beat = max(3, B_latency / N)`，`B_latency=13` AXI 拍（≈19.3 cnn 拍）：

| N | AXI 拍/beat | cnn 拍/beat | 写 374,400 beat 的时间 |
|---|---|---|---|
| 1（原版） | 13 | 19.3 | 48.7 ms（实测 49.1 ms ✔） |
| **4（默认）** | 3.25 | 4.83 | **12.2 ms** |
| 6 | 2.17 | 3.22 | 8.1 ms |
| 8 | 2.02 | 3.00 | 7.6 ms（FSM 3 拍封顶，无意义） |

**板上实测**：帧时 **58 → 51 ms**，profile `B` **86% → 15%**。

### 1.3 T1.2 读流参数化 + 长 burst

**改哪里**：`rowpipe_ddr_banks.v` 的 `rowpipe_axir_arb4` 与 `rowpipe_rd_stream`，以及驱动层例化。

**怎么实现的**：

1. **三个参数化入口**：`DEPTH`（FIFO 深）、`MAXB`（单 burst 最大 beat）、`MAX_INFLIGHT`（并发 burst 数）。
   `IDXW = clogb2(DEPTH)` 自动推导，`count/inflight` 统一 10 位 —— **改 DEPTH 不用再手改任何位宽**。
2. **防死锁硬钳**：`MAXB_E = min(MAXB, DEPTH/2)`。`free_ok` 判的是 `count+inflight < DEPTH-MAXB`，
   一旦 `MAXB ≥ DEPTH` 就永远装不下一条 burst，预取再也不启动 ⇒ 帧级卡死且无超时。
3. **删掉 4 个寄存器** `want_addr / want_len / cur_len1 / want_r`，改成组合推导：
   - 省 **49 FF/流**；
   - 而且**必须**组合：追加第 2 条 AR 时 `next_fetch` 已经推进，寄存器版会晚一拍 ⇒ 两条在飞 AR 同首地址。
4. **地址只在 `ar_ack` 推进**：`next_fetch` 在 AR 握手那一刻前进，而不是等 `beat_last`。
5. **`want_d` 影子位**：`inflight` 改成"AR 被接受时才计数"之后，`flush_now` 必须再等 `want_d` 落地，
   否则换 bank 时会漏掉"已抬 want、仲裁器还没接受"的那条 AR ⇒ 整幅错位。
6. **仲裁器允许同 client 追加 AR**：新增 `ar_more = (ast==A_R) && (ob<K) && wv[sel] && pipe_en[sel]`，
   并新增 4 根 `ack0..ack3` 把"AR 被接受"回送给读流。
   `pipe_en[3:0]` 顶层固定 `4'b0110`：**只让两个 `rd_stream` 参与追加** ——
   `src_stream`/`wstream` 的 `want` 在整个 burst 期间保持高，给它们追加会发**同地址 AR**⇒ 数据重复。

**落地配置**（`rowpipe_frame_driver.v:137`）：

```verilog
// C 长burst：MAXB=64 + DEPTH=256（DEPTH 必须 ≥ 2*MAXB，否则 free_ok 永不成立）
rowpipe_ddr_banks #(.MAXB(64), .DEPTH(256)) u_bank (...)
```

**板上实测**：`RGAP` **23% → 12%**（长 burst 生效）、`AR` **6% → 3%**，但帧时只 51→50 ms
—— 说明**读等待本来就被算力掩盖**。

### 1.4 T1.4 外层桥显示读优先

原来内层桥的 `display_read_urgent` 跨不过外层 CPU/video 桥。实现是一条线 + 一个参数：

1. `rtl/style/style_video_system.sv`：导出 `display_read_urgent`，**打一拍再出**
   （`display_read_urgent_q`），避免把显示 FIFO 的电平比较器拖进 CPU 侧 `arready` 组合锥；
   内层桥仍用原始电平 `display_read_urgent_raw`。
2. `rtl/ti60f225_oob_top.v:633/649/654`：`style_read_urgent` 连线到集成层。
3. `soc_video_ddr_integration.sv`：新增 `video_read_urgent` 端口（`:7`），
   例化外层桥时给 `#(.DYNAMIC_VIDEO_READ(1'b1))`（`:203`）。

**另外三个参数必须保持 0**（已写进 RTL 注释）：`URGENT_OVERRIDES_FAIRNESS=1` 会绕开上限、
`RESERVE_URGENT_READ=1` 不看 `vid_arvalid` 直接拒 CPU、`VIDEO_READ_PRIORITY=1` 无条件优先。
稳态仲裁是 **3:1**（`MAX_VIDEO_BURSTS=3`），CPU 保底 25% 读授权，最坏附加延迟约 1.4 µs
（UART 一个字 87 µs、3A 走 I2C 不过 DDR ⇒ 不会饿死 CPU）。

### 1.5 T1.3 CDC 命令队列：参数化了，但**没有**加深

`style_axi_cdc.sv:10` 新增 `parameter integer CMD_LOG_DEPTH = 2`（默认 = 原行为）。
**为什么不动默认值**：`style_async_fifo` 对 `LOG_DEPTH<=4 && WIDTH<=45` 走**寄存器堆**而非 RAM 块，
AR/AW 各 40 bit，加深到 4 就是 16×40 = 640 FF/通道、**合计 +960 FF** —— 当前 99% 的面积不值得预支。

### 1.6 结果：瓶颈从总线转到算力

| 档位 | MS | AR | RGAP | B | 说明 |
|---|---|---|---|---|---|
| 原版 | 58 ms | — | — | — | profiler 当时未挂 |
| B（posted-B） | 51 ms | 6% | 23% | **15%** | 写侧一项就 −12% |
| C（+长 burst） | **50 ms** | 3% | **12%** | 19% | 读等待被算力掩盖 |

- 写侧修好后读侧立刻接棒 —— 这正是历史 `wburst` 实验只涨 6% 的原因。
- 算力 4.925 M 拍 = **33.2 ms，占 50 ms 的 66%** ⇒ 下一步只能动算力。
- 面积是**净减少**：XLR 59,787 → 59,594（`u_rd0` 616→584、`u_rd1` 465→407），
  时序反而改善（`tx_cal_clk_90edge` setup 0.133→0.338 ns）。

---

## 二、算力重构（Track 3）：`TAIL_LOWRES`

### 2.1 诊断

算力公式与逐层账（`reports/TRACK3_COMPUTE_RESTRUCTURE.md`）：

```
cycles = (out_px / 16) × (ci × 9 + 16)      # +16 = requant 按时分复用串行化
```

| 层 | ci→cout | 输出 | 算力 | 占比 |
|---|---|---|---|---|
| L10 | 8→4 | 640×480 | 11.38 ms | **34.3%** |
| L11 | 4→3 | 640×480 | 6.72 ms | 20.3% |
| L0 | 3→4 | 640×480 | 5.56 ms | 16.8% |
| 其余 9 层 | — | ≤320×240 | 9.5 ms | 28.6% |

**640×480 上的三层吃掉 71%**；160×120 加一层只要 0.71 ms（与全分辨率差 16 倍）。

### 2.2 关键洞察：不需要重训

3×3 卷积权重与分辨率**无关**。RTL 里本来就有半分辨率采样机制（`rowpipe_engine.v:89`）：

```verilog
wire [31:0] srcW = up ? (win/2) : win;
if (up && iy[0]) src_base <= src_base + srcW;          // 每个源行读两遍
wire [19:0] src_addr = up ? (src_base + ix[19:1]) : ptr;  // 水平 2× 最近邻
```

语义是"输出保持全分辨率，输入按半分辨率采样"—— 当前 L10 就是这么读 L9 的。
于是只要把 L10 的卷积搬到 320×240、让 L11 用 `up=1` 去读，权重原样复用。

### 2.3 怎么实现的：一个编译期开关 + 三处描述符

`style_network_rowpipe.sv:26` 新增参数，描述符用三元表达式按它切换（**默认值即回退**）：

```verilog
parameter integer TAIL_LOWRES = 1   // 0 = 现状；1 = 方案 A

// L11：改为读 L10 的 320x240（up=1），输出仍 640x480
mk(4, 3, 640,480,640,40, 0,1,1,0,TAIL_LOWRES, 2'd1,2'd2,2'd0,0, 2'd2,2'd0,2'd0),
// L10：TAIL_LOWRES=1 时降到 320x240 卷积（up=0，顺序读 L9 的 320x240）
mk(8, 4, TAIL_LOWRES?320:640, TAIL_LOWRES?240:480, TAIL_LOWRES?320:640, TAIL_LOWRES?20:40,
      0,1,1,0, TAIL_LOWRES?0:1, 2'd0,2'd1,2'd0,0, 2'd1,2'd2,2'd0),
```

> ⚠ 状态：**工作区当前默认 `TAIL_LOWRES=1`（未提交）**，`L11` 的读 bank 也随之从 3（外部源帧）
> 改成 1（L10 的输出），写 bank 改为 2。TRACK3 文档写的是"默认 0 = 行为不变"，与当前工作区不一致。

### 2.4 预期与代价

| 指标 | 现在 | 方案 A |
|---|---|---|
| 算力 | 33.16 ms | **24.63 ms（−25.7%）** |
| 帧时 / 帧率 | 50 ms / 18 fps | ≈41 ms / ≈24 fps |
| 输出分辨率 | 640×480 | 640×480（不变） |
| 权重 | redsky v5 | **同一套，不用换** |
| 代价 | — | L11 只看到 320×240 特征，输出高频细节变少（画面更柔） |

**未经板上实测**，画质是唯一风险点。

---

## 三、算子与存储层优化（B1 系列，已固化在 RTL）

这一系列是 rowpipe 落地过程中逐项做掉的，机制写在源码头注释里。按编号：

### 3.1 DSP DUAL 双通道复用 + UINT8 偏移技巧（`conv3x3_core.v`）

- **每两个输出通道共用一个 `EFX_DSP48`（MODE="DUAL"）**：
  `A[18:8]×B[17:8]→O[47:24]` 给 `cout=2k`，`A[7:0]×B[7:0]→O[23:0]` 给 `cout=2k+1`；
  两边共用同一个 tap、不同权重，DUAL 的两个子乘法器都吃满。
  能力上限 PIX=16/COUT=16 时 **256 MAC/拍、128 DSP**。
- **为什么 UINT8 激活也能用 8×8**：向量生成阶段把无符号层的 tap 预先做成 `t' = t − 128`（位模式就是 `t ^ 0x80`），
  展开后 `Σt·w = Σt'·w + 128·Σw`，后一项是逐通道常数，**已折进偏置**。数学上精确等价。
- 取位宽必须按扩展后的 48 位 `O` 取（高路 `O[47:24]`、低路 `O[23:0]`）：按内部 37 位取能综合过、DSP 数也对，
  但**数值全错**，资源报告里看不出来。

### 3.2 B1c：存储通道数 ≥ MAC 宽度（`conv3x3_core.v` / `requant.v`）

co16 层用 `COUT=8` 的阵列**算两遍**（0..7 一遍、8..15 一遍），权重/偏置按 `CO_STORE=16` 存，`co_sel` 选半区。

关键实现细节（踩过的坑）：**必须同步读整字，半区选择放在寄存器之后**：

```verilog
reg [CO_STORE*8-1:0] wpack_full_r;
always @(posedge clk) wpack_full_r <= wrow[step_n];       // 同步读整字 ⇒ 推成 BRAM
wire [COUT*8-1:0] wpack = wpack_full_r[csel*COUT*8 +: COUT*8];  // 运行期切片放后面
```

写成 `wpack_r <= wrow[step_n][csel*COUT*8 +: COUT*8]` 时 Efinity 不再推成 RAM，
18,432 bit **全落 FF**（FF 23k→5k 的差别）。

### 3.3 B1e：`ci_tiles=2`（`rowpipe_layer.v:88`）

窗口一次只装 **8 通道**（`ci_par`），ci16 的层分两个 tile 跑、重读行缓冲 —— 用重读换来窗口寄存器/RAM 减半。
`S_RLD` 状态专管 tile 重载（18 拍，core 挂起但不清零）。

### 3.4 B1f：真 stride-2（`rowpipe_engine.v:201-240`）

原来 s2 层"算 4 倍、只写偶偶"；B1f 之后 **s2 层自己就只出 1/4 的像素**，地址就是顺序的 `pix`。
配套改动：`cfg_addr 8 = s2`、`cfg_addr 9 = 1` 的 skip 长度、`S_SER` 拆成"喂区"和"纯推窗"、
两个输出行之间空跑一整行输入（`cfg_skiplen=win` 的一条命令消费 win 列）。

### 3.5 B1g：权重 blob 走 DDR（方案 D）

- 权重不再是片内 ROM/行为数组，改成 DDR 里一段连续 16B 对齐数据（基址 `WEIGHT_ADDRESS = 0x06F0_0000`）。
- `rowpipe_ddr_banks` 增加**第 4 个读客户**=权重 blob 读流，128b = 一行权重；
  `rowpipe_engine.v:337` 起四段装载（权重/偏置/M/mid/shift/qlo/qhi）全部从这条流读。
- 代价可忽略：**903 beat/帧 ≈ 14,448 B，占 0.1%**。
- 固件在 `style_init_and_selftest()` 上电写一次并做 XOR 校验。

### 3.6 B1j：中间 bank 紧凑化（`rowpipe_ddr_banks.v:740,893`）

中间结果不再一律 16B/像素，而是**按层独立选格式**（`src_fmt / dst_fmt / id_fmt` 三个 2 位字段进描述符）：

| fmt | 含义 | 打包方式 |
|---|---|---|
| 0 | 16 B/像素 | 1 像素 = 1 beat（源帧、最终结果） |
| 1 | 8 B/像素 | 2 像素/beat（ci≤8 的中间层） |
| 2 | 4 B/像素 | 4 像素/beat（ci≤4 的层） |

实际链路：源帧 16B → **L0 写 4B** → L1 读 4B / 写 8B → L2~L9 全 8B → **L10 读 8B / 写 4B** →
**L11 读 4B、最终按 XBGR 4B/像素打包**。读写两侧的 fmt 各自独立，直接减少每层往返字节数。

### 3.7 B1h：上采样层重放（`rowpipe_ddr_banks.v:210`）

`up=1` 的层会把同一列读两遍（水平 2× 最近邻 + 每源行读两遍 ⇒ 同像素最多读 4 次）。
B1h 给读流加了 replay 影子逻辑，保证这种重复读的地址/拍数可重放，不会把 FIFO 计数搞乱。
**注意：这是正确性保障，不是省流量** —— 4× 读冗余本身还在（T2.1 才去消）。

---

## 四、DDR 读路径与显示实时性（更早一轮，10-12 前后）

### 4.1 显示 beat 缓冲（`style_display_beats.sv`）

**问题**：显示 reader 把 128 位 beat 慢慢拆成 4 个像素，像素 FIFO 满时 `RREADY` 反压，
**把共享读通道整条占住**（仿真里 CNN 读阶段 59.55% 的时间在等仲裁）。

**实现**：加 32 beat 同步 RAM + 弹性输出寄存器，存每 beat 的 4 个 RGB24 + RRESP + RLAST（99 位），
**无用的 XBGR padding 字节不存**，输出时补零。消费者停住时也能把整个最大突发收完，再按原速率拆包。
边界/响应错误/RLAST 校验仍由原 reader 处理。

**配套瘦身**：像素 FIFO 1024→512 深（抵消 RAM），系数下载 FIFO 与 CNN AR/AW 控制 FIFO 16→4（省 1379 FF / 593 LUT）。

| 模式 | CNN 总周期 | 短任务耗时 |
|---|---|---|
| 固定优先、无 beat 缓冲 | 2,269,633 | 15.2837 ms |
| 固定优先、有 beat 缓冲 | 1,029,441 | **6.9323 ms（−54.64%，×2.205）** |

代价：RAM 到 256/256（100%），XLR 58,665（96.49%）。

### 4.2 显示紧急读保留（`axi_shared_ddr_2m` 两个参数）

板上前一版实测：每秒约 **3458 个显示欠载上升沿**，画面闪烁。

**实现**：内层桥新增默认关闭的 `URGENT_OVERRIDES_FAIRNESS` / `RESERVE_URGENT_READ`，style 系统里同时打开：

1. 紧急显示请求可**覆盖 CNN 三次绕过上限**；
2. 在"显示 reader 正在拆包、下一次 AR 还没提出"的**间隙禁止接受新的 CNN AR**（这是关键——
   仅取消上限盖不住 inter-burst gap）；
3. urgent 条件增加"当前行任务进行中或请求排队"的限定，避免垂直空白期永久禁 CNN；
   低水位 256→**384**。

**板上结果**：用户确认"不再闪烁"；92.688 s 窗口内欠载只增 16 次（**0.173 次/秒**，原 3458 次/秒），
CSI/DMA/AXI/推理错误保持 0。代价：NN 从 14~15 fps 降到 **9~10 fps**（属于"保显示实时性"的主动取舍）。

---

## 五、面积优化

### 5.1 RAM 减法：去掉 OSD 与直方图叠加

`rtl/ti60f225_oob_top.v:917`（2026-10-21）：

```verilog
// 2026-10-21 RAM subtraction: no histogram overlay / text OSD (keep AE, tone/lift).
assign osd_vs = lift_vs, osd_hs = lift_hs, osd_de = lift_de;
```

tone/lift/AE 全部保留，只把直方图叠加与文字 OSD 的像素通路**旁路**（模块还在，输出被 tie 死）。

### 5.2 0-RAM FPS 叠加（`fps_overlay.sv`）

替换原 `osd_db`/`osd_font` 文本栈：5×7 字模逐像素**组合逻辑**（无 ROM），
在左图左上角画 `FPS xx`（×2 放大）。**0 RAM**，只在像素级加法器上花几个 LUT。

### 5.3 SoC 资源优化 P1/P2/P3（`docs/RESOURCE_OPTIMIZATION_PLAN.md`）

| 项 | 做了什么 | 机制 |
|---|---|---|
| **P1** | 统计/字符数组映射进 BRAM | 采集直方图 128×16 双 bank RAM + 64 位有效掩码（只清掩码不扫表）；`previous_row`/`hist_cache`/`counts`/`heights`/`page_mem` 改同步读 RAM；文字 OSD 字符页双时钟同步读 + 字库 ROM 两级流水 |
| **P2** | 关闭自动视频 Debugger | 关 `auto_instantiation`/`enable-mark-debug`，保留 Sapphire USER1/JTAG 与 CPU DEBUG |
| **P3** | 只保留 RAW10 解包 | 把 `PACK_TYPE` 覆盖改为 1，`depack48/56/64bit_inst` 全部消失，厂商加密块不动 |

**结果**：XLR **55,159（90.72%）→ 34,767（57.18%）**，−20,392（−36.97%）；
RAM 147→153（P1 新增 7 块、P2 减 1 块）；DSP 19 不变；setup 0.397→0.407 ns、hold 0.026 ns。
> 注意这组数字是 **style 网络接入之前**的 SoC 基线，与今天的 99% 占用不是同一套设计。

### 5.4 面积"天花板"是概率性的（重要经验）

| XLR | 占用 | 布线 | 时序 |
|---|---|---|---|
| 59,708 | 98.20% | PASS | +0.292 |
| 60,074 | 98.81% | PASS | +0.252 |
| 60,193 | 99.00% | **FAIL** | — |
| 60,165 | 98.96% | PASS | **vid_clk_dvi2 −0.710** |
| 60,267 | 99.12% | PASS | +0.472 |

⇒ 99% 以上同一密度可能过也可能不过；**每次构建必须同时看"布线 PASS"和"时序正负"**，
"PASS 但 slack 为负"是最危险的构建。

---

## 六、如何开 / 关（A/B 与回退）

所有优化都做成了**参数**，回退 = 改一个数字重编，不需要回退代码：

| 开关 | 位置 | 默认 | 备选 | 影响 |
|---|---|---|---|---|
| `MAX_B_OUT` | `rowpipe_ddr_banks.v:731` | **4** | 1 = 原串行（拍/beat 回 13） | 写侧 posted-B 深度 |
| `DEPTH` | `rowpipe_ddr_banks.v:728` | 64（驱动层覆盖 **256**） | 128 / 256 | 读 FIFO 深（+3 块 RAM/流） |
| `MAXB` | `rowpipe_ddr_banks.v:729` | 16（驱动层覆盖 **64**） | 32 / 64 | 单 burst 最大 beat（必须 ≤ DEPTH/2） |
| `MAX_RD_INFLIGHT` | `rowpipe_ddr_banks.v:730` | 1 | **2（勿开）** | 读并发；开 2 会 AXI 违规 |
| `CMD_LOG_DEPTH` | `style_axi_cdc.sv:10` | 2 | 4（+960 FF） | AR/AW 命令队列深 |
| `DYNAMIC_VIDEO_READ` | `soc_video_ddr_integration.sv:203` | **1** | 0 = 无显示优先 | 外层桥显示读优先 |
| `URGENT_OVERRIDES_FAIRNESS` | `style_video_system.sv:82` | 0 | **1（勿开）** | 会绕开 3 次上限 |
| `RESERVE_URGENT_READ` | `style_video_system.sv:82` | 0 | **1（勿开）** | 会直接拒 CPU |
| `TAIL_LOWRES` | `style_network_rowpipe.sv:26` | **1**（工作区未提交） | 0 = 现状几何 | L10 是否降到 320×240 |
| `ADAPTIVE_READ` / `DISPLAY_BUFFER` | `style_video_system.sv:3` | 1 / 1 | 0 | 自适应读、显示缓冲 |

**扫描阶梯建议**（Track 1 文档给的）：A 基线（`MAX_B_OUT=1`，应与改前逐位等价）→
B 写侧（默认 4）→ C 长 burst（`MAXB=64, DEPTH=256`）→ D 读并发（**不建议**）。

---

## 七、验证判据

### 7.1 必须成立的不变式（Track 1 上板自检）

| # | 不变式 | 破了会怎样 |
|---|---|---|
| I1 | `b_out ≤ MAX_B_OUT`，不为 0 的 B 不会让它回绕 | 回绕 ⇒ 不再发 AW ⇒ `idle` 不成立 ⇒ driver 卡死 |
| I2 | `acked`/`acked_virt` 只在 **B 回来**时增 | 提前增 ⇒ `result_done` 早成立 ⇒ 下一帧读到没落盘的数据 |
| I3 | `b_out==0` ⟺ AXI 写通道真的排空 | 层末误放行 ⇒ 层间数据串味 |
| I4 | `flush` 只在 `inflight==0 && !want_d` 发生 | 丢掉在途 AR ⇒ 换 bank 后整幅错位 |
| I5 | `next_fetch` 严格单调、`ar_ack` 每拍 ≤1 次 | 两条在飞 AR 同地址 ⇒ 数据重复 |
| I5b | 追加 AR 只发生在 `pipe_en[sel]=1` 的 client | src/wstream 重复读 ⇒ L0/权重层错 |
| I6 | 每层首读地址 == 上一层写出的同一像素下标 | 图整体平移/撕裂 |
| I7 | `count + inflight` 在 beat 落地时不变，FIFO 永不溢出 | 覆盖未读数据 ⇒ 随机错列 |

### 7.2 上板看什么

| 指标 | 期望 |
|---|---|
| `MS`（帧时） | Track1 后 50 ms；Track3 后应降到 ≈41 ms |
| profiler `B` / `RGAP` / `AR` | 分别 ≈19% / ≈12% / ≈3%（Track1 后的稳态） |
| `RPMS/CPMS` | CPMS 应≈算力占比；`RPMS+CPMS ≈ MS` |
| `PF − PFC` | ≤ 2（否则有 burst 卡住） |
| `AXI` / `DROP` / `ERR` | 全程 0（启动瞬态 FAULT=4、UF=2 允许） |

---

## 八、试过但**没有**落地的优化

| 尝试 | 做法 | 结果 | 结论 |
|---|---|---|---|
| **wburst 写 burst 合并**（分支 `wburst-18.5fps`） | `rowpipe_wr_engine` 加 `MAXB=8` 合并 | 写命令 451,250→90,250/帧，单面板 18.5 fps，但双面板写通道占用变长导致显示闪烁 | 已回退；教训是"只修一侧只值 +6%" |
| **读多 burst 并发**（`MAX_RD_INFLIGHT=2`） | 仲裁器 `ar_more` + 多 outstanding | 验证发现 `arvalid` 会在 `arready` 前撤销（**AXI 违规**），且 src/wstream 会重复发 AR | 代码保留、默认关；已加 `pipe_en` 隔离 |
| **性能计数器加宽到 32 位** | `stat_*` 24→32 位 | 60,193 XLR（99.00%）**布线失败**；改饱和比较器 → PASS 但 `vid_clk_dvi2` slack **−0.710 ns** | 退回简单自增 + 16 位 burst 计数，并在注释里写明风险 |
| **CI/CO/COUT 16→8** | 一行参数 | 未做。`CI` 决定 `s_col`/`o_id`/`i_id` 端口宽度（都是 `CI*8`），`conv3x3_core` 里还硬写 `.CIN(16)`，`TILED` 标志翻转 ⇒ **接口级改动** | 能省约 10 块 RAM + 1.3k XLR，但 rowpipe 零仿真覆盖，暂不动 |
| **Track 2 层间融合**（T2.1~T2.5） | 片上环形缓冲替代 DDR 往返 | 未做。RAM 只剩 12 块，融合 L10+L11 需 6 块、L0+L1 需 8 块，全搬片内要 25 块 | Track1 之后交通已不是瓶颈，收益≈0，明确放弃 |
| **`probe_max8` 探针变体** | `conv3x3_core.v.probe_max8` / `requant.v.probe_max8` / `rowpipe_layer.v.probe_max8` | 是"把 CO 阵列填到 8"的实验快照，未合入 | 属调试残留，可在清理时删除 |

---

## 九、诚实边界

| 项 | 状态 |
|---|---|
| Track 1 三处改动的实现与参数 | ✅ 读源码 + 提交正文核对 |
| Track 1 的板上数字（MS 58→51→50、B 86→15→19、AR 6→3、RGAP 23→12） | ✅ 来自 `cce5529` 提交正文的 100 MHz AXI 计数器实测 |
| 写侧吞吐模型 `max(3, B_lat/N)` | ✅ N=1 算出 48.7 ms 与实测 49.1 ms 吻合 |
| 面积净减 193 XLR、时序改善 | ✅ `0352fc3` 构建记录 |
| 显示 beat 缓冲 15.28→6.93 ms | ✅ `docs/DDR_READ_OPTIMIZATION.md` 的仿真对照 |
| 显示欠载 3458→0.173 次/秒 | ✅ 实板 92.688 s 窗口 |
| **Track 3 的 −8.53 ms** | ❓ 算术推导，**未经上板实测**；画质更柔是唯一风险 |
| **`TAIL_LOWRES=1` 是否已构建/上板** | ❓ 工作区改动未提交，未见对应构建记录 |
| B1 系列各单项的独立收益 | ❌ **未做逐项拆分构建**，只有合并后的结果；源码注释里的数字多为实测点值 |
| Track 2 融合的收益 | ❌ 只有模型估算 |
| rowpipe 全链仿真覆盖 | ❌ 目前基本为零，改描述符/几何只能靠上板看 |

---

## 附：一页对照——"想改什么，去看哪里"

| 想做的事 | 入口 |
|---|---|
| 写侧再快一点 | `MAX_B_OUT`（4→6，注意 DDR 桥深度未核实） |
| 读侧再快一点 | `MAXB`/`DEPTH`（须成对改，`MAXB ≤ DEPTH/2`） |
| 帧率再高一点 | `TAIL_LOWRES=1`（省算力，画质变柔） |
| 显示别闪 | `DYNAMIC_VIDEO_READ=1` + 内层 urgent 两参数 |
| 省面积 | CI/CO 16→8（接口级）、删 `probe_max8`/死代码 |
| 查每层算力 | `reports/TRACK3_COMPUTE_RESTRUCTURE.md` §1 |
| 查每层交通 | `reports/NETWORK_OPT_PLAN.md` §1.3 |
| 查优化全案 | `reports/NETWORK_OPT_PLAN.md`（Track 1~4） |
