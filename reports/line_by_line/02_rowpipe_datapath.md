# rowpipe 数据通路逐行阅读

阅读对象（**只读**，未改任何 RTL）：

| 文件 | 任务书行数 | **实际行数** | 说明 |
|---|---|---|---|
| `rtl/accel_rowpipe/rowpipe_engine.v` | 419 | **444** | 44 行差异在头部注释与 B1g 权重流注释 |
| `rtl/accel_rowpipe/rowpipe_ddr_banks.v` | 799 | **860** | 含 4 个 stream 子模块 + 2 个死代码模块 |
| `rtl/accel_rowpipe/rowpipe_frame_driver.v` | 178 | **191** | — |
| `rtl/accel_rowpipe/style_network_rowpipe.sv` | 136 | **145** | 行号引用以**实际行数**为准 |

> 所有 `file:line` 都对齐当前工作区文件（`ARCHITECTURE_FULL.md:808` 引用的行号也与当前 860 行版本吻合，说明文档行号没过期，是任务书的行数过期了）。

---

## 结论摘要（5 条）

1. **描述符解码与 Lead 给的真值完全一致**，但任务书漏了一条对带宽极其关键的位域：`srcf/dstf/idf`（描述符 `[101:100]/[103:102]/[105:104]`，`rowpipe_engine.v:72-75,92-94`）。它决定 bank 内的**存储宽度 4/8/16 B/像素**（`fmt`），也就是"几个像素挤进一个 16B beat"。`fmt` 由该层的 `cout` 决定（cout=4→4B，cout=8→8B），12 层里 `dstf` 与下一层 `srcf` 两两配对**全部自洽**（本报告 §2 有全表核对）。不看这条位域算出来的 DDR 账会错 2~4 倍。
2. **`virt`（L11 → 结果帧）通路完整条件链已核实，且唯一**：`style_network_rowpipe.v:80` 的 L11 `dstb=2` → `apply_desc` 取 `d[96:95]` → 引擎 `mem_wr_bank=2`（`rowpipe_engine.v:224`）→ `rowpipe_ddr_banks.v:747` 的 `virt=(wr_bank==2'd2)&&(cur_layer==4'd11)`。12 层里写 bank2 的有 L2/L5/L8/L11（`cur_layer` 分别为 2/5/8/11），只有 11 命中。**但这是隐式约定**：它依赖"只有最后一层会写 bank2"，任何 bank 重分配都会让它静默失效（结果帧写不进去 → 屏幕全黑），建议加显式 `is_last` 位。顺带：`virt` 通路的地址是 `result_address + wr_addr>>2 * 16`，**完全不用 `bank_base2`**，所以文档"BANK2 = 中间层 + L11 输出"是错的。
3. **一帧的 DDR 事务账（本报告 §7 有逐层表）：读 547,200 beat / 39,000 条 AR（8.76 MB）+ 写 374,400 beat / 374,400 条 AW+W+B（5.99 MB）**。payload 14.75 MB × 17.4 fps = **257 MB/s**，与实测"有效带宽 0.26 GB/s"逐位吻合 ⇒ 那个 0.26 GB/s 不是带宽上限，是"事务量 × 帧率"的结果，本身没有信息量。真正该看的是**每 beat 摊到 9.3 个 148.5 MHz 拍**（payload 地板是 1.485 拍/beat，因为 AXI 跑 100 MHz 而引擎跑 148.5 MHz），即 **6.3 倍事务开销**。
4. **读写两侧同时是延迟瓶颈，只修一侧拿不到收益**（这是本轮最有用的结论，且被历史实验证明）。写侧：单 beat + 逐 beat 等 B（`rowpipe_ddr_banks.v:491-501`），374,400 beat/帧 × ~13 拍/beat = 4.9 M 拍 = **49.1 ms @100 MHz**，与"等 B"的 profiler 计数器定义精确对应（§7.4）。读侧：`want_r` 单标志把并发限成**同时只有 1 个 burst 在飞**（`:251-257`），每 16 beat 暴露一次 AR→首拍往返。**决定性证据**：历史 `wburst-18.5fps` 分支只把写侧改好（写命令 451,250→90,250，5 倍），**帧率只涨 6%**——因为写侧一修好，读侧（约 40 ms 量级）立刻变成新瓶颈，两边差不多坏。⇒ **必须两侧都改才有复合收益**；先改读侧是因为它风险最低（只动 `want_r`/`free_ok`/`MAXB` 参数与并发计数，不碰数据打包）。
5. **发现 3 类真实隐患**（区分事实/推测见 §8）：① `wr_ready` 在 `beat_push` 那一拍**跳过 `wr_p_ready` 检查**（`:768` vs `:762`），当前靠"count 两拍不变"的隐含假设才不丢 beat，属脆弱设计；② 打包器（`pk_acc`）的残留像素**不计入 `wr_idle`**，层切换只看 `mem_wr_idle` ⇒ 若某层 `hout*wout` 不是 `2^fmt` 的整数倍，最后 1~3 个像素会被推到**下一层的 bank/地址**（当前 12 层全整除，属未触发的潜在 bug）；③ 两处**无超时挂死点**：引擎 `S_WAITPIX`（`rowpipe_engine.v:418`）与 driver `S_FLUSH`（`rowpipe_frame_driver.v:183`），只要 `result_pixels` 与实际输出像素数不一致就永久卡住。

---

## 12 层描述符全表（解码后的真值）

### 2.1 位域定义（**唯一权威源：`rowpipe_engine.v:96-118` + `style_network_rowpipe.sv:66-76`**）

```
[15:0] ci   [31:16] cout   [47:32] win   [63:48] hout   [79:64] wout
[87:80] ng  [88] res  [89] resu  [90] xorin  [91] s2  [92] up
[94:93] srcb  [96:95] dstb  [98:97] idb  [99] idxor
[101:100] src_fmt  [103:102] dst_fmt  [105:104] id_fmt
[127:106] 恒 0（22 位）
```

`mk()` 的实参顺序是 `(ci,cout,win,hout,wout,ng, res,resu,xorin,s2,up, srcb,dstb,idb, idxor, srcf,dstf,idf)`，而拼接写成从高到低的**逆序**（`style_network_rowpipe.sv:73-74`）：`{22'd0, idf,dstf,srcf, idxor,idb,dstb,srcb, up,s2,xorin,resu,res, ng,wout,hout,win,cout,ci}`。**核对结论：逆序正确，无位错位。** 这是本工程最容易被"看反"的一段代码，改描述符前必须两处一起改。

### 2.2 逐层真值表

| 层 | ci | cout | win | hout×wout | ng | res | resu | xorin | s2 | up | srcb | dstb | idb | idxor | srcf | dstf | idf |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| L0 | 3 | 4 | 640 | 480×640 | 40 | 0 | 1 | 1 | 0 | 0 | **3**(源帧) | 0 | 0 | 0 | 0 | **2** | 0 |
| L1 | 4 | 8 | 640 | 240×320 | 40 | 0 | 1 | 1 | **1** | 0 | 0 | 1 | 0 | 0 | **2** | 1 | 0 |
| L2 | 8 | 8 | 320 | 120×160 | 20 | 0 | 1 | 1 | **1** | 0 | 1 | 2 | 0 | 0 | 1 | 1 | 0 |
| L3 | 8 | 8 | 160 | 120×160 | 10 | 0 | 1 | 1 | 0 | 0 | 2 | 0 | 0 | 0 | 1 | 1 | 0 |
| L4 | 8 | 8 | 160 | 120×160 | 10 | **1** | 1 | 1 | 0 | 0 | 0 | 1 | **2** | **1** | 1 | 1 | 1 |
| L5 | 8 | 8 | 160 | 120×160 | 10 | 0 | 1 | 1 | 0 | 0 | 1 | 2 | 0 | 0 | 1 | 1 | 0 |
| L6 | 8 | 8 | 160 | 120×160 | 10 | **1** | **0** | 1 | 0 | 0 | 2 | 0 | **1** | 0 | 1 | 1 | 1 |
| L7 | 8 | 8 | 160 | 120×160 | 10 | 0 | 1 | 1 | 0 | 0 | 0 | 1 | 0 | 0 | 1 | 1 | 0 |
| L8 | 8 | 8 | 160 | 120×160 | 10 | **1** | **0** | 1 | 0 | 0 | 1 | 2 | **2** | 0 | 1 | 1 | 1 |
| L9 | 8 | 8 | 320 | 240×320 | 20 | 0 | 1 | 1 | 0 | **1** | 2 | 0 | 0 | 0 | 1 | 1 | 0 |
| L10 | 8 | 4 | 640 | 480×640 | 40 | 0 | 1 | 1 | 0 | **1** | 0 | 1 | 0 | 0 | 1 | **2** | 0 |
| L11 | 4 | 3 | 640 | 480×640 | 40 | 0 | 1 | 1 | 0 | 0 | 1 | **2** | 0 | 0 | **2** | 0 | 0 |

（`L11.dstb=2` + `cur_layer==11` 触发 `virt`；`L11.dstf=0` 在 `virt` 下被 `pf=2'd2` 覆盖，见 `rowpipe_ddr_banks.v:748`。）

### 2.3 bank 读写链 + 存储宽度一致性核对（**这是最容易出错、也最值钱的一张表**）

| 层 | 读自 | 读宽度 | 该 bank 上一写入者 | 写宽度 | 写到 | 核对 |
|---|---|---|---|---|---|---|
| L0 | 源帧 slot（bank3 通路） | 4 B/px（DDR） | frame_store | 4 B/px | BANK0 | ✅ `dstf=2` ↔ `L1.srcf=2` |
| L1 | BANK0 | 4 B/px | L0 | 8 B/px | BANK1 | ✅ `dstf=1` ↔ `L2.srcf=1` |
| L2 | BANK1 | 8 B/px | L1 | 8 B/px | BANK2 | ✅ ↔ `L3.srcf=1` |
| L3 | BANK2 | 8 B/px | L2 | 8 B/px | BANK0 | ✅ ↔ `L4.srcf=1` |
| L4 | BANK0 (+id BANK2) | 8/8 B/px | L3（id 来自 L2） | 8 B/px | BANK1 | ✅ |
| L5 | BANK1 | 8 B/px | L4 | 8 B/px | BANK2 | ✅ |
| L6 | BANK2 (+id BANK1) | 8/8 B/px | L5（id 来自 L5） | 8 B/px | BANK0 | ✅ |
| L7 | BANK0 | 8 B/px | L6 | 8 B/px | BANK1 | ✅ |
| L8 | BANK1 (+id **BANK2**) | 8/8 B/px | L7（id 来自 L5） | 8 B/px | **BANK2** | ✅ 但同 bank 读写，见 §8-⑧ |
| L9 | BANK2 | 8 B/px | L8 | 8 B/px | BANK0 | ✅ |
| L10 | BANK0 | 8 B/px | L9 | 4 B/px | BANK1 | ✅ ↔ `L11.srcf=2` |
| L11 | BANK1 | 4 B/px | L10 | **4 B/px XBGR → 结果帧** | 结果帧 | ✅ `virt` |

要点：
- `fmt` 与 `cout` 严格对应：`cout=4 → 4 B/px`、`cout=8 → 8 B/px`。**中间 bank 里没有一层真的按 16 B/px 存**：13 个格式位里 `dstf=0` 只出现在 L11，而 L11 被 `virt` 覆盖成"4 B/px 打 XBGR"；`srcf=0` 只出现在 L0，而 L0 走源帧流（`rd0_bank==3`，格式位被忽略，源帧固定 4 B/px）。⇒ **每个存储像素只写 `cout` 个字节，不做 16 字节对齐浪费**，这是 B1j "紧凑化"的实质，也是 §7 带宽账必须按 4/8 B 而 not 16 B 算的原因。
- 残差源不是"上一层的输出"，而是"**两层前写到该 bank 的那一层**"：L4←L2、L6←L5、L8←L5。与模型拓扑的 skip 连接必须一致，属于**需要模型侧确认**的点（板上能出图，暂判一致）。
- `resu/idxor` 的组合语义（**两位编码 3 种净语义，注释里没写**）：`i_id` 在引擎里被 `idxor` 预异或（`rowpipe_engine.v:206`），在层里又被 `cfg_resu` 异或+零扩展或符号扩展（`rowpipe_layer.v:964-965`）：
  - `(idxor=1,resu=1)`（L4）→ 两次异或**抵消**，净效果 = bank 原样字节**零扩展**（无符号 0..255）；
  - `(idxor=0,resu=1)`（未出现的组合）→ 单次 `^0x80` + 零扩展；
  - `(idxor=0,resu=0)`（L6/L8）→ **符号扩展**（int8）。
  即 L4 走无符号残差、L6/L8 走有符号残差。**L4 的双 XOR 是刻意的，不是 bug**，但这段代码没有任何注释说明这个组合表，属高危可读性缺陷；文档 §3.1 把 L4/L6/L8 都标成"残差 + idxor"是**错的**（只有 L4 的 idxor=1）。

---

## rtl/accel_rowpipe/rowpipe_engine.v（444 行）

### 职责与契约

- **职责**：把 `rowpipe_layer`（单层 3×3 卷积累加 + requant 核）时分复用 12 次，L0→L11 串行跑完整网；对外只给"bank 号 + 像素下标"，不给字节地址（`rowpipe_engine.v:46-47`）。地址全部用计数器生成，**运行期无除法/取模**（`:6-12` 的两条可综合化要求在 `:153-188` 落实）。
- **输入契约**：
  - `start`：单拍（driver 在 `S_IDLE` 打一拍 `eng_start`）。**`S_DONE` 也接受 `start`**（`:423-431` 的修复，旧版第二帧的 start 被吞）。
  - `descs`：12×128 位，组合输入，随时可读；引擎只在 `apply_desc` 时锁存当前层（`:105-118`）。
  - `mem_rd_avail0/1`：后端"这一拍数据有效"。引擎的 `data_ok`（`:201-202`）就是 `s_vld`，**没有任何超时**：后端不供数就永久等。
  - `mem_wr_ready`：后端写 FIFO 能收（= 层的 `o_ready`，直接连到 `u_layer`）。
  - `mem_wr_idle`：后端写通道已排空（层末同步用，`:65-67` 的注释解释了为什么必须有）。
- **输出契约**：`done` 是**电平**（保持到下次 start），`cur_layer`(=L) 电平。`w_timeout` 粘滞到帧首清。
- **消费者**：全部唯一消费者是 `rowpipe_frame_driver`（`rowpipe_frame_driver.v:108-128`）；`done` 再被 driver 转成 `S_DONE`，`cur_layer` 直通给 `rowpipe_ddr_banks` 当 `virt` 判据——**这条线是 L11→结果帧的唯一通路，断一下屏幕就黑**。

### 端口清单

| 端口 | 方向 | 位宽 | 域 | 语义 |
|---|---|---|---|---|
| `clk / rst_n` | in | 1 | **cnn_clk = vid_clk_dvi2 = 148.5 MHz** | 见 §7.1 时钟说明（不是 100 MHz） |
| `start` | in | 1 | 同上 | 单拍启动（S_IDLE 或 S_DONE 均接受） |
| `rom_layer/rom_addr` | out | 4/8 | 同上 | 行为 ROM 地址；B1g 模式下权重走 DDR blob，**这对口实际悬空**（`style_network_rowpipe.sv:94-102,144` 全 0） |
| `rom_w/b/m/mid/shift/qlo/qhi` | in | 128/32/32/32/6/8/8 | 同上 | 同上，**恒 0**（TB 专用） |
| `w_req_en` | out | 1 | 同上 | 本拍要一个权重 beat（仅在真正等/消费 beat 的拍拉高，`:278-287`） |
| `w_req_addr` | out | 20 | 同上 | **blob 内的 16B beat 序号（组合当前值）**，`:270-277` 说明了为什么必须是组合 |
| `w_req_ack` | out | 1 | 同上 | `= w_need_beat && w_avail`（同拍 valid/ack，不是 ready/valid） |
| `w_avail` / `w_data` | in | 1/128 | 同上 | DDR 权重流返回 |
| `w_timeout` | out | 1 | 同上 | 本帧权重流超时（粘滞；`S_IDLE`/`S_DONE` 的 start 清） |
| `mem_rd_bank0/addr0/en0/avail0/data0/ack0` | out/out/out/in/in/out | 2/20/1/1/128/1 | 同上 | 主读口。`addr0` 是**像素下标**，后端乘 16；`en0=in_range`；`ack0=s_ack&&in_range` |
| `mem_rd_bank1/addr1/en1/avail1/data1/ack1` | 同上 | 同上 | 同上 | 残差恒等支读口，只在 `res` 层用，地址恒 `ptr` |
| `mem_wr_bank/addr/data/we` | out | 2/20/128/1 | 同上 | 写口；`we = o_vld && o_pix_done && mem_wr_ready` |
| `mem_wr_ready` | in | 1 | 同上 | 后端能收（同时是层的 `o_ready`） |
| `mem_wr_idle` | in | 1 | 同上 | 后端写通道排空 |
| `descs` | in | 1536 | 组合 | 12×128 |
| `src_fmt/dst_fmt/id_fmt` | out | 2/2/2 | 同上 | 组合取自 `dcur`，直通给 banks 当读写宽度 |
| `done` | out | 1 | 同上 | **电平**，保持到下次 start |
| `cur_layer` | out | 4 | 同上 | = `L` |

### 内部结构（FSM）

`rowpipe_engine.v:233-235` 12 个状态：

| 状态 | 转移条件 | 用途 |
|---|---|---|
| `S_IDLE` | `start`→`S_LRST`（并 `apply_desc(0)`、`cnt_clr`、清 `w_to`） | 帧首 |
| `S_LRST` | 计 4 拍（`i>=4`）→ `S_CFG`（并预置 cfg0=win） | 层核异步复位保持 4 拍 |
| `S_CFG` | `cfg_i` 0..9 逐拍写 → 第 10 拍转 `S_W` | 10 条配置（win/ng/hout/wout/res/resu/ci/cout/s2/skiplen） |
| `S_W` | `k>=ci*9`→`S_B`；否则 `w_avail` 才 `k++` | 权重逐 beat 装（1 beat = 一行 16 通道权重） |
| `S_B` | `k>=4`→`S_M`；`ph=0` 等 beat；`ph=1` 拆 4×32 位 | bias 表 4 条（每 beat 拆 4 个 32 位） |
| `S_M` | `k>=8`→`S_Q`；`ph=1` 拆 2×(M,mid) | M/mid 表 16 条（每 beat 拆出 2 组 64 位） |
| `S_Q` | `ph=1` 后转 `S_PRE` | 量化头（shift/qlo/qhi） |
| `S_PRE` | `i >= win+18`→`S_GRP`；否则发一条 skip 命令（3 相握 ph0/1/2） | **PREPUSH：推 win+18 列填充窗口**（18 = 3×3 窗口的竖向 halo） |
| `S_GRP` | `y>=hout`→`S_WAITPIX`；否则发 `grp_vld`，等 `o_st` 回 0，`g` 计到 `ng-1` 后：最后一行 `y++`；否则 `s2`→`S_RPAD`、非 s2→`y++` | 逐组（16 列/组）推进 |
| `S_RPAD` | 一条 `skip_vld`（层内已改成 `skiplen=win` 的突发），回 `S_GRP` 并 `y++` | s2 层**整行空跑**（输出行 y 与 y+1 之间要跳过一整条输入行） |
| `S_WAITPIX` | `pix >= out_total_r && mem_wr_idle`：`L==11`→`S_DONE`；否则 `L++`、`apply_desc(L+1)`、回 `S_LRST` | 层末同步（**无超时**） |
| `S_DONE` | `start`→重跑 L0（与 IDLE 同流程）；否则保持 `done=1` | 帧尾 |

**超时/错误路径只有一条**（`:435-442`）：`w_need_beat && !w_avail` 连续 65,535 拍 ⇒ `w_to=1, done=1, st=S_DONE`。`w_to` 由帧首清。其余路径（读数据不来、写不排空）**都没有超时**。

### 逐行要点

**A. 头部与可综合化（1-79）**
- `:6-12` 说明三处"可综合化"：输入地址（普通层 `ptr`、上采样 `src_base+ix/2`）、输出地址（`pix` 顺序）、恒等支地址（`ptr`）。`:13-14` 说明帧缓冲已移出模块、bank 变成 2 读 1 写端口 —— 这是本模块到 `rowpipe_ddr_banks` 的接口由来。
- 端口注释 `:46-47` 明确"地址是像素下标不是字节，后端自己乘 16"，`640×480=307200 ⇒ 19 位够，留 1 位`（所以全是 20 位宽，这是 20 的来源）。
- `:65-67` 的 `mem_wr_idle` 注释记录了"第二帧稳定复现"的踩坑：层末不等写通道排空，下一层的读会读到还没落盘的旧数据。**这段注释可信度高，与 §8-② 的残留像素问题互补**。

**B. 层参数与描述符（80-118）**
- `:84-85`：`in_total_r` 为什么要**寄存**而不是现算——"留在数据路径上是个乘法器，会顶到 window 的 CE 路径（实测 145.4 MHz）"。这是本工程时序约束最紧的一处证据。
- `:88` 把 12 个字段全声明成 `integer`（32 位有符号）。位域赋值会自动零扩展，安全；但 `ng-1`、`wout-1` 这类比较全在 32 位域里做。
- `:89` `srcW = up ? (win/2) : win` —— 上采样层源行的"逻辑宽度"是 `win/2`（因为每个源像素被用两次），`win` 是 2 的幂/偶数，`/2` 综合成移位。
- `:91-94` `dcur` 是**组合选通**（`descs[{L,7'b0} +: 128]`），`src_fmt/dst_fmt/id_fmt` 直接从 `dcur` 取 ⇒ 换层那一拍 fmt 立刻变。**这里有个隐含时序要求**：banks 的 `fmt` 也是组合用的，层切换时读流必须已经 flush 到新 bank（靠 `need_restart` 的 bank 比较，见 §5-B），否则会用新 fmt 解析旧 bank 的残留 beat。
- `:100-103` `dsel` 用 `{l,7'b0}` 做变址 —— 12 个 128 位描述符的 2 选 1 树，属正常写法。
- `:105-118` `apply_desc`：**全部非阻塞赋值**，且 `in_total_r/out_total_r` 在这里算（`:115-116`），`in_total_r = (s2?4:1)*hout*wout` —— 这个 4 就是"stride-2 层一个输出像素吃 4 个输入像素（2 行 × 2 列）"。
- `:110-114` 位域与 §2.1 完全一致，**已逐位核对无误**。

**C. 层核与地址计数器（120-188）**
- `:138` `rowpipe_layer #(.CI(16),.CIW(8),.PIX(16),.CO(16),.COUT(16))`：输入通道上限 16、窗口只装 8 通道（ci_tiles=2，为省 FF）、空间并行 16 像素、输出通道上限 16。**CIW=8 意味着 ci=16 的层要重读行缓冲分两遍算**（当前最大 ci=8，故不触发）。
- `:164-188` 双计数器组：
  - 输入侧：`s_ack` 时 `ptr++`；`ix==win-1` 换行 + 上采样时 `iy[0]` 为 1 才推进 `src_base`（每 2 个输出行换 1 个源行）。
  - 输出侧：`o_vld && o_pix_done && mem_wr_ready` 时 `pix++`；`ox==wout-1` 换行 + `s2 && oy[0]` 时 `dst_base += wout/2`。
  - **注意 `pix` 的推进条件带 `mem_wr_ready`**：写通道堵住时输出计数器也停，`S_WAITPIX` 依赖的 `pix` 与写 FSM 同拍，这个设计是对的（不会提前宣布层末）。
  - `dst_base` 在 B1f 之后其实**已成死变量**（`:218-219` 注释："s2 层自己就只出 1/4 的像素，不再靠算 4 倍只写偶偶"），写地址恒为 `pix`。**这是一处遗留垃圾代码**（`dst_base`/`src_base` 只有 `src_base` 还在上采样支路用）。
- `:191` `src_addr = up ? (src_base + ix[19:1]) : ptr[19:0]` —— `ix/2` 用 `ix[19:1]`，即上采样时**同一源列被连续读两次**。这是 §5-B 里 `replay` 影子寄存器的存在理由。
- `:192-195` 关键注释：s2 层的输入是 2×hout × 2×wout 的全分辨率图，总量 `4*hout*wout`；**尾部多读 18 列被竖 halo 丢掉**。这解释了 `S_PRE` 的 `win+18`。
- `:196-197` `src_word`/`id_word`：越界（`ptr >= in_total_r`）时 `src_word=0`、`id_word={16{8'h80}}`（**偏移码的零值 = 0x80**，与 §2.3 的偏移域约定一致）。
- `:198-202` 极重要的死锁修复注释：越界那 82 拍的尾部填充必须算"有效消费"，否则 `s_vld` 跟着后端走会让 pix 卡 4014。`data_ok` 的写法（`:201-202`）就是：**越界时无条件 `data_ok=1`**；`res` 层在有界时还要等 `mem_rd_avail1`。
- `:204-207` `xorin`/`idxor` 各 XOR `{16{8'h80}}`（16 个通道整字异或）。**12 层全部 `xorin=1`** ⇒ bank 内一律存"偏移码 `q^0x80`" ⇒ **显示端必须再 XOR 一次**（`style_display.sv:107` 只对风格侧 XOR）。两端成对，改一端全反相。
- `:209-216` 读口：`mem_rd_en0 = in_range`（不是 `data_ok`），`mem_rd_ack0 = s_ack && in_range`；id 口地址恒 `ptr`、`en1 = res && in_range`。注意 **`en0` 与 `avail0` 是两回事**：`en0` 是"这一拍我要这个地址"，`avail0` 是"后端说数据已就位"，`data_ok` 是二者的与。
- `:218-228` 写口：`out_word = (cout>8) ? {o_col[127:64], lo_col[63:0]} : o_col` —— 因为层核的 MAC 阵列固定 8 通道（`rowpipe_layer.v:97-101`），`cout>8` 时一个像素分两拍出，**低 8 通道在上一拍被 `lo_col` 抓住**（`:228`）。当前 12 层 cout ≤ 8，**这条分支从未生效**。

**D. FSM 主体（293-433）**
- `:297` 每拍默认清 `grp_vld/skip_vld/cfg_we/ld_*/cnt_clr`，同拍后面的非阻塞赋值覆盖（"最后写赢"），是标准写法。
- `:306-310` `S_LRST` 用**阻塞赋值** `i = i + 1`，且 `i` 这个 integer 被 `S_PRE`/`S_GRP`/`S_DONE` 复用。功能上能跑，但**同一 always 里混用阻塞/非阻塞 + 多状态共享计数器**，是可读性/维护风险。
- `:308-309` 进入 `S_CFG` 时已经预置 `cfg_addr=0/cfg_data=win/cfg_we=1`，然后 `:315` 的 `cfg_i=0` 分支又写一次同样的 `cfg0=win` ⇒ **配置 0 被写两次**（无害，多 1 拍）。
- `:314-325` 10 条配置，`:323-324` 是 B1f 新加的 `CFG_S2`（8）与 `CFG_SKIP`（9，默认 1）。
- `:331-337` `S_W`: `k<ci*9` → 每个 `w_avail` 写一行权重 `ld_waddr=k`。**beat 内 16 通道 8 位**，`ci*9` 行 = 3×3×ci 权重。
- `:338-349` `S_B`：先锁 1 个 beat（`ph=0`），再用 4 拍拆成 4 条 32 位 bias（`ld_baddr = k*4+uc`）。`:342-347` 的 ph 握手是"一个 beat 拆多条目"的模板。
- `:350-362` `S_M`：每 beat 拆 2 条 64 位（低 32 = M、高 32 = mid），共 8 beat → 16 条。
- `:363-370` `S_Q`：1 beat 取 `shift[5:0]/qlo[13:6]/qhi[21:14]`，**注意 qlo 是 `signed [7:0]` 但这里直接接 `whold[13:6]`（无符号切片给有符号口）——宽度一致，位模式直传，行为正确**。
- `:371-386` `S_PRE` 三阶段握手：`ph=0` 在 `o_st==0` 时发 `skip_vld`；`ph=1` 等 `o_st!=0`；`ph=2` 等 `o_st==0` 再 `i++`。这是"命令两步等"的固件式握手，**每条 skip 至少 3 拍** ⇒ PREPUSH 的 `win+18`（640 层 = 658 条）≈ 2000 拍/层，12 层 ≈ 24k 拍 ≈ 0.16 ms/帧（可忽略，但它是**每帧固定开销**，层数多时会累）。
- `:377` s2 层在 PREPUSH 后把 `skiplen` 改成 `win` ⇒ `S_RPAD` 一条命令消费一整行（vs 640 条单列 skip）。**这是 16 倍命令压缩，说明作者已经意识到 skip 命令开销**。
- `:387-407` `S_GRP`：`g` 计到 `ng-1` 后推进 `y`；`:399` 最后一行不做 skip（`y<=y+1` 即可越界退出）—— 边界处理正确。
- `:409-417` `S_RPAD`：与 `S_PRE` 同款握手，成功后 `y++` 回 `S_GRP`。
- `:418-422` `S_WAITPIX`：`(pix >= out_total_r) && mem_wr_idle`。**两个条件缺一不可**：`pix` 证明像素都出了，`mem_wr_idle` 证明都落盘了。**但 `mem_wr_idle` 不含打包器残留（§8-②），也没有超时。**
- `:423-431` `S_DONE` 接受 `start`（修复"第二帧 start 被吞"）。`:430` `else done <= 1` 让 `done` 保持电平。
- `:435-442` 超时逻辑放在 `case` **之后**，用"后写覆盖"抢占状态转移（`:439-440` 直接把 `st` 打回 `S_DONE`）。**这意味着超时那一拍不管 FSM 在干什么都会被中断**，包括正在写 `S_DONE` 的合法路径 —— 因为 `w_need_beat` 只在 `S_W/S_B/S_M/S_Q` 的特定拍为 1，实际不会误触发。

### 风险与疑点

| # | 位置 | 问题 | 置信度 |
|---|---|---|---|
| E1 | `:418` | `S_WAITPIX` 无超时。若 `out_total_r`（=hout*wout）与实际输出像素数不一致（firmware 传错 geometry / 描述符写错），帧**永久卡死**，且 `done` 永不置位 ⇒ 上层 style_accel 永远 `pending`（看门狗靠 APB 读状态才发现）。同理 `:183` 的 `S_FLUSH`。 | **事实**（代码如此）；触发概率低（geometry 硬编码 640×480） |
| E2 | `:184` | 写地址恒 `pix`，`dst_base` 已成死变量；`src_base` 只在上采样支路用。死代码，易误导 | 事实 |
| E3 | `:307` | 同一 always 里混用阻塞赋值 + `integer` 计数器跨状态复用 | 事实（风格问题） |
| E4 | `:315` | `cfg0` 写两次 | 事实（无害） |
| E5 | `:89,175` | `srcW = win/2` 依赖 `win` 为偶数；描述符若给奇数 `win`，上采样行的基址会错半列（当前 win 全为偶数/2 的幂） | 推测（未触发） |
| E6 | `:201-202` | `data_ok` 对 `res` 层要求 id 口 `avail`，两个读流**必须同拍就绪**；若两条流（不同 bank、不同 burst 相位）错拍，`s_vld` 会抖，而层的 `adv` 依赖 `s_vld`（`rowpipe_layer.v:36-41` 的契约）——错拍可能导致窗口错位。实践中两流共用 `ptr` 且都在 `replay/cur_valid` 保护下，暂未暴露 | 推测（需波形确认；风险中） |

---

## rtl/accel_rowpipe/rowpipe_ddr_banks.v（860 行）

本文件 = **1 个 AR 仲裁器 + 3 个顺序读/写流 + 1 个权重直通流 + 2 个死代码模块 + 顶层**。逐个子模块看。

### 5.1 `rowpipe_axir_arb4`（35-117）：4 选 1、burst 粒度、单 AR 在飞

**职责**：把源帧流、rd0、rd1、权重流 4 个客户端的 AR 请求合成一条 AXI AR 通道。

逐行：
- `:66` 三态 `A_IDLE/A_AR/A_R`。
- `:71-77` `p0..p3` = 以 `last`（上次服务的客户）为起点的轮转顺序，`last=3`（复位值）表示"从 0 开始"。
- `:81-88` 优先级：按 `p0→p3` 顺序找第一个 `w` 为 1 的客户。**这是一种"round-robin 优先级"**，既公平又无饿死。
- `:90-97` 输出：`araddr/arlen` 由 `sel` 组合选出；`arvalid=(ast==A_AR)`；**`rready=(ast==A_R)&&brv[sel]`** —— 只有当前客户能收 beat。
- `:99-102` `bv0..3 = (ast==A_R)&&(sel==i)&&rvalid`：beat 总线是**组合**的（`bv` 与 `rdata` 同拍有效），客户端必须在同一拍落盘。`:33` 的注释说明了这个约定。
- `:108-115`：
  - `A_IDLE`：`pick_v` ⇒ `sel<=pick; A_AR`。
  - `A_AR`：`arready` ⇒ `A_R`。
  - `A_R`：`rvalid && rready && rlast` ⇒ `last<=sel; A_IDLE`。
  - **⇒ 一个 burst 期间 `sel` 锁死，不允许插入其它 AR。**

**关键量化**：AR 通道的利用率 = `nAR × (burst_beats + 2 + 首拍延迟)`。burst 结束后必须回 `A_IDLE` 再 `A_AR`，**固定 2 拍空转/次**，39,000 次 = 78,000 拍 = 0.5 ms（可忽略）；但每次 burst 的**首拍延迟**（AR 过 CDC + DRAM 仲裁 + R 过 CDC）无法被其它客户的 burst 掩盖，因为**同时只有一个 AR/burst 在飞**。这是 §7 的核心结论。

**疑点**：`rready` 无条件依赖 `brv[sel]`；`brv[sel]` 恒 1（4 个客户的 `beat_ready` 分别是 `1'b1`、`1'b1`、`1'b1`、`wstream.take`），所以只要 `wstream` 的 `take` 不成立就会挂住整条 R 通道（见 §5.5）。

### 5.2 `rowpipe_rd_stream`（122-267）：中间 bank 的顺序读流（**带宽主嫌疑**）

**职责**：引擎给"bank + 像素下标"，这里按 beat 顺序预取、按像素交付。参数 `DEPTH=64`、`MAXB=16`（`:122-125`）。

逐行要点：
- `:145` `IDXW=6`（64 深，故 6 位）。`:146-157` 状态：`wr_idx/rd_idx/count/head_addr/next_fetch/inflight/cur_len1/cur_data/cur_addr/cur_valid/cur_bank/want_r`。
- **`:159-168` replay 影子**（B1h 修复）：上采样层 `src_addr=src_base+ix/2` 会让同一列读两遍，旧判据第二次判"回头"就 flush 预取（实测 L10 单层 2081 次，帧级读饿死 +35% 拍数）。修法：保留最后弹掉的那一拍 `last_addr/last_data`，同地址直接影子重放，**不 pop、不 flush**。`replay = last_valid && (req_addr==last_addr) && (req_bank==cur_bank)`。⇒ **这是本文件里最值钱的一条性能修复**，也是理解 up 层读放大的关键。
- `:172-175` `req_beat = req_addr >> fmt`（像素→beat），`pix_last`：fmt0 恒 1；fmt1 看 `req_addr[0]`；fmt2 看 `req_addr[1:0]==3`。**pop 必须等一个 beat 的所有像素都被消费完**（`:199-201`）。
- `:177-189` `exp_w` 展开：把 beat 里本像素的槽零扩展到 128 位（fmt1 取 64 位半区、fmt2 取 32 位四分之一区）。**注意不补 0x80**，出的是 bank 原样字节。
- `:190-191` `need_restart = req_en && ((req_bank != cur_bank) || ((req_beat < cur_addr) && !replay))`。⇒ **换 bank 或回头都要 flush**。
- `:193-196` `out_data = replay ? last_data : exp_w`；`out_avail = replay || (cur_valid && req_beat==cur_addr && req_bank==cur_bank)`；**`beat_ready = 1'b1` 恒真**（只要被仲裁器选中就每拍收）。
- `:198-201` `flush_now = need_restart && (inflight==0)` —— **必须等在飞 burst 排空才能 flush**（否则丢 beat）。`pop` 条件里带 `pix_last`。
- `:204-208` **4KB 边界处理**：
  - `fetch_byte = bank_base + {next_fetch, 4'b0000}`（beat 序号 × 16）；
  - `room_bytes = 13'h1000 - fetch_byte[11:0]`（到本 4KB 页尾还剩多少字节）；
  - `room_beats = room_bytes>>4`（还剩几个 16B beat）；`bst_beats = min(room_beats, MAXB=16)`。
  - ⇒ **burst 严格不跨 4KB**，且 ≤16 beat = 256 B。**注意：4KB 页面允许 256 beat，MAXB=16 是自己加的更紧限制**（§7 的优化点之一）。
  - `free_ok = (count + inflight) < (DEPTH - MAXB)` = `< 48`。**阈值与 DEPTH=64、MAXB=16 配平：48+16=64=DEPTH，零余量**（见下）。
- `:210-259` 主 always（同一 `if/else if` 链，优先级重要）：
  - `clear`（帧首，`:217-218`）只清 `last_valid`（防跨帧 replay 到旧数据）。**其它状态不清**——跨帧靠 flush_now。
  - `flush_now`（`:219-225`）：全清 + `head_addr/next_fetch/cur_addr <= req_beat`（**内部指针是 beat，对外是像素，所以这里必须用 `req_beat`**，`:220` 的注释记录了这个坑）。
  - 正常分支：`cur_addr <= head_addr + pop`、`cur_valid <= ((count - pop) != 0)`、`pop` 时 `rd_idx++/head_addr++/last_* <= ...`；收 beat 时 `wr_idx++/inflight--/beat_last 时 want_r<=0 且 next_fetch += cur_len1`；`count` 按 `{beat_valid,pop}` 增减。
  - `:251-257` **预取发起**：`req_en && !need_restart && !want_r && free_ok` ⇒ `want_r<=1; want_addr<=fetch_byte; want_len<=bst_beats-1; cur_len1<=bst_beats; inflight+=bst_beats`。
    ⇒ **`want_r` 是单标志：从发起到 `beat_last` 之间不允许再发第二个 burst。这就是"同时只有 1 个 burst 在飞"的根因。**
- `:261-266` 存/读**分开两个 always**（`:261-262` 注释：同一个 always 里既写又读 Efinity 不认 RAM 模板，64×128 整块落 FF，实测单流 8,447 FF）。`cur_data <= mem[ridx_n]`，其中 `ridx_n = rd_idx + pop`（`:202`）——**这就是"rd_idx = rptr + beat_idx + wready"那条历史修复的现状形式**：读地址预先算上"这一拍会不会 pop"，寄存一拍后正好是下一拍要的头部数据，于是引擎的**组合读**（`mem_rd_data0` 直接接到 `data_ok`）不需要额外握手拍。**核对结论：三个流（rd_stream/src_stream/wr_engine）都保持了这个形式，修复在位。**

**风险与疑点**

| # | 位置 | 问题 | 置信度 |
|---|---|---|---|
| R1 | `:251-257` | **单 burst 在飞** ⇒ 每 16 beat 暴露一次完整往返延迟。读侧并发度 = 1，是 8.76 MB 读流量摊到 9.3 拍/beat 的头号嫌疑（§7.3） | **事实**（代码结构）；对帧率的影响 = **高置信推测**（有 wburst 反证，§7.4） |
| R2 | `:208` | `free_ok` 阈值 48 = `DEPTH-MAXB`，与 `DEPTH=64` 相加正好 64 ⇒ **零余量**。若有人把 `MAXB` 调到 32，`count` 可到 48+32=80 > 64 ⇒ **静默覆盖未读数据**（不报错，画面花）。属"参数一动就炸"的隐式耦合 | 事实 |
| R3 | `:229` | `cur_valid <= ((count - pop) != 0)` 用的是**旧 count**，同拍有 beat 到达时不并入 ⇒ FIFO 将空时**每 burst 尾多 1 拍气泡**。次要 | 事实（影响 <1%） |
| R4 | `:238-245` | `beat_ready` 恒 1 ⇒ 在飞 burst 的 beat **无条件入 FIFO**，`free_ok` 只拦"发起新 burst"。配合 R2 的零余量，最坏 `count` 恰好等于 `DEPTH` | 事实 |
| R5 | `:196` | `beat_ready=1'b1` 让 `inflight` 的语义变成"已请求未到达"，与 src_stream 的"字"单位不同（见 R9），两处单位不一致，易误读 | 事实 |

### 5.3 `rowpipe_src_stream`（274-391）：源帧流（4 B/px DDR → 128 位字，**4 拍/beat 展开**）

**职责**：把 DDR 里 XBGR 4 B/像素的源帧，展开成"1 像素 = 1 个 128 位字"。`DEPTH=64`、`MAXB=8`（`:275-276`）。

逐行要点：
- `:294-308` 状态：额外有 `exp_data/exp_cnt/expanding`（一个 beat 要拆 4 拍写）。
- `:310-313` 输出：`out_data = cur_data`（**没有 replay 影子**，因为 L0 是单调顺序读，不会回读）；`out_avail = cur_valid && (req_addr==cur_addr)`；**`beat_ready = !expanding`**（展开期间不收新 beat）。
- `:316` `need_restart = req_en && (req_addr < head_addr)` —— **注意与 rd_stream 不同：这里比的是 `head_addr`（pop 指针）不是 `cur_addr`**。语义上等价于"比 FIFO 里最老的还没被弹掉的还老"，但对刚 pop 完的那一拍不做 replay（源帧流不需要）。
- `:322-327` 4KB 边界：`fetch_byte = frame_base + {next_fetch, 2'b00}`（`next_fetch` 是**像素**序号，源帧 4 B/px 所以 ×4）；`room_beats/ bst_beats = min(room, MAXB=8)`；`bst_words = bst_beats*4`（1 beat = 4 像素）；`free_ok = count+inflight < DEPTH-32 = 32`。
  ⇒ **`MAXB=8` 是为了配平 `free_ok<32` + 32 = 64 = DEPTH**（`:327`），与 R2 同一种零余量设计。
- `:343-348` 读流水同 rd_stream（`cur_addr <= head_addr + pop`）。
- `:351-355` **展开写**：`expanding` 时 `wr_idx++`，`exp_cnt` 0→3 循环，第 3 拍清 `expanding`。
- `:358-367` 收 beat：锁 `exp_data`、`exp_cnt<=0、expanding<=1`、`inflight -= 4`、`beat_last` 时 `next_fetch += cur_len1*4`（`:365` 的 `{4'b0, cur_len1, 2'b00}`）。
- `:375-381` 预取发起：`req_en && !want_r && free_ok && !need_restart`，`inflight += bst_words`（**按"字"计**，与 rd_stream 的"beat"不同）。
- `:386-387` **展开写的 RAM 输出**：`mem[wr_idx] <= {104'd0, exp_data[exp_cnt*32 +: 24]}`。
  - **这是任务书问的"是否丢掉通道信息"的答案：没有丢。** `exp_data` 的一个 32 位像素 = `{X,B,G,R}`（`X` 在 bit[31:24] 是未用的填充字节），取 `[exp_cnt*32 +: 24]` = 取低 3 字节 `B,G,R`，高位补 0 ⇒ 128 位字里 **lane0=B、lane1=G、lane2=R，lane3..15 = 0**。丢掉的是 `X`（填充字节），不是通道。这也解释 `L0.ci=3` 只用 3 个 lane。
  - 与 `virt` 打包（`:808`）的 `{8'h00, wr_data[23:0]}` 是**同一套字节序**，因此 L0→…→L11 的 BGR 顺序自洽；`style_display.sv:107` 的 XOR 只是去偏置，不动字节序。
- `:388-390` 同款存/读分离。

**风险与疑点**

| # | 位置 | 问题 | 置信度 |
|---|---|---|---|
| S1 | 全模块 | **没有 `clear` 口**，顶层 `frame_start` 只接到 `rd_stream.clear` 与 `wr_engine.clear`（`:838`、`:694`）。跨帧只靠 `flush_now`（要求 `inflight==0`）。实际安全（L0 之后 11 层不碰 src 流，`inflight` 必然排空），但**与另两个流不一致**，属设计瑕疵 | 事实 |
| S2 | `:313` | `beat_ready = !expanding`：展开 4 拍期间对 AXI 天然背压。引擎稳态 1 字/拍消费 ⇒ 4 拍/beat 刚好配平（`:270-273` 注释），但这也意味着**源帧流的最大吞吐 = 1 beat / 4 拍**，L0 需 76,800 beat ⇒ **最少 307,200 拍 = 2.07 ms**（单这一层的地板） | 事实 |
| S3 | `:387` | 展开写用 `exp_cnt` 做**变量位选** `exp_data[exp_cnt*32 +: 24]`。三位变量切片能综合成 4:1 mux，成本可接受，但和 `rowpipe_layer.v:6-20` 里"红线：不许变量下标"的风格相冲突（那里是 16 选 1 宽 mux 才禁） | 事实（无害） |

### 5.4 `rowpipe_wr_engine`（396-505）：写引擎 + beat FIFO（**每 beat 一条命令**）

**职责**：把"地址+数据+是否结果帧"的像素级写请求缓进 FIFO，逐条发 AXI 单 beat 写。

逐行要点：
- `:424-428` **设计声明 + 回退记录**：`awlen=0` 单 beat，理由是"换 RAM 推断（不 peek 队列、不异步读地址阵列）"；`2026-10-19` 试过 ≤4 beat 合并版（512 位移位寄存器 + 连续地址检查），**帧级 TB 两帧都不对**（先反向后顺序都错）⇒ 回退，并注明"真要做必须单独立项、带逐 beat 写 trace 对着看"。
- `:429-441` `DEPTH=32`、`IDXW=5`；**三块分存数组** `amem/dmem/vmem`（地址/数据/virt 标志分开），加 `wptr/rptr/count`、`h_addr/h_data/h_virt/h_valid`（读头寄存）。
- `:443-451` `p_ready = count < DEPTH-2`（**有效深度 30**）；`idle = (count==0)&&(st==W_IDLE)`；`awlen=8'd0`；`wstrb=16'hFFFF`；`wlast = (st==W_DATA)`。
- `:453-454` `pop = (st==W_RESP) && bvalid`；`rnext = rptr + pop`（同 §5.2 的"预读一拍"）。
- `:456-461` 写：`p_we && p_ready` 时三块同拍写。
- `:464-472` 读头：**每拍无条件** `h_addr <= amem[rnext]` 等，`h_valid <= ((count - pop) != 0)`。⇒ FIFO 空→非空的第一个 beat 有 1 拍气泡（`h_valid` 落后 count 一拍），正确但非最优。
- `:474-504` FSM `W_IDLE→W_ADDR→W_DATA→W_RESP→W_IDLE`：
  - `W_IDLE`：`(count!=0) && h_valid` ⇒ `W_ADDR`；
  - `W_ADDR`：`awready` ⇒ `W_DATA`；
  - `W_DATA`：`wready` ⇒ `bready<=1; W_RESP`；
  - `W_RESP`：`bvalid` ⇒ `bready<=0; acked++/acked_virt++; bresp!=0 ⇒ error<=1; W_IDLE`。
  - **⇒ 每个 16 B beat 的固定开销 = 4 个状态拍（每态至少 1 拍）+ 等 `awready` + 等 `bvalid`。且 `bready` 只在 `W_DATA` 之后拉高 ⇒ 写响应不是 posted 的，B 没回来就不会发下一条 AW。**

**这是 §7 里"每 beat 事务开销"的直接来源**：一帧 374,400 个写 beat = 374,400 次 AW/W/B 握手，命令数与数据数 1:1（最坏情况）。

**风险与疑点**

| # | 位置 | 问题 | 置信度 |
|---|---|---|---|
| W1 | `:446,451,491-501` | **单 beat + 逐 beat 等 B**：写通道 in-flight 恒为 1，吞吐 = 1 beat/(3+L_b) 拍。若 L_b=13 拍 @100 MHz，写侧就要 8.2 M 拍（≈55 ms @148.5）——与实测同量级，但**被 wburst 实验反证**（§7.4），故列为主嫌疑之二 | 事实（结构）+ 推测（权重） |
| W2 | `:443` | `p_ready = count < DEPTH-2`，留 2 格余量却没解释（可能是给同拍 push+pop 的边界留的） | 事实（注释缺失） |
| W3 | `:499` | `bresp!=0 ⇒ error<=1`，`error` **粘滞到 rst_n**（`:479` 注释："error 故意保持粘滞"）。⇒ 一次 BRESP 错误后，`error` 永久为高，`style_accel` 的 `error_sticky` 也永久置位（只能 APB 清） | 事实 |
| W4 | `:453` | `pop` 只看 `st==W_RESP && bvalid`，不看 `bresp`：**错误响应也照样弹 FIFO**（数据丢了但当作写成功） | 事实（合理但需知） |

### 5.5 `rowpipe_wmem_stream`（513-538）+ `rowpipe_wstream`（540-588）

- `rowpipe_wmem_stream`（`:513-538`）：`$readmemh(FILE)` 的 **1407×128 位 ROM**（`:525` `mem[0:1406]`）——**这正是文档"权重 blob 22,512 B = 1,407 个 16B beat"的数字来源**（1407×16 = 22,512）。**当前无任何实例化，是死代码**（片上合成会把这块 ROM 一起带进去，浪费 1407×128 = 225 KB RAM？——注意：无实例化则综合会剪掉，通常无害，但若某版本工具不剪就是 32 块 BRAM 白占）。
- `rowpipe_wstream`（`:540-588`）：**当前生效的权重流**，没有 FIFO，"AXI 的 `rvalid` 数据直接就是引擎的 `w_data`"（`:508-511` 注释：只在层间空隙用，卡住 AR 总线几拍不影响图像流）。
  - `:557-566`：`cur` = 下一个要交付的 beat 序号；`busy` = 一个 burst 在飞；`rewind = req_en && (req_addr < cur)`；`match = req_en && (req_addr==cur)`；`take = beat_valid && (busy || rewind || (match && req_ack))`；`out_avail = beat_valid && match && !rewind`；`beat_ready = take`。
  - `:568-575` 4KB 边界同样处理，`blen = min(room_beats, 16)`。
  - `:577-587` 只有两个寄存器：收到 beat 就 `cur++`、`beat_last` 清 `busy`；**另外 `!busy && req_en && req_addr<cur` 时 `cur<=req_addr`**（帧首回卷恢复，`:585` 注释）。
  - **疑点**：`want = req_en && !busy && !rewind && (req_addr >= cur)`（`:573`）。若引擎请求的地址比 `cur` 大（跳读），`want` 会立刻发一个从 `cur` 开始的 burst（不是从 `req_addr`）——**对齐靠"引擎严格顺序请求"这个前提**。当前引擎确实是顺序 `k++`，成立；但一旦有人改权重加载顺序（比如缓存/预取），这里会静默错位。

### 5.6 顶层 `rowpipe_ddr_banks`（593-860）

**职责**：把引擎的像素级 2 读 1 写映射到 3 个 bank + 源帧 / 结果帧，负责：bank→基址译码、源帧通路选择、`virt` 判据、结果帧 4 像素打包、写引擎实例、错误汇总、`result_done` 生成。

逐行要点：
- `:599` `frame_start` 只清**帧内计数**（注释 `:596-598`：不清则第二帧 `result_done` 永远不成立）。
- `:663-668` bank 基址译码：`rd0_base/rd1_base/wr_base` 三份 2 位选择。**默认 `bank_base0`**（`rd0_bank=0` 或 3 都落到 bank0，但 `rd0_bank==3` 时走源帧流，`rd0_base` 不用）。
- `:671-672` `src_en = rd0_en && (rd0_bank==3)`；`ddr0_en = rd0_en && (rd0_bank!=3)` —— **源帧流与 bank0 共用 rd0 口，用 bank 号 3 做区分**。这是"用 bank 号当通路选择器"的隐式编码（与 `virt` 同类问题）。
- `:683-711` 三个流实例；`rd0` 的 `beat_valid` 来自 `bv_rd0`（仲裁器给的组合 beat valid），`beat_data` 直接接 `rdata`。
- `:713-714` `rd0_data/avail` 二选一。
- `:723-730` `wstream` 实例，`base=weight_base`。
- `:732-741` 仲裁器实例；`bv_src/bv_rd0/bv_rd1/bv_w` 回给各流。
- **`:747` `virt` 判据**（任务书焦点）：
  ```
  wire virt = (wr_bank == 2'd2) && (cur_layer == 4'd11);
  wire [1:0] pf = virt ? 2'd2 : wr_fmt;
  ```
  - 完整条件链（**已逐级核实**）：`style_network_rowpipe.sv:80` L11 `dstb=2` → `rowpipe_engine.v:114` `dstb<=d[96:95]` → `:224` `mem_wr_bank=dstb` → `rowpipe_frame_driver.v:122` → `:136` `.wr_bank(wr_bank)` + `:137` `.cur_layer(layer_index)` → `rowpipe_ddr_banks.v:747`。
  - `cur_layer` 来自 `rowpipe_engine.v:90` `assign cur_layer = L`，而 `L` 在 `S_WAITPIX` 才 `L<=L+1`（`:420`）⇒ **L11 的整个输出过程 `cur_layer` 恒 11**，判据稳定。
  - `pf = 2` 覆盖 `dstf=0`（`:748` 注释说明非 virt 的 fmt=1 是 2 像素/beat、virt 是 4 像素/beat）。
- `:749-768` 打包控制：
  - `pk_last = (pf==1) ? 1 : 3`（2 px 或 4 px 一组）。
  - `bank_push_addr = wr_base + {wr_addr, 4'b0000}`（16 B/px 直通地址）。
  - `pack_can_emit = (pf!=0) && (pk_cnt==pk_last)`。
  - `push_we = virt ? beat_push : ((wr_fmt==0) ? wr_we : beat_push)`；`push_addr/push_data` 同款三选一。
  - **`:768` `wr_ready = (pf==0) ? wr_p_ready : (!pack_can_emit || wr_p_ready)`** ⇒ 打包期间（`pk_cnt<pk_last`）**恒定 ready**，只有"要吐 beat 且 FIFO 满"时才反压。
- `:770-794` 紧凑 beat：
  - `comp_addr`：fmt1 `wr_base + wr_addr[19:1]<<4`；fmt2 `wr_base + wr_addr[19:2]<<4`（像素下标→beat 地址）。
  - `comp_data`：从 `pk_acc` 出发，把本像素**低 B 字节**并入槽位（fmt1 看 `pk_cnt[0]` 选高低 64 位；fmt2 按 `pk_cnt` 选 4 个 32 位槽）。**只搬低 4/8 字节，高位保持 `pk_acc` 原值** ⇒ 依赖"该 beat 的所有像素都被写过一次"。
- `:796-831` 打包 always：
  - `frame_start` 清 `pk_cnt/pk_acc/beat_push/res_words/res_beats`（`:800-803`，第二帧 `result_done` 的修复）。
  - **`virt` 分支**（`:806-817`）：`pk_acc[32*pk_cnt +: 32] <= {8'h00, wr_data[23:0]}`，`res_words++`；第 4 个像素时 `beat_push<=1`、`beat_addr <= result_address + {wr_addr[19:2],4'b0000}`、**`beat_data <= {8'h00, wr_data[23:0], pk_acc[95:0]}`**、`pk_cnt<=0`、`res_beats++`。
    - **字节序核对（任务书问）**：`beat_data[31:0] = pixel0`、`[63:32] = pixel1`、`[95:64] = pixel2`、`[127:96] = pixel3`（当前像素）。每 32 位槽 = `{X=0, B, G, R}` ⇒ **小端 XBGR，R 在 bit[23:16]**（与 `ARCHITECTURE_FULL.md:114` 一致，该行引用 `:808` 也精确命中）。4 个像素→1 beat→`result_address` 顺序写，**结果帧固定 4 B/px**。
    - **注意 `beat_data` 用的是 `pk_acc[95:0]`（前 3 个像素，已寄存）+ 当前像素 `wr_data`（组合）**，所以 `beat_data` 与 `beat_addr` 都在 `wr_we` 那一拍被寄存，下一拍由 `beat_push` 推入 FIFO ⇒ **时间上正确**。
  - 非 virt 紧凑分支（`:818-827`）：`pk_acc <= comp_data`，到 `pk_last` 时 `beat_push/beat_addr<=comp_addr/beat_data<=comp_data`、`pk_cnt<=0`。
  - fmt=0 直通分支（`:828-830`）：清 `pk_cnt/pk_acc`。
- `:833-845` 写引擎实例：`.clear(frame_start)`、`.p_addr(push_addr)`、`.p_data(push_data)`、`.p_virt(virt)`、`.p_we(push_we)`。
- `:847-853` 读通道 RESP 错也计数（`rd_err` 粘滞），`error = w_error | rd_err`。
- **`:856-859` `result_done`**：
  ```
  (res_words == result_pixels) && (res_beats == (result_pixels>>2)) &&
  (w_acked_virt == res_beats) && w_idle && !beat_push
  ```
  三个计数 + 写引擎空闲 + 无 pending push。`result_pixels` 由 driver 传 `frame_width*frame_height`（`rowpipe_frame_driver.v:82,144`）。**任何一项不成立就永远等**（driver 的 `S_FLUSH` 无超时）。

**风险与疑点**

| # | 位置 | 问题 | 置信度 |
|---|---|---|---|
| B1 | `:768` vs `:762` | `beat_push` 那一拍 `pk_cnt` 已被清 0 ⇒ `pack_can_emit=0` ⇒ **`wr_ready=1` 不检查 `wr_p_ready`**，而同一拍 `push_we=beat_push=1` 会进 FIFO。**当前不丢数据**只因为"上一边沿 `wr_p_ready` 为 1 且这一拍 count 不可能变"（中间没有其它 push 源）。属**脆弱设计**，任何增加 push 源的改动都会丢 beat | **事实**（逻辑如此）；风险 = 中 |
| B2 | 全文件 | **打包器残留不计入 `wr_idle`**：`wr_idle = w_idle`（`:834`），而引擎层末只等 `mem_wr_idle`（`rowpipe_engine.v:418`）。若某层 `hout*wout` 不是 `2^pf` 的整数倍，最后 1~3 个像素会在**下一层已经开跑后**被推入 FIFO，写进**下一层的 bank/地址**。当前 12 层全部整除（out_total ∈ {307200,76800,19200}，均被 4 整除），**未触发** | **事实**（逻辑缺口）；触发条件明确 ⇒ **潜在 bug** |
| B3 | `:747` | `virt` 用"bank2 && layer==11"隐式编码；bank 重分配/加层即刻静默失效 | 事实（可维护性） |
| B4 | `:671` | `rd0_bank==3` 当"源帧"标志，也是隐式编码（bank 号即通路选择器），与 B3 同类 | 事实 |
| B5 | `:856-859` | `result_done` 依赖 4 个计数精确相等，**无超时**；`result_pixels` 与实际输出不符就永久卡 `S_FLUSH` | 事实 |
| B6 | — | **`frame_start` 不清 `cur_bank`（rd_stream 内部状态）与 src 流状态**：靠 `flush_now` 收拾。rd_stream 的 `clear` 只清 `last_valid`。跨帧第一个请求若恰好等于 `cur_addr`（理论上可能）会误判 `out_avail`。实际上 `head_addr` 停在上帧末尾（大数），`req=0 < cur_addr` ⇒ 必走 `need_restart`（除了 src 流用 head 比较也对） | 推测（低风险） |

---

## rtl/accel_rowpipe/rowpipe_frame_driver.v（191 行）

### 职责与契约

- **职责**：帧协议层。`start` 脉冲 → `busy=1` → 启引擎跑 12 层 → 等写通道排空（`res_done`）→ `done=1`。是"引擎 ↔ 后端 ↔ 上层"的唯一粘合层，也是**帧间清零**的责任人。
- **谁给 start**：`style_network_rowpipe.sv:109` ← `style_accel.sv:109`（`.start(core_start)`，`core_start = start_sync[1] != start_seen`，`:95`），源头是 APB 写 `0x04[0]` 或自动模式（`style_accel.sv:69-76`）。
- **谁消费 busy/done/error**：`style_network_rowpipe` 把 `done` 转**单拍脉冲**（`:126-131`，因为 driver 的 done 是电平而 style_accel 按边沿累加 `done_toggle`）；`busy` → `core_busy` → `style_accel` 的 `coef_ready = core_reset[1] && !core_busy`（`:97`）；`error` → `core_error_snapshot`（`:103`）→ APB `0x08[2]`。

### 端口

| 端口 | 方向 | 位宽 | 域 | 语义 |
|---|---|---|---|---|
| `clk/rst_n` | in | 1 | **cnn_clk 148.5 MHz** | — |
| `start` | in | 1 | 同上 | 单拍启动（必须不 busy，`:168` 的 `S_IDLE` 只在非 busy 时停在 IDLE 才可能看到） |
| `source_address` | in | 32 | 同上 | 源帧基址（`0x05000000 + slot×0x140000`） |
| `result_address` | in | 32 | 同上 | 结果帧基址（源 + `0x00800000`） |
| `weight_address` | in | 32 | 同上 | 权重 blob 基址（`0x06F00000`，`style_network_rowpipe.v:18` 默认） |
| `frame_width/height` | in | 10/10 | 同上 | 640/480；只用于 `total_pixels` |
| `descs` | in | 1536 | 组合 | 12×128 |
| `busy` | out | 1 | 同上 | 电平，S_RUN/S_FLUSH 期间为 1 |
| `done` | out | 1 | 同上 | **电平**，保持到下次 start |
| `error` | out | 1 | 同上 | `bank_error | err_frame`（组合） |
| `layer_index` | out | 4 | 同上 | 直通 `eng.cur_layer` ⇒ **`virt` 判据的一半** |
| `cycles` | out | 32 | 同上 | 帧内拍数（S_RUN + S_FLUSH 累加，**不含 S_IDLE 那段**） |
| `rom_*` | out/in | — | 同上 | 透传，恒 0 |
| AXI 全套 | — | — | 同上 | 128 位数据、8 位 `arlen/awlen`、**无 ID 通道**（单 master、顺序） |

### 内部结构与 FSM

**关键常数（`:78-80`）**：
```
BANK0_BASE = 0x0600_0000   // 0x0600_0000 .. 0x064F_FFFF（5MB）
BANK1_BASE = 0x0650_0000   // 0x0650_0000 .. 0x069F_FFFF
BANK2_BASE = 0x06A0_0000   // 0x06A0_0000 .. 0x06EF_FFFF
```
`:73-77` 的注释解释了 5 MB：**"bank 存储格式是 16 B/像素，全分辨率中间帧 307,200×16 = 4.9 MB；2 MB 间隔时 L0 的帧会盖住 bank1/bank2 的起点，L1 一边读 L0 一边写 bank1 ⇒ 写进还在读的帧里"**。
**但按当前描述符（§2.3），中间 bank 里最大的一帧是 `640×480×4 B = 1,228,800 B = 1.17 MB`（L0→BANK0、L10→BANK1），根本不到 4.9 MB**。所以：
- **事实**：5 MB 间隔是安全的，真正的硬约束是三条——① 不能与结果帧区 `0x05800000..0x05F7FFFF` 相撞；② 不能越过权重 blob `0x06F00000`（BANK2 末尾 0x06EFFFFF 正好卡住，**这条才是 5 MB 的真正由来**）；③ 同 bank 前后两层"边读边写"需要 ≥ 该帧大小（1.17 MB）。
- **结论**：注释里的 4.9 MB 论证是 **B1j 紧凑化之前**的（那时全 16 B/px）。今天 2 MB 间隔就够，5 MB 是过保守但无害。**这条要写进 §9 的"文档/注释脱节"清单。**

**FSM（`:153-190`）**：

| 状态 | 转移 | 动作 |
|---|---|---|
| `S_IDLE` | `start` → `S_RUN` | `busy=1; done=0; cycles=0; eng_start=1; frame_start=1; eng_low=0; err_frame=0` |
| `S_RUN` | `eng_w_to` → **异常收尾**（`:178-180`：`err_frame=1; busy=0; done=1; st=S_IDLE`）<br>`!eng_done` → `eng_low=1`（留下证据）<br>`eng_done && eng_low` → `S_FLUSH` | `cycles++`；先看超时，再判 done |
| `S_FLUSH` | `res_done` → `S_DONE` | `cycles++`；**等结果帧最后一个 beat 的 BRESP** |
| `S_DONE` | 无条件 → `S_IDLE` | `busy=0; done=1`（下一拍就回 IDLE，所以 `done` 只保持 1 拍？—— 不：`done` 在 IDLE 里不被清，只有 `start` 才清（`:169`）⇒ **保持到下次 start**） |
| default | → `S_IDLE` | — |

**`eng_low` 的用途（任务书问）**：引擎的 `done` 是**电平**且保持到下次 start。driver 在 `S_IDLE` 打 `eng_start` 的**同一沿**，引擎要到下一拍才清 `done`；如果 driver 立刻判 `eng_done`，会把"上一帧残留的 done=1"当成"本帧完成"，**在 L0 还没开始时就跳去 S_FLUSH**。所以 `eng_low` 记录"本帧确实看到 `done` 落过 0"，只有见过 0 之后的 1 才算完成。`S_IDLE` 每次 start 清 `eng_low`。

### 逐行要点（补充）

- `:82` `total_pixels = frame_width * frame_height`（10×10 位 → 32 位乘法器一个，**常量化后可剪枝**，但这里两位都是端口 ⇒ 真乘法器；只在 `result_done` 比较用，可接受）。
- `:99-101` `eng_start/frame_start/eng_low` 三个单拍寄存器；`:162,166` 每拍默认清 ⇒ 天然单拍脉冲。
- `:104-106` `error = bank_error | err_frame`。**`bank_error` 是粘滞的（`rowpipe_ddr_banks.v:853`），`err_frame` 只在本帧有效（start 清）** ⇒ 一旦出现过 AXI 错，`error` 永久为高。
- `:163-165` 注释解释了 `frame_start` 的必要性：`res_words/res_beats/acked_virt` 原来只在 rst_n 清 ⇒ 第二帧 `result_done` 永远不成立、driver 卡死 `S_FLUSH`；"现有 TB 只跑一帧所以没暴露"。
- `:173-174` 注释解释了 `eng_low`（见上）。
- `:175-182` `S_RUN` 的**判断顺序**：先 `eng_w_to`（异常优先），再 `!eng_done`（记录）,再 `eng_done&&eng_low`。**没看 `error`** ⇒ BRESP 错误不会中止本帧。
- `:183-186` `S_FLUSH` **只等 `res_done`，无超时**。
- `:187` `S_DONE` 无条件回 IDLE，`:179` 的异常路径**直接跳 S_IDLE 不等 flush**（注释：避免挂死）。

### 风险与疑点

| # | 位置 | 问题 | 置信度 |
|---|---|---|---|
| D1 | `:175-186` | FSM **不看 `bank_error`**：BRESP/RRESP 错误只置 `error`，帧照跑完（浪费一整帧时间，且给出错误的 `done`）。上层只在 done 时快照 error，用户看到的是"完成但画面错" | 事实 |
| D2 | `:178-180` | 权重超时路径**不等 `res_done`** 直接回 IDLE 并置 `done`；此时写 FIFO/打包器可能有未落盘数据，下一帧 `frame_start` 会把 FIFO 指针清零 ⇒ **丢掉上帧 tail 写**。既然已判 error 可接受，但会污染下一帧的 bank 内容（下一帧 L0 全量覆盖 bank0，其余 bank 也都会先写后读，实际无害） | 事实（影响小） |
| D3 | `:183` | `S_FLUSH` 无超时 ⇒ `result_done` 不成立就永久 busy（`style_accel` 侧 `coef_ready=0`、后续帧全被丢）。**这是"第二帧现象"类 bug 的高发点** | 事实 |
| D4 | `:176,184` | `cycles` 在 S_RUN/S_FLUSH 累加但与 `style_accel` 的 148.5 MHz 常数寄存器（`0x34` 常数 148,500,000）配套，**说明 148.5 MHz 是全局约定**（时钟核对见 §7.1） | 事实 |
| D5 | `:82` | `frame_width*frame_height` 与描述符的 `hout*wout` **两个独立来源**，比对不上就挂死（与 B5/E1 同一根因） | 事实 |

---

## rtl/accel_rowpipe/style_network_rowpipe.sv（145 行）

### 职责与契约

- **职责**：`style_network`（队友版）的**原位替换 wrapper**：端口完全同款（`:4` 注释 "端口 = 队友 style_network 同款 ⇒ 直接替 style_accel 里的那一个实例"），内部 = `rowpipe_frame_driver`（12 层整网 + B1g 权重 blob 流）。
- **契约差异（`:6-13` 逐条）**：
  1. 权重不在 `coef_*` 写口，**必须预置在 DDR 的 `WEIGHT_ADDRESS`**（默认 `0x06F0_0000`，与 640 帧级 TB 的 WGT_A 一致）；
  2. `rowpipe_frame_driver` 的 `done` 是电平，而 `style_accel` 用边沿累加 `done_toggle` ⇒ **wrapper 把 done 转单拍脉冲**（`:126-131`）；
  3. `rom_*` 是 bench 假 ROM 口，B1g 模式全 0（`:94-102`）；
  4. 判据 = 640 帧级 TB 逐位对拍（`tb/tb_style_network_640.v`）。
- **实例化位置**：`rtl/style/style_accel.sv:109`（`.clk(cnn_clk)`），再上一层 `rtl/style/style_video_system.sv:61`，再上 `rtl/ti60f225_oob_top.v:633`（`.cnn_clk(vid_clk_dvi2)`）。**⇒ rowpipe 全部逻辑跑在 148.5 MHz**（`vid_clk_dvi2`），见 §7.1。
- **被替换的兄弟**：`style_accel.sv:118` 还并列实例化着 `style_network network(...)`（原版），两者共用 `core_start/core_busy/core_done` 等同名 wire ——**同一时刻只能有一个参与综合/生效**（当前用 `style_network_rowpipe`；`style_network` 若也实例化会造成双驱动！需要确认构建里是否真的两个都在）。

> ⚠ **这是一条值得 Lead 复核的构建级疑点**：`style_accel.sv:109` 与 `:118` 分别实例化 `style_network_rowpipe network(...)` 与 `style_network network(...)`，且两边都接 `core_busy/core_done/core_error/core_layer/core_cycles` 和同一组 AXI wire（`c_arvalid` 等）。若两个模块都被综合，`core_busy` 等 wire 会被**双驱动**（一个是 driver 输出，一个是原版网络输出），且两个 master 会同时驱动同一条 AXI。实际能跑通说明构建里必然有一个被注释/条件化掉了 —— **我这轮只读 5 个文件，没有核实 `style_accel.sv` 全文的生成条件，请 Lead 或读 style_* 的同事确认**（置信度：可疑，但不影响本报告的数据通路结论）。

### 12 层描述符（`:78-92`）

- `:66-76` `mk()` 函数：注释 `:78` "左高右低 ⇒ `DESCS[0 +: 128] = L0`"，即**书写顺序是 L11 在前、L0 在最后**。逐位核对见 §2.1，**无错**。
- `:79-92` 12 行 `mk(...)`，与 §2.2 的表逐字段一致（我已用脚本按位解析，全部匹配）。
- 小注：`mk` 形参 `ng` 是 `integer`，拼接里用 `ng[7:0]`（合法）；`res/resu/xorin/s2/up` 是 1 位；`srcb/dstb/idb/srcf/dstf/idf` 是 2 位。**描述符里每位都被用到，没有浪费位**（`[127:106]` 22 位恒 0 是余量）。

### 逐行要点（补充）

- `:104-106` `drv_busy/drv_done/drv_error/drv_layer/drv_cycles`；
- `:108-124` 只连了 driver 需要的口，**`rom_*` 是 wrapper 内部常量**（`:94-102` 全 0）——注意这意味着 `rom_layer/rom_addr` 这两根由 driver/engine 输出的线**没有负载**，只在 `:144` 的 `_unused` 里"消费"低 1 位；
- `:126-131` done 单拍化：`done = drv_done && !done_seen`，`done_seen <= drv_done`。**注意 `rst_n` 复位 `done_seen=0`，若复位时 `drv_done=1` 会误发一个 done 脉冲**（实际复位后 driver 的 done=0，无风险）；
- `:133-141` `busy/error/layer_index/cycles` 直通；5 个 stat 输出**硬接 0**（`:137-141`）⇒ APB `0xa8/0xb0/0xb4/0xb8` 的 read_cycles/compute_cycles/prefetch/overlap **在读 rowpipe 版时恒 0**（注意：这与实测报告的"算力 7.85 ms / DDR 等待 49.1 ms"不冲突，那两个数应来自 `style_ddr_profiler` 或探针，不是这组 APB）；
- `:144` `wire _unused = coef_we | coef_addr[0] | coef_word[0] | coef_data[0] | rom_addr[0] | rom_layer[0];` —— **只 OR 了最低 1 位**，综合会报"未使用位"警告但不会真的优化掉驱动逻辑（因为线连着 driver）。属常规去警告手法。

### 风险与疑点

| # | 位置 | 问题 | 置信度 |
|---|---|---|---|
| N1 | `:137-141` | 5 个性能统计口恒 0 ⇒ **APB 的 read_cycles/compute_cycles/prefetch/overlap 在 rowpipe 板上全是 0**。任何"用 APB 读数分析性能"的做法都会拿到 0，必须改用 profiler/探针 | 事实 |
| N2 | `:27` | `coef_we/coef_addr/coef_word/coef_data` **接收但忽略** ⇒ double-style 的 plan B 未实现；APB 0x28 的 coefficient_index 对 rowpipe 无效 | 事实 |
| N3 | `:126-131` | done 单拍脉冲实现依赖 `drv_done` 是电平且 driver 在 S_DONE 会保持；若 driver 改成脉冲，这里会漏帧 | 事实（隐性耦合） |

---

## rtl/accel_rowpipe/fps_overlay.sv（153 行）

### 职责与契约

- **职责**：替换原 `osd_db/osd_font` 文本栈的 **0 RAM 字形叠加**：在左图左上角画 "FPS xx"（5×7 字模 × 2 倍放大，白字黑底）。
- **位置**：de 坐标 `x 8..79`、`y 128..145`（`:7` 注释："de 的 y=120 对应左图第 0 行"）。
- **谁给数据 / 谁消费**：`rtl/ti60f225_oob_top.v:937-943`，`clk = hdmi_tx_slow_clk = 74.25 MHz`，`i_vs/i_hs/i_de/i_r/g/b` 来自 `lift_*`（lift 色调映射之后的显示流），`o_vs/hs/de/r/g/b` 进 dvi_encoder。**`i_fps` 来自 `style_fps_disp`（同域寄存器，源头是 core_clk 域的 `style_irq` 边沿计数，`top:918-935`）**。
- **FPS 计数口径**（`top:928-934`）：`style_irq` 上升沿计数，`fps_tick == 74_249_999`（74.25 M 拍 = 1 s）时锁存。注释记录了历史 bug："旧 148.5M 阈值 = 2 秒窗口 ⇒ 显示值是真帧率的 2 倍"。**⇒ 屏上 FPS 的可信度取决于 `style_irq` 是否每帧只有一个上升沿**（`style_irq = irq_enable && (done_sticky||error_sticky)`，`style_accel.sv:47`；固件必须每帧清 `done_sticky`，否则只数到 1）。

### 端口

| 端口 | 方向 | 位宽 | 域 | 语义 |
|---|---|---|---|---|
| `clk/rst_n` | in | 1 | hdmi_tx_slow_clk 74.25 MHz | — |
| `i_vs/i_hs/i_de` | in | 1 | 同上 | 显示同步；`i_de` 有效区 1280×720 |
| `i_r/i_g/i_b` | in | 8 | 同上 | 像素 |
| `i_fps` | in | 16 | 同上（源 core_clk，2FF 同步） | 待显示帧率 |
| `o_vs/o_hs/o_de` | out | 1 | 同上 | **全部打一拍**（`:141`） |
| `o_r/o_g/o_b` | out | 8 | 同上 | 框内白/黑，框外透传 |

### 逐行要点

- `:31-35` 常数：`TEX_X0=8, TEX_Y0=128, GW=5, GH=7, SCALE=2, BOX_W=72, BOX_H=GH*SCALE+4=18`。
- `:37-47` de 坐标计数器：`x` 11 位（0..1279）、`y` 10 位（0..719）；`i_vs` 清、`i_de` 递增、`x==1279` 换行。**注意 `i_vs` 期间每拍清 `x/y`，所以 vs 宽度 >1 行也没问题**；`y` 只数 de 行 ⇒ 与"de 第 120 行 = 左图第 0 行"的几何假设绑定。
- `:50-56` `fps1/fps2` 两级同步；`d1=(fps2/10)%10`（十位）、`d0=fps2%10`（个位）。**除以常数 10 两次**（综合成小乘法器），资源可接受；**fps>99 时十位回绕**（例如 120 → d1=2，显示"FPS20"）。板子 17 fps 不触发。
- `:58-62` 框/字判定：`in_box`（x 8..79、y 128..145）；`in_text`（x 10..69、y 130..143）。
- `:64-70` 几何：`tx = x-10`、`ty = y-130`、`ch = tx/12`（0..4 = F/P/S/十/个）、`cx = tx%12`、`gx = cx[4:1]`（=cx/2，0..5）、`gy = cy[3:1]`（=cy/2，0..6）。
  - **字距 12 = 5×2 宽 + 2 空白**；`gx<GW` 把 `gx==5`（cx 10/11）挡成空白 ⇒ 2 px 间隔正确。
  - `gy` 最大 6（cy 0..13 → 0..6），`in_text` 的 `y < 130+14` 保证不会到 7 ⇒ `lit()` 的 `default: r6` 分支是安全网。
- `:73-133` `lit(c, col, row)` 函数：`c` 0..2 是固定字形 F/P/S，3/4 是十位/个位数字（各带 10 分支 `case(d1)`/`case(d0)`）；**每行一个 5 位常量**，最后 `lit = r{row}[4-col]`（MSB = 左）。
  - **0 RAM 的实质**：12 个 `case` 全展开成组合逻辑 = 一张 5×7×12 的 LUT 表。资源 ≈ 每字形 7 个 5 输入 LUT + 一个 12:1 mux 树 ⇒ **远小于原 osd_font RAM**，这是"0 RAM"的收益。
  - `:121 default: ;` + `:130 default: lit=r6` ⇒ 越界安全。
- `:135` `px_lit = in_text && (gx<5) && (gy<7) && lit(ch,gx,gy)`。
- `:137-149` 输出寄存：`o_vs/hs/de` 与 `o_r/g/b` **同拍打一拍** ⇒ 像素与同步对齐（像素 n 的同步和数据一起延迟 1 拍，**不会错位**）。框内 `px_lit ? 白 : 黑`，框外透传。
  - **注意框内是"不透明矩形"**：`in_box` 覆盖 x 8..79（72 宽）× y 128..145（18 高），而文字只占 x 10..69 ⇒ **右边留 10 px 黑边、上下各 2 px 黑边**，外观左右不对称。`:34` 注释说"BOX_W=72 覆盖 5 个字符 + 边框"，实际 5×12+2 = 62 就够，72 偏大。
- `:152` `wire _unused = i_fps[15];` —— 只"使用"最高位防止整根未用警告。

### 风险与疑点

| # | 位置 | 问题 | 置信度 |
|---|---|---|---|
| F1 | `:55-56` | `fps>99` 时十位回绕（120→显示 20 而不是码）；`fps>199` 更离谱。当前 17 fps 不触发 | 事实（低优先） |
| F2 | `:34` | `BOX_W=72` 与文字宽度 62 不匹配 ⇒ 右侧 10 px 黑边，双面板下可能压到图中内容区（x 到 79，而左图 1:1 区域是什么范围需 display 侧确认） | 事实（外观） |
| F3 | `:50-54` | `i_fps` 是 16 位多 bit 跨时钟，只做 2FF 无握手；**慢变量约定下可接受**，但若某次 `style_fps_disp` 在两个十进制位之间跳变（如 19→20 的二进制跨位），2FF 采到中间值概率极低但仍存在 | 推测（极低） |
| F4 | 全模块 | 几何硬编码 `y=128`，绑定"de 前 120 行是黑边"的显示模式；换单/双面板或改 `img_y0` 就得同步改这里（**与 `style_display.sv:40-49` 的几何常量是两份独立硬编码**） | 事实（可维护性） |

---

## 7. 带宽专题：一帧的 DDR 事务账

### 7.1 先钉住时钟（这是所有账的前提）

| 时钟 | 频率 | 谁在跑 | 证据 |
|---|---|---|---|
| `core_clk` | **100 MHz** | SoC / APB / DDR 控制器 / **AXI 侧**（`style_axi_cdc` 的 `axi_clk`）/ frame_store / display | `ti60f225_oob_top.v:152` 注释、`style_accel.sv:127` `.axi_clk(clk)` |
| `vid_clk_dvi2` = **`cnn_clk`** | **148.5 MHz** | **rowpipe 全部逻辑**（engine/banks/driver）+ 捕获处理 | `top:633` `.cnn_clk(vid_clk_dvi2)`；`style_accel.sv:109` `.clk(cnn_clk)` |
| `hdmi_tx_slow_clk` | **74.25 MHz** | HDMI/DVI 输出、`fps_overlay`、`style_display` 像素侧 | `top:929` 注释 + SDC 13.468 ns |

**推论（很重要）**：
1. AXI 带宽地板 = `100 MHz × 16 B = 1.6 GB/s`（与文档一致）；
2. 但 rowpipe 的状态机拍是 **148.5 MHz** 拍 ⇒ **一个 AXI beat 地板成本 = 100/148.5 = 0.673 AXI 拍 = 1.485 个 rowpipe 拍**；
3. rowpipe ↔ AXI 之间有 `style_axi_cdc`（每通道一个异步 FIFO：**AR/AW `WIDTH=40, LOG_DEPTH=2` ⇒ 4 深；W `WIDTH=145`、R `WIDTH=131`、B `WIDTH=2`，都取默认 `LOG_DEPTH=4` ⇒ 16 深**，见 `rtl/style/style_axi_cdc.sv:15-23`）⇒ 每笔事务额外约 **2×3 拍同步延迟**，且**上行命令 FIFO 只有 4 深**；
4. 帧率 17.4 fps ⇒ 148.5 MHz 下一帧 = **8.54 M 拍**，100 MHz 下 = 5.75 M 拍。

### 7.2 逐层事务账（按 §2.2 描述符 + §2.3 格式解析算得）

| 层 | 读像素 | 读 beat | AR 条数 | 写像素 | 写 beat | 读 MB | 写 MB |
|---|---|---|---|---|---|---|---|
| L0 | 307,200 | **76,800** | 9,600（8 beat/burst） | 307,200 | 76,800 | 1.229 | 1.229 |
| L1 | 307,200 | 76,800 | 4,800 | 76,800 | 38,400 | 1.229 | 0.614 |
| L2 | 76,800 | 38,400 | 2,400 | 19,200 | 9,600 | 0.614 | 0.154 |
| L3 | 19,200 | 9,600 | 600 | 19,200 | 9,600 | 0.154 | 0.154 |
| L4 | 19,200×2 | 19,200 | 1,200 | 19,200 | 9,600 | 0.307 | 0.154 |
| L5 | 19,200 | 9,600 | 600 | 19,200 | 9,600 | 0.154 | 0.154 |
| L6 | 19,200×2 | 19,200 | 1,200 | 19,200 | 9,600 | 0.307 | 0.154 |
| L7 | 19,200 | 9,600 | 600 | 19,200 | 9,600 | 0.154 | 0.154 |
| L8 | 19,200×2 | 19,200 | 1,200 | 19,200 | 9,600 | 0.307 | 0.154 |
| L9 | 76,800 | 38,400 | 2,400 | 76,800 | 38,400 | 0.614 | 0.614 |
| L10 | 307,200 | **153,600** | 9,600 | 307,200 | 76,800 | 2.458 | 1.229 |
| L11 | 307,200 | 76,800 | 4,800 | 307,200 | 76,800（4 px/beat） | 1.229 | 1.229 |
| **合计** | 1,555,200 | **547,200** | **39,000** | 960,000 | **374,400** | **8.755** | **5.991** |

- 权重流：**903 beat/帧 = 14,448 B**（`:242-260` 的 `wbase_of` 表最后一项 854 + L11 的 49 = 903，与文档 `:175` 的"903 beat / 14,448 B"吻合），约 57 条 AR。**可忽略（0.03%）** —— 权重不是带宽问题。
- 15.7 MB/帧总量 − 权重 = **14.75 MB/帧**。× 17.4 fps = **256.6 MB/s**，与实测 **0.26 GB/s** 逐位吻合 ⇒ **那个数字就是"我们实际搬了多少"，不是"我们能搬多少"，完全不能当作带宽上限的证据**。
- 命令账：**AW 374,400 + W 374,400 + B 374,400 + AR 39,000 ≈ 1.16 M 次 AXI 握手 / 帧**，即 **每 16 B 有效数据付出 1.26 次握手**。写侧是极端不对称的 **1:1**（命令数 = 数据数）。

### 7.3 每 beat 9.3 拍的构成（拆解）

地板：921,600 beat × 1.485 拍 = **1.37 M 拍 = 9.2 ms**（= 1.6 GB/s）。实测一帧 8.54 M 拍 ⇒ **多付 7.2 M 拍**。候选开销：

| 机制 | 算式 | 拍数 | 占多付 |
|---|---|---|---|
| **A. 写引擎逐 beat 等 B**（`:491-501`） | 374,400 × (3 + L_b) − 374,400×1.485 | L_b=13 → **5.5 M** | 76% |
| **B. 读流单 burst 暴露往返**（`:251-257`） | 39,000 × (L_r) | L_r=100 → 3.9 M | 54% |
| C. 仲裁器每 burst 2 拍空转（`:108-115`） | 39,000 × 2 | 0.08 M | 1% |
| D. 每层 PREPUSH 658 条 skip × 3 拍 | 12 × 2,000 | 0.024 M | <1% |
| E. rd_stream FIFO 将空 1 拍气泡（R3） | 39,000 × 1 | 0.04 M | <1% |
| F. 与显示/采集共享 DDR 的仲裁损失 | 显示读 2.46 MB/帧 = 153,750 beat，加采集写 ~78,000 beat | 取决于仲裁 | 未知但**不小** |

### 7.4 判别实验：两侧各占多少（**这是本轮最该先做的事**）

**A 和 B 不是"二选一"，而是同时成立、互相掩盖**：`49.1 ms` 的写侧账几乎正好吃满一帧（49.1/57.5 = 85%），说明**写通道从头到尾都在等 B**；但写 FIFO 有 32 深，引擎可以"先把像素塞进 FIFO"，所以引擎在这 49 ms 里**同时在等读数据**（`data_ok`）。两侧都是延迟瓶颈 ⇒ 读数上只会看到"其中一个先撞墙"。

三条证据的一致性检验：

1. **支持写侧**：`49.1 ms` @ 100 MHz = 4.91 M 拍；除以 374,400 个写 beat = **13.1 拍/beat** —— 正好是"DDR3 写响应 B 的延迟"量级。且 `style_ddr_profiler` 的 counter 定义与此精确对应：**counter[3] = `write_response && !c_bvalid`**（`rtl/style/style_ddr_profiler.sv:13,25-26`：`c_wvalid&&c_wready&&c_wlast` 置位、`c_bvalid&&c_bready` 清零），其 TB **`tests/style_ddr_profiler_tb.sv:25`** 对 counter[3] 的期望值是 7（`c_wlast` 那一拍 + 等 `c_bvalid` 的 6 拍），**证明 counter[3] 就是"W 发完到 B 回来之间的拍数"**；`:42-45` 还专门测了"clear 期间在飞写要保留等 B 状态"。⇒ 49.1 ms 极可能就是 counter[3] 的累积。
2. **反对"只修写侧就够"**：`wburst-18.5fps` 把写命令 451,250 → 90,250（5 倍压缩，`ARCHITECTURE_FULL.md:324`），**帧率只从 17.4 → 18.5（+6%）**。若按上面算，写侧从 49.1 ms 降到约 17 ms，帧时应该从 57.5 → 25 ms（40 fps）—— 没有发生 ⇒ **写侧修好后，读侧接棒成为新的（差不多坏的）瓶颈**。这条反证恰恰支持"两侧同时坏"。
3. **口径矛盾**：文档的 **451,250 写命令/帧** 与我按描述符算出的 **374,400** 差 20%，两者都对不上（若板上 bit 是 B1j 之前的全 16 B/px 写，应是 883,200；若是全 1 beat/px，应是 960,000）。⇒ **那个 451,250 的测量口径不明，必须先复测再谈优化。**

**建议的判别/推进流程**：
1. 把 `style_ddr_profiler` 挂回 `style_video_system` 的 `axi_clk` 侧（它已在 `ti60f225_cam_hdmi.xml:91` 的工程文件里，只是**没有任何实例化**），APB 读 12 个 counter：**3**=等 B、**8**=读流水气泡、**7**=读 stall（`c_rvalid&&!c_rready`）、**10**=AR stall。一次测量就能给出两侧各占多少。
2. **两侧并行排期**：读侧（§7.6）风险低、可先上；写侧（§7.5，优先 A1"posted B"而不是重写 burst 合并）紧随。只做一侧的预期收益 ≈ +6%（已有实验证明）。

### 7.5 写侧优化（机制 A）

| 方案 | 做法 | 风险 | 预期 |
|---|---|---|---|
| A1 **AW/W/C 分离**：`bready` 常 1，不等 B 就发下一条 AW（用一个小 B 计数做流控） | 改 `:474-504` 的 FSM 为"命令通道 posted" | **低**（协议合法：AXI 允许 ≤16 未回 B；这里只放 2~4） | 写吞吐 1 beat/(3+L_b) → ~1 beat/1.5 拍 |
| A2 **恢复 burst 合并**（≤8/16 beat，不跨 4KB） | 历史分支已有代码，但**当时两帧都错** | **高**（文档已记录回退） | 写命令 374,400 → 23,400~46,800 |
| A3 定位 A2 的错因：**先怀疑 B1 缺陷**（`wr_ready` 那拍跳过 `wr_p_ready`）与 `pk_acc` 残留不计入 `idle`（B2） | 在合并版里加逐 beat trace | 中 | A2 的前置条件 |

**强烈建议先做 A1 而不是 A2**：A1 不改数据打包逻辑，只把"等 B"变成"计数 N 个未回 B"，风险远低于重写 burst 合并；而它恰好对当前 `awlen=0` 的结构也有效（把 13 拍/B 藏起来）。

### 7.6 读侧优化（机制 B，**风险最低、建议先上**）

| 方案 | 做法 | 风险 | 预期 |
|---|---|---|---|
| B1' **允许 ≥2 个 burst 在飞** | 把 `want_r` 换成 `inflight_bursts` 计数（0..2/3），`free_ok` 改为 `count+inflight < DEPTH - MAXB*(K+1)` | **低**（地址全由 `next_fetch` 递增决定，与"哪个 burst 先回来"无关，因为流是严格顺序的） | 读时间 ÷K |
| B2' **加长 burst** | `MAXB` 16 → 64（1 KB，4KB 页内允许到 256），FIFO 深度同步 64→256 | **低**（`room_beats` 逻辑已支持，只需配平 R2 的零余量） | AR 条数 39,000 → ~10,000 |
| B3' **加深 FIFO 覆盖组间空档** | DEPTH 64 → 128/256 | 中（BRAM：256×128b = 4 KB = 2 块 18Kb BRAM，代价很小） | 掩盖计算期的读饥饿 |
| B4' 提高 CDC 侧命令 FIFO 深度（AR/AW 4 → 16） | `style_axi_cdc.sv:15-23` 的 `LOG_DEPTH` | 低 | 允许前一条 AR 还没走完就排下一条 |

**B1'+B2' 合计预期**：读侧从 39,000 次往返暴露降到 ~10,000 次 ⇒ 若 B 的 L_r≈100 拍，读时间 3.9 M → 1.0 M 拍，**省 ~20 ms，帧率 17.4 → 26 fps 量级**。这是本报告给出的最高性价比动作。

### 7.7 5 MB bank 间隔的再论证（任务书问）

| bank | 曾写入的层 | 最大占用 |
|---|---|---|
| BANK0 | L0(640×480×4B=1,228,800)、L3(153,600)、L6(153,600)、L9(614,400) | **1.17 MB** |
| BANK1 | L1(614,400)、L4(153,600)、L7(153,600)、L10(640×480×4B=1,228,800) | **1.17 MB** |
| BANK2 | L2(153,600)、L5(153,600)、L8(153,600)（L11 **不写** bank2） | **0.15 MB** |

- **硬约束**：① 结果帧区 `0x05800000..0x05F7FFFF`（6 slot × 1.25 MB）与 BANK0 起点相差 0x80000；② BANK2 区间 `0x06A00000..0x06EFFFFF` 正好顶到权重 blob `0x06F00000` —— **"必须 5 MB"的真正理由是这条，不是 4.9 MB 的帧大小**；③ 同 bank 前后层"边读边写"要求间隔 ≥ 1.17 MB。
- ⇒ `rowpipe_frame_driver.v:73-77` 的 4.9 MB 论证是 **B1j 紧凑化之前**的事实（那时全 16 B/px）。今天 2 MB 就够。**结论：常数不用改（安全），但注释会误导后人，建议在报告里记一笔。**

---

## 8. 可疑代码清单（事实 / 推测分开）

**事实（代码如此，可直接验证）**

| # | file:line | 现象 | 为什么可疑 | 置信度 |
|---|---|---|---|---|
| ① | `rowpipe_ddr_banks.v:446,451,491-501` | 每个 16 B 写 = 1 条 AW + 1 拍 W + **等 B** + 才发下一条 | 写通道 in-flight=1，命令:数据 = 1:1，DDR3 写响应延迟被逐 beat 暴露 | 事实（结构）；对帧率的权重见 §7.4 矛盾 |
| ② | `rowpipe_ddr_banks.v:251-257` | `want_r` 单标志 ⇒ 同时只有 1 个读 burst 在飞 | 每 16 beat 暴露一次 AR→首拍往返（含双向 CDC） | 事实（结构） |
| ③ | `rowpipe_ddr_banks.v:768` vs `:762` | `beat_push` 那拍 `wr_ready=1` 不看 `wr_p_ready` | 若 count 在这两拍间变化就丢 beat；当前靠"无其它 push 源"侥幸正确 | 事实（脆弱设计，中风险） |
| ④ | `rowpipe_ddr_banks.v:834` + `rowpipe_engine.v:418` | `wr_idle` 不含打包器残留像素 | 层末同步不完整；`hout*wout` 不是 `2^pf` 倍数时会跨层错写 | 事实（潜在 bug，当前未触发） |
| ⑤ | `rowpipe_engine.v:418` / `rowpipe_frame_driver.v:183` | `S_WAITPIX` / `S_FLUSH` 无超时 | `result_pixels` 与描述符不符即永久挂死，且 `busy` 永不落 | 事实 |
| ⑥ | `rowpipe_ddr_banks.v:747` / `:671` | `virt`(bank2 && layer==11)、源帧(bank==3) 都是隐式编码 | 加层/重排 bank 即静默失效（结果帧不写 → 黑屏） | 事实（可维护性） |
| ⑦ | `rowpipe_ddr_banks.v:208,327` | `free_ok` 阈值 + MAXB 恰好 = DEPTH（48+16=64、32+32=64） | 零余量：MAXB 一动就静默覆盖未读数据 | 事实 |
| ⑧ | `rowpipe_ddr_banks.v:696,706` | L8 的 `srcb=1`、`idb=2`、`dstb=2` ⇒ **res 读与写同一 bank2** | 靠"写指针落后读指针约 2 行"才安全；若某天改成分组/更小缓冲即踩 | 事实（设计假设） |
| ⑨ | `style_network_rowpipe.sv:137-141` | 5 个 stat 口恒 0 | APB 的算力/预取统计在 rowpipe 板上全是 0，易被误当"没跑" | 事实 |
| ⑩ | `rowpipe_frame_driver.v:175-186` | FSM 不看 `bank_error` | AXI 出错时帧照跑完并报 done，错误只能靠 APB 状态位看到 | 事实 |
| ⑪ | `style_accel.sv:109,118`（本报告顺带发现） | 同时实例化 `style_network_rowpipe` 与 `style_network`，两者共用同名 wire 与同一组 AXI | 若都综合则双驱动；必须确认生成条件 | 事实（**需 Lead 复核**，我只读 5 个文件） |
| ⑫ | `rowpipe_engine.v:89` + 描述符 | `srcW=win/2`（上采样）依赖 win 为偶数 | 描述符写错奇数即半列错位（静默） | 事实（未触发） |

**推测（需要波形/实测确认）**

| # | file:line | 推测 | 依据 | 置信度 |
|---|---|---|---|---|
| ⑬ | `rowpipe_ddr_banks.v:251-257` | 读侧单 burst 是 49.1 ms 的主因 | wburst 只 +6% 的反证 + 每次 burst 的往返无法被掩盖 | **中高** |
| ⑭ | `rowpipe_ddr_banks.v:474-504` | 若 49.1 ms 来自 profiler counter[3]，则写侧为主因 | 4.91 M/374,400 = 13.1 拍/beat ≈ B 延迟 | 中（与⑬互斥） |
| ⑮ | `rowpipe_engine.v:201-202` | `res` 层两条读流必须**同拍**就绪，否则 `s_vld` 抖动会让窗口错位 | 层的 `adv` 依赖 `s_vld`（`rowpipe_layer.v:36-41`） | 低（两流共用 ptr，暂未暴露） |
| ⑯ | 全局 | 显示/采集与 rowpipe 共享 DDR 的仲裁损失可能占 10~20% | 显示读 2.46 MB/帧 + 采集写，`axi_shared_ddr_2m` 的 `VIDEO_READ_PRIORITY` 配置 | 中（需 profiler counter 0/6） |

---

## 9. 与 reports/ARCHITECTURE_FULL.md 的出入

（**未修改该文档**，只记录。行号指该文档。）

| # | 文档位置 | 文档说法 | 源码事实 | 性质 |
|---|---|---|---|---|
| 1 | `:122` | L0 读 `0x05800000`（源帧） | L0 读 `source_address`，源帧区 = **`0x05000000 + slot×0x140000`**（`:112` 自己也这么写）；`0x05800000` 是**风格帧**基址（`:113`）。⇒ 文档自相矛盾 | **文档错**（Lead 已判） |
| 2 | `:122-124` | L0/L1/L2 三层都标 "stride 2" | `L0.s2=0`（全分辨率进全分辨率出）；只有 **L1/L2 的 s2=1** | **文档错** |
| 3 | `:140` | "bank 三层复写：L5 写 bank2 → L6 读 → L8 写（覆盖）→ L9 读 → L11 写（覆盖）" | bank2 的写者是 **L2/L5/L8/L11 四个**，读者是 L3/L6/L9；且 **L11 不写 bank2**（virt 改写结果帧），所以"最后写入者"是 **L8**，不是 L11 | **文档错（3 处）** |
| 4 | `:197` | "L11 输出 写 bank2（`0x06A00000`）" | L11 的写走 `virt` ⇒ `beat_addr = result_address + …`，**bank2 基址完全不用** | **文档错** |
| 5 | `:260` | 地址表 "中间 BANK2 … + L11 输出" | 同上，BANK2 从未被 L11 写过 | **文档错** |
| 6 | `:126-130` | L4/L6/L8 都标 "残差 + **idxor**" | 只有 **L4 的 idxor=1**；L6/L8 是 `res=1, resu=0, idxor=0`（符号扩展路径） | **文档错** |
| 7 | `:324` | 写命令 "451,250/帧 → 90,250/帧" | 按描述符算是 **374,400 写 beat/帧**（= AW 数）。451,250 口径不明（可能是旧描述符集/21 层网络） | **口径待复测** |
| 8 | `:306,320` | "实测有效 0.26 GB/s"、"DDR 等待 49.1 ms（86.2%）" | 0.26 GB/s = 14.75 MB × 17.4 fps，**是事务量的结果不是上限**；49.1 ms 的量测载体（`style_ddr_profiler`）**当前没实例化**，且 counter 定义里 counter[3] 正是"等 B" | **解释需修正** |
| 9 | `:69` | "rowpipe_wr_engine / rd engine（3 个 AXI 口 + FIFO 阵列）" | 只有 **1 条 AR**（4 客户分时）+ **1 条 AW/W**，不是 3 个 AXI 口 | 文档措辞不准 |
| 10 | `:175` | 权重 blob 22,512 B（1,407 beat / 903 beat = 14,448 B） | **903 beat 正确**（`wbase_of` 末项 L11=854 + `4×9+13=49` = 903，`rowpipe_engine.v:251-269`）；但 **22,512 B 的来源不是当前 DDR 通路**：一是固件注释 `style_driver.c:38-39` 的旧口径，二是**未被实例化**的 file-based `rowpipe_wmem_stream`（`rowpipe_ddr_banks.v:638`，`mem[0:1406]`）⇒ 该条目应只保留 903 beat / 14,448 B | 🟡 **表述需收窄**〔2026-10-27 复核〕 |
| 11 | `:114` | XBGR，R 在 bit[23:16]，引 `rowpipe_ddr_banks.v:808` | ❌ **本条判断有误**：`rowpipe_ddr_banks.v` 那行只是**逐字节拷贝**（`{8'h00, wr_data[23:0]}`），证明不了字节序；实际 **R 在 bit[7:0]**——`ti60f225_oob_top.v:830` `R=display_pixel[7:0]`、`style_display_beats.sv:16` 逐字节展开、`REPLY_TO_MODEL_20s_experiment.md:84` 三重佐证。**2026-10-27 已据此修正 `ARCHITECTURE_FULL.md:114`** | ❌ 原判断错，已改 |
| 12 | `:78-80`（frame_driver 行号） | "bank 基址 `rowpipe_frame_driver.v:78-80`" | 正确（`:78,79,80` 三个 localparam） | ✅ 一致 |
| 13 | `:381` | 修复 #4 "`rd_idx = rptr + beat_idx + wready`" | 现状是三个流里的 `ridx_n = rd_idx + pop` + 寄存读（`rowpipe_ddr_banks.v:202,319,454`），**修复在位**，但表述应更新 | 表述过时 |
| 14 | 文档未记 | `srcf/dstf/idf` 位域（`[101:100]/[103:102]/[105:104]`）与 4/8/16 B/px 紧凑格式 | 这是决定 DDR 账的关键位域，**文档完全没有** | **文档缺失** |
| 15 | 文档未记 | `S_RPAD` / `cfg_skiplen`（B1f 整行空跑）、`replay` 影子（B1h）、`eng_low`（防第二帧 done 误判） | 三处都是踩过坑的修复，且注释里写明"实测" | **文档缺失** |
| 16 | `:73-77`（frame_driver 注释） | "间隔必须 ≥5 MB（16B/px × 307200 = 4.9 MB）" | 当前描述符下最大 bank 占用 **1.17 MB**；5 MB 的真实必要性来自"BANK2 末尾顶到权重 blob `0x06F00000`" | **注释过时**（安全但误导） |

---

## 10. 给 Lead 的 5 条要点

1. **带宽：读写两侧同时坏，只修一侧只值 +6%。** 写侧 = 单 beat + 逐 beat 等 B（374,400 beat/帧 × ~13 拍/beat = 49.1 ms @100 MHz，与 profiler counter[3] 定义吻合）；读侧 = `want_r` 单标志把并发限成 1 个 burst（每 16 beat 暴露一次 AR→首拍往返，且 `MAXB=16` 是自己加的、比 4KB 页允许的 256 beat 紧 16 倍）。**历史 wburst 只改写侧 = 17.4→18.5 fps（+6%）就是"另一侧接棒"的实测证据。** 建议：读侧先上（`MAXB` 16→64、允许 2~3 个 burst 在飞、FIFO 64→256，只动参数与 `free_ok`/`want_r` 逻辑，不碰打包），写侧紧随（优先"posted B"而不是重写 burst 合并）。

2. **`49.1 ms` 的归因可用现成工具一次测清。** `style_ddr_profiler` 在 `ti60f225_cam_hdmi.xml:91` 的工程文件里但**没有任何实例化**（死代码），12 个 counter 的语义已被 `tests/style_ddr_profiler_tb.sv:25,42-45` 逐位钉住：**3 = W 发完到 B 回来的拍数**、7 = 读 stall、8 = 读流水气泡、10 = AR stall。挂回 `style_video_system` 的 `axi_clk` 侧读一次，就能给出两侧各占多少，从而决定先上 §7.5 还是 §7.6、以及验证改完的效果。

3. **`virt` 通路已核实正确且唯一**（L11.dstb=2 → mem_wr_bank=2 → `wr_bank==2 && cur_layer==11`），但它是**隐式约定**（只有最后一层写 bank2），且 `bank_base2` 在 virt 下完全不用。**顺带修正三处文档错误**：L11 不写 bank2（写结果帧）、BANK2 的最后写入者是 L8、文档把 L6/L8 也标了 idxor（实际只有 L4）。

4. **两个真实隐患值得排期**：① 打包器残留像素不计入 `wr_idle`（`rowpipe_ddr_banks.v:834` + `rowpipe_engine.v:418`）——当前 12 层 `hout*wout` 都能被 4 整除所以没炸，但这是"改一层尺寸就错写下一层 bank"的定时炸弹；② 两处无超时挂死点（引擎 `S_WAITPIX`、driver `S_FLUSH`），一旦 `frame_width*frame_height` 与描述符 `hout*wout` 不一致就永久 busy。②的修法很便宜（加一个 1M 拍看门狗置 `error`）。

5. **另有三条需要别人确认的小事**：(a) `style_accel.sv:109` 与 `:118` 同时实例化了 rowpipe 版与原版 `style_network`，**共用同名 wire 与同一组 AXI** —— 请读 style_* 的同事确认生成条件里是否有一个被条件化掉（否则双驱动）；(b) `frame_driver.v:73-77` 的 "5 MB/4.9 MB" 注释是 B1j 之前的，今天 1.17 MB 就够，真正约束是 BANK2 顶到权重 blob；(c) `style_network_rowpipe.v:137-141` 的 5 个 stat 口恒 0 ⇒ **APB 的算力/预取统计在 rowpipe 板上永远读 0**，任何基于它的性能结论都不成立。
