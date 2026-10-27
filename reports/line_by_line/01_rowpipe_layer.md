# rowpipe 卷积核逐行阅读

> 阅读对象（全文逐行读完，未用 grep 代替）：
> - `rtl/accel_rowpipe/rowpipe_layer.v` —— **973 行**（列号 1..973，`endmodule` 在 973；`Measure-Object -Line` 报 928 是"非空行"口径，本报告的行号一律按 read 工具的物理行号）
> - `rtl/accel_rowpipe/conv3x3_core.v` —— 248 行
> - `rtl/accel_rowpipe/requant.v` —— 210 行
>
> 交叉核对（只读）：`rowpipe_engine.v`、`style_network_rowpipe.sv:79-92`（12 层描述符）、`reports/ARCHITECTURE_FULL.md`、
> 权重 blob `software/firmware/variants/rowpipe_weights_redsky_v4.h`（用 python 按 RTL 解析规则还原每层 M/mid/bias/shift/qlo/qhi）。
>
> 全文约定：**【事实】** = 源码可直接验证；**【推测】** = 我的判断，需实验确认。

---

## 结论摘要（5 条）

1. **【事实，最高价值】`requant` 的 ReLU 没有使能位，是靠 `qlo` 的符号隐式决定的**（`requant.v:90`、`requant.v:114`：`ar = (qlo_r < 0) ? a : (a>0?a:0)`）。
   而当前板上权重 `redsky_v4` 的 **L11（输出层）qlo=0 / qhi=255** ⇒ **输出层被强制做了 ReLU**；同时显示端（风格/右半侧）是 `rd_pixel[23:0] ^ 24'h808080`（`rtl/style/style_display.sv:107`，把数据当"零中心有符号 INT8"用，`ARCHITECTURE_FULL.md:200` 同述）。
   这两个约定互相矛盾。ReLU 会把最后一层所有负半轴夹成 **0**，只剩正半轴 ⇒ 均值必然偏正、且大量像素**恰好等于同一个值 0**。
   **【推测，大概率】这就是"INT8 均值 +28 / 70.9% 面积同色 `#989898`"的主因**：70.9% 的像素被夹到 0（显示端 `0^0x80=128`，再经 lift 抬到约 152 ⇒ `#989898`），剩下 29% 的正半轴均值 ≈ 28/0.29 ≈ 96，正好落在实测"范围 0..121、无负值"里。判别实验见 §给 Lead 第 1 条。

2. **【事实】`rowpipe_layer` 的 `CI=16 / CO=16 / COUT=16` 三个参数对当前 12 层全是"两倍超配"**：12 层描述符里 `ci ≤ 8`、`cout ≤ 8`。由此产生的大块浪费可以逐项数出来：行缓冲 `lb` = 1280×**128 bit** = 163,840 bit（CI=8 时为 81,920 bit，**省 8 个 10 kbit RAM 块**）、恒等支历史 `id_rb` = 338×128 = 43,264 bit（省 2 块）、输出 FIFO 槽 `OW`=258→194 bit、`rq_id_r1..r5` 640→320 FF、`o_col` 128→64 bit。在 XLR 97.3% / RAM 244/256 的压力下，这是**同一条 RTL 上最省事的一块空间**（改例化参数，不改一行逻辑）。

3. **【事实】`ci_tiles=2`（B1e）在本设计里是纯死代码，而且它压着一条未触发的雷**：`CIW=8` 恰好等于最大 `cfg_ci=8`，`S_RLD` 分支的进入条件 `cfg_ci > CIWV(8)` 恒假 ⇒ 19 拍重载、`wrap1280()`、`rld_a0/a1/a2`、三个读口地址 mux（`rdA_use/rdB_use/oid_use`）、每一拍窗口写入前的 `tile` 2:1 选择、以及 **tap 地址通路上的 `wci = ci_cnt - (tile?7:0)` 减法器**全都白搭（最后一个在关键路径上）。雷：`rowpipe_layer.v:458-462` 自己写了"必须 `2*cfg_win < D`"，而 **L0/L1/L10/L11 的 win=640、D=1280，正好等号不成立**——现在只有靠"tile 永不触发"才没事。

4. **【事实】RHE（round-half-to-even）实现逐位正确**，ARCH=0 / ARCH=1 两种写法我都做了代数验证（见 requant 段）：`(n + 2^(s-1) - 1 + ((n>>>s)&1)) >>> s` 与"余数<半舍、>半进、=半取偶"完全等价；ARCH=1 把它拆成两拍（`sum1_r + q0b_r`）后数值逐位不变。`s=0` 两条路径都有保护。`qhi` 零扩展、`qlo` 符号扩展也都对（`requant.v:159-160`、`198-199`）。

5. **【事实】跨模块契约比文件头注释写的要"长一截"**：头注释（L69-77）说"requant 两级流水 ⇒ 输出比喂晚 2 拍、每组 +2 拍排空"，实际 ARCH=1 是 **3 级（vld0/vld1/vld2）**，`feed`→`rq_out_vld` = **5 拍**，`o_col` 可见 = 6 拍；`S_DRAIN` 靠 `inflight==0` 退出，实际每组多花 ≈8 拍。我用 5 拍延迟反推了 FIFO 行为（见 rowpipe_layer §流水线）：**结论是不丢数、不死锁、稳态 1 列/拍**，只是账面常数和注释对不上，且 `inflight` 的"在飞 max=3/4"结论是错的（真值 5，被 `o_cnt+inflight<4` 自己限住了）。

---

## rtl/accel_rowpipe/rowpipe_layer.v（973 行）

### 职责与契约

**一句话**：这是 12 层风格迁移网络**时分复用的同一个卷积层**——吃"按列成串的 INT8 特征图"，用 2 行环形缓冲 + 18 列窗口拼出 3×3×ci 的 tap，交给 `conv3x3_core` 做 16 像素 × 8 通道的 MAC，再把累加器按像素送给唯一的 `requant`，最后按 `y→x→c` 的顺序带背压吐出。

**谁驱动它**：`rowpipe_engine.v:138-151` 例化（`#(.CI(16),.CIW(8),.PIX(16),.CO(16),.COUT(16))`）。
- `s_vld = data_ok`（`rowpipe_engine.v:201-202`）：本拍 DDR 读数据可用（残差层要两个 bank 都到齐）。
- `s_col`：128 位（16 通道 × 8 bit），来自 `mem_rd_data0`，按 `xorin` 做 `^0x80` 域转换（`rowpipe_engine.v:205`）。
- `grp_vld` / `skip_vld`：由引擎 FSM 的 `S_GRP`（每组一次）/`S_PRE`+`S_RPAD`（推窗）发出；引擎靠 `o_st==4'd0`（= `S_IDLE`）判断层"吃下了命令"（`rowpipe_engine.v:380-415`）。
- `cfg_*`：`S_CFG` 状态用 10 拍写完 WIN/NG/HOUT/WOUT/RES/RESU/CI/COUT/S2/SKIPLEN（`rowpipe_engine.v:311-327`）。
- `o_ready = mem_wr_ready`：后端写 FIFO 能收。

**它输出给谁**：
- `o_col`（`CO*8`=128 位，实际只有低 64 位有意义，见疑点 #4）→ 引擎的 `mem_wr_data`（`rowpipe_engine.v:226`）。
- `o_pix_done` → 引擎的写使能/像素计数（`rowpipe_engine.v:178`、`222`）。
- `o_id`（`CI*8` 位）→ 残差层的恒等支；引擎从 `mem_rd_data1` 读第二 bank 拼出来（`rowpipe_engine.v:197/206`）。`o_id` **和 `o_col` 同槽**，所以语义是"同一像素"。
- `s_ack` → 引擎推进 `ptr/ix/iy`（`rowpipe_engine.v:169`）和 DDR 读 ack（`212/216`）。
- `o_st` → 引擎的命令握手。
- `o_row_end`：**引擎接了但没用**（`rowpipe_engine.v:130` 声明后无任何引用）——契约 4 目前是"没人核对"的。

### 端口

| 端口 | 方向 | 位宽 | 时钟域 | 语义 |
|---|---|---|---|---|
| `clk` / `rst_n` | in | 1 | `cnn_clk`=148.5 MHz（顶层 `style_video_system` 里 `vid_clk_dvi2`） | 异步复位低有效（`negdege rst_n`），用它的 always 全是 `posedge clk` |
| `ld_we/ld_waddr/ld_wdata` | in | 1/8/`CO*8`=128 | 同上 | 权重行写口，直通 `conv3x3_core`（切片只取低 `CO_FILL*8`=64 位） |
| `ld_be/ld_baddr/ld_bdata` | in | 1/8/32 signed | 同上 | 逐通道 int32 偏置（**已含无符号层 128·Σw 修正**） |
| `ld_me/ld_midx/ld_m/ld_mid` | in | 1/8/32/32 | 同上 | requant 的 M 与恒等支乘数 mid（每通道） |
| `ld_shift` | in | `RQW`=6 | 同上 | 每层一份的右移量（0..38 实测最大 38） |
| `ld_qlo` / `ld_qhi` | in | 8 signed / 8 unsigned | 同上 | 饱和下限/**无符号**上限；`qlo` 的符号兼职当"是否 ReLU" |
| `cfg_we/cfg_addr/cfg_data` | in | 1/8/16 | 同上 | 运行期几何/残差/stride 配置，地址表见 `L213-219` |
| `s_vld` | in | 1 | 同上 | "本拍 `s_col` 是要消费的那一列"（不是自由流） |
| `s_col` | in | `CI*8`=128 | 同上 | 16 通道 × int8，低字节 = 通道 0 |
| `grp_vld` | in | 1 | 同上 | 启动一组（PIX=16 个输出列，s2 时 8 个） |
| `skip_vld` | in | 1 | 同上 | 只推窗口不出结果，`cfg_skiplen` 列/次 |
| `o_vld` | out | 1 | 同上 | = FIFO 非空（`o_hold_v`），挂起时保持 |
| `o_col` | out | `CO*8`=128 | 同上 | 一像素的 8/16 字节（实际低 64 位有值） |
| `o_ready` | in | 1 | 同上 | 下游收下这一拍 |
| `o_row_end` | out | 1 | 同上 | 每 `cfg_wout` 个被接走的像素一次（引擎未用） |
| `o_pix_done` | out | 1 | 同上 | 像素完成拍（co≤8 时恒 = `o_vld`） |
| `s_ack` | out | 1 | 同上 | = `adv`，本拍真的消费了一列 |
| `o_st` | out | 4 | 同上 | FSM 状态只读引出（Efinity 不许层次化引用） |
| `o_id` | out | `CI*8`=128 | 同上 | 残差恒等支，与 `o_col` 同槽 |
| `i_id` | in | `CI*8`=128 | 同上 | 残差恒等支输入（引擎在"喂这个像素"那拍给） |

### 内部结构（FSM / 流水线 / 缓冲）

**FSM（`st` 4 位，`L259-261` 编码，`L668-785` 实现）**

| 状态 | 码 | 干什么 | 出口条件 |
|---|---|---|---|
| `S_IDLE` | 0 | 等命令 | `skip_vld`→`S_SKIP`（清 `skip_cnt`）；`grp_vld`→装 `nstep=cfg_ci*9`、清 `s_ky/s_kx/ci_cnt/scyc/pass/tile`→`S_START` |
| `S_SKIP` | 1 | 只推窗口 | `s_vld` 且 `skip_cnt==cfg_skiplen-1`→`S_IDLE`；否则 `skip_cnt++` 留原地（**完成条件=消费条件**，`L690-693`） |
| `S_START` | 2 | 打一发 `start_go` | 无条件→`S_STEP`（同时清计数器） |
| `S_STEP` | 3 | 每拍一步 `step_go` | `ci_cnt<cfg_ci`：`s_kx/s_ky/ci_cnt` 前进，**可能插 `S_RLD`**；否则→`S_WAIT` |
| `S_WAIT` | 4 | 等 `acc_vld` | `acc_vld` 且 `pass==0 && npass2`（本设计恒假）→`S_START`；否则 `ser=0`→`S_SER`（tile=1 时先 `S_RLD`） |
| `S_RLD` | 8 | 整窗重载 19 拍 | `rld_cnt==WN(18)`→`rld_nxt`；否则 `rld_cnt++`（**本设计永不进入**） |
| `S_SER` | 5 | 喂 requant + 推窗 | `adv_ser` 且 `scyc==PIXV1(15)`→`S_DRAIN`（并推进 `grp_in_row`/`out_row`） |
| `S_DRAIN` | 6 | 排在飞的输出 | `inflight==0` 后数 2 拍→`S_NEXT` |
| `S_NEXT` | 7 | 清 pass/tile/ci_cnt | →`S_IDLE` |

无 `default` 落入陷阱：`default: st <= S_IDLE`（`L782`）。**没有死锁环**：所有等待条件（`s_vld`/`acc_vld`/`inflight`）都由外部或自身流水推进。

**流水线级数（从 `s_col` 到 `o_col`）**

| 级 | 位置 | 说明 |
|---|---|---|
| 0 | `L410` `lb[wp] <= s_col` | 行缓冲写（`adv` 拍） |
| 1 | `L494-497` `q_c/q_a/q_b` | 三个读寄存，`adv` 门控；BRAM Tco + 对齐（约定 b/d） |
| 2 | `L627-651` tap | 纯组合：`w[wsel_idx]` 24:1 → `wf` 水平 halo → `s_kx*8 +: 128` 常数切片 |
| 3 | `conv3x3_core` | DSP `A_REG/B_REG/P_REG/O_REG`=4 级 + `acc_r` 1 级，`DSP_LAT=3` 是"实测有效延迟" |
| 4 | `L899-901` `rq_pix_acc_r/feed_d/rq_sel_d` | mux 后插的那一级（注释说关键路径 Slack −0.791 ns 才加的） |
| 5 | `requant` ARCH=1 内部 3 级 | `ar_r` → `prod_r` → `sum1_r/q0b_r` → `q_out` |
| 6 | `L344-355` 输出 FIFO | `o_q[o_tl]` 落槽，`o_vld/o_col` 从 `o_hd` 出 |

**实测延迟（我按代码逐拍推的，不是注释）**：`feed`(t) → `feed_d`=1(t+1) → `vld0`(t+2) → `prod_r`(t+3,`vld1`) → `sum1_r`(t+4,`vld2`) → `q_out`/`rq_out_vld`(t+5) → 落 `o_q`(t+6)。**⇒ `feed`→`o_col` 可见 = 6 拍**；注释 `L69-77`/`L303-306` 说的"2 拍/在飞 max=3"是旧账。

**缓冲清单**

| 缓冲 | 深度×宽 | 类型 | 说明 |
|---|---|---|---|
| `lb` | 1280 × 128 bit（163,840 bit） | 推断 RAM（同步读） | 行缓冲/延迟线；`D=1280` 是编译期定死的 |
| `w[24]` | 24 × 144 bit = 3,456 FF | 触发器 | 窗口：CIW=8 通道 × 3 行 × 18 列 |
| `id_rb` | 338 × 128 bit（43,264 bit） | RAM（读口寄存） | 恒等支 PUSH 深历史 |
| `o_q` | 4 × 258 bit = 1,032 FF | 触发器 | 输出 FIFO，尾指针 2 位必须回绕 4 |
| `acc_lo_r` | 16×8×32 = 4,096 FF | 触发器（**死**） | `npass2` 钉 0，写进去没人读 |
| `rq_id_r1..r5` | 5 × 128 = 640 FF | 触发器 | 恒等支 5 级流水（`r3` 之外还多两级，见疑点 #6） |

### 逐行要点

**L1-83｜文件头（读它比读代码更容易误解，注意其中三处已过期）**
- L1-20：tap 结构红线——窗口位宽必须是 `ci_par`（CIW）而不是 CI；列方向禁止变量下标（`w[kx+p]` 会综合出 18:1 宽 mux，探针 v2 直接装不下）。这是全文件最重要的一条设计约束。
- L22-47：窗口四约定 (a)(b)(c)(d)。(a) `col0=最旧/col17=最新`，所以移位是 `{newbyte, w[len-1:8]}`；(b) 三行都要寄存（BRAM Tco 对齐）；(c) **行缓冲按"消费"推进而不是按拍**（`adv = (S_SER||S_SKIP)&&s_vld`）；(d) `q_c/q_a/q_b` 必须 `adv` 门控，否则"每组头 3 列尾 2 列错"。
- L48-52：对齐常数 `n = y*66 + x + 151`——这是 WIN=66 小 TB 的旧口径，**和当前 640 档无关**（640 档每行恰好消费 `ng*16 = win` 列，见 §行缓冲）。
- L54-66：core 是批处理的（一次 `start` 只出一组累加器）；`core_step` 必须组合（`step_go`），否则 tap 比权重超前一步、末步越界取 `tsel[CI*9]` 出 x。
- L67-77：requant 时分复用 + 一个成本公式 `1+1+ci*9+3+16+2+1`。**公式里的 `3` 和 `2` 都偏乐观**（实际 acc_vld 等 4 拍、DRAIN 约 8 拍，见疑点 #6）。
- L78-82：输出顺序 `y→x→c`，和 `L{i}_chain.hex` 的 `c→y→x` 不同（TB 要重排）。

**L84-106｜参数表头（超配的源头）**
- `CI=4`（默认）/ 实例化 16：输入通道 = 端口宽度 = 行缓冲宽度。**当前 12 层最大 ci=8**。
- `CIW=CI`（默认）/ 实例化 8：窗口通道数。注释 L89-93 讲 ci_tiles 怎么省 FF——现在 `CIW=8=最大cfg_ci`，这段机制永不触发（摘要第 3 条）。
- `PIX=16`：空间并行，`WN=PIX+2=18`。
- `CO=16`：**输出端口**的通道上限（`o_col` 宽 `CO*8`）。实际最大 cout=8 ⇒ 高 64 位恒 0。
- `COUT=16`：本层实际输出通道的**默认值**（`cfg_cout` 的复位值）。**关键：`cfg_cout` 在全文只被写、从不被读**（见疑点 #4），所以这个参数目前对功能毫无影响。
- `RQW=6`：shift 位宽；blob 里实测 shift ∈ {30,31,36,37,38}，6 位够（<64）。

**L107-182｜端口（表见上）+ 三处契约注释**
- L143-148：输出带背压，`o_ready=0` 时 `o_vld` 保持、`o_col` 冻结、**不丢拍**。
- L153-160：`s_ack = adv` 是纯加法项，让上游不必偷看内部信号推进指针。
- L166-182：残差两支的约定——`o_id` 从**输出 FIFO 头**出（和 `o_col` 同槽），且**已延迟 `PUSH` 列**，下游不要再自己延迟。这条在 2026-10-16 改过一次（旧写法组合直出引脚 ⇒ 配错像素）。

**L184-199｜局部常量**
- `CW=CI*8=128`、`WN=18`、`TILED=(8<16)=1`（**编译期恒 1**，所以 tile 相关逻辑一定被综合）、`CIX=TILED?CIW:0=8`、`CIWV=8/CIW1V=7`（注意别混：`CIWV=CIW`，`CIW1V=CIW-1`）。
- `CO_ARR=8`（MAC 阵列宽度，硬定）、`CO_FILL=8`（存储通道数）、`CO_EXTRA=(16>8)?8:0=8`（高半区空字节）。
- `OW=CO*8+CI*8+2=258`：FIFO 槽 = `o_col`(128) + `o_id`(128) + `{half,pdon}`(2)。

**L201-246｜固定缓冲 + cfg 寄存器组**
- `D = max(2*WIN_MAX, PUSH_MAX+1) = 1280`（`WIN_MAX=640`，`PUSH_MAX=658`）。
- cfg 地址表 10 项（L213-219）。**复位默认值有意思**：`cfg_cout<=COUT`、`cfg_res<=0`、**`cfg_resu<=1`**、`cfg_s2<=0`、`cfg_skiplen<=1`（L227-230）——旧 TB 不改也能跑。
- 写口是"一拍一个地址"（`L231-245`），引擎 `S_CFG` 连写 10 拍。

**L247-292｜运行期化开关 + 状态编码**
- `L248` `wire npass2 = 1'b0;  // cap8 static: no co16 two-pass` —— **co16 两遍拼接被硬关掉**。于是 `acc_lo_r`（L289-291）写了没人读、`rq_col_full` 的高半区恒 0、引擎里 `cout>8` 那条 `lo_col` 拼装也是死的。
- `PIXH=8`、`pix_eff = cfg_s2 ? 8 : 16`、`ser_end = pix_eff-1`（L254-257）。
- 状态编码 L259-261；内部计数器位宽都经过核对：`ci_cnt` 5 位（≤16）、`ser` 5 位（npass2 时 0..31，本设计 0..15）、`grp_in_row` 6 位（NG max 40）、`out_row` 9 位（HOUT max 480）、`wp` 11 位（0..1279）。
- `L280` `assign o_st = st;` 必须在 `reg st` 之后（注释记了 ModelSim 报错）。

**L293-355｜输出 FIFO（契约 3 的落点）**
- 注释 L298-315 把"为什么深度 4"推了一遍：`o_cnt+inflight` 跨落地恒定 ⇒ 只要 `OD > inflight_max` 就既不溢出也不丢；并且**深度必须是 2 的幂、指针位宽要正好回绕**（把 OD 改 6 而指针还 3 位 ⇒ 每 8 个输出错 2 个 x）。这段是全文件最有价值的注释之一。
- `OD=4`、`ODV=5'd4`（L324-325，防"integer 参数位选=0"的老坑）。
- `rq_col_full`（L335-336）：`half_d5 ? {rq_q, 8'd0} : {8'd0, rq_q}` —— 本设计 `half_feed=npass2?…:0 ≡ 0`，所以**高半区永远是 0**。
- FIFO 主体 L344-355：`o_push` 门控 `o_cnt<ODV`、`o_take=o_cnt&&o_ready`；槽内容 `{rq_id_r5, pdon_d5, half_d5, rq_col_full[CO*8-1:0]}`。
- `inflight`（L384-386）：`+feed - rq_out_vld`。

**L357-397｜adv / feed 的推导（背压正确性的核心）**
- `fifo_ok = (o_cnt+inflight) < ODV`（L370）：把"在飞的"也数进去，否则组尾丢像素。
- `in_feed_zone = (!cfg_s2) || (scyc <= ser_end)`、`feed = (st==S_SER) && fifo_ok && s_vld && in_feed_zone`（L375-376）。
- `adv_ser`（L391-393）：s2 时喂区看 `fifo_ok`、喂区外只看 `s_vld`；**co16 时只在 `ser[0]` 那拍推窗**（每像素 1 列）。
- `adv = adv_ser || ((st==S_SKIP)&&s_vld)`、`s_ack = adv`（L394-397）。
- **我实测推演了"inflight 真值=5 而门限是 4"**：首组前 4 拍全速 feed，第 5 拍被 `fifo_ok` 挡住，随后 `rq_out_vld` 到达，稳态收敛到 `o_cnt=1, inflight=2`，**吞吐仍是 1 列/拍、无丢无死**。⇒ 不是 bug，但注释里"在飞 max=3/4"的数字是错的，谁要动 `OD` 必须按 5 重算。

**L399-432｜行缓冲与三个定点抽头**
- `lb` 数组 L408（无复位：靠"首个输出行用垂直 halo 反射"避开 X，见 §行缓冲）。
- `wp` 回绕写死 `1279`（L413）——`D` 一旦不是 1280 这里必须同步改。
- 抽头地址 L419-422：`rdA = wp + D - cfg_win`（一行前）、`rdB = wp + D - 2*cfg_win`（两行前）；`%D` 用"加 D 减一次"的实现（中间值 <2D）。
- `push_eff = cfg_win + WN`、`oid_a = wp + D - push_eff`（L430-432）：恒等支抽头。
- **win=640 的边界算术**：`rdB_s = wp + 1280 - 1280 = wp` ⇒ 正好读到"本拍要写的格"，而该格存的是 1280 列前的值 = 两行前，**语义正确**（这是 `D=2*WIN_MAX` 刚好踩线的巧合，见疑点 #3）。

**L434-484｜tile 重载地址（B1e，死路径但占面积）**
- `rld_r2 = wp + 3821 + j`（= wp+3840−19+j）、`rld_r1/r0` 各减 `cfg_win`（L444-446）；`wrap1280()` 先减 2560 再减 1280（L447-454）。fsm 只在 `S_RLD` 时有效。
- `L458-462` 的警告：**必须 `2*cfg_win < D`**，否则 row0 与 row2 物理地址重合 ⇒ 静默错。当前 win=640 恰不满足（8 折余量 0），只有靠"cfg_ci≤8 ⇒ 永不 tile"幸存。
- L463-467 `synthesis translate_off` 的 `$display` 只在仿真里报警。
- 三个读口借用（L468-484）：`rdA←row1`、`rdB←row0`、`oid_a←row2`；恢复拍用 `rdA_m1/rdB_m1`（`rdA-1`，否则重载后下一拍移窗错一列）。**注释 L486-492 记了一条硬约束：每个 RAM 读口只能挂一个目的寄存器**，否则 Efinity 判 "read port is not synchronous"、163,840 bit 掉进 logic memory、XLR 42k→177k。

**L486-554｜窗口生成（②）**
- `w[0:CIW*3-1]`，索引 `ci*3+row`；`row0=两行前、row2=本拍输入`（L507）。
- generate 里三组切片 `sb_*`（正常推进）与 `rb_*`（重载），都带 `tile ? [8*(gi+CIX)+:8] : [8*gi+:8]` 的 2:1 选择（L516-523）——**这是 72 个 8 位 2:1 mux**，本设计 `tile` 恒 0。
- 移位语义 L542-550：`{新字节, w[WN*8-1:8]}`，新字节进 col17。注释 L525-538 记了两个踩过的坑：反向移位会让 kx 整体反；把 halo 写回**寄存器**会让 col17 那半边顺着移位污染下一组的 col1。

**L556-588｜③b 恒等支抽头**
- `o_id_c = lbO_w = lb[oid_a]`（L582）：恒等支 = 输入列流的 `PUSH` 列延迟，直接用行缓冲抽头，**不经过窗口**。
- 注释 L568-576 记了两种错写法：`w[OROW][(ser+OCOL)*8+:8]`（ser 与窗口同进同退 ⇒ 每拍读回同一格，无解）和常数列（值对但时间不对）。**D=34 是 TB 实测出来的唯一通过值**（旧档位），说明这个常数不能"大概一行"。

**L590-651｜tap 三轴分选 + 两级 halo + stride-2 gather**
- `first_grp/last_grp = grp_in_row==0 / ==cfg_ng-1`（L604-605）。
- `first_row/last_row`（L617-620）：`last_row = cfg_s2 ? 0 : (out_row==cfg_hout-1)` —— **s2 层没有末行反射**（输出行 y=hout-1 用输入行 hin-3..hin-1，全都真实存在）。
- 垂直 halo（L622-623）：`ky_eff` —— 头行 ky=0 改取 row2、末行 ky=2 改取 row0。**只改选择，不动寄存器**（注释 L600-603 记了"改喂进寄存器的字节"会污染下行头两列的坑）。
- 降维（L607-627）：先 `w[wci*3+ky_eff]` 选一整行（24:1 × 144 bit），再在 18 列上做水平 halo，最后 `s_kx*8 +: 128` 常数切片 —— 比"144 个 (ci,row,kx) 组合各切 128 位再 144:1"省 2.5×。
- `wci = TILED ? (ci_cnt - (tile?CIWV:0)) : ci_cnt`（L625）：**tap 地址通路上的一个减法器**，本设计 `tile≡0` 恒等于 `ci_cnt`。
- 水平 halo（L629-633）：`wf` = `{last_grp?col15:col17, col1..16, first_grp?col2:col0}` —— 行首组 `col0←col2`、行尾组 `col17←col15`（反射填充的等价实现）。
- stride-2（L636-651）：`g0/g1/g2` 是**纯布线** gather（像素 p 取列 `2p,2p+1,2p+2`），`taps_s2` 只填低 8 个像素、8..15 填 0；`taps = cfg_s2 ? taps_s2 : taps_s1`。

**L653-785｜步进与组时序（④，FSM 主体）**
- `start_go = (st==S_START)`、`step_go = (st==S_STEP) && (ci_cnt<cfg_ci)`（L663-665）—— 注释 L656-662 记了"两个都必须组合"的两条实测理由（tap 超前一步越界出 x；start 寄存会让 27 步只发 26 拍、FSM 卡 S_WAIT）。
- `S_SKIP`（L690-693）：带 `cfg_skiplen` 突发（默认 1；s2 层设成 `win`，一条命令空跑一整行）。
- `S_STEP`（L709-728）：每拍推进 `s_kx→s_ky→ci_cnt`；tile 切点在"发完 (CIW-1,2,2) 那一拍"，判据 `TILED && cfg_ci>CIWV && !tile && ci_cnt==CIW1V && s_kx==2 && s_ky==2`。**注意 `CIWV=CIW=8` 而 `CIW1V=7`**：判据写的是 `>CIWV`（即 >8），所以 `cfg_ci=8` 不会误触发；若错写成 `>CIW1V` 就会在 L2 最后一步插重载、把 `acc_vld` 脉冲吞掉（注释 L716-718 记了这个实测）。
- `S_WAIT`（L732-744）：`acc_vld` 后进 `S_SER`；`npass2` 分支恒不执行。
- `S_RLD`（L748-749）：19 拍（第 0 拍只给地址）。
- `S_SER`（L755-770）：`scyc` 数推窗拍数（0..15）→ 到 15 进 `S_DRAIN`，**同时**推进 `grp_in_row`，行末再推进 `out_row`；`ser` 跟 `feed` 走（注释 L766-768 记了"塞进 adv 分支 ⇒ 死锁"）。
- `S_DRAIN`（L776-779）：`inflight!=0` 时只数 `s_drain_cyc`（观测用），排空后 `drain` 数 2 拍再走 ⇒ **总耗时 ≈ 5+3 拍**，注释写"3 拍"。
- `S_NEXT`（L780-781）：清 `ci_cnt/pass/tile/co_sel`。

**L787-797｜conv3x3_core 例化**
- `.CIN(16)`、`.COUT(CO_ARR=8)`、`.CO_STORE(CO_FILL=8)`、`.K(3)`、`.WADDR_W(8)`；`n_step=nstep`、`start=start_go`、`step=step_go`、`co_sel`（本设计恒 0）。

**L799-923｜requant 例化 + 流水对齐**
- `rq_pix_acc`（L885-887）：16:1 × 256 bit 的像素 mux，压在 requant 乘法器前（关键路径来源之一）。
- 3+2 级流水（L899-914）：`rq_pix_acc_r/rq_sel_d/feed_d` + `rq_id_r1..r5`（**恒等支打了 5 级**，比数据链多 2 级）+ `half_d1..d5` + `pdon_d1..d5`。全部**不门控**（门控会和数据链错开）。
- `.ARCH(1)`、`.COUT(8)`、`.CO_STORE(8)`、`.PW(6)`。
- `rq_id_arr`（L872-878）：`rq_id_full[32*(rq_sel_d*CO_ARR+gh)]` —— 半区选择必须用**延迟后**的 `rq_sel_d`，注释 L868-869 记了用当拍 `rq_sel` 会静默错的实测。

**L925-946｜输出 skid + 契约 4**
- `px_cnt`（L930-936）：只在 `o_take && head_pdon` 时递增，到 `cfg_wout-1` 归零。
- `o_row_end = o_take && head_pdon && (px_cnt==cfg_wout-1)`（L938）、`o_vld=o_hold_v`、`o_col=o_q[o_hd][CO*8-1:0]`、`o_id=o_q[o_hd][CO*8+2+:CI*8]`（L939-946）。

**L948-971｜恒等支域转换（这里最容易误判成 bug，其实是对的）**
- `rq_id_full[32*gri] = (gri<cfg_ci) ? (cfg_resu ? {24'd0, ib^8'h80} : $signed({{24{ib[7]}},ib})) : 0`。
- 我专门推了一遍"`resu` 用零扩展到底对不对"：卷积支的 tap 已经在硬件里被做成 `t'=t-128`，而偏置里补了 `128·Σw`，所以**累加器 acc 落在"真实激活整数域"（无符号层是 0..255）**。恒等支必须同域，所以 `resu=1`（无符号源）应当拿 **真实 u8 值**并零扩展：`i_id` 进来时是"中心化域"（引擎已按 `idxor` 反异或过），再 `^0x80` 正好还原成真实 u8 ⇒ `{24'd0, ib^8'h80}` **正确**。`resu=0`（有符号源）存的是补码 ⇒ 符号扩展 **正确**。
- 交叉验证 3 个残差层的描述符与 blob 完全自洽：L4 `resu=1/idxor=1/idb=2`（源是 L2 的 ReLU 无符号输出），L6 `resu=0/idxor=0/idb=1`（源是 L4 的有符号输出），L8 `resu=0/idxor=0/idb=0`（源是 L6 的）。**⇒ 这里不是 bug，不要改。**

### 风险与疑点

> 行号 + 现象 + 置信度。**先事实、后推测。**

**#1【事实/最高价值】输出层被隐式 ReLU —— 主因候选**
- 位置：`requant.v:114`（ARCH=1）/ `requant.v:90`（ARCH=0）；触发数据来自 `rowpipe_engine.v:368`（`ld_qlo <= whold[13:6]`）。
- 事实链：`qlo_r < 0` → 不 ReLU；否则 ReLU。**当前 blob（redsky_v4 / redsky_q 两套都一样）L11 的 `qlo=0 / qhi=255`** ⇒ 输出层 ReLU 生效。对照：L4/L6/L8 是 `qlo=-127/qhi=127`（有符号、不 ReLU），其余层 `qlo=0`（ReLU）——**设计意图就是"qlo=0 标志 ReLU 层"，而 L11 落进了这个模式**。
- 但显示端按"零中心有符号"用（`ARCHITECTURE_FULL.md:200`：右半 `rd_pixel ^ 0x808080`），`reports/FOR_MODEL_mean_bias_and_flat_area.md:44` 也写"期望均值 0 → 显示 128"。
- **【推测，大概率】** 后果：最后一层负半轴全部→0 ⇒ (a) 均值必然偏正；(b) 所有被夹的像素**恰好同值**（70.9% 同色）；(c) 实测"R 范围 0..121，最小值=0，无非负之外的负值"完全吻合。量化自洽性：若 70.9% 为 0、其余均值 ≈ 28/(1−0.709) ≈ 96（在 0..121 内），整体均值 = 0.29×96 ≈ 27.8 ✓。
- 置信度：**代码事实=确定；因果链=大概率（需一次判别实验，见给 Lead #1）**。

**#2【事实】`cfg_cout` 写了从不读 + `npass2` 硬钉 0 ⇒ `COUT`/`CO_EXTRA` 一整条路径是死的**
- 位置：`L240`（唯一写点）、全文无读点；`L248`；`L289-291`；`L335-336`；`rowpipe_engine.v:221`（`cout>8` 的 `lo_col` 拼装）。
- 影响：功能上暂时无害（最大 cout=8），但 (a) 若将来出现 cout>8 的层会**静默只算 8 通道、高半区输出 0**；(b) `acc_lo_r` 4,096 个 FF 是纯浪费（综合大概能剪掉，但在 97.3% XLR 下值得去 `map.rpt` 确认一下是否真被剪）。

**#3【事实】`2*cfg_win < D` 在 win=640 层不成立，靠"tile 永不触发"幸存**
- 位置：`L458-462`（自己写的约束）、`L444-457`（重载地址）、`L719-720`（触发条件）。
- 现象：D=1280、win=640 ⇒ 等号不成立，`row0` 与 `row2` 物理地址重合。**现在 cfg_ci ≤ 8 所以进不去 `S_RLD`，正确性不受影响**；一旦加一层 ci=16@640 就会静默错（仿真只有 `$display` 提示）。
- 置信度：确定（是"潜在雷"而非"当前 bug"）。

**#4【事实】`o_col` 高 64 位恒 0 / 输出带宽翻倍**
- 位置：`L332-336`（`half_feed≡0`）、`L940`；引擎 `mem_wr_data = out_word = o_col`（128 位）。
- 现象：cout≤8 的层每像素写 16 字节，其中高 8 字节是 0（另有 `cout` 之外通道的残值）。这是设计定的 16 B 对齐布局，**不是 bug**；但如果 DDR 带宽是瓶颈，这是 2× 的写放大（`FOR_MODEL` 报告里的"σ/同色"与带宽无关，仅记一笔）。

**#5【事实】`S_STEP` 期间 MAC 满速、`S_SER` 期间 MAC 全空 ⇒ MAC 利用率 ≈ 69%**
- 位置：`L709-728`（每拍一步）、`L755-770`（16 拍只喂 requant）。
- 数量：ci=8 组 = 72(MAC) + 1(idle) + 1(start) + ≈4(等 acc_vld) + ≈18(S_SER，含 FIFO 爬坡) + ≈8(DRAIN) + 1(NEXT) ≈ **105 拍/组**，MAC 有效 72 拍 ⇒ 69%。requant 若做成 16 路并行可省掉这 18 拍（+17% 吞吐），代价是 16 倍乘法器——**当前是面积优先，可以接受，但成本模型要按 105 拍算，不是注释里的 96**。

**#6【事实】延迟/在飞账本与注释不符（不影响功能）**
- 位置：`L69-77`、`L298-315`、`L322-324`、`L776-779`。
- 现象：注释说"requant 两级、在飞 max=3、DRAIN 2~3 拍"；实际 ARCH=1 三级、`feed→rq_out_vld`=5 拍、`o_col` 可见=6 拍、DRAIN≈8 拍。我按 5 拍延迟做了逐拍推演：**不丢数、不死锁、稳态 1 列/拍**。但如果有人按注释去调 `OD`（比如觉得"4 太深，改 2"），会真的丢数据。
- 置信度：确定（账本错，功能对）。

**#7【事实】`o_row_end` 无人消费**
- 位置：`L938` 产生；`rowpipe_engine.v:130` 接收后无引用。
- 影响：`cfg_wout` 若与引擎的 `wout` 不一致（描述符写错），没有任何硬件互锁能发现，只表现为画面行错位。**建议**：引擎的 `ox/oy` 计数改成用 `o_row_end` 复位/校验，成本几乎为零。置信度：确定（是"缺少交叉校验"而非 bug）。

**#8【猜想】`initial` 初始化 `id_rb` 的可移植性**
- 位置：`L843` `initial for(...) id_rb[si] = {CI{8'h80}}`。
- 说明：如果综合器不认这条 initial，上电后 `id_rb` 是未定值。但我算了时序：`adv&&cfg_res` 在 PREPUSH 阶段就推进 `id_wp`，而首组消费前至少已 adv 658 次 > 深度 338 ⇒ **所有格都被真实数据覆写过**，所以这条 initial 实际不重要。置信度：猜想（无害）。

**#9【事实】tap 关键路径上的死逻辑（面积/时序双输）**
- 位置：`L625`（`wci` 的减法+mux）、`L516-523`（72 个 `tile` 2:1）、`L479-481`（3 个读口地址 mux）、`L719-720`（tile 判据）。
- 现象：这些都是 `TILED=1` 但 `cfg_ci≤8` ⇒ 逻辑值恒定，却因为 `cfg_ci/tile` 是**运行期信号**而不可能被综合剪掉。其中 `wci` 直接喂 `w[wsel_idx]` 这个 24:1×144 bit 大 mux，在关键路径上。

### 文档偏差（`reports/ARCHITECTURE_FULL.md`，已知有错，只记录不改）

| 文档位置 | 文档说法 | 源码事实 |
|---|---|---|
| `§3.2` L147 | `CIW(8) // 输入通道位宽` | CIW 是**窗口通道数**（窗口 = CIW×3 行 × 18 列 × 8 bit）；位宽是 `CIW*8` |
| `§3.2` L150 | `COUT(16) // 输出通道位宽` | COUT 是"本层实际输出通道"的**复位默认值**；MAC 阵列固定 `CO_ARR=8`，且 `cfg_cout` **从未被读** ⇒ 一层最多算 8 通道 |
| `§3.3` L159 | `q = clamp(RHE(relu?(acc)·M, shift), qlo, qhi)` | 没写 `relu?` 的判据是 **`qlo` 的符号**（隐式、无使能位）——正是这一点掩盖了 L11 的问题 |
| `§3.1` L122 | L0 "stride 2" | 描述符 L0 `s2=0`（`style_network_rowpipe.sv:91`）；L1/L2 才是 s2=1 |
| `§3.1` L126/128/130 | L4/L6/L8 都"残差 + idxor" | 只有 **L4** `idxor=1`；L6/L8 `idxor=0`（它们的 id 源是有符号张量） |
| `§3.1` L133 | L11 写 bank `0x06A00000`（BANK2） | 描述符 L11 `dstb=0` ⇒ BANK0（`0x06000000`）；`§阶段4` 又说最终落到 `result_address`，两处自相矛盾 |
| `§3.4` L175 | "22,512 B（1,407 beat）" 与 "903 beat / 14,448 B" | 实测 header 3612 word = 14,448 B = **903 beat**；我按 `wbase_of` 逐层验证偏移表 12 层全部吻合 ⇒ 903 是对的，22,512 B 是旧值 |
| `L6` | XLR 59,132/60,800（97.2%） | Lead 给的是 97.3%，差 0.1%，无关紧要，仅记录 |

补充偏差（对本文档之外的旧注释）：`rowpipe_layer.v:48-52` 的"开局 151 拍 / 每行 66 列"是 WIN=66 小 TB 的旧口径；640 档下**每行恰好消费 `ng*16 = win` 列、没有行间 skip**（只有 `s2` 层用 `S_RPAD` 空跑一整行），而 **PREPUSH = `win+18` = 658 列**，尾部同样多消费 658 列（`rowpipe_engine.v:373`，注释 L198-200 里写的"82 拍"是旧口径）。

---

## rtl/accel_rowpipe/conv3x3_core.v（248 行）

### 职责与契约

**一句话**：3×3×CIN 的 INT8 批处理点积引擎——`start` 一发清累加器，之后每拍喂一个 `(cin,ky,kx)` 的 `PIX` 个 tap，最后一拍后 `acc_vld` 拉高一拍，`acc_flat` 上就是 `acc + b'`。

`acc[p][c] = Σ_{cin,ky,kx} tap[cin][p][ky][kx] · W[cin][ky][kx][c] + b'[c]`，全整数、无误差。

**谁驱动**：`rowpipe_layer.v:790-797`（`start=start_go`、`step=step_go`、`n_step=cfg_ci*9`、`taps` 来自 ③ 段、`co_sel` 恒 0）。
**输出给谁**：`acc_vld` 给层 FSM 的 `S_WAIT`；`acc_flat` 给层里 16:1 像素 mux → `requant`。

### 端口

| 端口 | 方向 | 位宽 | 域 | 语义 |
|---|---|---|---|---|
| `clk/rst_n` | in | 1 | 148.5 MHz | 异步低有效 |
| `ld_we/ld_waddr/ld_wdata` | in | 1/8/`CO_STORE*8` | 同上 | 权重行写：地址 = `cin*9+ky*3+kx`，数据 = 每通道一字节 |
| `ld_be/ld_baddr/ld_bdata` | in | 1/8/32 | 同上 | 偏置（含 128·Σw 修正） |
| `n_step` | in | 16 | 同上 | 本层步数 = `cin*9` |
| `start` | in | 1 | 同上 | 单拍脉冲：清累加器、计数归零、`busy=1` |
| `step` | in | 1 | 同上 | 推进一个 `(cin,ky,kx)`；**必须与 `taps` 同拍** |
| `co_sel` | in | 2 | 同上 | 8 通道半区（`CO_STORE>COUT` 时有效，本设计恒 0） |
| `taps` | in | `PIX*8`=128 | 同上 | PIX 个 int8，低位是 p=0 |
| `acc_vld` | out | 1 | 同上 | 最后一拍后 3 拍（`DSP_LAT`）拉高一拍 |
| `acc_flat` | out | `PIX*COUT*32`=4096 | 同上 | `[p*COUT+c]`，组合（含 `+b'`） |

### 内部结构（无状态机，纯"计数器 + 流水"）

| 逻辑块 | 行号 | 作用 |
|---|---|---|
| 权重/偏置存储 | `L99-106` | `wrow[0:143]`（16 通道×9）与 `bmem[0:7]`；**同步写** |
| 步进计数 | `L109-116` | `step_cnt`、`busy`、`last=(cnt16==n_step-1)`、`go=step&busy` |
| 延迟匹配 | `L118-131` | `go_pipe/last_pipe` 移位 `DSP_LAT=3` 拍 |
| 控制 | `L133-148` | `acc_vld<=last_d`；`start` 清计数并置 busy；`go&&last` 清 busy |
| 权重同步读 | `L150-166` | `step_n`（把 `start` 也算进去）+ `wpack_full_r<=wrow[step_n]` |
| MAC 阵列 | `L168-233` | `PIX`×`COUT/2` 个 `EFX_DSP48(DUAL)`，每个出 2 个通道 |
| 输出 | `L235-246` | `acc_flat = acc_r + bmem[...]` |

**流水线**：`taps`(t) → DSP（A/B/P/O 四级寄存，实测有效延迟 3）→ `go_pipe[2]`=1 那拍累加 → `last_d` → `acc_vld`(t+4)。累加器本身是 FF 阵列（`NACC=PIX*COUT=128` 个 24 位）。

### 逐行要点

- **L1-44 文件头**：核心是两条——(1) 每两个输出通道共用一个 `EFX_DSP48` DUAL（`A[18:8]×B[17:8]` 给偶数通道、`A[7:0]×B[7:0]` 给奇数通道），所以 `INT8_MAC_PER_DSP=2`，PIX16×COUT8 用 **64 个 DSP**；(2) **UINT8 激活的偏移技巧**：tap 预做成 `t'=t^0x80=t-128`，展开后 `Σt·w = Σt'·w + 128Σw`，后一项逐通道折进偏置 ⇒ 数学精确、硬件只要一个 XOR。
- L28-31：权重布局必须"一个 `(cin,ky,kx)` 一行 `COUT` 字节"，否则每拍要 72 个读端口，综合不出来。
- L36-43：握手四条 + `DSP_LAT` 必须和 producer 一致（本节 `L89-96` 详述："taps 与 step 同拍 → 3；taps 提前一拍稳住 → 2"）。
- **L98-106**：`wrow` 按 `CO_STORE` 宽存、`bmem` 也按 `CO_STORE`；`csel = (CO_STORE>COUT)?co_sel:0`（本设计 8>8 假 ⇒ 恒 0）。
- **L112-116**：`cnt16 = {{(16-(WADDR_W+1)){1'b0}}, step_cnt}` —— 显式零扩展，注释记了"直接 `step_cnt[15:0]` 是越界片选，ModelSim 给 x ⇒ `last` 永不成立 ⇒ 仿真死等"。
- **L119-131**：`go_pipe/last_pipe` 是 `DSP_LAT` 位移位寄存器；`last_pipe` 的输入是 `go & last`（只认"最后一步真的发生"）。**注意 `go_pipe` 用同一 `rst_n` 同步复位**，复位后 3 拍内 `go_d=0` ⇒ 不会误累加。
- **L133-148**：`acc_vld <= last_d`（**无条件**，所以 `start` 后如果 `n_step=0` 会误出 `acc_vld`——但 `n_step=cfg_ci*9≥27`）；`start` 优先于 `go`（`if(start)...else if(go)`）⇒ start 与 step 同拍时 start 赢，呼应"start 与 step 必须不同拍"。
- **L150-166**：`step_n = start?0 : go? step_cnt+1 : step_cnt`，`wpack_full_r <= wrow[step_n]`。**这是"下一拍地址本拍算好"的同步读模式**，注释 L151-157 记了分离 assign 会让 18,432 bit 全落 FF；L161-163 还记了"整字读、半区选择放在寄存器之后"（带运行期切片的读会让 Efinity 不认 RAM）。我核对了时序：`step` 拍 `step_cnt=s`、`wpack_full_r` 里正是 `wrow[s]` ✓。
- **L168-233 MAC 阵列**：
  - `t` 一律按 `$signed` int8（`L175`），无符号层已经在向量生成阶段做过偏移。
  - `A = {{3{t[7]}}, t, t}`（19 位，高 11 位是 t 的符号扩展）；`B = {{2{w_hi[7]}}, w_hi, w_lo}`（18 位）。**两侧都符号扩展正确**（DUAL 的高路吃 11×10 位，低路吃 8×8）。
  - `dsp_o` 取值 `O[47:24]`（高路）/`O[23:0]`（低路）—— 注释 L210-215 特别说明"按内部 37 位取能综合过、DSP 数也对，但**数值全错**，资源报告里看不出来"。这是本文件最危险的一处知识。
  - 累加器 `acc_r` 声明为 `reg signed [23:0]`（`L169`）但赋值用 `32'sd0`；按最坏情况 |acc| ≤ 144×128×127 ≈ 2.34M < 2^22 上限 4.19M ⇒ **24 位够用**，但余量只有 1.79×，且没有任何保护（若将来 ci 涨到 32 就会静默溢出）。
- **L235-246**：`acc_flat = acc_r + bmem[csel*COUT+gc]`（32 位全宽）。注释 L236-237 记了"`last_d` 与最后一次累加同拍、`acc_r` 下一拍落定、`acc_vld` 也是下一拍 ⇒ 这里不要再加一次乘积（第一版就是这么错的）"。

### 风险与疑点

**C#1【事实】`acc_r` 只有 24 位、无饱和保护**
- `L169` + `L222/228`。最坏情况 144 步 × (128×127) ≈ 2.34M（23 位有符号上限 4.19M），当前 ci≤8（72 步）时最大 1.17M，**余量充足**。但只要有人把 ci 提到 16 且权重全满量程，就会在 24 位处回绕，且**没有任何断言/饱和**。置信度：确定（是"余量小且无保护"）。
- 顺带：偏置 `b' = b + 128Σw` 也在 32 位里加，不溢出 ✓。

**C#2【事实】`bmem` 只按 `CO_STORE=8` 存，但引擎每层固定写 16 个通道的偏置**
- `L100/L105`（`ld_baddr < CO_STORE` 才写）+ `rowpipe_engine.v:338-348`（bias 4 beat = 16 个通道）。⇒ 通道 8..15 的偏置被**静默丢弃**。当前 cout≤8 ⇒ 无害；一旦有 cout>8 的层，高半区偏置就是旧值（上一层的），**静默错**。置信度：确定（潜在雷）。

**C#3【事实】`start` 后如果 `n_step` 与真实步数不一致，`acc_vld` 永不来**
- `L115` + `L143-146`：`busy` 只在 `go&&last` 清。若 `n_step` 比实际 `step` 数多（例如 `cfg_ci` 写错），`last` 永不成立 ⇒ `acc_vld` 不来 ⇒ 层卡在 `S_WAIT`（**表现是整帧 freeze，不是图像错**）。这是"静默挂死"类风险，但有 `wtimer` 之外的超时保护吗？层里没有——**只有引擎的权重流有 `wtimer`**。置信度：确定（设计如此，缺超时）。

**C#4【推测】`go_pipe` 的复位极性**
- `L120-127`：`if(!rst_n) go_pipe<=0; else go_pipe <= {go_pipe[DSP_LAT-2:0], go}` —— `DSP_LAT=3` ⇒ `[1:0]` 拼接 ✓；若 `DSP_LAT=1` 会变成 `go_pipe[-1:0]` 非法片选。当前 3 ⇒ 无问题，仅记录这个"参数一变就报错"的脆弱点。置信度：确定（脆弱，非当前 bug）。

### 文档偏差

- `ARCHITECTURE_FULL.md` 只在层次图里提到 `conv3x3_core`（`L66`），**没有记录**：DSP 阵列固定 8 通道（`CO_ARR`）、`acc_r` 24 位、权重/偏置/`acc_flat` 的位宽、`DSP_LAT=3` 的"生产者相位"契约。这些恰好是"改一处就静默错"的地方，建议后续补进文档。

---

## rtl/accel_rowpipe/requant.v（210 行）

### 职责与契约

**一句话**：把 int32 累加器（可选地加上残差恒等支）一次乘加 + RHE 移位 + 饱和成 int8/uint8：
`q = clamp(RHE(relu?(acc)·M + id·mid, shift), qlo, qhi)`。

**谁驱动**：`rowpipe_layer.v:916-923`，`.ARCH(1)`（三拍流水）、`.COUT(8)`、`.CO_STORE(8)`、`.PW(6)`；`co_sel=rq_sel_d`（恒 0）。
**输出给谁**：`q_out`(64 位) + `out_vld` → 层的输出 FIFO。

### 端口

| 端口 | 方向 | 位宽 | 域 | 语义 |
|---|---|---|---|---|
| `ld_e/ld_idx/ld_m/ld_mid` | in | 1/8/32/32 | 148.5 MHz | 逐通道写 M 与 mid（`ld_idx<CO_STORE` 才写） |
| `ld_shift` | in | `PW`=6 | 同上 | 每层一份右移量 |
| `ld_qlo/ld_qhi` | in | 8 signed / 8 **unsigned** | 同上 | 饱和上下限；`qlo` 符号兼职 ReLU 使能 |
| `use_id` | in | 1 | 同上 | 本层是否加恒等支（= `cfg_res`） |
| `id_in` | in | `COUT*32`=256，**signed** | 同上 | 恒等支，已扩展成 int32 |
| `co_sel` | in | 2 | 同上 | 半区（本设计恒 0） |
| `in_vld` | in | 1 | 同上 | 一拍一个像素的 COUT 个累加器 |
| `acc_in` | in | `COUT*32`=256 | 同上 | int32 累加器，`[c]` 低位是 c=0 |
| `out_vld` | out | 1 | 同上 | ARCH=1 时延 3 拍，ARCH=0 时延 2 拍 |
| `q_out` | out | `COUT*8`=64 | 同上 | 8 个通道的量化结果 |

### 内部结构（两套实现，二选一；本设计用 ARCH=1）

**ARCH=0（`L153-168`，两级）**：`prod_r <= ar*m + xr*mid`（级①）→ `rhe()` + 饱和（级②）。
**ARCH=1（`L169-207`，三级，rowpipe 用）**：
1. 级① a（`L117-124`）：ReLU/符号/`use_id` 选择**单独打一拍**（`ar_r/xr_r`），并把 `m_r/mid_r` 复制成 `m_h0/m_h1/mid_h0/mid_h1`；
2. 级① b（`L127-129`）：`prod_r <= ar_r*m_sel + xr_r*mid_sel`（32×32→64）；
3. 级②（`L184-190`）：`sum1_r <= prod_r + half_m1_r`；`q0b_r <= (prod_r>>>shift)[0]`；
4. 级③（`L195-204`）：`t = sum1_r + q0b_r`；`qs = t >>> s_r2`；三级比较器饱和；`q_out <= qc[7:0]`。
`vld0/vld1/vld2/out_vld` 逐级跟随（`L131-133`、`L191-193`、`L205-206`）。

**RHE 的代数验证（我做的，不是抄注释）**
设 `n = q·2^s + r`（`q = n>>>s`，`0 ≤ r < 2^s`），`h = 2^(s-1)`。要实现"`r<h` 舍、`r>h` 进、`r=h` 取偶"，公式取
`RHE = (n + h − 1 + (q&1)) >>> s = q + floor((r + h − 1 + (q&1))/2^s)`：
- `r ≤ h−1`：分子 ≤ `(h−1)+h−1+1 = 2h−1 = 2^s−1` ⇒ floor=0 ⇒ q ✓
- `r ≥ h+1`：分子 ≥ `(h+1)+h−1+0 = 2^s` ⇒ floor=1 ⇒ q+1 ✓（上界 `(2h−1)+h−1+1 = 3h−1 < 2^(s+1)`，floor≤1 ✓）
- `r = h`：分子 = `2^s−1+(q&1)` ⇒ q 偶 ⇒ 0（保持）、q 奇 ⇒ 1（进位）✓
**⇒ 公式与"half-to-even"完全等价，ARCH=0 与 ARCH=1 的数值也逐位相同**（ARCH=1 只是把 `+h−1` 和 `+q0b` 拆到两拍，`half_m1_r` 在装参数时算好，见 `L174-177`）。`s=0` 两条路径都有保护（`L143`、`L176`、`L188`）。

### 逐行要点

- **L1-29 文件头**：公式、RHE 为什么必须实现（"写成 `(n+2^(s-1))>>s` 就是四舍五入，在 .5 上与 torch.round 系统性不符"）、两级流水、接口粒度（一拍一个像素的全部 COUT 通道）。
- **L32-39 参数**：`COUT`（阵列宽，B1c 起用 8）、`CO_STORE`（存储宽）、`PW=6`、`ARCH`（0=两级/1=三拍，"数值逐位相同，只多 1 拍"）。
- **L64-77 参数寄存器**：`m_r/mid_r` 逐通道、`shift_r/qlo_r/qhi_r` 每层一份。**注意 `L74-75` 是两个独立的 `if (ld_e && ld_idx<CO_STORE)`**——同一个 `ld_e` 同时写 M 和 mid（引擎 `L355-358` 正好一起给），✓。
- **L79-100 ARCH=0 级①**：`ar = (qlo_r<0) ? a : (a>0?a:0)` —— **ReLU 判据就是这一行**；注释 L88-89 说明"M 恒正，所以先 ReLU 再乘 ≡ 模型里先乘再 ReLU，且省一级"（正确：ReLU 与正数乘法可交换）。
- **L91-92 的关键注释**：恒等支与卷积支**共用同一分母（同一 shift），所以两支先加后舍、只舍入一次**，与模型 `round((x+y)/s_out)` 形状一致 ✓。
- **L101-134 ARCH=1 级①**：`m_h0/m_h1/mid_h0/mid_h1` 是 `m_r` 的复制（`H1=(CO_STORE>COUT)?COUT:0`，本设计 8>8 假 ⇒ `H1=0`，`m_h1` 与 `m_h0` 内容相同——**无害但白占 4×8×32 位 FF**）；`m_sel = csel[0]?m_h1:m_h0`（`csel≡0` ⇒ 恒 `m_h0`）。注释 L102-104：把 ReLU/符号扩展这 10 级从 DSP 关键路径上隔离出去（138 MHz 的教训）。
- **L136-149 `rhe()` 函数**：只给 ARCH=0 用；`half = 1 <<< (s-1)`，`rhe = (n+half-1+((n>>>s)&1)) >>> s`。**注意 `(n>>>s)&1` 里的 `n` 是原始 n（未加 half），与 ARCH=1 用 `prod_r>>>shift_r` 一致** ✓。
- **L151-168 ARCH=0 级②**：`qhv = $signed({56'd0,qhi_r})`（**零扩展**）、`qlv = $signed({{56{qlo_r[7]}},qlo_r})`（**符号扩展**），注释 L156-158 记了"把 qhi 当有符号读的话 255 变 −1，所有输出被夹到 −1 ⇒ 196607 个比较里 187770 个不符，错得很整齐，像缩放问题"。这是个很值得记的排障指纹。
- **L169-207 ARCH=1 三级**：
  - `half_m1_r`（`L174-177`）：`ld_shift==0 ? 0 : (1<<(ld_shift-1))-1`。**它由 `ld_e` 触发**，而引擎在 S_M（8 拍 M 装载）和 S_Q（quant 头）都会拉 `ld_e`；`ld_shift` 在 S_M 期间还是**上一层的旧值**，但 S_Q 是最后一次 `ld_e` 且带着本层正确 shift ⇒ **最终值正确**（顺序：S_M 全在 S_Q 之前，`rowpipe_engine.v:350-370`）。这是一个"看起来像 bug、实际靠顺序对齐"的地方，**若将来把 S_Q 挪到 S_M 前面就会静默错**。
  - `s_r2 <= shift_r`（`L193`）延迟一拍配 `sum1_r` ✓。
  - `L188`：`(shift_r==0) ? 1'b0 : q0[0]` —— `q0` 是有符号右移的结果，取第 0 位 = `(prod_r>>>shift)&1` ✓ 与公式一致。
- **L198-200**：饱和用 64 位比较（`qs`/`qhv`/`qlv` 都是 64 位有符号），**先比较后截低 8 位**（`L203`），没有中间截断 ⇒ 正确。

### 风险与疑点

**R#1【事实，最高价值】ReLU 无使能位，绑死在 `qlo` 的符号上**
- 位置：`L90`（ARCH=0）、`L114`（ARCH=1）。引擎侧唯一的控制量是 `ld_qlo`（`rowpipe_engine.v:368`）。
- 后果：**无法表达"无符号输出但不做 ReLU"**。当前 blob 里 L11 `qlo=0` ⇒ 输出层被 ReLU ⇒ 输出永远不会出现负值，与显示端 `^0x80`（期望零中心有符号）矛盾。
- 置信度：**代码事实=确定**；"这就是板上均值 +28 / 70.9% 同色的主因"=**大概率**（见给 Lead #1 的判别实验）。
- 修法（两条都不大动结构）：(a) **模型/blob 侧**：L11 改成 `qlo=-128, qhi=127`，M/shift 按有符号零中心重标定 —— 只换权重 blob，不动 RTL；(b) **RTL 侧**：给描述符/配置加一个显式 `relu_en` 位（描述符 `[127:106]` 空闲，`rowpipe_engine.v:96-99` 的位域表里 `[105:104]` 之后是空的），`ar = relu_en ? max(a,0) : a`。代价：一次重综合（约 10 min）。

**R#2【事实】`qlo=-127` 而不是 −128（三个残差层）**
- 位置：blob L4/L6/L8 的 `qlo=-127`；`L160/L199` 的符号扩展逻辑没有问题。
- 后果：真实值 −128 会被夹成 −127，**丢掉一个码**（对称量化常规做法，对均值影响 ≈ 1/256 码，可忽略）。置信度：确定（不是 bug，记录以便对账）。

**R#3【事实】`prod_r` 是 64 位，但它是"两个 32×32 乘积之和"**
- 位置：`L96-97`、`L128-129`。两个满量程 int32 乘积之和可达 2^63，接近 64 位有符号溢出边界；再加上 `half`（≤2^37）理论上会回绕。
- 实际：`acc` 是量化累加器（实测量级 1e5~1e6），`M` ≤ 1e9 ⇒ 乘积 ≤ 1e15 ≪ 2^63。**当前无风险**，但没有任何保护。置信度：确定（理论边界，非当前 bug）。

**R#4【事实】ARCH=1 里 `m_h0/m_h1/mid_h0/mid_h1` 每拍无条件重载**
- 位置：`L117-124`。这 4 组寄存器每拍都在 `m_r` 上重采样，**与 `ld_e` 无关**。因为 `m_r` 只在装参数时变，功能上等价（只是 `m` 路径晚了 1 拍，由静态值掩盖），但白占 4×8×32 = 1,024 FF，而 `csel≡0` 时 `m_h1/mid_h1` 完全没用。在 97.3% XLR 下值得删（改例化参数 `CO_STORE==COUT` 时可以把整个 `H1` 分支用 generate 剪掉）。置信度：确定（浪费，非 bug）。

**R#5【推测】`out_vld` 复位为 0，但 `vld0/vld1/vld2` 的复位是异步的**
- `L131-133`、`L191-193`、`L205-206` 都用 `negedge rst_n`；而 `prod_r/sum1_r/q_out` 的 `always` 里只有 `q_out` 有复位，`prod_r/sum1_r/q0b_r` 是**无复位**的（`L127`、`L186-189`）。⇒ 复位后前几拍 `prod_r` 是 X，但 `out_vld` 被复位钳住不会误吐 ✓。置信度：确定（安全，因为 valid 链独立复位）。

### 文档偏差

- `ARCHITECTURE_FULL.md:159-169` 的公式和参数表（M signed32、shift 6、qlo signed8、qhi 8）与源码一致 ✓；但**没写 ReLU 的判据**（`qlo<0`）、没写"两支共用一次舍入"、"qhi 零扩展/qlo 符号扩展"、"ARCH=1 是三级/延迟 3 拍"。这四条恰好是数值对账时最容易踩的。
- 文档说 `shift` 是"每层一份（非每通道）" ✓ 一致。

---

## 给 Lead 的 5 条要点

1. **【最高价值，可直接上板验证】输出层 L11 被 `requant` 隐式 ReLU 了。**
   - 证据（都是确定的代码/blob 事实）：`requant.v:114` 用 `qlo_r < 0` 当 ReLU 使能，没有独立开关；我用 RTL 的解析规则还原了 `rowpipe_weights_redsky_v4.h` / `_redsky_q.h` 的每层参数，**两套 blob 的 L11 都是 `qlo=0 / qhi=255 / shift=37(M=600515771 或 shift=39)`**，而 L4/L6/L8 是 `qlo=-127/qhi=127`。显示端按零中心有符号用（`ARCHITECTURE_FULL.md:200` 的 `^0x808080`）。
   - 与实测的吻合度：ReLU 于输出层 ⇒ 负半轴全部变 0 ⇒ 恰好解释"**均值 +28、范围 0..121 且最小值为 0、70.9% 面积同色**"（0.29×96≈28 自洽）。
   - 判别实验（10 分钟，不动 RTL）：**把 L11 的 qlo 从 0 改成 −128（qhi=127），M/shift 按有符号零中心重标定后重出 blob**，跑同一套指标看均值是否回 0、σ 是否上升；或直接读 DDR 最后一层的直方图，若 0 附近有 ≈70% 的尖峰即确诊。
   - 若模型侧坚持 L11 就是 u8 非负，那就是**显示端 `^0x80` 与 blob 的符号约定不一致**，需要改显示端而不是模型——两种修法互斥，必须先定约定。

2. **【面积】`CI=16 / CO=16 / COUT=16` 是 2× 超配，可以靠"只改例化参数"拿回最多空间。**
   12 层实测 `ci ≤ 8`、`cout ≤ 8`。改 `.CI(8)`（保持 `CIW=8`）后：`TILED=(8<8)=0` ⇒ tile 全套逻辑（`S_RLD`/`wrap1280`/`rld_*`/三个读口 mux/tap 路径上的 `wci` 减法器/72 个 `tile` 2:1）被综合剪掉；`lb` 163,840→81,920 bit（**省 8 个 10 kbit RAM 块**）；`id_rb` 43,264→21,632 bit（省 2 块）；`rq_id_r1..5` 640→320 FF；`o_col`/FIFO 槽 258→194 bit。再改 `.CO(8)` 可再省 64 bit×4 槽 + `rq_col_full`/`rq_id_full` 的高半区。**在 XLR 97.3% / RAM 244/256 下这是最划算的一刀**（代价：只支持 ci≤8、cout≤8，当前正好够）。

3. **【潜在雷，两个，都不影响当前正确性但会静默错】**
   - (a) `rowpipe_layer.v:458-462` 自己规定"`2*cfg_win < D`"，而 **L0/L1/L10/L11 的 win=640 让等号不成立**（D=1280）。现在靠"所有层 ci≤8 ⇒ tile 永不触发"活着；一旦加 ci16@640 层就静默错（仿真只有 `$display`）。
   - (b) `rowpipe_engine.v:338-348` 每层写 16 个通道的 bias，而 `conv3x3_core.v:105` 只存 `CO_STORE=8` 个 ⇒ **cout>8 的层高半区偏置是上一层的残值**；同理 `cfg_cout` 写了从不读（`rowpipe_layer.v:240` 唯一写点）⇒ 出现 cout>8 的层会"只算 8 通道 + 高半区输出 0"。
   - 另外 `o_row_end`（`rowpipe_layer.v:938`）引擎接了不用，`cfg_wout` 与 `wout` 不一致时没有任何互锁——建议引擎的 `ox` 计数改用 `o_row_end` 复位，成本≈0。

4. **【账本纠正】** 头注释（`rowpipe_layer.v:69-77`、`298-315`）的成本模型偏低：`requant` ARCH=1 是 3 级、`feed→rq_out_vld` = **5 拍**、`o_col` 可见 = **6 拍**、`S_DRAIN` 实际 ≈8 拍（不是 2~3）。我按 5 拍延迟逐拍推过：**不丢数、不死锁、稳态 1 列/拍**（`o_cnt+inflight<4` 自己限流，收敛到 `o_cnt=1, inflight=2`）。真实每组 ≈105 拍（ci=8）而不是 96，MAC 利用率 ≈69%；`requant` 串行化贡献了其中 18 拍。**不要去"按注释"改 `OD`**——真在飞是 5，改小会丢数据。

5. **【已验证正确的部分，避免后续误改】** (a) RHE 的两种实现都逐位正确（我做了代数证明，含 `s=0`、取偶、负数算术右移三种情况）；(b) `qhi` 零扩展 / `qlo` 符号扩展正确；(c) 残差两支**共用一次舍入**，与模型 `round((x+y)/s)` 形状一致；(d) `resu` 的 `{24'd0, ib^0x80}` 零扩展**是正确的**（因为累加器在"真实激活整数域"，且引擎已按 `idxor` 反异或一次），L4/L6/L8 的 `resu/idxor/idb` 与 bank 轮转完全自洽——**这三层不要动**；(e) `lb[wp]` 在 win=640 时"读到本拍要写的格"看起来吓人，但该格恰好存着两行前的值，语义正确。
