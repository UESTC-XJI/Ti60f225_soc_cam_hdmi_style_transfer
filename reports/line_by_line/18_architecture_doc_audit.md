# `reports/ARCHITECTURE_FULL.md` 与当前代码一致性审计

> 审计对象：`reports/ARCHITECTURE_FULL.md`（452 行，最后改动 2026-10-26 00:15，文档自称 HEAD `5dfaf5a`）
> 审计时间：2026-10-27 14:00　当前 HEAD：`6114e76`（分支 `feature/colour-calib-redsky-q`）
> 约束：**只读**；未修改 `ARCHITECTURE_FULL.md` 本身；未跑构建、未碰板子/OpenOCD。
> 权威基准：`outflow/ti60f225_oob.place.rpt` / `.timing.rpt`（**10-27 12:30–12:37 的全新构建**，已含今天全部 RTL 改动）、
> `reports/FOR_MODEL_QUANT_CONTRACT.md`（量化契约，权威）、`REPLY_TO_MODEL_20s_experiment.md`（10-27 13:45 最新实测）、
> `FOR_MODEL_FIRMWARE_GUIDE.md`（10-27 13:16）、`L11_QUANT_FIX_2026-10-26.md`、以及源码逐处核对。

---

## 一、结论先行

**共核对 63 条可验证硬事实：❌ 错误 8 条、⚠️ 过时 14 条、🟡 不精确/不完整 21 条、✅ 正确 20 条。**
另有 **3 块结构性缺失**（性能账、量化铁律、现场调试法）与 **1 个整节需要重写**（§六 DDR 仲裁与带宽）。

### 最严重的三条

| # | 位置 | 问题 | 为什么最严重 |
|---|---|---|---|
| **1** | 文档 `:320`（§六 "Measured 分解"） | **"算力 7.85 ms（13.8%）+ DDR 等待 49.1 ms（86.2%）"——整条结论方向已经反了** | 当前实测是 **算力 33.2 ms（66%）+ 总线等待 ~16.8 ms（34%）**（`FOR_MODEL_FIRMWARE_GUIDE.md:304`、`:191`）。照这份文档做决策，会把资源投在已经修好的总线上，而真正的瓶颈（算力，L10 一层吃掉 29.6% MAC）被忽略。**这是唯一一条会导致错误技术路线的偏差。** |
| **2** | 文档 `:114` | **"XBGR 4 B/像素，R 在 bit[23:16]"——字节序写反了** | 实际 **R 在低字节 `bit[7:0]`**：`ti60f225_oob_top.v:830` 明写 `hdmi_tx_rdata = display_pixel[7:0]`；`REPLY_TO_MODEL_20s_experiment.md:84` 也确认"源帧 640×480 XBGR，**R 在低字节**"。改权重/换风格的人若按文档理解通道，会做出**整条颜色链反色**的改动。（另：该条引用的 `rowpipe_ddr_banks.v:808` 已漂移到 `:956`，且该文件正被另一队友编辑。） |
| **3** | 文档 `:6` | **"时序 slack +0.046 ns"与 `:53` "顶层 7,581 行"** | slack 实测 **+0.292 ns**（`timing.rpt:65`），且 `core_clk→core_clk` 是 **+1.644 ns**、`vid→vid` **+0.436 ns`——文档那个数既旧又来源不明。顶层实为 **996 行**（Track1 后 1002 行），文档写 7,581 行（**差 7.6 倍**），会让人误判这个文件的阅读成本与修改风险。 |

---

## 二、审计方法

| 类别 | 我核了什么 | 手段 |
|---|---|---|
| 资源/时序 | XLR / RAM / DSP / WNS / 各时钟可达频率 | 读 `outflow/ti60f225_oob.place.rpt`、`ti60f225_oob.timing.rpt`（10-27 12:30/12:37 构建） |
| 性能 | 帧率、MS、算力/总线分解 | 读 `FOR_MODEL_FIRMWARE_GUIDE.md`、`REPLY_TO_MODEL_20s_experiment.md`、profiler 实测行 |
| 量化 | blob 布局、L11 头、qlo/ReLU、XOR | 读 `requant.v:114`、`rowpipe_weights.h`、`style_driver.c`、两份契约报告 + **手工解码 q 头字** |
| 模块 | 活/死代码 | 全库脚本扫描 `module` 定义 vs 实例名（156 定义 / 105 实例名），再对关键项手工 grep 复核 |
| 地址 | DDR / APB / slot | 读 `style_frame_store.sv`、`rowpipe_frame_driver.v`、`style_video_system.sv`、`video_apb_ctrl.sv`、固件 |
| 时钟 | 频率与用途 | 读 `ti60f225_oob.sdc` + `timing.rpt` 的 Clock Frequency Summary + `ti60f225_oob_top.v` 端口连接 |
| 显示 | 几何、字节序、XOR | 读 `style_display.sv`、`style_display_beats.sv`、`ti60f225_oob_top.v` |

**审计边界（诚实声明）**：
- `rtl/ddr3_controller/` 与 `rtl/dvi_tx/` 含**厂商加密件**（`dvi_encoder.v_encrypted.v`、DDR3 PHY 细节），我只核对了文档对它们的**接口级描述**，未做活性/内部结构判定；脚本里出现的 `memory_bus_ctl`/`phy_ctl` 等"零实例化"提示**可能是我的正则漏抓**，不作为结论。
- `rowpipe_ddr_banks.v` 在 10-27 12:00 被另一队友修改（本审计前 2 小时），其**行号**类引用一律视为易漂移。
- 历史实测类数字（如 10-25 的 σ 9.9→12.3）**无法用当前构建复现**，我按"历史记录"处理并标注。

---

## 三、逐条清单

### 3.1 资源与工具（文档开头 5 行）

| # | 文档行 | 类别 | 文档写的 | 当前真相 | 证据 |
|---|---|---|---|---|---|
| 1 | `:6` | ⚠️ 过时 | XLR **59,132/60,800（97.2%）** | **59,708/60,800（98.20%）**，仅余 1,092 | `place.rpt:44`（10-27 12:30） |
| 2 | `:6` | ✅ 正确 | RAM 244/256 | 244/256（95.31%） | `place.rpt:55` |
| 3 | `:6` | ✅ 正确 | DSP 147/160 | 147/160（91.88%） | `place.rpt:56` |
| 4 | `:6` | ❌ **错误** | 时序 slack **+0.046 ns** | **最差 setup slack = +0.292 ns**；`core_clk→core_clk` **+1.644**；`vid_clk_dvi2→vid` **+0.436**；`hdmi_slow→hdmi_slow` **+4.982**；最差 hold **+0.071** | `timing.rpt:65,77,72,75,88` |
| 5 | — | 🟡 **缺失** | （无） | 建议补**量程余量**：core_clk 8.356 ns=**119.674 MHz**、vid 6.298 ns=**158.781 MHz**、hdmi_slow 8.486 ns=**117.841 MHz**、i_mipi_rx_pclk **157.381 MHz** | `timing.rpt:47-55` |
| 6 | `:4` | ⚠️ 过时 | HEAD `5dfaf5a` + 未提交 XOR 修复 | 当前 HEAD **`6114e76`**（10-27），且工作树有大量未提交改动 | `git log -1` |
| 7 | `:5` | ✅ 正确 | Efinity 2026.1 | Version **2026.1.132** | `place.rpt:3` |

### 3.2 性能与帧时间（§六，本次偏差最集中处）

| # | 文档行 | 类别 | 文档写的 | 当前真相 | 证据 |
|---|---|---|---|---|---|
| 8 | `:306` | ⚠️ 过时 + 🟡 误导 | 实测有效 **0.26 GB/s（MS=57ms 时）** | MS 已 50 ms ⇒ ≈**0.30 GB/s**；且该数**是事务量的结果、不是带宽上限**（原文自己也在 `line_by_line/02:693` 指出过） | `REPLY_TO_MODEL_20s_experiment.md:112`；`02_rowpipe_datapath.md:693` |
| 9 | `:308` | ⚠️ 过时 | 显示帧率 **17.2–17.5 fps**（MS 57–58） | **18 fps @ MS 50 ms** | `REPLY:112`、`FOR_MODEL_FIRMWARE_GUIDE.md:17` |
| 10 | `:320` | ❌ **错误（方向反了）** | 算力 **7.85 ms（13.8%）** + DDR 等待 **49.1 ms（86.2%）** | 算力 **33.2 ms（66%）** + 总线 ≈**16.8 ms（34%）**；profiler 实测窗 `T=101,178,407` 拍、`B 19% / RGAP 12% / AR 3% / DAR 3%` | `FOR_MODEL_FIRMWARE_GUIDE.md:304,191` |
| 11 | `:324` | ⚠️ 过时 | burst 合并版"**最终回退了**" | posted-B + `MAXB=64` 已是**当前设计**（Track1 C 档：posted-B + 显示读优先级 + 64 拍 burst） | `REPLY:108`、`FOR_MODEL_FIRMWARE_GUIDE.md:14` |
| 12 | `:307` | 🟡 未复核 | 每帧流量 12.29 MB（83%）+ 显示读 2.46 MB + 源帧写 | 数量级可信，但"83%"是按**旧的 0.26 GB/s 口径**算的被除数，需按新口径重算 | — |
| 13 | `:369` | ⚠️ 过时 | 问题 #8「DDR 有效带宽低」= 🟡 已知 | 总线**已不是瓶颈**（算力占 66%）⇒ 该项应移入"已改善"并改写结论 | `FOR_MODEL_FIRMWARE_GUIDE.md:304` |
| 14 | `:370` | ✅ 正确 | `style_display_beats` FIFO 深 32 | `memory[0:31]`、`in_ready=count<32` — 深 32 ✓ | `style_display_beats.sv:10,14` |
| 15 | `:309` | 🟡 不完整 | 仲裁模块 `axi_shared_ddr_2m`（`style_video_system:69`） | 是**两层桥串联**：内层 `:69`（`DDR_ID_W=6`）+ 外层 `soc_video_ddr_integration.sv:203`（`DDR_ID_W=4`）。**只写一层会让人以为只有 3 主 1 仲裁** | `soc_video_ddr_integration.sv:203`、`reports/line_by_line/15_track1_urgency_cdc.md` |
| 16 | `:314-317` | ⚠️ 过时 | 外层桥参数 `URGENT=0 / RESERVE=0 / VIDEO_PRIORITY=!ADAPTIVE_READ / DYNAMIC=ADAPTIVE_READ` | 10-27 起**外层桥已 `#(.DYNAMIC_VIDEO_READ(1'b1))` + `video_read_urgent` 已连**（Track1 改动）；内层参数不变 | `soc_video_ddr_integration.sv:203-204` |

### 3.3 量化契约 / L11 / 权重 blob

| # | 文档行 | 类别 | 文档写的 | 当前真相 | 证据 |
|---|---|---|---|---|---|
| 17 | `:175` | 🟡 不精确 | blob "大小 **22,512 B**（1,407 beat，DDR 记录 903 beat/14,448 B）" | 实际 blob = **903 beat / 14,448 B / 3,612 word**；22,512 B 是**固件注释里预留窗口的说法**（`style_driver.c:39` 说 1,407 beat，与数据数组自相矛盾）。文档把源注释的错误照抄了 | `rowpipe_weights.h:1,907`、`FOR_MODEL_QUANT_CONTRACT.md:27` |
| 18 | `:176` | ✅ 正确 | 位置 0x06F00000（`WEIGHT_ADDRESS`） | `parameter [31:0] WEIGHT_ADDRESS = 32'h06F0_0000` | `style_network_rowpipe.sv:18`、`style_driver.c:40` |
| 19 | `:177` | 🟡 不精确 | 加载时机"**固件上电写一次**" | 固件确实只在开机写一次 + 校验一次，但 **`rowpipe_engine` 每帧都从 DDR 重读权重** ⇒ 这是"不重烧现场改权重"的物理基础，文档漏了这半句 | `style_driver.c:41-45`、`L11_QUANT_FIX_2026-10-26.md:52` |
| 20 | `:179` | ✅ 正确 | 固件算 XOR 与 `ROWPIPE_WEIGHT_XOR` 比对 | ✓（当前值 **`0xcbc67865`**） | `style_driver.c:43-45`、`rowpipe_weights.h:908` |
| 21 | `:185` | ⚠️ 过时 | redsky v4 `0xcb1d96c9` = **"✅ 当前板上"** | 当前板上是 **redsky v5 = `0xcbc67865`**；且 v4 那套的 L11 头已被改过（XOR 变 `0xcb3cccd5`）。整张"6 套权重"表的状态列需重列 | `REPLY:109`、`rowpipe_weights.h:908`、`L11_QUANT_FIX:16` |
| 22 | `:158-169` | ✅ 正确 | requant 公式、M/shift/qlo/qhi 位宽、RHE 语义 | 与 `requant.v` 和契约 §1.2 一致 | `FOR_MODEL_QUANT_CONTRACT.md:39-48` |
| 23 | `:162-167` | 🟡 **关键缺失** | 只列了 qlo/qhi 的"位宽/来源" | **没有说"`qlo>=0` 等于开 ReLU"这条铁律**——L11 的平坦泛白就是踩了它。这是全文最该补的一句 | `requant.v:114`、契约 §1.3 |
| 24 | 全文 | 🟡 **缺失** | （无 L11 头一节） | 当前 L11 量化头 = **shift 37 / qlo 129 / qhi 127**（word `0x001FE065`，位于 `0x06F03860`；我按 `[5:0]=shift,[13:6]=qlo,[21:14]=qhi` 手工解码验证） | `REPLY:16`、`L11_QUANT_FIX:57` |

### 3.4 模块清单与死代码

| # | 文档行 | 类别 | 文档写的 | 当前真相 | 证据 |
|---|---|---|---|---|---|
| 25 | `:53` | ❌ **错误** | 顶层 `ti60f225_oob_top.v` **7,581 行** | **996 行**（887 非空）；Track1 后 **1002 行** | 实际文件；`reports/line_by_line/04_top_soc.md` |
| 26 | `:78` | ❌ **错误** | `video_apb_ctrl` 挂在 `soc_video_ddr_integration` 之下 | 它在**顶层**实例化（`osd_apb`），`soc_video_ddr_integration` 里没有它 | `ti60f225_oob_top.v:678` |
| 27 | `:86` | 🟡 不精确 | `dvi_encoder  rtl/dvi_tx/` | 实际是 `rtl/dvi_tx/dvi_encoder.v_encrypted.v`（**厂商加密，不可读**） | 文件系统 |
| 28 | `:62` | 🟡 不完整 | `style_accel → style_network_rowpipe` | 还有 `parameter bit USE_ROW_PIPE` 的 generate 分支与备选实现 `style_network`（非 rowpipe 版） | `style_accel.sv:108-126` |
| 29 | `:75` | ✅ 正确 | `axi_shared_ddr_2m bridge`（内层） | ✓ 但应注明在同一模块里**还存在外层那一份** | 见 #15 |
| 30 | 全文 | 🟡 **缺失** | 树里没有 `fps_overlay` | **`fps_overlay` 是显示链的最后一级（活代码）**，文档完全没提 | `ti60f225_oob_top.v:937`、`rtl/accel_rowpipe/fps_overlay.sv` |
| 31 | 全文 | 🟡 **缺失** | 没有死代码清单 | 我手工 grep 确认**零实例化**的：`osd_apb_regs`、`osd_text_double_buffer`、`osd_fixed_text`、`hdmi_startup_colorbar`(+`hdmi_startup_select`)、`i2c_owner_mux`、`soc_jtag_channel_mux`、`ddr_address_map_check`、`capture_frame_stats`、`hdmi_info_overlay`(+`_apb`)、`hdmi_frame_histogram`（仅被死模块引用）、`pp_probe/pp_tone/pp_kuwa_iso/pp_kuwa_aniso/pp_wc_finish`、`auto_tone_lift`、`sc431hai_auto_exposure`、`efx_dsi_tx`、`rgb_gain`(旧)、`rgb_area_resize_3to2`、`soc_oob/*`、`frame_buffer_V4/*`、`cam_i2c_ctrl/*` | 全库扫描 + 逐项 `grep '^\s*<mod>\b'` |
| 32 | `:48` | 🟡 不完整 | §一 流程图写 "→ lift → tone → OSD → HDMI" | 真实顺序是 **tone → lift → (OSD 直通) → fps_overlay → dvi_encoder**；OSD 与直方图已 tie-off（`db_char_pixel=1'b0`） | `ti60f225_oob_top.v:880-943` |

### 3.5 地址映射

| # | 文档行 | 类别 | 文档写的 | 当前真相 | 证据 |
|---|---|---|---|---|---|
| 33 | `:256-257` | ✅ 正确 | 源/风格 slot `0x05000000`/`0x05800000` + n×`0x140000`，6 slot，1.25 MB | `raw_base(slot)` 表 0x05000000..0x05640000；result = raw + `0x00800000` | `style_frame_store.sv:26-27,87` |
| 34 | `:258-260` | ✅ 正确 | BANK0/1/2 = `0x06000000`/`0x06500000`/`0x06A00000`，各 5 MB | ✓（源码注释还强调"间隔必须 ≥5 MB，原来的 2 MB 是错的"） | `rowpipe_frame_driver.v:78-80` |
| 35 | `:262-263` | ✅ 正确 | APB STYLE `0xf8100200` / VIDEO `0xf8100000` | ✓ 与 `paddr[15:8]==8'h02` 的 RTL 判决、固件 `STYLE_BASE/VIDEO_BASE` 完全一致 | `ti60f225_oob_top.v:629`、`style_driver.c:7`、`video_regs.h:3` |
| 36 | `:283` | ❌ **错误** | `0xbc` = `{state, mode[1:0]}` 显示模式（若启用） | STYLE 区 **没有 0xbc**：`style_video_system` 的 prdata mux 只到 `0x38..0x50 / 0x54 / 0x58..0x64`，其余落到 `accel_prdata`（`style_accel` 也无 0xbc ⇒ 恒 0） | `style_video_system.sv:104-108`、`style_accel.sv:82-91` |
| 37 | `:265-283` | ⚠️ 过时 | STYLE 表无 `0x54`，无 `0x58..0x64` | **10-27 新增 profiler**：`0x54`=freeze/clear，`0x58..0x64`=5 个计数器（T/AR/DAR/RGAP/BW） | `style_video_system.sv:89-108`、`style_ddr_profiler.sv:13-18` |
| 38 | `:296` | ❌ **错误** | `0x0dc` = `STATS_CFG`（**未实现**） | `0x0dc` 返回 `st_cfg`（= `cap_source_seq`），**已实现** | `video_apb_ctrl.sv:103` |
| 39 | `:287-296` | 🟡 不完整 | VIDEO 表只有 8 行 | 实际实现 40+ 个偏移；至少缺 `0x034/038/03c`（版本/复位状态）、`0x058/05c`（cap/disp seq）、`0x0c0/0c4`（stats_seq/st_y）、`0x0d0/0d4/0d8/0e0/0e4/0e8`、`0x100/104`（hist）、`0x140`(fault_sticky)、`0x144..160`（drop/axi/underflow/frames/csi） | `video_apb_ctrl.sv:69-128` |
| 40 | `:295` | 🟡 不精确 | `0x180–0x1A0` = AWB 统计（**未实现，读回 0**） | `0x180..0x18c` 确是 0，但 **`0x190/0x194` 是可写的 cap_shadow 字段、`0x198/0x19c` 是 cap_mirror 回读**（已实现） | `video_apb_ctrl.sv:119-126,203-216` |
| 41 | `:267-282` | ✅ 正确 | STYLE `0x00..0x50 / 0xa8..0xb8` 各项 | 逐条与 `style_accel.sv:82-91` 吻合；`0x34 = 148500000` 也 ✓ | `style_accel.sv:88` |

### 3.6 时钟（§四）

| # | 文档行 | 类别 | 文档写的 | 当前真相 | 证据 |
|---|---|---|---|---|---|
| 42 | `:234-235` | ❌ **概念错误** | 把 **`cnn_clk` 148.5 MHz**、**`pix_clk` 74.25 MHz** 列为"时钟" | 它们是 `style_video_system` 的**端口名**，物理时钟是 `vid_clk_dvi2`(6.734 ns) 与 `hdmi_tx_slow_clk`(13.468 ns)。SDC 的 13 条约束里**没有 cnn_clk/pix_clk** | `ti60f225_oob_top.v:634`、`ti60f225_oob.sdc:6-19,80`、`timing.rpt:36-37` |
| 43 | `:237` | 🟡 缺数字 | `vid_clk_dvi2` 频率写 "—" | **148.5 MHz**（period 6.734 ns） | `timing.rpt:36` |
| 44 | `:231-237` | 🟡 不完整 | 表里只有 5 个时钟 | 实际 13 个约束：另含 `i_mipi_rx_pclk` **50 MHz**、`i_cam_ck_CLKOUT` **100 MHz**、`sdram_clk`/`tx_cal_clk`/`rx_cal_clk`/`tx_cal_clk_90edge` **400 MHz**、`clk_100m` 100 MHz、`CLK_25M` 25 MHz、`fb` 53.999 MHz、`hdmi_tx_fast_clk` 371.195 MHz | `timing.rpt:31-43` |
| 45 | `:247` | 🟡 不精确 | 按键同步 = "**双 `style_key_toggle`** 同步器（`sp_meta/sp_sync` 与 `spc_meta/spc_sync`）" | `style_key_toggle` 只有 **1 个实例**（`style_video_system.sv:56`）；`sp_*`/`spc_*` 是 **`style_display` 内部的两组 2FF**，不是两个 toggle 模块 | `style_display.sv:18-21,27-30` |
| 46 | `:244` | ✅ 正确 | `clk → pix_clk` 像素 FIFO WIDTH=60、LOG_DEPTH=9=512 | ✓（`BUFFERED ? 9 : 10`） | `style_display.sv:108` |

### 3.7 显示链与几何（§三 阶段 4/5）

| # | 文档行 | 类别 | 文档写的 | 当前真相 | 证据 |
|---|---|---|---|---|---|
| 47 | `:114` | ❌ **错误** | R 在 `bit[23:16]` | **R 在低字节 `bit[7:0]`**（见结论 #2） | `ti60f225_oob_top.v:830-832`、`REPLY:84` |
| 48 | `:114` | ⚠️ 行号漂移 | 引用 `rowpipe_ddr_banks.v:808` | 现在是 `:956`（且该文件正被编辑） | `rowpipe_ddr_banks.v:956` |
| 49 | `:201` | ✅ 正确 | 双面板 x=260..900 + 900..1540；单面板 580..1220 | `img_x0=580/260`、`img_x1=1220/1540`、`active h∈[260,1540)` —— 逐字吻合 | `style_display.sv:40-43` |
| 50 | `:200` | ✅ 正确 | `style_display.sv:107` 用 `right_side` 判断，右半 `^0x808080` | `wire [31:0] rgb={8'b0, right_side ? (rd_pixel[23:0]^24'h808080) : rd_pixel[23:0]}` —— **行号也对** | `style_display.sv:107` |
| 51 | `:199` | ✅ 正确 | 显示读取 `raw_base(slot)+0x800000+row*2560` | ✓（640 px × 4 B = 2560 B/行） | `REPLY:84-88` |
| 52 | `:207-208` | ✅ 正确 | tone `0x04c=0x00202001`、lift `0x080=0x00002001`（enable=1,strength=32） | `DISP_DEFAULT = {… 32'h00002001, 32'h00202001}`；bit0=enable、bit15:8=0x20=32 ✓ | `video_apb_ctrl.sv:38` |
| 53 | `:221` | 🟡 历史值 | strength 32→0 时 σ 9.9→12.3、单色占比 32.5%→70% | 无法用当前板复现（现在板上 σ 已是 62.8/59.0/45.7 量级）；应标注"10-25 的历史测量" | `REPLY:32-33` |

### 3.8 固件、已知问题、其他

| # | 文档行 | 类别 | 文档写的 | 当前真相 | 证据 |
|---|---|---|---|---|---|
| 54 | `:346-348` | ⚠️ 过时 | `STYLE_R/G/B_GAIN = 520/290/520` | 源码里 `#define` 确实还是 520/290/520，但**当前板上用的是 400/256/414（24 色卡校准）**；文档把"源码默认值"当成"板上生效值" | `camera_3a.c:18-20`、`REPLY:110`、`COLOR_CHECKER_CALIB_2026-10-27.md` |
| 55 | `:333` | ✅ 正确 | `style_driver.c` 只校验 XOR、不做像素对比 | ✓ | `style_driver.c:43-45` |
| 56 | `:336` | ✅ 正确 | `camera_awb.c` 因 `r_sum` 为 0 就 return | `:14 … \|\|!s->r_sum\|\|!s->b_sum\|\|!s->g_sum)return 0;` ✓ | `camera_awb.c:14` |
| 57 | `:339` | ✅ 正确 | `rowpipe_weights.h` = 3,612 words / 14,448 B | ✓ | `rowpipe_weights.h:1,907` |
| 58 | `:382` | 🟡 不可验证 | 已验证修复 #5 "PnR seed 1 → 7" | 当前 `_b.bat` **只有一行 `efx_run … compile`，没有任何 seed 参数**；seed 应在工程 XML/设置里，我无法确认 | `_b.bat`（全文 5 行） |
| 59 | `:451` | ⚠️ 过时 | "各层的实际周期数 ❌ 未测（只知总 MS）" | 现在**已可测**：profiler 5 项（`0x58..0x64`）+ `last_cycles`(`0x1c`) + RPMS/CPMS 快照(`0xa8/0xac`) + PF/PFC/OVLP(`0xb0..0xb8`) | `style_video_system.sv:97-108`、`style_accel.sv:89-90` |
| 60 | `:452` | ⚠️ 过时 | "RAM 244/256 的细分 ❌ 未查" | `outflow/ti60f225_oob.hier_util.rpt`（123.8 KB）就是层级资源细分，已具备 | 文件系统 |
| 61 | `:445` | 🟡 过于自信 | §十二 "时钟域 ✅ **按信号名前缀统计**" | 恰恰因为"按前缀"才出现 #42 那种把端口名当时钟的错误；建议降级为 🟡 并改为"按 SDC + 端口连接核对" | 结论 #42 |
| 62 | `:400-405` | ⚠️ 部分漂移 | 源码位置速查表 | `style_network_rowpipe.sv:79-95` ✓、`rowpipe_frame_driver.v:78-80` ✓、`style_display.sv:107` ✓；但 `rowpipe_ddr_banks.v:808` → `:956` | 逐条核对 |
| 63 | `:419-434` | 🟡 不精确 | 构建命令含 `rm -rf work_syn work_pnr work_pt outflow` + `_b.bat` | `_b.bat` 实际是 `efx_run.bat … --prj -f compile --output_dir outflow`；"清目录"是人工步骤，未写进脚本 | `_b.bat` |

---

### 3.9 经核对**正确**、修订时请勿改动的 20 条（防止误伤）

修订一份 452 行的文档时，最大的风险是"把对的也改坏"。下面 20 条我已逐条验证，**当前是正确的**：

| 文档行 | 内容 | 验证依据 |
|---|---|---|
| `:6` | RAM 244/256、DSP 147/160 | `place.rpt:55-56` |
| `:5` | Efinity 2026.1 | `place.rpt:3`（2026.1.132） |
| `:98` | CSI RX 输出 RAW8 像素流 | `csi_rx_controller.sv` + top:480-483 |
| `:99` | debayer 2 px/clk、**BGGR 相位**（`CAM_RAW_GREEN_FIRST=0`） | `defines.v:4377`=1'b0、`top:806-809` |
| `:105` | `rgb_gain_v1` 里 `gain_g` 奇偶行都用、R/B 各一次 | `rgb_gain_v1.v:77-87`（两个分支都如此） |
| `:111` | `style_frame_store` 6 slot、3 态 | `style_frame_store.sv:17,74-82` |
| `:112-113` | 源/风格 slot 地址与 stride | `style_frame_store.sv:26-27,87` |
| `:120-133` | **12 层拓扑表**（ci→cout、输出尺寸、上采样位置） | `style_network_rowpipe.sv:79-92` 描述符逐项解码，**与表格完全一致**（含 L9/L10 的 `up=1`） |
| `:135-138` | 3 个中间 bank 轮转、各 5 MB | `rowpipe_frame_driver.v:78-80` |
| `:169` | RHE = round-half-to-even，不能用 `(n+2^(s-1))>>s` | `FOR_MODEL_QUANT_CONTRACT.md:47` |
| `:176` | 权重位置 `0x06F00000` | `style_network_rowpipe.sv:18` |
| `:179` | XOR 校验机制 | `style_driver.c:43-45` |
| `:199-201` | 显示读取地址公式、`right_side` 判断、双/单面板 x 坐标 | `style_display.sv:40-43,107` |
| `:207-208` | tone/lift 的 APB 默认值与 enable/strength | `video_apb_ctrl.sv:38`（`DISP_DEFAULT`） |
| `:244` | 像素 FIFO WIDTH=60 / LOG_DEPTH=9=512 | `style_display.sv:108` |
| `:258-260` | BANK0/1/2 基址 | `rowpipe_frame_driver.v:78-80` |
| `:267-282` | STYLE 区 `0x00..0x50`、`0xa8..0xb8` 各项 | `style_accel.sv:82-91`（含 `0x34=148500000`） |
| `:333` | `style_driver.c` 只校验 XOR、不做像素对比 | `style_driver.c:43-45` |
| `:336` | `camera_awb.c` 因 `r_sum` 为 0 直接 return | `camera_awb.c:14` |
| `:339` | `rowpipe_weights.h` 3,612 words / 14,448 B | `rowpipe_weights.h:1,907` |
| `:370` | `style_display_beats` 深 32 | `style_display_beats.sv:10,14` |
| `:400-402` | 12 层描述符/层位域/bank 基址的行号 | `style_network_rowpipe.sv:79-92`、`rowpipe_frame_driver.v:78-80` |

> 另注：文档 §三 的**层描述符细节**（`res/resu/xorin/s2/up/srcb/dstb/idb/idxor` 这些标志位）在文档里只写了"残差 + idxor"，
> 经核对：**`res`(残差) 出现在 L4/L6/L8 ✓**，但 **`idxor=1` 只在 L4**（描述符里 idxor 是独立字段）。
> 所以 `:126/:128/:130` 三行的"残差 + idxor"应改为：L4 = "残差 + idxor"，L6/L8 = "残差"（无 idxor）。
> 同理 `:122-124` 的 "stride 2"：描述符里 `s2=1` 的是 **L1/L2**，**L0 的 `s2=0`**（L0 输入输出同为 640×480）——
> 这三行的 "stride 2" 标签需逐个复核（L0 那一行存疑，属 🟡）。

## 四、三块新增内容的草稿（可直接粘贴）

### 4.1 【新增章节】帧时间账：50 ms 花在哪了（2026-10-27 实测）

**结论：瓶颈已从总线转移到算力。**

| 项 | 值 | 占比 | 证据 |
|---|---|---|---|
| 帧时间 MS | **50 ms** | 100% | `FOR_MODEL_FIRMWARE_GUIDE.md:17`、`REPLY_TO_MODEL_20s_experiment.md:112` |
| 帧率 | **18 fps** | — | 同上 |
| **算力**（12 层 3×3 conv 的 MAC 时间） | **33.2 ms** | **66%** | `FOR_MODEL_FIRMWARE_GUIDE.md:304` |
| **总线等待**（上界，事件重叠） | **≤18.5 ms** | **≤37%** | 见下 |

**总线部分的 profiler 实测**（固件 DDR 日志第一行原样）：
```
DDR100M T 101178407 AR 3 DAR 3 RGAP 12 B 19
```
`T=101,178,407` 拍 @100 MHz = **1.0118 s**（约 1 秒观测窗，含 ~18 帧）。

| 事件 | 占比 | 窗内时间 | 折算每帧（÷18.2 帧） | 含义 |
|---|---|---|---|---|
| `B` | 19% | 192 ms | **10.6 ms** | 写数据发完、等 B 响应回来 |
| `RGAP` | 12% | 121 ms | **6.7 ms** | 读 burst 在飞但没有 beat 到达（AR→首拍往返） |
| `AR` | 3% | 30 ms | **1.7 ms** | CNN 侧 AR 被压住 |
| `DAR` | 3% | 30 ms | **1.7 ms** | 显示侧 AR 被压住 |
| 合计 | 37% | — | **≤20.7 ms（上界）** | 33.2 + 20.7 = 53.9 ms ≈ 50 ms ✓（重叠导致略大于实测） |

> ⚠️ **口径警告（必须写进文档）**：这四项是**接口占用率，不是互斥的时间划分**——同一拍可以既在等 B 又在读 gap
> （`style_ddr_profiler.sv:3` 原文："Events overlap: they describe interfaces, not an additive time partition"）。
> **只能当上界用，不能相加当结论。**

**由此得到的下一步（与 NETWORK_OPT_PLAN 一致）**：
- 算力里最贵的是 **L10（8→4，640×480）一层吃掉全网 29.6% 的 MAC**，而它只做上采样；L10 降到 320×240 可省 **14.4 ms**，L0 降到 160×120 可省 **5.6 ms** ⇒ 33.2→20 ms，帧时间 50→37 ms（**17→27 fps**）。
- 再加分辨率的成本是**平方**的：640×480 加一层 = 11.4 ms，160×120 加一层 = 0.71 ms ⇒ 新层应加在低分辨率处。

### 4.2 【新增章节】量化层的两条铁律（踩过坑，务必保留）

**铁律 1：`qlo >= 0` 就等于"这一层要 ReLU"，末层必须 `qlo < 0`。**

```verilog
// requant.v:114 —— 硬件没有独立的 ReLU 开关
wire signed [31:0] ar = (qlo_r < 0) ? a : ((a > 0) ? a : 32'sd0);
```

- 11 个中间层 `qlo=0` 是**对的**（它们本来就是 ReLU 层），与 `spec.json` 的 `activation_signed=[F,F,F,F,F,T,F,T,F,T,F,F]` 一致。
- **末层（L11）必须是负的**：`qlo=0` 会把负半轴全夹成 0 ⇒ DDR 里 56% 的字节是 `0x00` ⇒ 显示端 `^0x80` 变成 128 ⇒ 屏上一大片 `#989898`。
- 当前上板值：**L11 头 = `shift 37 / qlo 129（=−127）/ qhi 127`**，字 `0x001FE065`，位于 `0x06F03860`。
- 换算方法（改权重时照做）：`m = M >> shift`；要求 `m × (末层 acc 跨度 ≈ 105,286) ≈ 255` ⇒ `shift ≈ 38`；`shift=37` 时 conv 满幅 460 LSB（超量程 1.8 倍，会大面积贴轨）。

**铁律 2：权重 blob 的 XOR 自检只在开机跑一次 ⇒ 可以直接 DDR 直写换权重/换量化头。**

- 固件：开机写一次 blob，算一次 XOR 与 `ROWPIPE_WEIGHT_XOR` 比对（`style_driver.c:41-45`）。
- RTL：`rowpipe_engine` **每帧都从 DDR 重读权重**（`L11_QUANT_FIX_2026-10-26.md:52`）。
- ⇒ 运行中直接改 DDR 的 blob 区域，下帧即生效，**不影响任何固件状态、不需要重烧 bit/ELF**。
- ⚠️ 两个边界：(a) 改动**掉电即失**（易失，`REPLY:114`）；(b) 改完 XOR 就不再等于固件里的常量，**下次复位固件会判校验失败**（`return -3`）并卡在自检 ⇒ 要固化必须同时改 `rowpipe_weights.h` 并重编固件。

### 4.3 【新增章节】三种"不重烧"的现场调试法

| # | 手段 | 地址 / 命令 | 生效时机 | 单次耗时 | 适用场景 |
|---|---|---|---|---|---|
| **A** | **DDR 直写权重 / 偏置** | `0x06F00000 + 层偏移`；例：L11 bias ch0/1/2 = `0x06F037A0/A4/A8`（int32，当前 `64324/60688/33738`） | 下一帧 | **~20 s**（halt→mww→resume） | 调风格强度、消通道 DC 偏色（实测 `B−R +8.1 → −0.2`，σ 不变） |
| **B** | **DDR 直写量化头** | `0x06F03860` = `{qhi[21:14], qlo[13:6], shift[5:0]}`，当前 `0x001FE065` | 下一帧 | **~20 s** | 改末层是否 ReLU、改输出量程（`shift`）——**修"平坦泛白"用的就是这条** |
| **C** | **APB 改相机增益** | 写 `0xf8100040/44/48` = gain_r/g/b（Q8.8），再写 `0xf8100050 = 1` 生效 | 下一个 `raw_vs` 边界（≤1 帧） | **微秒级**（+1 帧等待） | 白平衡/曝光联动；比"改固件→编译→烧→重配 bit"快约 20 倍 |

> **C 的坑（必须写）**：`0x050` 的提交要在采集帧边界完成，若**相机断流（无 `raw_vs`）**，请求永不 ACK ⇒ `cap_busy` 永久为 1 ⇒
> 之后所有 `0x050` 写都返回 **PSLVERR**（`video_apb_ctrl.sv:79-80`、`video_cfg_cdc.sv:2` 的"no-frame requests remain pending"）。
> **A/B 的坑**：连续重烧 ELF 会锁存采集故障（`FAULT 1 / CAP 0 / 3A state 7`），**只 reset CPU 清不掉，必须重新上电**。

---

## 五、修订建议：**就地改 + 定向重写**（不要整篇重写）

**判断依据**：文档的骨架（§一 系统总览、§二 模块树、§三 五阶段、§五 地址映射、§七 固件、§十 源码速查）**结构是对的**，
63 处事实里多数只是数字过期；真正**结构性错误**集中在 §四（时钟把端口名当时钟）与 §六（仲裁/带宽整节已反）。

### 5.1 处理方式分三档

| 档 | 范围 | 动作 |
|---|---|---|
| **整节重写** | §四 时钟域划分、§六 DDR 带宽与仲裁 | 用本文 #42-46、#8-16 的正确值重写；§六 补"两层桥串联"与"瓶颈已从总线转到算力" |
| **就地改数字** | `:6` 资源/时序、`:306-308` 性能、`:320` 分解、`:175-185` blob/权重、`:114` 字节序、`:283/296` APB、`:346-348` 增益、`:451-452` 诚实边界 | 逐条替换成"当前值 + 日期戳"（**建议每条都带证据行号**，例如 `outflow/…place.rpt:44 @2026-10-27 12:30`） |
| **新增章节** | 本文 §4.1/4.2/4.3 三块 | 直接粘贴；放在 §六 之后作为新 §七/§八 |

### 5.2 建议的新章节结构（12 章 → 15 章）

```
一、系统总览与一句话结论        （改写：加"瓶颈=算力 66%"）
二、顶层模块树 + 活/死代码标注   （改：修 996 行、video_apb_ctrl 位置、加 fps_overlay、
                                加"零实例化清单"小节）
三、五个阶段                     （保留；只修 :114 字节序）
四、时钟域划分                   （**重写**：13 条 SDC 约束 + 量程余量，
                                明确 cnn_clk/pix_clk 只是端口名）
五、地址映射（DDR/APB）          （就地改：补 0x54/0x58..0x64、删 0xbc、修 0x0dc、
                                补 VIDEO 全表）
六、AXI 与仲裁                   （**重写**：两层桥串联、ID 压缩为何安全、
                                内/外层参数现状与"为什么不能开 URGENT_OVERRIDES"）
七、【新】帧时间账               （本文 4.1）
八、【新】量化契约与两条铁律     （本文 4.2 + L11 头现状）
九、【新】现场调试手册           （本文 4.3）
十、DDR 布局与 slot 轮转         （原 §五 的 DDR 部分独立出来，含 6 slot + 3 bank + 权重区）
十一、固件结构与"源码默认值 vs 板上生效值"  （修 :346-348 那类混淆）
十二、已知问题（按责任方）        （更新：DDR 带宽项移出；AWB/OSD 项标注固件未跟上 RTL）
十三、已验证的修复                （保留，补 posted-B / 显示优先级 / L11 头）
十四、源码位置速查                （保留，加"行号易漂移"提示）
十五、诚实边界与审计方法          （把 §十二 的 ✅ 降级为"按 SDC/端口连接核对"，
                                并加"本表的每个数字都带日期与出处"）
```

### 5.3 两条流程建议（防止再次整体过期）

1. **给每个数字加"有效期"**：形如 `XLR 59,708/60,800（98.20%，outflow/…place.rpt @2026-10-27 12:30）`。
   这份文档这次之所以一次偏差 63 条，就是因为**数字没有出处、也没有日期**。
2. **把"活/死代码"与"APB 寄存器表"做成生成物**：两者都能从源码自动导出（我这次用的扫描脚本 30 行就能产出死代码清单；
   APB 表可以从 `video_apb_ctrl.sv` 的 case 列表 + `style_video_system` 的 prdata mux 提取），
   写进文档必然漂移。

---

## 六、附：本次审计的核对清单（可复现）

| 我读了 | 用途 |
|---|---|
| `outflow/ti60f225_oob.place.rpt`（59 行，10-27 12:30） | XLR/RAM/DSP/IO |
| `outflow/ti60f225_oob.timing.rpt`（前 90 行 + 摘要，10-27 12:37） | 13 条时钟、setup/hold slack、可达频率 |
| `reports/FOR_MODEL_QUANT_CONTRACT.md`（208 行） | 量化契约（权威） |
| `reports/FOR_MODEL_FIRMWARE_GUIDE.md`（319 行，节选） | 50 ms / 33.2 ms / profiler 实测行 |
| `reports/REPLY_TO_MODEL_20s_experiment.md`（126 行） | 18 fps、redsky v5 XOR、板上增益、L11 地址与 q 头 |
| `reports/L11_QUANT_FIX_2026-10-26.md`（88 行） | L11 头实验序列、DDR 直写方法、耗时 |
| `requant.v:100-129` / `rowpipe_weights.h:1,907,908` / `style_driver.c:36-49` / `camera_awb.c:14` | 量化铁律与固件事实 |
| `style_display.sv`(153) / `style_display_beats.sv:10-16` / `rowpipe_frame_driver.v:71-90` / `rowpipe_ddr_banks.v:956` | 显示几何、FIFO 深度、bank 基址、字节序 |
| `style_video_system.sv:89-108` / `style_accel.sv:82-91` / `video_apb_ctrl.sv:69-128,203-216` | APB 全表核对 |
| `ti60f225_oob.sdc` / `ti60f225_oob_top.v:626-660,830-943` | 时钟约束、端口连接、显示链顺序 |
| 全库模块扫描脚本（156 定义 vs 105 实例名）+ 关键项手工 grep | 死代码清单 |
| `git log -1` / `_b.bat` | HEAD、构建命令 |
| **未做** | 构建、上板、OpenOCD、修改任何文件 |