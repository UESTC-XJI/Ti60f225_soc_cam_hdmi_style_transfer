# style 子系统逐行阅读

> 范围：`rtl/style/` 全部 **14** 个 `.sv`（任务写"15 个"但只列 14 个，目录也只有 14 个，无缺失）。
> 交叉引用（只读）：`rtl/ti60f225_oob_top.v`、`rtl/debayer/debayer_top_2to1.v`、`rtl/accel_rowpipe/style_network_rowpipe.sv`、
> `rowpipe_ddr_banks.v`、`rowpipe_engine.v`、`conv3x3_core.v`、`reports/ARCHITECTURE_FULL.md`、`reports/BOARD_REPLY_bank_reuse.md`。
> 方法：`read` 全文通读 + python 手算；**未跑综合/构建**。按**工作区当前内容**（含未提交的 XOR 修复）描述。

## 结论摘要（5 条）

1. **显示通路不可能"糊"。** DDR→HDMI 是一次严格 1:1 拷贝：`style_axi_rows` 只重排字节、`style_display_beats` 只剥 X 填充字节、
   像素 FIFO 只搬运、`style_display:121` 是 `pixel<=image&&match ? packet[31:0] : 0`。**匹配失败一律变黑，无插值/复制/移位**。
   ⇒ "双面板空间细节损失"不可能是 `style_display` 的匹配/欠载逻辑造成的（量化证明见「显示路径专题」）。
2. **σ 12.3 vs 23 是量纲不一致，不是丢了细节。** 23.0 是 DDR 里**单通道 R** 的 σ（`BOARD_REPLY:145-150`：R=23.0/G=44.9/B=26.1），
   12.3 是截图 **luminance=(R+G+B)/3** 的 σ（同文件 `:33`）。若三通道独立，`σ_lum=√(23²+44.9²+26.1²)/3=18.9`；
   实测 12.3 ⇒ 隐含通道相关 ≈0.6（风格化输出正常），再叠加采集卡 1280→1920 的 1.5× 低通。
3. **帧缓存是 6 态不是 3 态**（文档 §111 错）。6 态 + `ready_queue`(FIFO 顺序推理) + `latest_slot`(最新完成显示) 双轨设计自洽，
   未发现漏帧/泄漏；唯一的可观测性缺口是**换槽不可检测**（`epoch` 由 display 自己产生，与 slot 的 `frame_ids` 无关）。
4. **XOR 修复自洽。** 全工程只剩 2 处 `^0x808080`：`style_display:107`（活，仅 `right_side`，正确）与
   `style_axi_rows:57`（**写**方向，而活配置 `wr_start=0'b0` ⇒ 死代码）。无三次、无零次。
5. **两个彻底死的东西**：`style_accel` 的 `g_monet` 支（`style_network`/`row_core`/`mac8x12`，`USE_ROW_PIPE` 从未被覆盖）
   与 `style_ddr_profiler`（全工程无实例）。后果：**APB `0xa8/ac/b0/b4/b8` 五个性能快照在板上恒 0**，`0x2c` 系数写口空写。

---

## 系统级：style_video_system 的六段流水

```
              cnn_clk 148.5M              clk 100M                      pix_clk 74.25M
 rgb_datax2 ─►┌─────────┐ 34b ┌──────┐  ┌────────────┐ AXI写 ┌───────┐
 (48b,2px/clk)│vga_crop ├────►│cap   ├─►│frame_store │──────►│ DDR   │
              │2×2 平均 │     │fifo  │  │6 对 slot   │◄──r───│0x0500…│
              └─────────┘     │34/11 │  │FSM 6 态    │       │+0x80… │
                              └──────┘  └─────┬──────┘       └───┬───┘
                                              │nn_start/src/res  │
                                        ┌─────▼─────┐ AXI读/写   │
                                        │style_accel├────────────┘
                                        │APB+mailbox│
                                        │└rowpipe活 │
                                        │└network死 │
                                        └───────────┘
              ┌────────────┐ 20b ┌──────┴─────┐ AXI读
 ch0_hs/vs/de ◄┤style_display├◄──┤requests 16 │
 display_pixel │720p60/双单面板│  └────────────┘
               │pix_fifo 60/512│
               └───────────────┘
 panel_key ─► style_key_toggle(clk,5ms) ─► single_panel ─► 双域各 2FF
```

| 段 | 时钟 | 驱动 | 输出 | 握手/背压 |
|---|---|---|---|---|
| ①`style_vga_crop` | cnn_clk | debayer `rgb_vs/de/datax2` | `valid/sof/eof/pixel` 1px/拍 | 无背压，下游必须吞 |
| ②`capture_fifo` | 写 cnn / 读 clk | ① | 34b `{sof,eof,pixel}` | 满则 `cap_overflow`（粘滞） |
| ③`style_frame_store` | clk | ② | 512B AXI 写 + `nn_*` 邮箱 + `display_slot/valid` | `cap_ready=state==COLLECT`；换槽看 `display_safe` |
| ④`style_accel` | clk(APB)+cnn(核) | ③ 或 APB | AXI 主、`job_done/error` | mailbox+toggle |
| ⑤`style_display` | clk(行FSM)+pix | ③ 的 slot；pix 自走时序 | `pixel/hs/vs/de/underflow` + AXI 读 | 请求/像素双向 FIFO |
| ⑥`style_key_toggle` | clk | 板载 `panel_key`(低有效) | `toggle→single_panel` | 2FF+5ms 消抖 |

三处外部接口：APB（`paddr[7:0]`，`style_select=paddr[15:8]==8'h02`，顶层 `:629`）、AXI（`awid/arid` 6 位 → `axi_shared_ddr_2m`）、板载按键。
全子系统 AXI 事务统一 **16B/beat、INCR**（`:70-75` `awsize=3'd4, awburst=2'b01`）。

---

## 逐文件章节

### 1. `style_video_system.sv`（82 行）

**职责**：demo 分支的"视频系统替身"，顶掉基线 resize/framebuffer/CVO（`:1`）。全工程唯一实例在 `rtl/ti60f225_oob_top.v:633`（`style_demo`）。

**端口**：时钟组 `clk/cnn_clk/pix_clk`（顶层接 `core_clk 100M / vid_clk_dvi2 148.5M / hdmi_tx_slow_clk 74.25M`，`:634`）；
`key_panel`（异步，低有效）；`rgb_vs/rgb_de/rgb_data[47:0]`（**cnn_clk**，2px/拍）；APB 从机；`pixel[31:0]/hs/vs/de/underflow/capture_fault/resized_frames`；
AXI 主 5 通道；`parameter bit DISPLAY_BUFFER=1'b1, ADAPTIVE_READ=1'b1`（**顶层未覆盖任何参数**）。

**逐行要点**
- `:19` crop 挂 **cnn_clk**（=debayer 输出域）✓。`:22` `enable_sync` 是 `stream_enable`(clk) 的 2FF 进 cnn。
- `:24` `cap_input_valid = crop_valid && (crop_sof ? enable_sync[1] : cap_gate)` —— 帧首用同步后的 enable，帧中只看锁存值
  ⇒ **enable 在帧中变化不会撕裂当前帧**（只影响下一帧）。
- `:25-33` `cap_gate` 在 sof 采样、eof 清 0；`cap_overflow` 在 `cap_input_valid&&!cap_input_ready` 置 1，**粘滞仅在复位清**。
- `:34` `capture_fault = crop_fault||cap_overflow`。注意 `crop_fault` **恒 0**（见 §2 R1），所以板上 LED1 只反映 `cap_overflow`，且一次溢出后永久亮。
- `:35-37` `capture_fifo #(34,11)`=2048 深。余量：抓帧入率 307200px/33.3ms=**0.092 px/clk@100M**；store 吞吐 128/165=0.78 px/clk
  ⇒ 8.4× 余量；FIFO 可吸收 2048/0.092≈**22,260 clk≈222 µs**（≈6.7 摄像头行）的 AXI 停顿。
- `:38-45` 声明。`nn_cycles` 只作为 accel 的 `last_cycles` 落点，**值再无消费者**。`unused_bid/rid` 被桥驱动后丢弃。
- `:46-50` store 实例。`:52` key 在 clk 域。`:53-56` display 实例（读走 `vid_arid=2`，写走 `vid_awid=1`）。
- `:69-78` 桥：`DDR_ID_W(6)`、`URGENT_OVERRIDES_FAIRNESS=0`、`RESERVE_URGENT_READ=0`、`VIDEO_READ_PRIORITY=!ADAPTIVE_READ`。
- `:79-81` `prdata` 旁路：`0x38 captured / 0x3c dropped / 0x40 inferred / 0x44 infer_errors / 0x48 display_frame_id / 0x4c display_dma_errors / 0x50 bridge_errors`，
  其余透传 `accel_prdata`。这 7 个地址在 accel 里走 default（读 0）⇒ 无冲突。

**风险**：R1（事实）`0x38..0x50` 的读没有独立 `pready`，共用 accel 的（几乎恒 1），语义不干净但无害。
R2（事实）`irq` 只来自 accel，`underflow/dma_errors` 无中断，只能轮询。
R3（事实）注释说"nested bridge saves full local IDs"，实际 ID 被丢弃，未保存。

**文档偏差**：模块树（`ARCHITECTURE_FULL:59-76`）未列 `style_ddr_profiler`（死文件）、未标注 accel 有两支互斥实现。

---

### 2. `style_vga_crop.sv`（48 行）

**职责**：1920×1080 → 中心 **1280×960** → **2×2 四舍五入平均** → 640×480，1px/拍（只在奇数源行出数）。
**端口**：`clk,rst_n,i_vs,i_de,i_rgb[47:0] → valid,sof,eof,pixel[31:0],fault,completed_frames[31:0]`，单域（cnn_clk）。

**逐行要点**
- `:10` `X0=(1920-1280)/4=160, Y0=(1080-960)/2=60`。**X0 除 4 是因为 `pair_x` 单位是"像素对"**（1 拍 2 像素）⇒ 160 pair = 320 源像素左边距 = (1920-1280)/2 ✓。
- `:11` `line[0:639]` 27b，只存偶数行的 `pair_sum`。
- `:17` `pair_sum[c*9+:9]={1'b0,i_rgb[c*8+:8]}+{1'b0,i_rgb[24+c*8+:8]}`。**全工程最容易读错的字节序陷阱**：
  `debayer_top_2to1.v:150-151` 拼接为 `{b1,g1,r1,b0,g0,r0}`（MSB→LSB）⇒ **`i_rgb[7:0]=R0`、`[23:16]=B0`、`[31:24]=R1`**；
  c=0 取 R0+R1 ⇒ **`pixel[7:0]=R`**，像素字 = `{8'h00,B,G,R}`。顶层注释 `//b,g,r,b,g,r` 是"MSB 在前的字节串"，不矛盾。
- `:19-20` `inside_crop=started&&i_de&&pair_x∈[X0,X0+640)&&y∈[Y0,Y0+960)`（960=480×2）；`odd_row=(y-Y0)&1`。
- `:21-24` 偶数行写 line、奇数行读 line→`previous` + `pair_sum`→`current`（读写互斥，单端口够）。
- `:30-32` `v1<=inside_crop&&odd_row&&!fault`；`s1<=(pair_x==X0&&y==Y0+1)`；`e1<=(pair_x==X0+639&&y==Y0+959)`;
  `valid<=v1; sof<=s1&&v1; eof<=e1&&v1` ⇒ sof/eof 与首/末像素**严格同拍**（逐拍推过，成立）。
- `:33-40` 唯一算式：`total = prev[c*9+:9]+cur[c*9+:9]+10'd2`（≤510+510+2=1022，10 位刚好）→ `pixel[c*8+:8]=total[9:2]`，
  即 `(a+b+2)>>2` 四舍五入 ✓。`:39` `if(e1)completed_frames++`（按帧计数，顶层接 `resize_completed_frames`）。
- `:41` `if(vs_d&&!i_vs)` 用 **vs 下降沿**起帧（`started<=1`）。`:42-45` `i_de&&started` 时 `pair_x` 0..959、`y` 0..1079 循环 ——
  **完全不信行同步，只按 `i_de` 拍数硬数**；行长短抖动会把后续行整体错位，且无任何检查。

**风险**：R1（事实，高，静态可证）**`fault` 从未被置 1**（全文只有 `:27` 复位分支赋值）⇒ crop 侧异常完全无检测。
R2（推测，低）`started` 置 1 后永不复位，vs 丢失时会表现为垂直滚动而非报错。
R3（事实）2×2 平均是有损低通 —— 真实的细节收缩，但发生在**写 DDR 之前**，DDR 里存的已是平均后帧，故不能解释"显示 σ < DDR σ"。
R4（事实，低）行缓存/`previous`/`current` 无复位（`:21`），但首行奇数行前 line 已被写过，不暴露。

**文档偏差**：文档未记录 2×2 平均这一步（只在源码 `:2` 注释里）——这是 σ 的第一个真实收缩点。

---

### 3. `style_async_fifo.sv`（60 行，9 个实例）

**职责**：灰码指针异步 FIFO + 读侧弹性输出寄存器 + 写侧水位。**全子系统所有跨域数据的唯一基石**。
**端口**：`reset_n,wclk,rclk,in_valid/in_ready/in_data / out_valid/out_ready/out_data, write_level[LOG_DEPTH:0]`（写域输出）。

**逐行要点**
- `:8` `wp/rp/wg/rg` 各 `LOG_DEPTH+1` 位（多一位区分满空）✓。`:9` 两组 2FF（`rg1/rg2,wg1/wg2`，带 `async_reg`）。
- `:11-15` 复位同步器 `wrst/rrst`；`in_ready=wrst[1]&&!full`；`full = wg=={~rg2[top],rg2[top-1:0]}`（经典高两位取反比较）✓；`empty = rg==wg2` ✓。
- `:19-23` 灰→二进制组合转换 ✓。`:26` `write_level = wp-read_binary`，注释明说"不含读侧弹性字、可能滞后 2 拍"⇒ **偏保守（偏大）**，
  正好是 `style_display:75` 想要的"宁可早报急"。
- `:27` `generate if(LOG_DEPTH<=4 && WIDTH<=45)`：小 FIFO 走触发器阵列（`flat`+逐项使能），大 FIFO 走 `mem[]`+`syn_ramstyle=block_ram`。
  分档结果：`requests(20,4)/ar(40,2)/aw(40,2)/coeff(45,2)` 触发器；`w(145,4)/r(131,4)/pixels(60,9)/capture(34,11)` 走 mem。
- `:37-39` **大支是组合读**：`assign read_word=mem[rp[...]]` —— 与文件头 "synchronous RAM prefetch" 不符。
  读侧 `:54-57` 是"永远预取下一字"的弹性寄存器，吞吐 1 字/拍、延迟 1 拍 ✓。
- `:41-48` 写侧：`if(!wrst[1])` 时把 `wp/wg/rg1/rg2` 全部清零（复位期顺手清自己的同步器，防垃圾）✓。
- `:49-59` 读侧：`if(!out_valid||out_ready)` 才推进；`rp<=rn; rg<=gray(rn)` ✓。

**风险**：R1（推测，中）`:39` 的**异步读**（尤其 `pixels` 60b×512、`capture` 34b×2048）在 Efinity 上可能展开成巨型 LUT mux，
在 XLR 97% 的边界上不可忽视。**未跑综合，未验证**；对比 `style_display_beats:19` 同一作者做的是同步读。
R2（事实）`write_level` 偏大 ⇒ `pixel_level<384` 阈值方向安全。R3（事实，极低）复位释放不同步，但被 `in_ready` 的 `wrst[1]` 门控。

**文档偏差**：文档只列 display 的 2 个 FIFO，实际 **9 个**（+capture/coeff/ar/aw/w/r/b）。

---

### 4. `style_frame_store.sv`（130 行）

**职责**：6 对 slot 的帧管理 + 512B AXI 写引擎 + 推理调度（FIFO 顺序）+ 显示调度（最新完成）。
**端口**：`cap_valid/cap_ready/cap_packet[33:0]`；`stream_enable`；`nn_ready/done/error` → `nn_start/nn_source/nn_result`；
`display_frame_event/display_safe`（in）→ `display_slot[2:0]/display_valid`（out）；5 个 32 位统计；AXI 写 5 通道。

**内部结构**：`:15` 六态；`:16-17` 所有权/帧号数组；`:20` `burst_buffer[0:31]`；`:23-29` `raw_base()`；
`:30-37` 空闲扫描/READY 环/latest；`:39-45` 组合找空闲槽+打包；`:46-49` AXI 组合输出；`:52-56` 写缓存流水；`:57-129` 主 FSM。

**逐行要点**
- `:15` `FREE=0,CAPTURE=1,READY=2,INFER=3,COMPLETE=4,DISPLAY=5` —— **6 态，文档 §111 的"3 态"是错的**。
- `:23-29` `raw_base()` 逐条列死：`0x05000000/0x05140000/0x05280000/0x053C0000/0x05500000/0x05640000`，步长 `0x140000`；
  风格帧 `+0x00800000`（`:87`）。帧实占 640×480×4=**0x12C000**，每 slot 富余 81,920B(6.25%) ⇒ 行永不跨 slot。
- `:20` 512B 突发缓存 = 一整个最大突发（`awlen=31`）。
- `:31` `ready_queue[0:5]` + head/tail/count(4 位)。为什么 6 够：READY 数 ≤ 非 INFER/DISPLAY 的槽数 ≤ 6，永不溢出。
- `:34-36` **两套机制**：推理按 `ready_queue` 的 **capture 顺序**（`:67-68` 注释：单任务完成顺序即入队顺序，无需 32 位比较级联）；
  显示取 `latest_slot`（最新完成）。`pop_ready = stream_enable&&nn_ready&&!infer_active&&ready_found`（单任务、单推理器）。
- `:37` `push_ready = state==RESP&&bvalid&&bready&&frame_final&&!frame_bad&&bresp==0` —— **只有最后一组突发写成功才入 READY**。
- `:41-43` 空闲扫描从 0 号槽往上找第一个 FREE（6 级优先链，组合）。`:44` `pack_next[pack_index*32+:32]=cap_packet[31:0]`（**字节序不动**）。
- `:46` `cap_ready=state==COLLECT`（抓帧期 1 包/拍，只有打突发时才关闸）。`:47-49` `awlen=31`、`wstrb=16'hffff`、`wlast=send_index==31`。
- `:51-55` `burst_read_address = state==PREFETCH?0:send_index+1`；`if(state==PREFETCH||(wvalid&&wready&&!wlast)) send_word<=burst_buffer[...]`
  —— 读地址提前一拍的标准写法 ✓。
- `:53-54` 只有"128 位字的第 4 个像素"且 `(!eof||cap_pixels==FRAME_PIXELS-1)` 才写缓存 ⇒ **不写残缺突发**（307200%4==0，末组必满）。
- `:69-73` `case({push_ready,pop_ready})` 同拍进出净变化 0 ✓。`:74-75` 入队/出队。
- `:76-85` **显示切换**：`if(display_frame_event) display_pending<=1;`
  `if(display_pending&&display_safe)` → 清 pending；若有 `complete_found`：释放旧 DISPLAY 槽 → 释放**所有非 latest 的 COMPLETE** →
  `complete_slot→DISPLAY`、`display_slot<=complete_slot`、`display_valid<=1`、`latest_valid<=0`。
  **无帧可显示时 `display_pending` 也清 0（一帧只试一次），旧槽继续显示** ⇒ 画面冻结但链不阻塞，且**显示侧丢帧不计数**（文档未记录）。
- `:86-89` 推理启动：`nn_source=raw_base(ready_slot)`、`nn_result=+0x800000`、`ownership→INFER`。
- `:90-94` `nn_done`：错→FREE+`infer_errors++`；对→COMPLETE+`inferred++`+`latest_slot/latest_valid`。
- `:96-114` COLLECT：sof（`:97-102`）若上一帧未收完则丢回 FREE 并 `dropped++`；无空闲槽则 `dropped++` 且整帧丢（FIFO 像素被消费掉，不堆积）；
  eof 但像素数≠307200 → 丢（`:104-105`）；正常像素 → `pack_index`0..3 → `fill_index`0..31 → 第 32 组时
  `awaddr<=raw_base(cap_slot)+cap_offset; frame_final<=cap_packet[32]; state<=ADDR`。
- `:115-126` ADDR→PREFETCH→SEND→RESP。RESP：`bresp!=0` 置 `frame_bad`、`cap_offset+=512`；最后一组时成功→READY+`frame_ids<=captured`、失败→FREE+`dropped++`。
- 地址算式：`0x05000000 + slot*0x140000 + burst*512`，burst 0..2399（`cap_offset` 21 位，2400×512=1,228,800 ✓）。

**所有权 FSM（必答）**

| 转移 | 触发 |
|---|---|
| →CAPTURE | 空闲槽被 sof 选中（从 0 号槽向上的第一个 FREE） |
| CAPTURE→READY | 最后一组突发 `bresp==0`（且 `!frame_bad`） |
| CAPTURE→FREE | eof 像素数错 / 任一 bresp≠0 / 被下一 sof 抢占 / 无空闲槽 |
| READY→INFER | `pop_ready` |
| INFER→COMPLETE / FREE | `nn_done && !nn_error` / `&& nn_error` |
| COMPLETE→DISPLAY | `display_pending&&display_safe&&complete_found` |
| DISPLAY→FREE / COMPLETE→FREE | 下次切换时释放旧显示槽 / 释放所有非 latest 的 COMPLETE |

**一致性核对（同拍冲突逐项）**：①`nn_done` 置 COMPLETE 与"回收其它 COMPLETE"同拍 —— 回收读旧值（此槽是 INFER）⇒ 不会误收 ✓；
②显示释放与 capture 抢同槽 —— 扫描是组合块用旧值，该槽这拍选不中，慢一拍无害 ✓；③READY→INFER 与 capture 抢槽不可能（READY≠FREE）✓。

**风险**：R1（事实，高，现场级）`pop_ready` 被 `stream_enable` 与门挡住 ⇒ **关掉 stream_enable 会让 READY 帧永久积压、画面冻结而抓帧计数继续涨**（与 §5 R1 的 APB 陷阱会互相掩护）。
R2（事实，中）**换槽不可检测**：`row_epoch` 来自 display 自己的 8 位 epoch，与 `frame_ids` 无关 ⇒ 若切换发生在帧中，"半帧来自 A、半帧来自 B"不会被 `match/obsolete` 发现。
（触发窗口很窄：`display_pending` 通常在 `v≈0` 的 IDLE 就被消费；但**理论窗口存在**，属可观测性缺口。
建议把 `frame_ids[7:0]` 也塞进请求包校验。）R3（事实，低）`frame_id` 32 位回绕。
R4（事实，低）`dropped` 混杂 5 种原因（无空闲槽/eof 错/bresp 错/被抢占/…），**且不含显示侧丢帧**，现场无法区分。

**文档偏差**：**§111 "3 态"→实际 6 态；§112 "每 slot 1.25MB"→实际步长 1.31MB、帧占 1.2288MB；
§114 "R 在 bit[23:16]"→错，R 在 bit[7:0]**（§2 `:17` 推出；文档引的 `rowpipe_ddr_banks.v:808` 只是逐字节拷贝，证明不了字节序）。
另有 `display_pending` 的"一帧一请求、无帧可显就丢"语义未记录。

---

### 5. `style_accel.sv`（128 行）

**职责**：APB 从机（100M）+ cnn_clk 域计算核外壳。稳定 mailbox + 完成 toggle 跨域；45 位系数 FIFO 搬 APB 写。

**APB 映射（逐个核对）**

| addr | 读 | 写 | 备注 |
|---|---|---|---|
| `0x00` | `0x3154534e`("NST1") | — | MAGIC，固件据此认设备 |
| `0x04` | `{27'b0,stream_enable,4'b0}` | `bit4=stream_enable`，`bit0=启动` | **见 R1 陷阱** |
| `0x08` | `{27'b0,coeff_idle,1'b0,error, done,pending}` | `bit1`清 done / `bit2`清 error | |
| `0x0c` | `irq_enable` | `irq_enable` | |
| `0x10/14/18` | `source_cfg/result_cfg/geometry` | 同 | 默认 `0x05000000/0x05800000/{480,640}` |
| `0x1c` | `last_cycles` | — | 核周期（cnn_clk 拍）✓ 有效 |
| `0x28` | `coefficient_index` | `coefficient_index[15:0]` | `pwdata[4:0]>23` 报 pslverr |
| `0x2c` | 0 | **写系数 FIFO(45b×4)** | 活支空写（R3） |
| `0x30` | `{acknowledged,issued}` | — | 灰码已收/已发 |
| `0x34` | `148500000` | — | cnn_clk 频率 |
| `0xa8/ac/b0/b4/b8` | 5 个性能快照 | — | **活支恒 0**（R2） |
| `0xbc` | 0 | — | 文档说有，**不存在** |

**逐行要点**
- `:3` `USE_ROW_PIPE=1'b1` 默认，**全工程无任何实例覆盖** ⇒ `g_monet` 永不 elaborate。
- `:20-21` `coef_write=psel&&penable&&pwrite&&paddr==0x2c&&!pending`；`coef_input={idx[15:8],idx[4:0],pwdata}`=45b ✓。
- `:24-27` coeff FIFO `LOG_DEPTH(2)`=4 深；注释"four entries cover CDC latency"。核忙时（`:97` `coef_ready=core_reset[1]&&!core_busy`）会满，
  靠 `pready=!(coef_write&&!coeff_input_ready)`（`:43`）**用 APB 等待顶住，不丢** ✓。
- `:28-35` `committed/committed_gray` 在 cnn 加 → `cg1/cg2`(clk) → 灰→二进制 `acknowledged` → `coeff_idle=issued==acknowledged` ✓ 正规灰码。
- `:37-42` `config_ok`：源帧 4KB 对齐且 ∈`[0x05000000, 0x05800000-frame_bytes]`、结果 ∈`[0x05800000,0x06000000-frame_bytes]`、
  `w∈[32,640]且 w[4:0]==0`、`h∈[24,480]且 h[17:16]==0`。代入 640×480：源上界 `0x056D4000`（slot5 `0x0576C000` ✓ 仍在界内）、
  结果上界 `0x05ED4000`（风格 slot5 `0x05F6C000` ✓）⇒ **边界检查实际有效，不是死检查**。
- `:44-46` `pslverr` 三种：pending 期改配置 / 启动但 `!auto_ready||!config_ok` / `coefficient_index[4:0]>23`。
- `:53-55` `done1<=done_toggle;done2<=done1;done_seen<=done2;` + `job_done=done2!=done_seen`（toggle→脉冲）✓；
  `job_error=core_error_snapshot` 是电平，与 `job_done` 同拍采样 ✓。
- `:58` 复位 `geometry<={16'd480,16'd640}` ⇒ w=640,h=480 ✓。
- `:66-74` APB 写：`0x04` **同时** `stream_enable<=pwdata[4]` 与启动位 —— **最大的坑（R1）**。
- `:75-77` `auto_start` 路径：`mail_geometry<={16'd480,16'd640}` **硬编码**，忽略 `0x18`；且**不检查 `config_ok`**（只检查 `auto_ready`）。
  实际无害（`auto_source` 恒来自 `raw_base()` 合法），但"校验只覆盖手动路径"。
- `:80-92` `prdata` 组合，default 读 0 ✓。`:83` MAGIC 小端解出 `"NST1"` ✓。
- `:93-94` `core_reset<={core_reset[0],1'b1}` = **2 位移位复位延长器**（不是 2FF 同步器），`core_reset[1]` 作核 rst_n ⇒ 同步释放+2 拍延长 ✓。
- `:95-97` `core_start=start_sync[1]!=start_seen`（toggle→脉冲）；`coef_ready=core_reset[1]&&!core_busy`。
- `:100-104` cnn 域：`start_sync<={start_sync[0],start_toggle}; start_seen<=start_sync[1];` ⇒ `core_start` 恰是 `start_sync[1]` 的单拍脉冲 ✓。
- `:106-126` generate：`g_row`（活，`style_network_rowpipe`，**5 个 `stat_*` 全接进来**）/`g_monet`（死，`style_network`+`style_row_core`+`style_mac8x12`）。
  **判死三证据**：①默认 1 且无覆盖；②`style_network` 全工程只在 `tests/style_network_tb.sv:31` 有实例；③未 elaborate ⇒ 内部 `$readmemh`/`program.vh` 全不生效。
- `:127` `style_axi_cdc cdc(.*,...)` —— `.*` 隐式连接，端口改名会静默失配（编译期一般会报，风险不大）。

**风险**：**R1（事实，高，现场级）`0x04` 写启动会顺手覆写 `stream_enable`。** 固件若写 `0x04=0x01` ⇒ `stream_enable=0` ⇒
`pop_ready`（frame_store:36）、`auto_start`（本文件:75）、`cap_input_valid`（video_system:24）全被挡 ⇒ **整链停摆、APB 全正常、无任何错误位**。必须写 `0x11`。
R2（事实，中）活支 5 个 `stat_*` 恒 0（`style_network_rowpipe:137-141`），故 `0xa8/ac/b0/b4/b8` 恒读 0 ⇒ **任何基于它们的 DDR 等待分析都是假的**。
R3（事实，低）活支 `coef_we` 进 `_unused` ⇒ `0x2c` 空写，但 `0x30` 照常递增，容易让固件误判"系数已加载"（真权重在 DDR `0x06F00000`）。
R4（事实，低）`pending` 只在 `job_done` 清，**核挂死则永久 pending**，所有配置写被 pslverr 拒，无 watchdog。

**文档偏差**：`§283` 的 `0xbc` 不存在；`§281` 的 5 个快照存在但恒 0（未标注）；未写 `0x04` 陷阱；未说明 `style_network` 是死支。

---

### 6. `style_axi_cdc.sv`（25 行）

**职责**：把 cnn_clk 域核的 AXI 主口搬到 clk 域。**每通道一个 async FIFO，共 5 个**。
**逐行**：`:15-16` AR/`:17-18` AW 均 `(40,2)`，写 cnn 读 clk，`{arlen,araddr}=40b` ✓；
`:19-20` W `(145)`（1+16+128）**LOG_DEPTH 默认 4 ⇒ 16 深 = 256B**，同向；
`:21-22` R `(131)`（1+2+128）**方向相反**（写 clk 读 cnn）；`:23-24` B `(2)`，方向同 R。
`:13-14` 注释："row DMA has one transaction in flight per direction ⇒ shallow control queues suffice"。

**风险**：R1（事实，中）AR/AW 仅 4 深，rowpipe 有 3 个读口共用一条 AR，会被 `in_ready` 反压（正常 AXI 反压，转成核侧延迟）。
R2（事实，中）**W 通道 16 深（256B）是写通道弹性的天然上限**——写通道是 rowpipe 的主要瓶颈（文档 §322 写命令数巨大），
一旦桥反压最多吸收 16 拍就顶回核。这也是"写 burst 合并（MAXB=8）"方案的物理上限（已回退，§324）。
R3（事实，低）B 通道只有 2 位、ID 丢弃 ⇒ **假设一路只有 1 个在途写事务**，将来并行写必须加宽 ID。

**文档偏差**：`§248` 只说"style_axi_cdc"，未记 5 个通道的深度/方向（W、R 是反向的，极易看错）。

---

### 7. `style_ddr_profiler.sv`（33 行）—— **死文件**

**职责**：12 个"接口事件"计数器，本可回答"DDR 卡在哪"。`:13-17` 的 12 项：
`{vid_rvalid&rready, 核 rvalid&rready, network_idle, 写成败, c_wvalid&!c_wready, c_awvalid&!c_awready,
vid 未就绪, c_rvalid&!c_rready, read_active 空转, arvalid&!arready, c_arvalid&!c_arready, 常量1}`。
**逐行**：`:19` `value=index<12?counters[index]:0`；`:23-26` `read_active/write_response` 追踪在途事务；
`:27-30` `clear` 与 `enable&&!freeze` 同拍互斥（clear 优先）✓；`:3` 注释明说"事件重叠，不是时间分区"。

**风险**：**R1（事实，高）全工程无实例** —— 只有 `tests/style_ddr_profiler_tb.sv:9` 与 `ti60f225_cam_hdmi.xml:91`（文件列表）。
接口没接到任何 AXI 信号 ⇒ **现场零统计**，这正是"0.26 GB/s 卡在哪只能靠推理"的原因之一。
**建议**：接进 `style_video_system`（5 个 clk 域观察点），或最小成本把 `style_display` 的
`rd_done/rd_error/underflow/read_urgent` 4 个信号接到计数器。R2（事实，低）`network_idle` 语义无定义（无实例，无从判断）。

**文档偏差**：模块树未列本模块，也没说它没实例化 ⇒ 读者会以为"有 DDR 性能计数器可用"。

---

### 8. `style_display.sv`（153 行）—— 核心

**职责**：固定 720p60 时序 + DDR 行读取 + 双/单面板布局。缺像素补黑、同步不停（`:1`）。DDR 只供两个 VGA 矩形，上下 120 行黑条本地生成（`:2`）。

**端口**：`clk/pix_clk/rst_n`；`display_slot[2:0],display_valid`（in, clk）；`display_frame_event,display_safe`（**out**，clk —— 名字像输入，实为回告 store）；
`single_panel`（in, 按键域）；`pixel[31:0],hs,vs,de,underflow`（out, pix）；`dma_errors[31:0]`（out, clk）；`read_urgent`（out, clk，去桥）；
AXI 读一通道；`parameter BUFFERED=1'b1`。

**时序/几何（必答，全部复核）**

| 项 | 值 | 出处 |
|---|---|---|
| h total / v total | 1650 / 750 | `:119` |
| hs / vs | `h<40` / `v<5` | `:121` |
| DE 窗口 | `h∈[260,1540)`(1280)、`v∈[25,745)`(720) | `:43` |
| 图像窗口 | `v∈[145,625)`(480 行)、`h∈[img_x0,img_x1)` | `:42` |
| 双面板 | `img_x0=260,img_x1=1540` ⇒ 左 260..899 原画 / 右 900..1539 风格 | `:40-41` |
| 单面板 | `580/1220` ⇒ 居中 640，左右各 480 黑 | `:40-41` |
| `expect_row/expect_x` | `v-145` / `h-img_x0`（`h<img_x0` 钳 0） | `:44,:49` |
| 请求 | `h==0 && v∈[144,624)`，`row=v-144` | `:50-52` |
| 行地址 | `raw_base(slot)+row*2560`；风格 `+0x00800000`、`+row*2560` | `:140-141,:147` |
| 帧率自检 | 1650×750×60 = 74.25M ✓ | — |

**请求比显示早一行**：v 行 h==0 请求 `row=v-144`，该行在 v 行 `expect_row=v-145` ⇒ **数据提前一整行（22.2µs）到位** ✓。

**逐行要点**
- `:18-23` pix 域 `single_panel` 2FF（`sp_meta/sp_sync`）✓。`:24-32` **clk 域再 2FF（`spc_*`）**：
  注释说"行 FSM 在 clk 域，需要自己的同步器，喂 pix 域的副本会 CDC 违规并读错行"——**推理对、对象错**：
  `single_panel` 本身**就是 clk 域**（来自 clk 域的 `style_key_toggle`）⇒ `spc_*` 是 **clk→clk 冗余**（无害，白花 2 FF）。
- `:33` `h[10:0]`（1650>1024 ✓）、`v[9:0]`（750 ✓）。
- `:38-39` 单面板时两侧**驱动黑而不是关 DE**，HDMI timing 不变 ✓ 好设计。
- `:49` `expect_x` 钳位防左黑边无符号回绕 ✓。
- `:50` `request=h==0&&v>=144&&v<624&&dv2`（`dv2` 是 `display_valid` 的 pix 域延迟，防 slot 未同步就发请求）。
- `:53-55` 请求 FIFO `WIDTH(20)`=epoch8+slot3+row9 ✓，**16 深 = 16 行 ≈355 µs 容忍**；溢出则 `request&&!request_ready` 进 underflow（`:122`）
  且该请求**永久丢失**（FIFO 满时 in_valid 被忽略）⇒ 那一行必黑。
- `:56-65` `eg1/eg2` + 灰→二进制 `current_epoch`；`display_frame_event=current_epoch!=seen_epoch`。
  **注意这是 display 自己的 60Hz 帧事件，不是 store 换槽事件**（见 §4 R2）。
- `:70` `PIXEL_LOG=BUFFERED?9:10` ⇒ 512/1024。`:71` `pixel_level` 接 FIFO `write_level`（宽度 LOG_DEPTH+1 ✓）。
- `:72-75` **`read_urgent`** = `display_valid && (state!=IDLE||req_valid) && (pixel_level<384 || row_age>=1600 || req_valid)`：
  `pixel_level<384`=3/4 阈值（留 128 像素≈1.7µs）；`row_age>=1600`（12 位饱和，`:130`）=行事务已待 ≥16µs 的"死线保护"；
  `req_valid`=有新行待读。`display_valid==0` 时永不报急（上电首帧不抢 CNN，无害）。
  注释 `:73-74` 说明这是修过的（早先版本在消隐期恒报急会把 CNN 饿死）✓。
- `:80-87` `generate if(BUFFERED)`：`style_display_beats` 插在 AXI R 与 `style_axi_rows` 之间；else 直连。板上 BUFFERED=1。
- `:88-92` `style_axi_rows reader(... rd_pixels=640, rd_channels=3 ...)`：3 通道 ⇒ `rbpp=4` ⇒ **640×4=2560B/行=160 beat**。
  **写口全 tie-off**（`wr_start=0`、`awready=0`、`bvalid=0`）⇒ 写 FSM 是死逻辑，连带 `style_axi_rows:57` 的写 XOR 也死。
- `:93-99` `raw_base()` 与 store 里**逐字重复**（一致性靠人手，两处都 0..5 步长 0x140000）。
- `:100` `req_ready=state==IDLE` —— IDLE 时每拍吃掉一个请求（迟滞由 FIFO 弹性寄存器决定）⇒ **陈旧 epoch 请求被自动丢弃，不会死锁**
  （这是我最先怀疑的点，逐拍验证 `style_async_fifo:54` 的 `if(!out_valid||out_ready)` 后排除）。
- `:101` `display_safe=state==IDLE&&!rd_busy`。`:102-110` 像素 FIFO `WIDTH(60)`=epoch8+row9+x11+rgb32 ✓、`LOG_DEPTH(9)`=512。
  **每像素带 28 位标签，这是整条显示路径的防错核心。**
- `:107` **XOR 修复**：`rgb={8'b0, right_side ? (rd_pixel[23:0]^24'h808080) : rd_pixel[23:0]}`。
  自洽性：左半裸值 ✓；右半解偏置 ✓；全工程仅 2 处 `808080`（本行 + `style_axi_rows:57` 死写）⇒ 无三次/零次 ✓。
  前提不变量：DDR 风格帧每字节 = `q^0x80`（证据：`rowpipe_engine:205-206` 读无符号张量时 `^0x80`、`conv3x3_core:18-26` 偏移技巧、
  `rowpipe_ddr_banks:808` 逐字节拷贝不改域；板上"右半亮度 22→170"是经验证据。**未逐行读 rowpipe，属别的任务**）。
- `:111-114` **匹配/淘汰**：
  ```
  match    = pixel_valid && epoch==packet[59:52] && expect_row==packet[51:43] && expect_x==packet[42:32];
  obsolete = pixel_valid && (epoch 不符 || v>=625 || (v>=145 && (行过旧 || (同行 && h>=img_x0 && 列已过))));
  pixel_ready = obsolete || (image && match);
  ```
  **三字段（帧/行/列）全对才算命中**；不因"列太超前"而丢（波束在后面就等待，正确）。
  **单调性保证**：行内先推原画 x=0..639 再推风格 x=640..1279（`:131` 的 x 不重置），消费顺序也是 0..1279
  ⇒ **FIFO 内 (row,x) 严格单调，这是"不重排序也能对上"的根本原因**。
- `:114` 只在 `image` 区消费 ⇒ 黑边/黑条不消耗 DDR ✓。
- `:115-124` pix 块：`:118` `slot1/slot2` 3 位裸 2FF、`dv1/dv2`；`:120` `h==0&&v==0` 时 epoch+1 与 `epoch_gray`（只在这一拍变，灰码有效）；
  `:121` `hs<=h<40; vs<=v<5; de<=active; pixel<=image&&match?packet[31:0]:0` —— **pixel/hs/vs/de 同拍寄存器化，相位严格一致** ✓。
  `:122` `underflow<=（image&&dv2&&!match)||(request&&!request_ready)` = **欠载唯一观测点**（电平，板上靠顶层 `underflow_seen` 粘住 LED3）。
- `:125-152` clk 行 FSM：`:129-131` `row_age`（IDLE 清 0、饱和 4095）、`x` 在 `rd_valid&&rd_ready` 时加 1（**跨两次读连续 0..1279**）；
  `:133-143` IDLE 要求 `req[19:12]==current_epoch`，`right_side<=single_panel_clk`（**单面板首次即风格侧** ⇒ 只读 1 次 DDR）；
  `:144` START 发单拍 `rd_start`；`:145-149` WAIT 里 `if(!right_side)` 换风格地址回 START，否则回 IDLE。
  **`rd_done` 语义**（`style_axi_rows:92`）：`rs==R_DRAIN && rn==0` ⇒ 要等 640 像素**全部推进像素 FIFO** 才算 done ⇒ **两行串行读**。

**风险**
- **R1（事实，高）`style_display_beats` 深 32 的真实含义**：32×16B=512B=**恰好一个最大突发（arlen=31）**。
  文档 §370 的"需 160"是**错前提**：160 beat 是整行量，但 `style_axi_rows` 边收边消费（水位 >24 字节才拉低 `rready`），
  只需覆盖"一次突发+反压延迟"⇒ 32 够。真实余量是 **0 拍**，不足只会变成 AXI 反压、**不会丢数据**。
  ⇒ "已证伪为根因"的结论对，但理由应改为"深度恰等于一个最大突发，短了只反压不丢"。
- **R2（事实，中高）两行串行读 ⇒ 右半结构性更容易欠载**：一个显示行 22.22 µs 内要串行完成 320 beat（5120B）；
  风格行的数据在时间上排后，却只比原画晚 640 像素（8.6 µs）被需要 ⇒ **任何额外仲裁延迟先打右半**。
- **R3（事实，高，量化）显示读带宽 ≥147 MB/s 不可压缩**：2.46 MB/显示帧 ×60Hz = **147.5 MB/s，与 CNN 帧率无关**
  （片上无帧缓存，`BUFFERED` 只是 512 像素 FIFO）。CNN 侧 12.29MB×17.2fps=**211 MB/s**。合计 **359 vs 实测 260 MB/s**（缺 27%）。
  ⇒ 结构性预算问题，不是 `style_display` 的 bug；`read_urgent` 只改变分布、不改总量。
- **R4（事实，中）`display_slot` 3 位裸 2FF 无灰码/无握手**：换槽瞬间可能采到非法值（011→100 采到 111）⇒ 该行读错帧；
  **无任何校验能发现**（`epoch` 是 display 自己的，只防跨帧不防错 slot）。概率 ~1clk/帧但命中即一行错帧。
  建议：换槽后延迟 N 拍使用，或给 slot 加灰码。
- R5（事实，低）请求丢一个就整行黑。R6（事实，低）`dma_errors` 逐行可能重复计数（`style_axi_rows:74` 每次 `rd_start` 清 `rd_error`，实际只计一次 ✓）。
- R7（事实，低）DE 720 行里只有 480 行有内容，其余 240 行全黑但占用 DE —— 与"只供两个 VGA 矩形"一致 ✓。

**文档偏差**：`§247` "双 style_key_toggle 同步器（sp_*/spc_*）"→ 实际**只有 1 个** key_toggle；`spc_*` 是 clk→clk 冗余。
`§370` "深 32 vs 需 160"的"需 160"不成立（见 R1）。`§393/§396`（行 FSM `:126-152`、`style_axi_rows:45-50`）行号略偏。
文档未记"28 位标签 + 三字段匹配 + 请求早一行"的时序设计。

---

### 9. `style_display_beats.sv`（30 行）

**职责**：AXI R 通道弹性缓冲 + 格式转换（剥掉每 32 位字的 X 填充字节，重排成 `{8'b0,R,G,B}×4`），`rlast/rresp` 随数据走。
**逐行**：`:10` `reg [98:0] memory[0:31]`（99=1+2+3×32 ✓）；`:11` `wp/rp` 5 位、`count` 6 位（能到 32）✓；
`:12-14` `push=in_valid&&in_ready`、`fetch=(!out_valid||out_ready)&&count!=0`、`in_ready=count<32`（满则反压 AXI，合法）；
`:16` `out_data={8'b0,w[95:72],8'b0,w[71:48],8'b0,w[47:24],8'b0,w[23:0]}` ⇒ 每像素补 8 位零、像素 0 在 `[31:0]` ✓（下游按 `rc_next[4:2]*32` 定址）；
`:18` 存 `{last,resp, in[119:96],in[87:64],in[55:32],in[23:0]}` —— 取每 32 位字的 `[23:0]`（RGB）、丢 `[31:24]`（X）✓；
`:19` **同步读** `word<=memory[rp]`（注释 `:3` "Synchronous RAM read avoids a wide asynchronous read mux" —— 对比 §3 R1）；
`:26-27` `case({push,fetch})` 净变化 0、`out_valid<=fetch` 同拍 ✓。

**风险**：R1（事实，极低）`wp/rp/count` 同拍同步更新，一致 ✓。R2（事实，低）`count<32` 保证不覆盖未读数据 ✓。
R3（事实，低）`out_resp` 只在 `out_valid` 时有效，下游 `style_axi_rows:81` 恰在 `rvalid&&rready` 检查 ✓。

---

### 10. `style_axi_rows.sv`（117 行）

**职责**：紧凑 NHWC 行 DMA，128 位 INCR 突发（≤32 beat、不跨 4KiB）。注释 `:1-2`"RGB is XBGR8888 little-endian in DDR; features are compact signed INT8"。
**活用途只有一个：`style_display` 的读口**（写口 `wr_start=0`）。

**逐行要点**
- `:15-19` 读/写各 4 态；`rb/wb[319:0]` = **40 字节储池**；`rc/wc` 6 位字节计数。
- `:20-29` `burst_len(remaining,address)`：`boundary=(4096-addr[11:0])>>4`、`n=min(remaining,32)`、`n=min(n,boundary)`、返回 `n-1`。
  对 `raw_base+row*2560`（2560=0xA00）行首在 4KiB 内的偏移按 0xA00/0x1400/0x1E00/0x2800/0x3200/0x3C00/0x600… 循环，
  最紧是偏移 3584（行 3、9…）时 `boundary=32` ⇒ **正好还能发 32 beat，从不被截成 0** ✓。
- `:31-34` `rd_valid=rd_busy&&rc>=rbpp&&rn!=0`；`rready = rs==R_DATA && (rc-(rpop?rbpp:0))<=24`（水位控制，留 ≥16B 空间才收下一拍）。
- `:39` `wr_ready=wr_busy&&wn!=0&&(wc+wbpp <= (wpop?56:40))`（活配置不执行）。
- `:43-65` 组合"消费+追加"流水（**全文件最需要小心的一段**）：
  ```
  if(rbpp==4) rd_pixel[23:0]=rb[23:0]; else rd_pixel=rb[191:0];    // 工作区已删掉 ^24'h808080
  rb_next = rpop ? rb>>(rbpp*8) : rb;
  if(rvalid&&rready) rb_next |= ({{192{1'b0}},rdata} << (rc_next[4:2]*32));
  ```
  **`rc_next[4:2]*32` 只在 `rc` 为 4 的倍数且 ≤28 时等于 `rc*8`**（`rc_next[4:2]` 只留 bit2..4 ⇒ 最大 224 位=28 字节）。
  - `rbpp=4`（**唯一活用途**）：水位保证插入时 `rc≤28` ⇒ **完全正确** ✓。
  - `rbpp=8/12/16`（只有死支 `style_network` 会用）：`rready` 允许 `rc≤32`，`rc=32` 时 `rc_next[4:2]=0` ⇒ **移位 0，新数据盖最老字节**；
    且 `rc_next` 可达 48 > 40 字节池溢出 ⇒ **坏的**。不影响板子。**R1（事实，高）**。
  - `:45-49` 注释解释删 XOR 的理由（"在这里 XOR 会把原画加上偏置，逼调用方再 XOR 回来，反而抵消风格帧的偏置"）✓ 与修复意图一致。
- `:57` `if(wbpp==4) pack_pixel={160'b0,8'b0,(wr_pixel[23:0]^24'h808080)}` —— **仅剩的第二处 XOR，在写方向且活配置写口关闭 ⇒ 死代码**。
  若将来接写口必须重审：它无条件 XOR 三个字节，等于假定"所有写入都是 INT8+0x80 域"（对风格帧成立、对原画不成立）。
- `:73-77` `rd_start&&!rd_busy`：`rn<=rd_pixels`、`rbpp<=channels==3?4:channels`、`rleft<=(pixels*bpp)>>4`（beat 数）、首发 AR。
- `:80-91` 收数据：`rresp!=0 || rlast!=(rbeat==arlen)` 记错；`if(rlast)` 减 `rleft`，最后一拍→R_DRAIN，否则发下一个 AR
  ⇒ **AR 串行（一次只有一个在途突发）**：显示一行 160 beat = **5 个串行突发**，突发间有 AR 往返延迟（→ §8 R2）。
- `:92` `if(rs==R_DRAIN&&rn==0)` → `rd_done` ⇒ **done 等消费者把 640 像素全取完**（关键语义，display 靠它切第二次读）。
- `:93-114` 写侧对称（活配置不执行）。

**风险**：R1（事实，高）`rbpp≠4` 时储池移位/水位错误（触发条件 `rd_channels∈{8,12,16}`，活配置恒 3 ⇒ 安全）。
**建议**：改成完整位宽的 `rc_next*8` 或加 `assert(rbpp==4)`。R2（事实，中）`rd_error` 粘滞到下次 `rd_start` 清 ✓ 可接受。
R3（事实，低）`rd_start` 有 `!rd_busy` 保护 ✓；`rleft` 16 位（≤160）✓。

**文档偏差**：`§396` "AXI 读（无 XOR）`style_axi_rows.sv:45-50`" → 行号应为 `:43-65`，且**写侧 `:57` 仍 XOR**（文档未提，易误读为全文件无 XOR）。

---

### 11. `style_key_toggle.sv`（43 行，任务写 41 行）

**职责**：板载按键消抖 + 一次按下翻转一次。**逐行**：`:7` `DEBOUNCE_COUNT=500000`=5ms@100MHz ✓；`:15` `cnt[19:0]`（500000<2^19 ✓）；
`:20-22` 2FF 同步异步引脚，复位值 1（低有效未按=1）✓；`:28-39` `if(key_sync2!=stable)` 持续计数到 `DEBOUNCE_COUNT-1` 才接受，
一致则清零重启窗口 ✓；`:41` `if(stable_d&&!stable) toggle<=~toggle` —— **只在 1→0（按下）翻转** ✓。

**风险**：R1（事实，极低）单拍毛刺会把 `cnt` 清 0，稳健 ✓。R2（事实，低）按住不重复翻转 ✓。
R3（事实）文件风格与其他文件不同（全展开带注释），与文档 `§380`"按键边沿检测修复"的记录吻合 ✓。
**文档偏差**：`§247` 说"双 style_key_toggle"→ **只有 1 个实例**（`style_video_system:52`）。

---

### 12. `style_mac8x12.sv`（82 行）—— 死支成员

**职责**：8 输出通道 × 12 INT8 项/拍的 MAC + 5 级流水 + BN/量化。只经 `style_row_core` 在 `g_monet` 里用；另有独立 TB。
**逐行**：`:4-5` `ACC_WIDTH=32,AFFINE_WIDTH=48`（`row_core:131` 覆盖为 `20/36`）；`:18-19` `ce=!out_valid||out_ready` 作**全局时钟使能**
"让所有流水级在输出反压下稳定"（`:3`）✓ 好做法；`:20-23` 5 级有效/首/末/relu + 每级 tag/skip/mul/bias/shift；
`:24-28` 96 个 16b product、24 个 18b sum4、8 个 20b dot/acc、8 个 affine（`ACC_WIDTH=20` 依据见 `row_core:129`：27×128×128=442368<2^19 ✓）；
`:30-43` `quantize()`：符号-幅值取绝对值 → 加半再移（**ties-away，不是 RHE**）→ relu → 饱和 [-128,127]；
`:34` 先拼回符号位再取负，能正确处理 -2^(N-1) ✓；`:57-58` `if(in_valid)` 才算乘法（省功耗）；
`:64-67` `dot[i]=sum4[3i]+sum4[3i+1]+sum4[3i+2]`（24=8×3 ✓）；`:68-71` `first_pipe[2]` 时清零重载（`accumulator` 与 `total` 存同值，冗余但不错）；
`:72-74` `affine=total*M16+B32`；`:75` **只有 last 那拍才出有效结果** ✓；`:76-79` 输出 tag/skip + 8 个量化字节。

**风险**：R1（事实）**不综合**。若把 `USE_ROW_PIPE` 改成 0：`:73` 的 8 个 20×16 乘法 + `:57` 的 96 个 8×8 ⇒ DSP 远超 160，**不可回退**。
R2/R3（事实，低）`shift==0` 时正确跳过加半 ✓。
**文档偏差**：`§169` "RHE（round-half-to-even）"与本模块的 ties-away 不符；但 rowpipe 的 `requant.v` 是另一份实现（本模块不参与 bit 流），
所以该偏差对板子无影响，只是文档把"requant RHE"套到了整个工程头上，容易误导。

---

### 13. `style_row_core.sv`（209 行）—— 死支成员

**职责**：可复用的行卷积核，片上只留 3 输入行 + 1 残差行，DMA 提供行映射与零边框。`MAX_WIDTH=640`。
**逐行（只挑契约相关）**
- `:22-24` 行缓存 `rowNlo[0:639]`(64b)+`rowNhi[0:319]`(128b)+`skip[0:159]`(192b) ⇒ 每行 640×16bit×3 行。
  **一旦被 elaborate 就是 ~60 kbit RAM ⇒ 244/256 立刻爆**（这也是为什么绝不能改 `USE_ROW_PIPE=0`）。
- `:30` 6 态 IDLE/FETCH/LATCH/ISSUE/DRAIN/NORM；`:31` `advance=!out_valid||out_ready` 全局节流（与 mac 的 `ce` 同源）。
- `:69-82` **24 个系数 bank**（32b×256），`if(coef_we&&!busy&&coef_word==bank) mem[coef_addr]<=coef_data; else if(advance) wr<=mem[coefficient_address];`
  ⇒ **权重与 BN 共用存储**（注释 `:59-60`），地址在 FETCH/NORM 时切到 `naddr`、否则 `waddr` ✓。
- `:73-76` `initial $readmemh(COEFF_FILE,initial_coeff); for(a) mem[a]=initial_coeff[a][bank*32+:32];`
  —— 用"256×768 位数组再按 bank 切片"，仿真可行；活支不走这里 ⇒ **`rtl/style/model/coeff.hex` 对 bit 流无影响**。
- `:90-96` BN 缓存 `active_norm`（按 co_group 选 `norm_word/norm_cache1/2`，group 1/2 首次用到时缓存）。
- `:98-108` 点卷积路径：`point_pixel` 取被 `row_select[3:2]` 选中的行；`pw_slice=point_pixel>>(red_group*96)`（12 tap × 8 位 = 96）。
- `:102-106` `rgb_terms` 三条硬编码分支（3 通道 RGB 特化）——"静态接线省 96:1 交叉开关"。
- `:110-119` `activation_word` generate：`depthwise?dw_slice:kernel3?rgb_terms:pw_terms`，12 tap×8 lane=96 字节 ✓ 对上 mac 的 `[767:0]`。
- `:129-131` `style_mac8x12 #(ACC_WIDTH(20),AFFINE_WIDTH(36))` + 注释给出位宽推导（27×128×128<2^19；|acc·M+B|<2^35 ⇒ 36 位够）✓ **本子系统最好的注释之一**。
- `:139-148` 残差 `v+skip`（`use_residual` 时 clamp [0,127]）；`assembled_next[(mac_tag[1:0]*8+qlane)*8+:8]=v` ⇒ 按 co_group 拼 192 位输出 ✓。
- `:157-165` 出数/启动：`out_x==output_width-1` 时 `busy<=0;done<=1`；`column<=kernel3?0:1`；`co_groups=(cout+7)>>3`、`red_groups=depthwise?1:kernel3?3:(ci+11)/12`。
- `:171-184` 三轴推进（red_group→co_group→x），kernel3 时 patch 左移（stride2 移 2、否则移 1）✓。
- `:189`/`:52-58` 零边框由 `fetch_present` + `choose_row(sel,present)` 返回 0 实现 ✓。

**风险**：R1（事实）不综合、不实例化（除 `tests/style_row_tb.sv`）。R2（事实，低）`:78` 写口与 `:79` 读口共用 `mem` 同一时钟沿，`else if` 读优先，靠 `!busy` 保证编程期不读 ✓。
**文档偏差**：`§169` RHE（见 §12）；`§165` "shift 每层一份（非每通道）"与本模块 `shifts[lane*8+:8]=active_norm[lane*64+16+:8]`（**每通道一份**）矛盾 —— 以 rowpipe 的 `requant.v` 为准。

---

### 14. `style_network.sv`（139 行）—— 死支成员

**职责**：旧实现，"在 DDR 里跑完整 23 层图"（`:1`），`include "model/program.vh"` 提供 `descriptor_word()`。
**逐行（只记"为什么死"与契约差异）**
- `:4` 依赖 `COEFF_FILE`+`PROGRAM_FILE`（后者声明了但**没被使用**）。
- `:20` `` `include "model/program.vh" `` —— **编译期依赖**：只要文件还在工程列表里，`program.vh` 就必须存在（**没实例化也会因 include 缺失而编译报错**）。这是"死文件仍要维护"的代价。
- `:21-29` 从 160 位 descriptor 解出 `ci/co/kernel3/dw/stride2/up2/residual/relu`、输入输出宽高、`weight_base/norm_base`、`src/dst/skipaddr`、`input_pitch/output_pitch`。
- `:30` **10 态 FSM** IDLE/DESC/SETUP/MAP/READWAIT/SKIP/SKIPWAIT/RUN/WAITROW/NEXTROW；`:32-33` 3 bank 缓存 + `cache_y[0:2]`（3 行窗口）。
- `:34-35` 注释："Pointwise, non-residual layers only: ... No extra line RAM" ⇒ 预取只对 1×1/非残差/无 stride/无上采样层开启（`:116`）。
- `:40` `style_axi_rows dma(.*, .rd_ready(1'b1), .wr_valid(core_valid), .wr_pixel(core_pixel));` —— **`rd_ready=1'b1` 常通**（不反压），
  写侧直连 core 输出。**这是唯一会走 `style_axi_rows` 写路径（含 `:57` XOR）的实例** ⇒ 因为它死，那行 XOR 才是死的。
- `:52-55` `virtual_y=y*(stride2?2:1)+(kernel3?ky-1:0)`、`physical_y=up2?virtual_y>>>1:virtual_y`、3 bank 命中查找 ✓ 与 `row_core.choose_row` 同义。
- `:69-71` 三个统计：`read_cycles`(READWAIT/SKIPWAIT 拍)、`compute_cycles`(core_busy 拍)、`overlap_cycles`(rd_valid&&core_busy)
  —— **正是 APB `0xa8/0xac/b8` 的来源**，活支把它们接 0 ⇒ §5 R2。
- `:84` IDLE 启动时清所有统计 ✓。`:88-89` `ky==3` 后转 SKIP（有残差）或 RUN；越界 ⇒ `row_present[ky]<=0`（零边框）。
- `:131-134` `y==oh-1 && layer_index==22` ⇒ done（**23 层 = index 0..22**）；否则 `layer_index++` 回 DESC。

**风险**：R1（事实，高）纯死代码，唯一实例在 `tests/style_network_tb.sv:31`；`USE_ROW_PIPE` 无覆盖 ⇒ `g_monet` 不 elaborate。
R2（事实，中）**"23 层 vs 12 层"是最大文档陷阱**：`style_network` 是 23 层 + APB 系数，rowpipe 是 12 层 + DDR 权重 blob；
两个实现的层数、bank 数、权重来源全不同。R3（事实，低）`PROGRAM_FILE` 声明未用。
**文档偏差**：`§26-28` 图写"rowpipe 12 层"（对），模块树只列 rowpipe（对），但没说明 `style_network.sv` 仍在编译文件列表里。

---

## 跨时钟域与时序专题

**只有 3 个域**（文档 §229-237 把 `pix_clk` 与 `hdmi_tx_slow_clk` 列成两行，实为同一时钟 `.pix_clk(hdmi_tx_slow_clk)`）：
`clk=core_clk 100M` / `cnn_clk=vid_clk_dvi2 148.5M` / `pix_clk=hdmi_tx_slow_clk 74.25M`。

| # | 信号 | 方向 | 机制 | 判定 |
|---|---|---|---|---|
| 1 | crop→capture_fifo | cnn→clk | async FIFO(34,11) 灰码 | ✓ |
| 2 | `stream_enable` | clk→cnn | 2FF `enable_sync`（慢变电平） | ✓ |
| 3 | `cap_gate` 帧内门控 | cnn 本地 | 本地锁存 | ✓ |
| 4 | 系数写 | clk→cnn | coeff FIFO(45,2) | ✓ |
| 5 | `issued→acknowledged` | clk→cnn→clk | **灰码** `committed_gray` | ✓ 正规 |
| 6 | `start_toggle` | clk→cnn | 2FF + toggle 解脉冲 | ✓ |
| 7 | mailbox `source/result/geometry` | clk→cnn | **无同步器**，靠"payload 先稳、toggle 后到" | ✓ 但无形式保证 |
| 8 | `done_toggle` | cnn→clk | 2FF + `done_seen` | ✓ |
| 9 | `core_reset` | cnn 本地 | 2 位移位复位延长 | ✓ |
| 10 | AXI 5 通道 | cnn↔clk | `style_axi_cdc` 5×async FIFO | ✓（W 16 深是隐式上限） |
| 11 | 行请求 | pix→clk | requests FIFO(20,16) | ✓ |
| 12 | 像素 | clk→pix | pixels FIFO(60,512) | ✓ |
| 13 | `epoch` | pix→clk(灰)→pix | `epoch_gray`→2FF→二进制 | ✓ 正规灰码 |
| 14 | `display_slot[2:0]` | clk→pix | **3 位裸 2FF** | ⚠ 多位无编码（§8 R4） |
| 15 | `single_panel` | clk→pix | 2FF `sp_*`；**另有 clk→clk 冗余 `spc_*`** | ✓/冗余 |
| 16 | `key_panel` | 异步→clk | 2FF + 20 位消抖 | ✓ |

**未发现"会挂死"的 CDC 遗漏**：所有握手都是 toggle 或 FIFO，没有"多 bit 电平直接跨域且必须同时有效"的情形。
最弱的一环是 **#7 mailbox**（逻辑成立：payload 与 toggle 同拍写，toggle 经 2FF 至少晚 2 个目的时钟被看到，
而 payload 1 个目的时钟即稳定 ⇒ 安全；但若将来改成"同拍多路切换 payload"就会踩坑）与 **#14 slot**（唯一真正裸的多位 2FF）。

**带宽预算（可复核算术）**
```
显示读 = 2读/行 × 640px × 4B × 480行 = 2,457,600 B/显示帧 × 60Hz = 147.5 MB/s  （与 CNN 帧率无关）
CNN    = 12.29 MB/帧 × 17.2 fps                              = 211.4 MB/s
合计 = 358.9 MB/s    vs 实测有效 260 MB/s（文档 §306）       ⇒ 缺 98.9 MB/s (27.6%)
```
自洽解：显示实际只拿到 ~50 MB/s ⇒ 60Hz 下约 1/3 的行读被推迟，但靠"提前一行 22.2µs + 512 像素 FIFO 6.9µs"的余量，
**大部分被推迟的行仍在行内送达**，只在行首几十列丢像素（`underflow` 脉冲）⇒ 视觉上是轻微暗边而非半屏黑。
**单行死线**：一行 1650 拍@74.25M=22.22µs；两次串行读 320 beat，若 DDR 给 230 MB/s 恰好 22.2µs ⇒ **零余量**。
`row_age>=1600`（16µs）是唯一的死线保护，属事后补救而非事前保证。

---

## 显示路径专题：一行像素从 DDR 到 HDMI（含欠载条件）

以双面板第 `row` 行（波束在 `v=row+145`）为例：

**阶段0 请求**（pix，`v-1=row+144` 行 `h==0`）：`in_data={epoch,slot2,v-144}`（20 位）进 requests FIFO(16 深)。
满则请求**永久丢失**⇒ 整行黑（`underflow`）。

**阶段1 取请求**（clk）：`IDLE: req_valid&&req_ready&&req[19:12]==current_epoch` ⇒ `row_epoch/row_slot/row_number/x<=0`、
`right_side<=single_panel_clk`（单面板首次即风格侧）、`rd_address<=raw_base(slot)+row*2560(+0x800000)`。
`req_ready=state==IDLE` ⇒ 陈旧 epoch 请求被就地丢弃，**不会死锁**。

**阶段2 第一次读=原画**（clk）：`rd_start` → `style_axi_rows` 首发 `arlen=burst_len(160,addr)`；5 个 32-beat 突发串行；
`rdata` → `style_display_beats`(32 深，剥 X) → `style_axi_rows` 40B 储池 → `rd_valid`（一像素）。
每像素 `x++` 并推入像素 FIFO：`{row_epoch(8),row_number(9),x(11),rgb(32)}`，`rgb={8'b0,rd_pixel[23:0]}`（裸值）。**x=0..639**。

**阶段3 第二次读=风格**（clk）：`WAIT: if(rd_done)` → `rd_error` 计数 → `if(!right_side)` 换 `+0x800000` 地址回 START（否则回 IDLE）。
**x 不清零** ⇒ 第二读的像素带 **x=640..1279**；`rgb={8'b0,rd_pixel[23:0]^0x808080}`（**唯一解偏置点**）。

**阶段4 消费**（pix）：三字段匹配；左半 `expect_x=h-260`∈[0,640) 命中原画，右半 ∈[640,1280) 命中风格；
命中才输出，失败一律黑。**无任何平滑/重采样。**

**阶段5 出门**：`pixel → top: rdata=pixel[7:0],g=[15:8],b=[23:16]`（`:830-832`）→ `luma_color_suppress`(tone) → `luma_tone_map`(lift)
→ `ae_frame_stats`（只测光）→ `dvi_encoder` → TMDS → HDMI 1280×720@60。
**R/B 交换发生在顶层 `CAM_RAW_GREEN_FIRST`（=1'b0，`defines.v:4377`）⇒ 不交换 ⇒ `pixel[7:0]` 必须就是 R**，与 §2 推出的 `{00,B,G,R}` 一致 ✓。

**欠载的完整条件表（"为什么少了像素"的唯一清单）**

| 条件 | 位置 | 后果 | 可观测 |
|---|---|---|---|
| ① 请求 FIFO 满（16 行） | `display:50,55` | 该行无请求，整行黑 | `underflow` |
| ② 行 FSM 卡在 WAIT（AXI 不响应） | `display:145` | 两读都晚，行首列黑 | `row_age` 饱和 + `read_urgent` 持续 |
| ③ 像素 FIFO 里还没有 `expect_x` 那个像素 | `display:111,121` | 该列黑，下一列自动对齐（不漂移） | `underflow` |
| ④ FIFO 头是更早的行（读落后 ≥1 行） | `display:112` | 旧行像素被丢弃，可能整行黑 | `underflow` |
| ⑤ epoch 不符（跨帧残留） | `display:112` | 正常帧首清空 | 不计（设计如此） |
| ⑥ slot 2FF 撕裂 | `display:118` | 一行内容来自错 slot（**非黑**） | **不可观测**（缺校验） |
| ⑦ 换槽发生在帧中 | `frame_store:77-85` | 一帧由两 slot 的行拼成（**非黑**，撕裂） | **不可观测** |

⇒ 只有 ⑥⑦ 产生"非黑的错像素"，且都是整行/整半帧级错误，**不可能是"均匀的细节变少"**。

**12.3 vs 23 的三个乘性因素（可验证）**
1. **口径**：23.0 = DDR 单通道 R 的 std；12.3 = luminance=(R+G+B)/3 的 std。三通道独立时 `σ_lum=18.9`；实测 12.3 ⇒ 隐含通道相关 ≈0.6。
2. **窗口**：DDR 是"行 240 全 640 像素"（一维）；截图是 2D 窗口（`x=980..1900,y=200..880,step=2`）。
3. **采集卡 1.5× 上采样**：HDMI 1280×720，截图窗口到 x=1900 ⇒ 采集帧宽 ≥1920=1280×1.5；1.5× 双线性/盒式是低通，σ 再降 10–25%。
**判别实验（最高优先级建议）**：把 `0x05800000` 的 R/G/B dump 出来，按 `(R+G+B)//3` 算 luminance σ，取 `row 240..300, col 0..639`。
若得 **11–13** ⇒ "细节损失"彻底不存在，问题只是口径。

---

## 给 Lead 的 5 条要点

1. **"双面板细节损失"我判定为测量口径问题，不是 RTL 缺陷（置信度高）。** 证据：①display 是 1:1 拷贝+失败补黑，无平滑路径；
   ②23.0=单通道 R 的 σ、12.3=luminance 的 σ，换算只需通道相关 0.6；③采集卡 1.5× 上采样再降 10–25%。
   **建议立刻做**：对 `0x05800000` 同一行区间按 `(R+G+B)//3` 重算 σ；若 ~12 ⇒ 从问题清单删掉 #4。
2. **XOR 修复自洽，可提交（置信度高）。** 只剩 2 处 `^0x808080`：`style_display:107`（活、正确）与 `style_axi_rows:57`
   （写方向，活配置 `wr_start=0` ⇒ 死）。无三次/零次。**建议顺手删掉 `:57` 或加注释**，防将来接写口踩雷。
3. **3 个会"静默停摆且无错误位"的现场陷阱**：①APB `0x04` 写启动会覆写 `stream_enable=bit4`（写 `0x01` 而非 `0x11` 就整链停摆）；
   ②`frame_store:36` 的 `pop_ready` 被 `stream_enable` 挡，同因；③`accel:64` `pending` 只在 `job_done` 清，核挂死即永久 pending、无 watchdog。
   **建议**：文档/固件显式规定"启动必须写 `0x11`"，或把 `stream_enable` 挪出同一寄存器。
4. **带宽预算是硬约束，不是可修的 bug（量化）**：显示 147.5 MB/s（**与 CNN 帧率无关，因片上无帧缓存**）+ CNN 211 MB/s
   = 359 vs 实测 260 MB/s（缺 27%）。这解释 17.2fps，也解释**右半比左半更容易欠载**（两读串行、风格行排后但只晚 8.6µs 被需要）。
   可选方向：①把行读改成"原画/风格交错发 AR"，让风格数据提前到；②降显示刷新（720p30）——**这是唯一真省流量的办法**；
   ③片上帧缓存（RAM 244/256，不可能）。能改的只有**分布**，不是**总量**。
5. **死代码与失效寄存器清单（防后续误判）**：`style_network`/`style_row_core`/`style_mac8x12`（`USE_ROW_PIPE` 无覆盖，仅 TB 实例化）
   与 `style_ddr_profiler`（**无任何实例**）。直接后果：**`0xa8/ac/b0/b4/b8` 五个性能快照恒 0**（`style_network_rowpipe:137-141` 全接 0）、
   `0x2c` 空写、`0xbc` 不存在、`style_vga_crop.fault` 永不置 1（`capture_fault` 只反映 `cap_overflow`）。
   **建议**：把这 5 个 stat 改成接 rowpipe 的真实计数（改 5 行），并把 `style_ddr_profiler` 接进 `style_video_system`（≈20 行）——
   这是目前**唯一**能拿到 DDR 仲裁事件统计的手段。

---

### 附：诚实边界

| 项 | 状态 |
|---|---|
| `style_async_fifo` 大支**异步读**在 Efinity 落 BRAM 还是 LUT | ❌ 未验证（按约束未跑综合） |
| DDR 风格帧每字节 = `q^0x80` | ✅ 三方交叉证据；❌ 未逐行读 rowpipe（2300+ 行，属别的任务） |
| `style_accel` mailbox 跨域"payload 先稳" | ✅ 逻辑成立、❌ 无形式约束 |
| 12.3 vs 23 的最终结论 | 🟡 强推断（口径），需一次 DDR dump 复核 |
| `display_slot` 裸 2FF 撕裂的实际触发率 | ❌ 未测（理论 ~1clk/帧） |
| `CAM_RAW_GREEN_FIRST=0` 与 R/B 顺序 | ✅ 源码确认；将来置 1 会红蓝互换 |
| `style_network` 的 23 层是否曾上过板 | ❌ 未知 |
