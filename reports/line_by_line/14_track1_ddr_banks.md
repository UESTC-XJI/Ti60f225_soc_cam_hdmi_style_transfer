# Track 1 总线优化实施说明（`rowpipe_ddr_banks.v`）

**改动文件**：`rtl/accel_rowpipe/rowpipe_ddr_banks.v`（唯一改动文件，860 → 997 行）
**未动**：`rowpipe_frame_driver.v`、`style_network_rowpipe.sv`、`rowpipe_engine.v`、`style_axi_cdc.sv`、SDC —— 顶层例化**不需要传参**，全部吃 `rowpipe_ddr_banks` 的默认值
**未做**：没跑 Efinity、没跑仿真、没碰板子/OpenOCD（按约定，构建与上板由 Lead 统一做）

---

## 1. 结论摘要（5 条）

1. **三处改动全部落地，且全部参数化**：`DEPTH` / `MAXB` / `MAX_RD_INFLIGHT` / `MAX_B_OUT` 四个模块参数挂在 `rowpipe_ddr_banks:709-722`，**默认值 = 改动前行为**（DEPTH=64、MAXB=16、MAX_RD_INFLIGHT=1），只有 `MAX_B_OUT` 默认 4（已开写侧优化，按你的要求）。回退 = 改一个数字，不需要回退代码。
2. **面积是"净减少"不是净增加**：默认配置下 **FF ≈ −85、LUT4 ≈ +32、RAM +0**（≈ 净减 50 XLR）。原因是我把读流里的 `want_addr[31:0]`/`want_len[7:0]`/`cur_len1[7:0]`/`want_r` 四个寄存器（49 FF × 2 流）改成了**组合推导**。激进配置（DEPTH=256/MAXB=64/并发=2）额外 **+8 FF / +15 LUT4 / +6 RAM 块**（RAM 244→250/256）。
3. **写侧吞吐模型与实测对上了**：`拍/beat = max(3, B_latency/N)` 在 N=1、B_latency=13 AXI 拍时算出 **48.7 ms**，与实测 **49.1 ms** 吻合 ⇒ 模型可信，可以据此选 N。
4. **你 11:29 那版 T1.1 我保留了结构、修了 3 处**：① `MAX_B_OUT` 提为参数；② `b_dec` 改成用"含本拍新发"的 `b_pend` 判（你原来的 `b_out != 0` 单条判据在"同拍一进一出"时会漏一笔）；③ `b_virt_flag` 换成 **4 位环形队列**（逐笔 virt）。另外 **`acked/acked_virt` 仍然严格只在 B 回来时自增**（你要求的重点）。
5. **我自己引入/发现过两个坑，都已修**：① 多 burst 后 `inflight` 改为"AR 被接受时"才计数，于是"已抬 want、仲裁器还没接受"的那条 AR 在 `flush` 时会被漏掉 ⇒ 换 bank 后整幅错位。加了 1 位 `want_d` 影子（`:254`），`flush` 现在必须等它落地。② `src_stream`/`wstream` 的 `want` 在整个 burst 期间保持高，一旦 `MAX_RD_INFLIGHT>1`，仲裁器会给它们追加**同地址**的 AR ⇒ 数据重复。加了 per-client 使能 `pipe_en[3:0]`（`:67`，顶层固定 `4'b0110`），**只让两个 rd_stream 参与追加**。这两个都是"只在扫参到 D 档才爆"的 bug，默认配置看不出来。

---

## 2. 改动清单（逐段 + 为什么）

### 2.1 `rowpipe_axir_arb4:35-150`（T1.2-A：允许同 client 追加 AR）

| 位置 | 改了什么 | 为什么 |
|---|---|---|
| `:35-49` | 新增 `parameter MAX_INFLIGHT` | 并发度可扫；=1 时下面所有新逻辑被常数传播剪掉 |
| `:62-67` | 新增输入 `pipe_en[3:0]`（哪些 client 支持追加 AR） | **必须有**：`src_stream`/`wstream` 的 `want` 在整个 burst 期间保持高（靠 `beat_last` 才清），给它们追加会让它们拿着**同一个 `want_addr`** 再发一条 AR ⇒ 同地址读两遍 ⇒ 数据重复。只有 rd_stream 把地址做成组合推导、能在 `ar_ack` 推进，才安全 |
| `:73-76` | 新增 4 根输出 `ack0..ack3`（AR 被接受的单拍脉冲） | **这是整个 T1.2 的关键**：读流原来看不到 AR 握手，只能等 `beat_last` 才推进地址；多 burst 在飞时必须在**发起那一刻**推进，否则两条在飞的 AR 会拿到同一个首地址 |
| `:84-85` | `ob[2:0]`：当前 client 已接受未 rlast 的 burst 数 | 单 sel 仲裁器原来只允许一条 AR 在飞 |
| `:114` | `ar_more = (ast==A_R) && (ob<K) && wv[sel] && pipe_en[sel]` | 在收 R 的同时为**同一个** client 追加 AR。AXI 同 ID 的读数据必须按 AR 顺序返回，所以对下游透明 |
| `:117` | `arvalid = (ast==A_AR) \|\| ar_more` | K=1 时 `ar_more≡0` ⇒ 与原版逐拍等价，且 `arvalid` 上不多挂 `wv[sel]` 这条组合路径（**默认配置时序不变**） |
| `:127-130` | `ack0..3 = ar_fire && (sel==i)` | 回送给读流 |
| `:137-146` | `A_R` 里用 `ob_n = ob + ar_add - ar_last` 单次加减；只有 `ob_n==0` 才让出总线 | 同拍"一条收完 + 一条追加"不能分两处赋值 |

**没改的**：轮转优先级、`rready`、`bv0..3`、`sel_a/l` 选择——仲裁公平性和 R 通道语义完全不动。

### 2.2 `rowpipe_rd_stream:154-335`（T1.2-B：参数化 + 多 burst）

| 位置 | 改了什么 | 为什么 |
|---|---|---|
| `:154-157` | `DEPTH`/`MAXB`/`MAX_INFLIGHT` 三个参数 | 扫参入口 |
| `:181-204` | `clogb2` 常数函数 ⇒ `IDXW` **自动推导**；`MAXB_E` 硬钳；`CNTW=10` | 你担心的"`IDXW` 写死 6、`count` 写死 8 位"全部消除。`MAXB_E = min(MAXB, DEPTH/2)` 是**防死锁**：`free_ok` 判的是 `DEPTH-MAXB`，一旦 `MAXB ≥ DEPTH` 就永远装不下一条 burst，预取再也不启动（帧级卡死、无超时） |
| `:195-197` | 删掉 `want_addr/want_len/cur_len1/want_r` 四个寄存器，`want_addr/want_len` 改组合 | ① 省 49 FF/流；② **必须**组合：追加第 2 条 AR 时 `next_fetch` 已推进，寄存器版会晚一拍 ⇒ 两条 burst 同首地址 |
| `:254` | `flush_now = need_restart && (inflight==0) && !want_d` | 见 §1-5①，**这是我自己引入并修掉的坑** |
| `:272` | `want = (bursts_out<K) && free_ok && !need_restart`（原来是 `want_r` 寄存器） | 并发门 + 容量门 |
| `:312-322` | `inflight`、`bursts_out` 用**一次加减**；`next_fetch` 在 `ar_ack` 推进；`want_d` 维护 | 同拍"进一条/出一条"若写成两个 `if`，后写者会覆盖前写者（非阻塞赋值的经典坑） |

### 2.3 `rowpipe_wr_engine:461-625`（T1.1：在你那版上做 4 处手术）

| 位置 | 改了什么 | 为什么 |
|---|---|---|
| `:461-466` | `MAX_B_OUT` 从 localparam 提为参数（默认 4，钳 1..8） | 你要的"只改参数重编做 A/B / `=1` 回退" |
| `:509-514` | `LIMIT` 钳位 + `b_out` 扩到 4 位 + `vq[LIMIT-1:0]` 环形队列 + `vq_wp/vq_rp` | 替代 `b_virt_flag` 单标志。**理由**：单标志依赖"层末必然排空"，而权重超时 abort（`rowpipe_frame_driver.v:178`）不等排空就回 `S_IDLE`，会让上一层的 virt 串到本层 ⇒ `acked_virt` 谎报 ⇒ `result_done` 的 `w_acked_virt == res_beats` 永不成立 ⇒ driver 卡死 `S_FLUSH`（**那里没有超时**） |
| `:546-551` | `b_pend = b_out + b_inc`；`b_dec = bvalid && (b_pend!=0)`；`b_dup` 单独留痕 | 你原来 `b_dec && (b_out!=0)` 的判据在"同拍一进一出"时会把合法 B 误判成异常；用 `b_pend` 才准。而且 `b_dup` 不再顺带增 `acked`（否则 `acked_virt` 会冲过头，同样让 `== res_beats` 永不成立） |
| `:601-606` | `case({b_inc,b_dec})` 单次加减 | 同拍进出抵消，不会多算 |
| `:610-624` | `vq` 入队（W 握手）/ 出队（B 回来）；`acked`/`acked_virt` 只在 `b_dec` 时增 | **你强调的那条**：`result_done` 靠 `acked_virt` 判"数据真落盘"，提前到 W 握手时增会让 driver 在写没完成时收尾 |

### 2.4 顶层 `rowpipe_ddr_banks:714-727` + 例化（`:829-845`、`:869-881`、`:981`）

- 4 个参数 + 扫描阶梯注释（写在参数块里，改的人一眼能看到）。
- `u_rd0/u_rd1` 传 `DEPTH/MAXB/MAX_INFLIGHT` 并接 `.ar_ack(rd0_ar/rd1_ar)`。
- `u_arb` 传 `MAX_INFLIGHT`，接 `.ack1/.ack2`，`.ack0()/.ack3()` 悬空（src/wstream 保持单 burst，不需要）。
- `u_wr` 传 `MAX_B_OUT`。
- **`rowpipe_frame_driver.v` 不用改**：以上全部有默认值。

---

## 3. 参数与扫描阶梯（建议按 A→B→C→D，每档单独构建）

| 档 | 配置 | 预期（按 §4 模型） | 目的 |
|---|---|---|---|
| **A 基线** | 全默认 **除** `MAX_B_OUT=1` | 应与今天**逐位等价**（~57.5 ms / 17.4 fps） | 先验证"参数化没有改变行为" |
| **B 写侧** | 默认（`MAX_B_OUT=4`） | 写侧 48.7 → **12.2 ms**，帧 ~24 ms / **~40 fps** | 单项最大收益 |
| C 长 burst | B + `MAXB=64, DEPTH=256` | 读侧 AR 39,000 → ~10,500 条，帧 ~20 ms | +6 RAM 块，需确认 BRAM 推断 |
| D 读并发 | C + `MAX_RD_INFLIGHT=2` | 读侧再 ÷2，帧 ~17 ms / 算力封顶 | 最后一步 |

> 注意：**C 档必须同时改 DEPTH**（`MAXB=64, DEPTH=64` 会被 `MAXB_E` 钳到 32，等于白改）。

---

## 4. 写侧吞吐理论（你问的 N=4/6/8）

`拍/beat = max(3, B_latency/N)`，其中 3 = `W_IDLE→W_ADDR→W_DATA` 的状态拍数（**cnn_clk 域**），
`B_latency=13` 是 AXI 侧（100 MHz）实测写响应延迟 ⇒ 折成 cnn_clk 为 **19.3 拍**。

| N | AXI 拍/beat | cnn_clk 拍/beat | 374,400 beat 的写时间 | 相对今天 |
|---|---|---|---|---|
| 1（原版） | max(2.02, 13) = **13** | 19.3 | **48.7 ms** ← 与实测 49.1 ms 吻合 | 1.0× |
| 2 | max(2.02, 6.5) = 6.5 | 9.65 | 24.3 ms | 2.0× |
| **4（默认）** | max(2.02, 3.25) = 3.25 | **4.83** | **12.2 ms** | 4.0× |
| 6 | max(2.02, 2.17) = 2.17 | 3.22 | 8.1 ms | 6.0× |
| 8 | max(2.02, 1.63) = **2.02** | 3.00 | 7.6 ms | 6.4× |

**⇒ 上板建议先试 4，再试 6；8 已经没有意义**（N≥7 后 FSM 的 3 拍成为瓶颈，再多的在飞笔数不加速）。
前提是 DDR 桥支持同 ID 多笔未回——AXI 规范允许 16，但 `axi_shared_ddr_2m` 的实际接受深度未核实，**这是 N=6 上板前必须确认的风险点**。

### 4b. 读侧收益模型（决定 C/D 两档值不值得做）

一帧读 547,200 beat，AXI 侧地板 812k cnn 拍（6.4%）+ 每条 burst 暴露一次往返。设暴露延迟
`L_r ≈ 100 cnn 拍`（AR 过 CDC + DDR 仲裁 + R 过 CDC，`02_rowpipe_datapath.md` §7.3 的推算值）：

| 配置 | AR 条数/帧 | 读侧拍数 | 读时间 | 说明 |
|---|---|---|---|---|
| MAXB=16, K=1（**默认**） | **39,000** | 3.90M + 0.81M = 4.71M | **31.7 ms** | = 今天的行为 |
| MAXB=16, K=2 | 19,500 | 1.95M + 0.81M = 2.76M | 18.6 ms | 只加并发，不加长 burst |
| MAXB=64, K=1 | **8,550~10,500** | 0.86~1.05M + 0.81M | **11.2~12.5 ms** | 长 burst 是主力 |
| MAXB=64, K=2 | 4,275~5,250 | 0.43~0.53M + 0.81M | **8.3~9.0 ms** | 两者叠加 |

> AR 条数算法：`ceil(547,200 / 实际平均 burst 长度)`。理想 64 beat/burst ⇒ 8,550；被 4KB 页边界切短（平均 ~52）⇒ ~10,500。默认配置实测平均 14.03 beat/burst（39,000 条）与 §7.2 的推导一致。

### 4c. 四档的帧时预估（把 §4 与 §4b 合起来）

| 档 | 写时间 | 读时间 | 帧时预估 | fps | 备注 |
|---|---|---|---|---|---|
| A 基线 | 48.7 ms | 31.7 ms | **≈57.5 ms**（实测 57.5）| 17.4 | 两侧都坏，写侧是卡口 |
| B `MAX_B_OUT=4` | 12.2 ms | 31.7 ms | **≈40 ms** | ~25 | **写侧修好后读侧立刻接棒**（正是 wburst 只 +6% 的原因）|
| C B+`MAXB=64,DEPTH=256` | 12.2 ms | 11.2 ms | **≈20 ms** | ~50 | 两侧大致平衡，进入算力封顶区 |
| D C+`MAX_RD_INFLIGHT=2` | 12.2 ms | 8.3 ms | **≈20 ms** | ~50 | **几乎没有额外收益**：写侧 12.2 成为新卡口 |

**⇒ 强烈建议：C 档就是本轮的目标终点，D 档（多 burst 并发）收益 < 1 ms，却是风险最高的一处（仲裁器改状态机 + 两个我修掉的潜在 bug 都在这个开关上）。如果构建预算紧，D 直接不开（保持默认 1），代码留着即可。**

---

## 5. 面积（三条分开，按默认配置 / 激进配置）

### 5.1 默认配置（`DEPTH=64, MAXB=16, MAX_RD_INFLIGHT=1, MAX_B_OUT=4`）

| 模块 | FF | LUT4 | 说明 |
|---|---|---|---|
| `rowpipe_axir_arb4` | **+1** | **+5** | `ob` 在 K=1 时只剩 1 位有效（bit[2:1] 常数 0，被剪）；4 个 `ack` 是纯与门 |
| `rowpipe_rd_stream` ×2 | **−96** | **+12** | −49 FF/流（`want_addr 32` + `want_len 8` + `cur_len1 8` + `want_r 1`）；+2 `count`、+2 `inflight`、+2 `bursts_out`、+1 `want_d`、+2 `IDXW` 相关；LUT 主要是 `want` 的门限比较和小位宽加减 |
| `rowpipe_wr_engine` | **+10** | **+15** | `b_out` 3→4（+1）、`vq` 4、`vq_wp/rp` 6、去掉 `b_virt_flag`（−1）；LUT 是 `b_pend` 加法 + `vq` 写译码 + `vq_rp` 读 mux |
| 顶层 | 0 | 0 | 只有 2 根 wire |
| **合计** | **≈ −85 FF** | **≈ +32 LUT4** | **≈ 净减 50 XLR；RAM 244/256 不变** |

> 结论：**`MAX_B_OUT=4` 这一档在当前 98.33%（1,013 XLR 余量）下是"净腾出空间"**，不会把 PnR 推过线。这是本方案在面积上最舒服的形态。

### 5.2 激进配置（`DEPTH=256, MAXB=64, MAX_RD_INFLIGHT=2`）

| 项 | 增量 | 说明 |
|---|---|---|
| FF | **+8** | `wr_idx/rd_idx` 6→8 位（+4/流） |
| LUT4 | **≈ +15** | `MAXB=64` 让 `bst_beats` 比较位宽增大、`bursts_out<2` 比较、`ar_more` 的 `wv[sel]` mux |
| **RAM** | **+6 块** | `mem` 8,192 bit → 32,768 bit，每流 1 块 → 4 块（10 kbit/块），两流共 **+6** ⇒ **RAM 244 → 250/256** |

> ⚠ **RAM 只剩 6 块余量**。如果 PnR 报 RAM 不够，把 `DEPTH` 退回 128（每流 +1 块，共 +2 ⇒ 246/256），`MAXB` 同步降到 64 仍成立（`128 ≥ 2×64` 刚好卡边界，建议此时用 `MAXB=48` 更稳）。

---

## 6. 必须成立的不变式（上板验证判据）

| # | 不变式 | 怎么验 | 破了会怎样 |
|---|---|---|---|
| I1 | `b_out ≤ MAX_B_OUT` 恒成立，且不清零时不为 0 的 B 不会让它回绕 | 探针看 `b_out` 最大值；或看 `error` 是否被 `b_dup` 置位 | 回绕 ⇒ 不再发 AW ⇒ `idle` 永不成立 ⇒ driver 卡死 `S_FLUSH` |
| I2 | `acked == 发出的 W 笔数`，`acked_virt == virt 笔数`，两者都在 **B 回来时**增 | APB 侧无法直接看，探针看 `u_wr.acked` vs `u_wr.wptr-rptr` 累计 | 提前增 ⇒ `result_done` 早成立 ⇒ 下一帧读到没落盘的旧数据 |
| I3 | `b_out==0` ⟺ AXI 写通道真的排空（`idle` 的定义） | `wr_idle` 断言时看 AXI `bvalid` 应恒 0（≥3 拍） | 层末误放行 ⇒ 层间数据串味（第二帧稳定复现那类） |
| I4 | `bursts_out ≤ MAX_RD_INFLIGHT`；`flush` 只在 `inflight==0 && !want_d` 时发生 | 探针看 `flush_now` 与同一拍的 `bursts_out`/`want_d` | flush 丢掉在途 AR ⇒ 它的 beat 落进清空后的 FIFO ⇒ 换 bank 后前几列错、整幅错位 |
| I5 | `next_fetch` 严格单调递增（只有 flush 会回卷），且 `ar_ack` 每拍至多 1 次 | 探针记 `ar_ack` 次数 = AR 握手次数 | 两条在飞 AR 同地址 ⇒ 数据重复、后半图错 |
| I5b | 追加 AR **只**发生在 `pipe_en[sel]=1` 的 client（本案只有 rd0/rd1） | 探针看 `u_arb.ar_more && (sel==0 \|\| sel==3)` 恒为 0 | src/wstream 被追加同地址 AR ⇒ 读回重复数据 ⇒ L0/权重层错 |
| I6 | 每层首个读地址 = 上一层写出去的同一像素下标（`next_fetch` 与 `head_addr` 不漂移） | 比对 `u_rd0.next_fetch` 在层边界 == `hout*wout` 的累计 | 图整体平移/撕裂 |
| I7 | `count + inflight` 在 beat 落地时不变；FIFO 永不溢出 | 探针看 `count` 最大值应 < DEPTH | 覆盖未读数据 ⇒ 随机错列 |
| I8 | `vq` 的 `vq_wp - vq_rp` == `b_out`（环形队列不漂） | 探针比较两指针差与 `b_out` | `acked_virt` 偏 ⇒ I2 的 `==` 永不成立 ⇒ 卡 `S_FLUSH` |
| I9 | `MAXB_E ≥ 1` 且 `DEPTH - MAXB_E > 0`（防 `free_ok` 恒假） | 综合后看 `MAXB_E` 的常数；或直接查 RTL 参数 | 预取永不启动 ⇒ 帧级卡死 |
| I10 | `result_done` 的三个计数在同一帧内单调增到目标值 | 探针看 `res_words/res_beats/w_acked_virt` 的关系 | `S_FLUSH` 无超时 ⇒ 卡死 |

---

## 7. 上板出错时先看哪里（现象 → 第一嫌疑 → 计数器/信号）

| 现象 | 第一嫌疑 | 先看什么 |
|---|---|---|
| **整幅全黑 / 只有第一帧对** | `acked_virt` 计数错 ⇒ `result_done` 不成立 | `u_wr.b_out`、`u_wr.vq_wp`/`vq_rp` 差、`u_wr.acked_virt` 与 `res_beats`；APB `0xa8..0xb8` 若全 0 说明帧没结束 |
| **换层处撕裂/整体错位（尤其 L3/L6/L9 换 bank 后）** | I4/I5：flush 丢在途 AR | `u_rd0/bursts_out`、`u_rd0/want_d`、`u_rd0/inflight` 三者是否同时为 0 时 `flush_now` 才拉高 |
| **画面周期性错几列** | I7：FIFO 溢出 | `u_rd0/count` 峰值；若 > DEPTH-MAXB 就是容量门失效 |
| **帧率没提升反而略降** | `MAX_B_OUT` 太大被 DDR 桥限流（同 ID 未回数不支持） | profiler `B`（等 B %，现在是 counter[8]）应从 86 掉到 ~25；若反而升高 ⇒ 桥不接受多笔未回 |
| **帧率略降 + 偶发错图** | `ar_more` 追加的 AR 被桥丢弃/乱序 | profiler `RGAP`/`RBP`；探针看 `arvalid&&arready` 次数是否 == `rlast` 次数（I5 的等式） |
| **L0 的图整体重影/行重复（D 档才出现）** | I5b：src 流被追加了同地址 AR | 探针看 `u_arb.ar_more` 在 `sel==0`（src）时是否曾为 1；正常应恒 0（顶层 `pipe_en=4'b0110`） |
| **完全不启动（busy 常低）** | I9：`free_ok` 恒假 | 子模块里 `MAXB_E` 的常数（综合报告或探针看 `want` 是否恒 0） |
| **写侧没变化（仍是 ~49 ms）** | `MAX_B_OUT` 没传下去 / 被钳成 1 | 探针看 `u_wr.b_out` 是否到过 4；看 `idle` 是否在层末仍被频繁拉低 |

**推荐的三个探针（如果只能加 3 个）**：① `u_wr.b_out[3:0]`（写侧优化是否真的生效）；② `u_rd0.bursts_out[1:0]` + `u_rd0.want_d`（读并发是否真的生效、flush 是否安全）；③ `u_rd0.count[9:0]`（FIFO 深度是否够）。

---

## 8. 我没做 / 做不了的（须由构建或上板补）

1. **没综合、没仿真**：所有面积是**静态估算**（依据 `ARCHITECTURE_FULL.md:6` 的 XLR 59,132/60,800、RAM 244/256 基线 + Efinity 的 XLR=FF+LUT+carry 结构）。真值请看这次 `map.rpt` 的 `XLR / FF / LUT4 / RAM` 四行做差。
2. **`DEPTH=256` 是否仍推成 BRAM 未验证**：`mem` 的存/读分离写法（写一口 `always @(posedge clk) if(beat_valid&&beat_ready) mem[wr_idx]<=...` + 读口寄存 `cur_data<=mem[ridx_n]`）**一个字都没动**，理论上 Efinity 仍认 RAM 模板；但深度从 64 变 256 后每个实例要 4 块 10 kbit，**如果 map 报告里这几块落到 logic memory（FF），立即退回 DEPTH=64**（你会看到 FF 暴涨约 8,000×2）。
3. **`axi_shared_ddr_2m` 是否支持同 ID 多笔未回**未核实（N=6 的前提）。
4. **没有做"读侧 burst 跨 4KB"以外的合并**（写侧仍是 `awlen=0` 单 beat）：写侧这次只解决"等 B"，命令数仍是 374,400/帧。按 §4 模型，N=4 后写侧已不是瓶颈，**再合并 burst 的边际收益 < 1 ms，不建议现在做**（历史上 wburst 两帧都错，风险不成比例）。
5. **`rowpipe_src_stream` 没动**：它仍是 `MAXB=8` 单 burst（L0 的 9,600 条 AR 占全帧 25%）。要改需要动它的 4 拍展开逻辑（`beat_ready=!expanding`），风险明显大于收益，**建议放在 D 档之后单独评估**。

---

## 9. 与你那版 T1.1 的差异（一眼可 diff）

| 项 | 你 11:29 版 | 现在 |
|---|---|---|
| `MAX_B_OUT` | `localparam = 4` | **模块参数**，默认 4，钳 1..8，从顶层传入 |
| 下溢保护 | `else if (b_dec && b_out!=0)` | `b_pend = b_out+b_inc` 判 `b_dec`，同拍进出也正确；`b_dup` 单独置 error |
| virt 记账 | `b_virt_flag` 单标志 + 不一致检测 | **`vq[LIMIT-1:0]` 环形队列**，逐笔 virt |
| `acked` 在 `b_dup` 时 | 会自增（可能冲过 `res_beats`） | 只在 `b_dec` 时增，`b_dup` 不动 |
| `idle` | 含 `b_out==0` ✅ 保留 | 同 |
| FSM | 3 态（去掉 `W_RESP`）✅ 保留 | 同 |
| `bready` 常 1 ✅ | 保留 | 同 |

**其余（`pop` 在 W 握手、`b_out` 门限、层末 `idle` 语义）我一行没动**——你 11:29 那版的主体设计是对的。

---

## 10. 回退矩阵（出问题时只改一个数，不动代码）

参数都在 `rowpipe_ddr_banks:724-727`（**顶层默认值就是上板配置，`rowpipe_frame_driver` 不用改**）：

| 症状 | 改哪个参数 | 改成 | 预期回到 |
|---|---|---|---|
| 写侧效果不对 / `b_out` 异常 | `MAX_B_OUT` | **1** | 完全等价原串行写（+省 7 FF）|
| 长 burst 引起错图/桥不支持 | `MAXB` | **16**（`DEPTH` 可留 256）| 原 16-beat burst；RAM 多占但不影响功能 |
| FIFO 溢出（`count` 到顶） | `DEPTH` | **128** 或 **64** | 容量门恢复；`MAXB` 会被 `MAXB_E` 自动钳到 `DEPTH/2` |
| 多 burst 并发引起错图/重复数据 | `MAX_RD_INFLIGHT` | **1** | 仲裁器逐拍等价原版（`ar_more≡0`）|
| RAM 超限 | `DEPTH` | **64** | RAM 244/256 不变 |
| 全部回退 | 四个参数 | `64 / 16 / 1 / 4` | 只剩 posted-B 写侧优化 |

**唯一的"代码级回退"**（如果连 posted-B 都要退）：把 `MAX_B_OUT` 设 1 即可 —— FSM 已是 3 态（去掉 `W_RESP`），单笔在飞时与原来的 4 态串行**功能等价**，只是少一个状态的延迟。

## 11. 一句话交接

> 默认配置 = 今天的行为 + 写侧 posted-B（净省 ~50 XLR）。要到 50 fps 只需 **C 档一行参数**（`MAXB=64, DEPTH=256`，+6 RAM 块）。D 档留着但建议不开。上板若出问题，先看 `u_wr.b_out` 与 `u_rd0.bursts_out/want_d` 这三个信号——它们分别对应本报告的两个核心机制和两个已修的坑。
