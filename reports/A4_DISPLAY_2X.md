# A-4：L11 直写 320×240 + 显示端 2× 放大（并行方案）

> 2026-10-28　执行：style-system　**未构建位流、未上板、未提交 git**
> 隔离 A/B：`_sim/ab_a4.ps1`（网络侧）、`_sim/run_disp_a4.ps1`（显示侧），原始数字存档 `_sim/A4_RESULT.txt`

---

## 一、三个前置问题的答案

### Q1 `result_pixels` 契约是谁定的、改它波及谁？

| 项 | 位置 | 结论 |
|---|---|---|
| 定义 | `rowpipe_frame_driver.v:89` `total_pixels = frame_width*frame_height`（来自 APB mailbox 的 geometry={480,640}） | 640×480 = 307,200 像素 |
| 传参 | `rowpipe_frame_driver.v:165` `.result_pixels(total_pixels)` | **只有这一处** |
| 唯一消费者 | `rowpipe_ddr_banks.v:1044-1048` `result_done = (res_words==result_pixels) && (res_beats==result_pixels>>2) && (w_acked_virt==res_beats) && w_idle && !beat_push` | 只做这三个比较 |
| 下游链路 | `result_done` → frame_driver `res_done`（S_FLUSH→S_DONE）→ `drv_done` → `style_network_rowpipe.done` → `style_accel.job_done` → `frame_store.nn_done`（slot 标 COMPLETE） | 对不上就卡死 S_FLUSH（响铃式失败，不会画错图） |
| **固件** | `style_driver.c:52`：`regs[4]=0x05000000`（源）、`regs[5]=0x05800000`（结果）、`regs[6]=0x01e00280`（geometry） | **固件只把地址/几何告诉硬件，从不读结果帧、不关心其长度** ⇒ **不需要改固件** |
| 其他隐含假设 | `style_accel.sv` 的 `config_ok` 用 `frame_bytes=w*h*4` 做 result 上界检查 | 结果帧变小 ⇒ 该检查变成"偏保守"，**无需改** |

**结论**：契约改动被完全限制在 `rowpipe_frame_driver.v` + `rowpipe_ddr_banks.v` + `style_display.sv` 三个文件；
改法是把 `result_pixels` 按 TAIL_LOWRES 缩放（`TAIL_LOWRES ? total_pixels>>2 : total_pixels`）。

### Q2 显示端每行读 320 像素、输出 640 列，时序够不够？

- **端口位宽**：`style_axi_rows.sv:5` `rd_pixels` 是 `[9:0]` ⇒ 320 合法；内部 `rn[9:0]`、`rleft[15:0]=(320*4)>>4=80` beat。
- **突发**：80 beat 被 `burst_len()` 切成 32+32+16；1280 B 一行的页内偏移循环 0/0x500/0xA00/0xF00，
  最紧的 0xF00 处 `boundary=16` beat ⇒ 切成 16+32+32，**不跨 4 KiB** ✓（函数本来就处理）。
- **时序反而更宽松**：每行读 beat 从 160 降到 80；两面板每行总计 320 → **240 beat**（原画 160 + 风格 80），
  同一条 22.2 µs 的显示行 ⇒ 余量从"零"变成 +25%。
- **关键设计**：放大放在 **clk 域**（一个源像素写两条进像素 FIFO），**pix_clk 域一行代码都不用改** ——
  tag 流仍是"每行 1280 条、x 连续（双面板 640..1279 / 单面板 0..639）"，与改动前**逐拍同构**。
  因此 `match`/`obsolete`、FIFO 深度余量、`read_urgent` 阈值、`x`/`row_number` 流水全部不变。
- 新增的唯一节流：`rd_ready` 多一级 `!(style_dup&&dup_pend)` ⇒ 风格侧每 2 拍吃 1 个源像素（正好是 2× 放大所需）。

### Q3 双面板地址会不会搞混？

| 面板 | 地址 | 跨距 | 像素数 |
|---|---|---|---|
| 左（原画） | `raw_base(slot) + row*2560`（`style_display.sv:172`，**未改动**） | 2560 B | 640 |
| 右（风格） | `raw_base(slot) + 0x00800000 + (row>>1)*1280`（`:171` 单面板 / `:179` 双面板第二次读） | 1280 B | 320 |

- `+0x00800000` **只出现在风格分支**；两次读共用同一个 `row_slot`（来自请求包 `req[11:9]`），不存在混用。
- 行号 `row_number` 仍是**显示行** 0..479（tag 不变），只有地址里做 `>>1`；479>>1=239 ⇒ 末行地址 305,920 B + 1280 B = 307,200 B = 结果帧正好结束，**不越界**。
- 单面板只读一次（风格），x 从 0 起 640 列 ✓ 已仿真验证。

---

## 二、改了什么（3 文件，+70 / −101 行）

1. **`rtl/accel_rowpipe/rowpipe_ddr_banks.v`** —— **只删不加**：删掉 A-3 的整套 2×2 复制
   （`RESULT_X2/X2_SRC_W/X2_TGT_W` 三参数、`x2_data/x2_a0/x2_base/x2_scb/x2_i/x2_busy` 六个寄存器、
   `x2_beat/x2_off/x2_addr/x2_push` 四个组合量、4 处选择 mux、`result_done` 里的 `!x2_busy` 项）。
   与 `git diff 5deabe9^` 对比：除 9 行说明注释外**逐字节等于 A-3 之前**。
2. **`rtl/accel_rowpipe/rowpipe_frame_driver.v`** —— 不再传 RESULT_X2 等参数；
   `.result_pixels(TAIL_LOWRES ? (total_pixels>>2) : total_pixels)`。
3. **`rtl/style/style_display.sv`** —— ①`rd_pixels` 加选择器（原画 640 / 风格 320）；
   ②风格行的地址 = `+0x00800000+(row>>1)*1280`；③clk 域水平 2× 复制（`dup_pend`/`dup_rgb`，`pix_we/pix_rgb/rd_ready`）；
   ④`req_ready` 加 `!dup_pend`（防止极端情况下把待写的第 2 条打到下一行的 tag 上）。
   **pix_clk 域、AXI 接口、端口列表、模块参数全部未动。**

未改：`style_video_system.sv`（不需要）、`rowpipe_layer.v`、`rowpipe_engine.v`、`style_network_rowpipe.sv`（按要求不碰）。

---

## 三、A/B 结果（全部 iverilog 隔离台，板上未跑）

### 3.1 网络侧（`_sim/ab_a4.ps1`，TB_TINY 64×48，**生产配置 LOWRES=1**）

| | base（A-3：写通道 2×2 复制） | opt（A-4：L11 直写） |
|---|---|---|
| error | **0** | **0** |
| finished（result_done 置起） | **True** | **True** |
| cycles | 48,247 | 48,221 |
| **wr_beats（全层总写 beat）** | **2,880** | **2,304**（−576 = 768−192 ✓） |
| 结果帧 beat（tiny） | 768（由复制产生） | 192（19,200 的 1/4 几何） |
| 结果帧像素一致性 | base 的 64×48 复制帧 vs opt 的 32×24 原生帧，按最近邻 2×2 展开后 **768/768 逐像素相同**；水平成对 384/384、垂直成对 384/384 | |

按生产几何等比：**结果帧写 76,800 → 19,200 beat/frame**，`result_done` 在新契约下正常置起。

### 3.2 显示侧（`_sim/run_disp_a4.ps1`）

BASE = `_sim/base/style_display.sv`（HEAD，读 640/跨距 2560）+ DDR 里放"已复制好的 640×480 风格帧"；
OPT = `rtl/style/style_display.sv` + DDR 里放"320×240 原生风格帧"。
两种 DDR 内容不同，但**屏幕上应出现的画面相同**；期望值由独立的场景函数第三方算出（不是从 RTL 反推）。

| 场景 | base | opt | A/B 逐行相同 |
|---|---|---|---|
| 双面板 20 行 × 1280 列 = 25,600 px | mism=**0** | mism=**0** | ✅ True |
| 双面板 64 行 × 1280 列 = **81,920 px** | mism=**0** | mism=**0** | ✅ True |
| 单面板 8 行 × 1280 列 | mism=**0** | mism=**0** | ✅ True |
| AR 突发数（64 行） | 645 | **517**（−20%） | — |

⇒ 水平/垂直 2× 都成立、无半幅、无错行、无欠载（任何丢像素都会立刻计入 mism）。

---

## 四、预期收益

| 项 | 变化 | 依据 |
|---|---|---|
| **L11 写时间** | 76,800 → 19,200 beat（**−75%**）；A-3 口径"写侧受限 ≈4.15 ms" ⇒ 预期 **L11 ≈ 1.55 ms（回到算力受限）**，约 **−2.6 ms/帧** | A-3 提交说明 + beat 数比例 |
| DDR 写流量 | **−921,600 B/帧**（结果帧 1,228,800 → 307,200 B） | 计算 |
| 显示读流量 | 2,457,600 → **1,843,200 B/显示帧（−25%）**，AR 数 −20% | 仿真实测 AR 645→517 |
| 读侧仲裁（RGAP ~10 ms） | 间接改善（显示读与 CNN 读抢同一口） | 推理，待实测 |
| **面积** | **净 −100 ~ −150 XLR**：删写通道 ≈ **−200**（A-3 官方口径 +200），显示端新增 ≈ **+45**（`dup_pend` 1 + `dup_rgb` 32 + `rd_pixels_sel` 10 + 32 位 2:1 mux） | 估算，**未综合** |

**老实说**：面积只回吐 ~0.2%（60,098/60,800 的 98.85% → 约 98.6%），**主要收益是时间与带宽，不是面积**。
如果 Lead 的动机是"怕布不通"，这个方案帮不上大忙（−150 XLR ≈ 0.25%）；它的价值在 −2.6 ms 和 −25% 显示读。

---

## 五、风险评估

**低风险，且关键部分已被仿真正面证明。**

1. **不重新引入历史那类 CDC 错行**：地址生成仍 100% 在 clk 域，只依赖 `row_number`（clk）与
   `single_panel_clk`（clk 域 2FF，原本就有）。没有新增任何跨域路径；pix_clk 域**完全没改**。
2. **仿真能证明且已证明**：地址/行映射（垂直 2×）、列复制（水平 2×）、双面板与单面板、无欠载 —— 81,920 像素 0 失配，
   且与"改动前的画面"逐行相同（A/B identical）。
3. **仿真不能证明的三件事**（必须上板才知道）：
   - 真实 DDR 仲裁：我的 AXI 从端是理想模型，请求节奏变了（每行 3 个突发而非 5 个）；
   - 面积/时序：未综合。写通道删掉 128 位 mux 对 148.5 MHz 有利，显示端新增 32 位 mux 在 100 MHz 域，压力很小；
   - 60 Hz 刷新下的实际 underflow（预期改善）。
4. **一条要记住的新跨文件约束**：显示端写死 320/1280。若以后把 `TAIL_LOWRES` 改回 0，必须同步把显示端改回 640/2560。
   **失配是显眼的错**（画面会整块错位/黑），不是隐蔽的错。
5. **两处遗留（我无权限改）**：`style_network_rowpipe.sv:102/133` 的注释仍提 `RESULT_X2`；
   `tests/tb_ci_co_equiv.v:101-103` 的 `-DTB_A3` defparam 现在指向不存在的参数（只在显式 `-DTB_A3` 时才会报错，不影响构建/综合）。
   `ti60f225_cam_hdmi.xml` 不含 `tests/`，**综合不受影响**。

---

## 六、给 Lead 的建议

1. 先跑一次构建看面积/时序（预期 XLR 60,098 → ~59,950，slack 略好）。
2. 上板第一件事看 APB `0x4c`（`display_dma_errors`）与 LED3（underflow）：如果地址错，这两个会立刻涨。
3. 若 320→640 的最近邻放大在视觉上"块感"太重，可以只改 `style_display`：把水平复制换成
   "(p0+p1+1)>>1"（双线性的一半）—— 但这要改 pix 域，属于另一档风险，不建议与本次一起上。
