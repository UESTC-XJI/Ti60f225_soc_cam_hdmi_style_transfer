# Ti60F225 风格迁移系统 —— 完整架构梳理

> 日期：2026-10-26（初版）
> **最后校准：2026-10-27（对照当日构建实测）。文中数字若无日期标注，均为 2026-10-26 之前的历史值，采信前请复核。**
> 分支：`feature/colour-calib-redsky-q`（HEAD `6114e76`，2026-10-27）
> 器件：Efinix Titanium Ti60F225，Efinity 2026.1.132
> 当前资源：**XLR 59,708 / 60,800（98.20%）**、RAM 244/256（95.31%）、DSP 147/160（91.88%）
> 　　[2026-10-27 12:30 构建，`outflow/ti60f225_oob.place.rpt:44,55,56`]
> 时序：**最差 setup slack +0.292 ns**（`core_clk→core_clk` +1.644 ns、`vid_clk_dvi2→vid_clk_dvi2` +0.436 ns、
> 　　`hdmi_tx_slow_clk→hdmi_tx_slow_clk` +4.982 ns）；最差 hold +0.071 ns
> 　　[2026-10-27 12:37 构建，`outflow/ti60f225_oob.timing.rpt:65,72,75,77,88`]
> 帧时间：**50 ms / 18 fps**，其中 **算力 33.2 ms（66%）、总线 ≤18.5 ms（34%）**（详见 §十三）
> 　　[2026-10-27 板上实测，`reports/REPLY_TO_MODEL_20s_experiment.md`、`reports/FOR_MODEL_FIRMWARE_GUIDE.md:304`]

---

## 一、系统总览（一条数据通路，五个阶段）

```
 ┌─────────┐   CSI-2    ┌────────┐   RAW8    ┌─────────┐  XBGR 4B/px
 │ 摄像头   │ ─────────> │ CSI RX │ ────────> │ Debayer │ ────────────┐
 │ (MIPI)  │            │ 控制器 │           │ +RGB增益 │             │
 └─────────┘            └────────┘           └─────────┘             │
                                                                      v
                                                    ┌──────────────────────────┐
                                                    │   DDR3（源帧 slot 0..5）   │
                                                    │  0x05000000 + slot*0x140000│
                                                    └──────────────────────────┘
                                                                      │
                                              ┌───────────────────────┘
                                              v
                              ┌──────────────────────────────────┐
                              │  rowpipe 12 层风格网络（CNN）      │
                              │  L0 → L11，3 个中间 DDR bank 轮转  │
                              └──────────────────────────────────┘
                                              │
                                              v
                                                    ┌──────────────────────────┐
                                                    │  DDR3（风格帧 slot 0..5）  │
                                                    │  0x05800000 + slot*0x140000│
                                                    └──────────────────────────┘
                                              │
                                              v
                              ┌──────────────────────────────────┐
                              │  style_display（读 DDR）           │
                              │  → tone → lift → FPS叠加 → HDMI   │
                              └──────────────────────────────────┘
                                              │
                                              v
                                        ┌──────────┐
                                        │  HDMI TX │
                                        └──────────┘
```

> **显示链顺序（2026-10-27 修正）**：实际是 `display_pixel → luma_color_suppress(tone) → luma_tone_map(lift) →`
> `fps_overlay(FPS 叠加, 最后一级) → dvi_encoder`。**OSD 与直方图已 tie-off**（`db_char_pixel=1'b0`、
> `osd_db_ack/active/busy` 全 0，`ti60f225_oob_top.v:912-916`），所以图中不再出现 OSD。

---

## 二、顶层模块树

```
ti60f225_oob_top                                    rtl/ti60f225_oob_top.v (996 行；2026-10-27 Track1 后 1,002 行)
├── pll / 时钟生成                                  PLL → 多时钟域
├── csi_rx_controller          inst_efx_csi2_rx     rtl/csi_rx_controller.sv
├── debayer_top_2to1                                rtl/debayer/debayer_top_2to1.v
│   └── rgb_gain_v1                                 rtl/debayer/rgb_gain_v1.v
│   └── raw_to_rgb                                  rtl/debayer/raw_to_rgb.v
├── style_video_system         style_demo           rtl/style/style_video_system.sv
│   ├── style_frame_store      store                rtl/style/style_frame_store.sv
│   ├── style_accel            accelerator          rtl/style/style_accel.sv
│   │   └── style_network_rowpipe  network          rtl/accel_rowpipe/style_network_rowpipe.sv
│   │       │                 （`USE_ROW_PIPE=1` 分支；=0 时走备选 style_network）  style_accel.sv:108-126
│   │       └── rowpipe_frame_driver                rtl/accel_rowpipe/rowpipe_frame_driver.v
│   │           ├── rowpipe_engine   u_eng          rtl/accel_rowpipe/rowpipe_engine.v
│   │           │   └── rowpipe_layer #(CI16,CIW8,PIX16,CO16,COUT16)  u_layer
│   │           │       ├── conv3x3_core            rtl/accel_rowpipe/conv3x3_core.v
│   │           │       └── requant                 rtl/accel_rowpipe/requant.v
│   │           └── rowpipe_ddr_banks u_bank        rtl/accel_rowpipe/rowpipe_ddr_banks.v
│   │               └── rowpipe_wr_engine / rd engine（3 个 AXI 口 + FIFO 阵列）
│   ├── style_display          display              rtl/style/style_display.sv
│   │   ├── style_display_beats  beats             rtl/style/style_display_beats.sv
│   │   ├── style_axi_rows      reader             rtl/style/style_axi_rows.sv
│   │   └── style_async_fifo    pixels/requests    rtl/style/style_async_fifo.sv
│   ├── style_key_toggle       key_panel_toggle    rtl/style/style_key_toggle.sv
│   ├── style_ddr_profiler     profiler            rtl/style/style_ddr_profiler.sv（2026-10-27 挂回，5 项）
│   ├── axi_shared_ddr_2m      bridge              rtl/soc_integration/axi_shared_ddr_2m.sv（**内层**，DDR_ID_W=6）
│   └── style_vga_crop                              rtl/style/style_vga_crop.sv
├── soc_video_ddr_integration  soc_video_inst       rtl/soc_integration/soc_video_ddr_integration.sv
│   ├── axi_shared_ddr_2m      bridge              （**外层** CPU↔视频仲裁，DDR_ID_W=4）:203
│   └── Sapphire RISC-V SoC（VexRiscv + UART + I2C + SPI + JTAG）
│       └── video_apb_ctrl（VIDEO_BASE 0xf8100000）  rtl/soc_integration/video_apb_ctrl.sv
│           　⚠ 它实例化在**顶层** `ti60f225_oob_top.v:678`（`osd_apb`），不在本模块内
│           　└── video_cfg_cdc ×2（capture / display 配置 128 位 CDC）+ isp_cdc_mailbox(144)
├── ddr3_top                   u_ddr3_top           rtl/ddr3_controller/ddr3_top.v
│   └── memory_bus_ctl / phy_ctl / DDR3 硬核（厂商提供，部分加密不可读）
├── luma_color_suppress        tone_adjustment      rtl/isp/luma_color_suppress.v
├── luma_tone_map              lift_adjustment      rtl/isp/luma_tone_map.v
│   └── lift_tables.vh（3 张查找表）                 rtl/isp/lift_tables.vh
├── fps_overlay                u_fps_overlay        rtl/accel_rowpipe/fps_overlay.sv（显示链最后一级，:937）
└── dvi_encoder                dvi_encoder_m0       rtl/dvi_tx/dvi_encoder.v_encrypted.v（**厂商加密**）
```

**零实例化（死代码，仍在编译单元里、不消耗资源）**——2026-10-27 全库扫描 + 逐项 grep 确认：
`osd_apb_regs`、`osd_text_double_buffer`、`osd_fixed_text`、`osd_font8x16`、`hdmi_startup_colorbar`(+`hdmi_startup_select`)、
`i2c_owner_mux`、`soc_jtag_channel_mux`、`ddr_address_map_check`、`capture_frame_stats`、`hdmi_info_overlay`(+`_apb`)、
`hdmi_frame_histogram`、`pp_probe/pp_tone/pp_kuwa_iso/pp_kuwa_aniso/pp_wc_finish`、`auto_tone_lift`、
`sc431hai_auto_exposure`、`efx_dsi_tx`、`rgb_gain`(旧版)、`rgb_area_resize_3to2`、`soc_oob/*`、`frame_buffer_V4/*`、`cam_i2c_ctrl/*`。
> 注意：`rtl/ddr3_controller/` 与 `rtl/dvi_tx/` 含加密/黑盒件，其**内部**模块的活性未做完整判定。

---

## 三、五个阶段的详细说明

### 阶段 1：摄像头 → CSI RX → Debayer

| 项 | 内容 |
|---|---|
| **摄像头** | MIPI CSI-2，RAW8 Bayer，通过 I2C 配置（`software/firmware/camera_init_table.h`，165 条初始化） |
| **CSI 接收** | `csi_rx_controller.sv` → 输出 RAW8 像素流 |
| **Debayer** | `debayer_top_2to1.v`：2 像素/时钟，**BGGR 相位**（`CAM_RAW_GREEN_FIRST = 0`） |
| **RGB 增益** | `rgb_gain_v1.v`：Q8.8 定点，`pixel × gain / 256` |
| **增益来源** | `video_apb_ctrl.sv:52`<br>`gain_r = cap_active[15:0]`、`gain_g = cap_active[31:16]`、`gain_b = cap_active[47:32]` |
| **默认值** | `CAP_DEFAULT`：**R=360 / G=256 / B=425**（`16'h0168 / 16'h0100 / 16'h01a9`，`video_apb_ctrl.sv:32`） |
| **固件覆盖** | `camera_3a.c:18-20` 的 `#define STYLE_R/G/B_GAIN` = **520/290/520**（源码值）；**2026-10-27 板上实际生效的是 400/256/414**（24 色卡校准） |

**⚠️ 已知限制**：`rgb_gain_v1` 里 `gain_g` 在奇偶行都被使用，而 R/B 各只用一次。这可能是 G 通道 σ 异常（G/R=1.95）的候选原因之一，**未验证**。

### 阶段 2：源帧写入 DDR

| 项 | 内容 |
|---|---|
| **缓冲管理** | `style_frame_store.sv`：6 个 slot 轮转，每个 slot 有 3 态（FREE / CAPTURING / COMPLETE） |
| **源帧地址** | `0x05000000 + slot × 0x140000`（每 slot 1.25 MB，存 640×480×4B XBGR） |
| **风格帧地址** | `0x05800000 + slot × 0x140000`（即 `raw_base + 0x00800000`） |
| **像素格式** | 每像素 4 B，`{X, B, G, R}`（MSB→LSB）—— **R 在 bit[7:0]**（不是 [23:16]！）。证据：`ti60f225_oob_top.v:830` `hdmi_tx_rdata = display_pixel[7:0]`、`:831 G=[15:8]`、`:832 B=[23:16]`；`style_display_beats.sv:16` 逐字节展开时颜色字节落在每 32 位槽的低字节；`reports/REPLY_TO_MODEL_20s_experiment.md:84`（2026-10-27）亦确认"R 在低字节"。<br>打包点：`rowpipe_ddr_banks.v` 的 `{8'h00, wr_data[23:0]}`（**该行号已从 808 漂到 956**，2026-10-27 核） |

### 阶段 3：rowpipe 12 层风格网络（核心）

#### 3.1 网络拓扑（12 层全 3×3 卷积）

| 层 | ci→cout | 输出尺寸 | 读 bank | 写 bank | 特殊 |
|---|---|---|---|---|---|
| L0 | 3→4 | 640×480 | `0x05800000`（源帧，描述符 `srcb=3`） | `0x06000000` | `resu/xorin=1`，`s2=0` |
| L1 | 4→8 | 320×240 | `0x06000000` | `0x06500000` | `s2=1`（下采样 ×2） |
| L2 | 8→8 | 160×120 | `0x06500000` | `0x06A00000` | `s2=1` |
| L3 | 8→8 | 160×120 | `0x06A00000` | `0x06000000` | — |
| L4 | 8→8 | 160×120 | `0x06000000` | `0x06500000` | **残差 + idxor**（`idxor=1` **仅此一层**） |
| L5 | 8→8 | 160×120 | `0x06500000` | `0x06A00000` | — |
| L6 | 8→8 | 160×120 | `0x06A00000` | `0x06000000` | **残差**（`res=1`） |
| L7 | 8→8 | 160×120 | `0x06000000` | `0x06500000` | — |
| L8 | 8→8 | 160×120 | `0x06500000` | `0x06A00000` | **残差**（`res=1`） |
| L9 | 8→8 | 320×240 | `0x06A00000` | `0x06000000` | **上采样 ×2**（`up=1`） |
| L10 | 8→4 | 640×480 | `0x06000000` | `0x06500000` | **上采样 ×2**（`up=1`）；**吃掉全网 29.6% 的 MAC**，是当前算力瓶颈 |
| L11 | 4→3 | 640×480 | `0x06500000` | `0x06A00000` | **最终输出**；`relu_dis=1` 强制透传（见 §十四） |

> 本表已按描述符逐字段复核 [2026-10-27，`style_network_rowpipe.sv:79-92` 的 `mk(...)`]。
> ⚠ 两处修正：① "残差 + idxor" 原表写在 L4/L6/L8 三行——**残差（`res`）确实在这三层，但 `idxor=1` 只在 L4**；
> ② 原表把 L0/L1/L2 都标 "stride 2"——描述符里 **`s2=1` 的只有 L1/L2，L0 的 `s2=0`**（L0 输入输出同为 640×480）。
> **待核**：`res`/`resu` 两个标志位的语义在 RTL 里没有注释说明，上表的"残差"是按 `res=1` 推断的；
> 字段**位置**（`res,resu,xorin,s2,up` 的排列）已确认，**语义**建议向 RTL 作者确认。

**3 个中间 bank 轮转复用**（每 5 MB）：
- BANK0 = `0x06000000`
- BANK1 = `0x06500000`
- BANK2 = `0x06A00000`

**⚠️ 重要结构限制：bank 三层复写。** L5 写 bank2 → L6 读 → L8 写（覆盖）→ L9 读 → L11 写（覆盖）。**板子 halt 后，中间 bank 只剩最后写入者的数据，读不到历史层。**

#### 3.2 每层的硬件配置

```verilog
rowpipe_layer #(
    .CI(16),    // 输入通道上限
    .CIW(8),    // 输入通道位宽
    .PIX(16),   // 每时钟像素数
    .CO(16),    // 输出通道上限
    .COUT(16)   // 输出通道位宽
) u_layer
```

#### 3.3 量化（requant）

每层输出都做一次 requant：

```verilog
q = clamp( RHE( relu?(acc) · M , shift ), qlo, qhi )
```

| 参数 | 位宽 | 来源 | 说明 |
|---|---|---|---|
| **M** | signed 32 | 权重 blob，每输出通道一个 | `M / 2^shift ≈ s_a·s_w / s_out` |
| **shift** | 6 | 权重 blob，**每层一份（非每通道）** | |
| **qlo** | signed 8 | 同上 | 下限 |
| **qhi** | 8 | 同上 | 上限 |

**`RHE` = round-half-to-even**（不是四舍五入）。写成 `(n + 2^(s-1)) >> s` 会和 PyTorch 系统性不符。

#### 3.4 权重 blob

| 项 | 值 |
|---|---|
| 大小 | **903 beat / 14,448 B / 3,612 word**（`rowpipe_weights.h:1,907`；与 `FOR_MODEL_QUANT_CONTRACT.md:27` 一致）<br>**RTL 独立验证**：层偏移表 `wbase_of` 最后一项 L11 = 854，L11 为 `ci=4` ⇒ `4×9+13 = 49` ⇒ `854+49 = 903` ✓（`rowpipe_engine.v:251-269`）<br>⚠ **"22,512 B（1,407 beat）"不是当前 DDR 通路的实际大小**，它有两个历史/旁支来源：① 固件注释 `style_driver.c:38-39` 引旧 `INTERFACE.md §8` 的口径；② **未被实例化**的 file-based 流式加载器 `rowpipe_wmem_stream`（`rowpipe_ddr_banks.v:638`，`FILE="weights_blob.hex"`，`mem[0:1406]`）。固件实际只写 `ROWPIPE_WEIGHT_WORDS = 3612` 个字 |
| 位置 | DDR `0x06F00000`（编译期参数 `WEIGHT_ADDRESS`，`style_network_rowpipe.sv:18`） |
| 加载时机 | 固件**上电写一次**（`style_init_and_selftest`，`style_driver.c:40-41`）；但 **`rowpipe_engine` 每帧都从 DDR 重读权重** ⇒ 这是"不重烧现场改权重"的物理基础（见 §十五） |
| 布局 | 每层 = `ci×9` 权重 beat + 4 bias beat + 8 个 M/mid beat + 1 个 Q beat = `ci×9 + 13`；12 层共 903 beat（`FOR_MODEL_QUANT_CONTRACT.md:29-37`） |
| 校验 | 固件算 XOR 与 `ROWPIPE_WEIGHT_XOR` 比对，**只在开机跑一次**（`style_driver.c:43-45`） |

**近期用过的权重**（2026-10-27 校准）：

| 风格 | XOR | 状态 |
|---|---|---|
| **redsky v5** | **`0xcbc67865`** | ✅ **2026-10-27 当前板上**（`rowpipe_weights.h:908`、`REPLY_TO_MODEL_20s_experiment.md:109`） |
| redsky v4（原始） | `0xcb1d96c9` | 历史；其 L11 头被改过后 XOR 变 `0xcb3cccd5`（`L11_QUANT_FIX_2026-10-26.md:16`） |
| redsky q | `0xc06d273c` | ✅ 已验证 |
| starry g065/g075/g085 | `0xff827fe7` / `0xf6a82050` / `0xcdc157c0` | g075 已验证；**g075/g085 中过"末层被 ReLU"的坑** |
| ink v14a / v14a_safe | `0x434fd8b6` / `0x20eb625b` | ❌ 板上无输出 |
| ink v14a_VERIFIED | `0x423d41f9` | ✅ 已验证 |
| greatwave | `0x433c18e4` | ✅ 已验证 |
| scream / scream_pastel | `0x6127e407` / `0x54ede8f4` | 未测（已被 redsky 系列替代） |

### 阶段 4：风格帧回写 + 显示

| 项 | 内容 |
|---|---|
| **L11 输出** | 写 bank2（`0x06A00000`），`rowpipe_frame_driver` 打包成 XBGR beat |
| **最终落点** | `result_address` = `0x05800000`（= 风格帧 slot 0） |
| **显示读取** | `style_display.sv`：`raw_base(slot) + 0x800000 + row*2560` |
| **格式转换** | `style_axi_rows` 不做转换；`style_display:107` 用 `right_side` 判断：<br>右半（风格）`rd_pixel ^ 0x808080`<br>左半（原画）裸值 |
| **显示模式** | 双面板：左 640 原画（x=260..900）+ 右 640 风格（x=900..1540）<br>单面板（KEY1）：居中 640（x=580..1220），左右各 480 黑边 |

### 阶段 5：HDMI 输出前的后处理

| 模块 | 位置 | 参数 | 作用 |
|---|---|---|---|
| **luma_color_suppress** | `rtl/isp/luma_color_suppress.v` | `tone` 0x04c = `0x00202001`<br>enable=1, high_green=32, dark_red=32 | 抑制亮绿/暗红 |
| **luma_tone_map** | `rtl/isp/luma_tone_map.v` | `lift` 0x080 = `0x00002001`<br>enable=1, **strength=32** | 暗部提亮（增益型，最大 1.25×） |

**lift 的真实公式**（读源码确认，非加法）：

```verilog
luminance = (R + 2G + B) / 4
extra     = lift_extra_lookup(luminance)        // 0..256，峰值在 code=32
cap       = lift_safe_cap_lookup(max)           // HIGHLIGHT_SAFE=1，防过曝
requested = 256 + (extra × strength) >> 7
factor    = min(requested, cap)
out       = v × factor / 256
```

**实测影响**：strength 32 → 0（关闭）时，右半 σ 从 9.9 升到 12.3（+24%），但**最大单色占比从 32.5% 恶化到 70.0%**。

### 阶段 6：HDMI TX

`dvi_encoder` → TMDS 差分输出 → 1280×720@60（74.25 MHz 像素时钟）。

---

## 四、时钟域划分

### 4.0 先分清"端口名"与"物理时钟"（2026-10-27 修正）

> ⚠ **`cnn_clk` 与 `pix_clk` 不是时钟，是 `style_video_system` 的输入端口名。**
> 顶层的连接是（`ti60f225_oob_top.v:634`）：
> ```verilog
> style_video_system style_demo(.clk(core_clk),.cnn_clk(vid_clk_dvi2),.pix_clk(hdmi_tx_slow_clk), ...)
> ```
> 也就是说：`cnn_clk` ≡ **`vid_clk_dvi2`（148.5 MHz）**，`pix_clk` ≡ **`hdmi_tx_slow_clk`（74.25 MHz）**。
> SDC 里**没有** cnn_clk/pix_clk 这两个时钟（`ti60f225_oob.sdc:6-19,80`，共 13 条）。
> 把它们当独立时钟写进表（本文件 2026-10-26 版就是这样）会误导 CDC 分析。

### 4.1 SDC 约束的全部 13 个时钟 [2026-10-27 12:37 构建，`outflow/ti60f225_oob.timing.rpt:31-43`]

| 时钟（SDC 名） | 周期 | 频率 | 波形 | 用途 |
|---|---|---|---|---|
| `core_clk` | 10.000 ns | **100 MHz** | {0, 5.000} | **主域**：APB、Sapphire SoC、DDR 控制器 AXI、`style_frame_store`、rowpipe AXI 侧、显示读引擎 |
| `clk_100m` | 10.000 ns | 100 MHz | {0, 5.000} | 与 `core_clk` 同频的另一个约束名（板级 100 MHz 输入） |
| `vid_clk_dvi2` | 6.734 ns | **148.5 MHz** | {0, 3.367} | debayer、`camera_raw_gearbox` 目标侧、**rowpipe 计算核**（= 端口名 `cnn_clk`） |
| `hdmi_tx_slow_clk` | 13.468 ns | **74.25 MHz** | {0, 6.734} | HDMI 像素域：tone/lift/meter/`fps_overlay`/`dvi_encoder`、显示侧（= 端口名 `pix_clk`） |
| `i_mipi_rx_pclk` | 20.000 ns | **50 MHz** | {0, 10.000} | CSI 像素时钟、`camera_raw_gearbox` 源侧、CSI 粘滞诊断 |
| `i_cam_ck_CLKOUT` | 10.000 ns | **100 MHz** | {0, 5.000} | CSI byte clock（4 lane 采集） |
| `sdram_clk` | 2.500 ns | **400 MHz** | {0, 1.250} | DDR3 CK |
| `tx_cal_clk` | 2.500 ns | 400 MHz | {0, 1.250} | DDR PHY 写校准 |
| `tx_cal_clk_90edge` | 2.500 ns | 400 MHz | {0, 1.250} | DDR PHY 写校准（90°） |
| `rx_cal_clk` | 2.500 ns | 400 MHz | {0, 1.250} | DDR PHY 读校准 |
| `hdmi_tx_fast_clk` | 2.694 ns | 371.195 MHz | {0.337, 1.684} | TMDS 串行时钟（10:1 并串） |
| `fb` | 18.519 ns | 53.999 MHz | {0, 9.259} | 帧缓冲参考时钟 |
| `CLK_25M` | 40.000 ns | 25 MHz | {0, 20.000} | 板级 25 MHz（未用于主通路） |

**时序余量（可达频率，越高越宽松）** [同上构建，`.timing.rpt:47-55`]：
`core_clk` **119.674 MHz**（对 100 MHz 目标）、`vid_clk_dvi2` **158.781 MHz**（对 148.5）、
`hdmi_tx_slow_clk` **117.841 MHz**（对 74.25）、`i_mipi_rx_pclk` **157.381 MHz**、`i_cam_ck_CLKOUT` **170.300 MHz**。
最紧的是 DDR 校准时钟（`rx_cal_clk` 473 MHz / 2.5 ns 目标）与 `sdram_clk`（458 MHz），它们决定了报告开头的 +0.292 ns。

### 4.2 跨域处理

| 跨越 | 机制 | 核对状态 |
|---|---|---|
| `core_clk ↔ hdmi_tx_slow_clk`（显示行请求） | `style_async_fifo`（gray 码指针，WIDTH=20） | ✅ `style_display.sv:53` |
| `core_clk → hdmi_tx_slow_clk`（像素数据） | `style_async_fifo`（WIDTH=60，`LOG_DEPTH=9`=512） | ✅ `style_display.sv:108` |
| `vid_clk_dvi2 ↔ core_clk`（采集→网络） | `style_async_fifo`（WIDTH=34，LOG_DEPTH=11=2048） | ✅ `style_video_system.sv:35` |
| `core_clk ↔ vid_clk_dvi2`（rowpipe AXI） | `style_axi_cdc`（AR/AW 命令 FIFO + W/R/B 数据 FIFO） | ✅ 2026-10-27 命令 FIFO 由 4 深加深到 16 深 |
| APB → 捕获侧配置 | `video_cfg_cdc`（128 位，`FALLING_EDGE=1`，`raw_vs` 边界提交） | ✅ `video_apb_ctrl.sv:46` |
| APB → 显示侧配置 | `video_cfg_cdc`（128 位，`FALLING_EDGE=0`，`display_vs` 边界提交） | ✅ `video_apb_ctrl.sv:49` |
| 采集域 AE 统计 → core_clk | `isp_cdc_mailbox`（WIDTH=144，toggle 握手） | ✅ `video_apb_ctrl.sv:173` |
| 帧事件（raw/resize/display → core_clk） | `video_frame_event_cdc`（toggle + 2FF） | ✅ `video_frame_diagnostics.sv:45-51` |
| 按键 → 显示域 | `style_key_toggle` **1 个实例**（`style_video_system.sv:56`）+ `style_display` 内部**两组 2FF**（`sp_meta/sp_sync`、`spc_meta/spc_sync`，`:18-30`） | ⚠ 2026-10-26 版写成"双 `style_key_toggle`"，实为 1 个 toggle 模块 + 2 组同步器 |

---

## 五、地址映射总表

| 区域 | 基址 | 大小 | 用途 |
|---|---|---|---|
| **源帧 slot** | `0x05000000 + n×0x140000` | 1.25 MB / slot | 摄像头 XBGR 帧，6 个 slot |
| **风格帧 slot** | `0x05800000 + n×0x140000` | 1.25 MB / slot | 风格化结果，6 个 slot |
| **中间 BANK0** | `0x06000000` | 5 MB | rowpipe 中间层 |
| **中间 BANK1** | `0x06500000` | 5 MB | rowpipe 中间层 |
| **中间 BANK2** | `0x06A00000` | 5 MB | rowpipe 中间层 + L11 输出 |
| **权重 blob** | `0x06F00000` | **14,448 B**（903 beat / 3,612 word）[2026-10-27, `rowpipe_weights.h:1,907`] | rowpipe 权重 + 每层 q 头 |
| **APB STYLE** | `0xf8100200` | — | style_accel 寄存器（+ DDR 仲裁桥） |
| **APB VIDEO** | `0xf8100000` | — | `soc_video_ddr_integration`（寄存器 + Sapphire SoC） |

### APB 寄存器清单（STYLE 区）

| 偏移 | 用途 |
|---|---|
| `0x00` | MAGIC = `0x3154534e`（"NST1"） |
| `0x04` | `stream_enable` + 启动位 |
| `0x08` | 状态（pending / done / error / coeff_idle） |
| `0x0c` | `irq_enable` |
| `0x10/14/18` | `source_cfg` / `result_cfg` / `geometry` |
| `0x1c` | `last_cycles` |
| `0x28` | `coefficient_index` |
| `0x30` | `{acknowledged, issued}` |
| `0x34` | 常数 148,500,000（cnn_clk 频率） |
| `0x38/3c/40` | `captured` / `dropped` / `inferred` |
| `0x44/48/4c` | `infer_errors` / `display_frame_id` / `display_dma_errors` |
| `0x50` | `bridge_errors` |
| `0x54` | **DDR profiler**：`[0]=freeze`（冻结计数便于连贯读） `[1]=clear`（写 1 清零）〔2026-10-27 新增〕 |
| `0x58..0x84` | **profiler 窗口**（`index=(paddr-0x58)>>2`，共 12 个槽位）。本版只实现 5 项：`0x58`=总拍数 T、`0x5c`=CNN AR 反压、`0x60`=显示 AR 反压、`0x64`=读气泡 RGAP、**`0x78`=等 B（BW，index 8）**；其余槽位（`0x68/6c/70/74/7c/80/84`）**读回 0**。固件仍按 12 项全读（`style_driver.c:72`）〔2026-10-27 新增，依据 `style_video_system.sv:105,117-119` + `style_ddr_profiler.sv:67-71`〕 |
| `0xa8/ac` | `read_cycles` / `compute_cycles` 快照 |
| `0xb0/b4/b8` | `prefetch_starts` / `prefetch_completions` / `overlap_cycles` |
| ~~`0xbc`~~ | ⚠ **不存在**：RTL 的 prdata mux 只到 `0x38..0x50 / 0x54 / 0x58..0x68`，`0xbc` 落到 `accel_prdata`（`style_accel` 也无此地址）⇒ **读回 0**。〔2026-10-27 删〕 |

### APB 寄存器清单（VIDEO 区）

> 全部偏移以 fabric `paddr[15:0]` 表示（顶层条件：`paddr[15:8]!=8'h02` 选 VIDEO 区）；
> 固件基址 `VIDEO_BASE = 0xf8100000` [2026-10-27, `video_regs.h:3`]。
> **本表已按 `video_apb_ctrl.sv:69-128` 的 case 全量补齐**（2026-10-26 版只列 8 行）。

| 偏移 | 读 | 写 | 说明 |
|---|---|---|---|
| `0x000–0x030` | `0x000` 返 `CORE_ID=0x4f534431`，其余 0 | **静默忽略**（`legacy_hit=paddr<=0x30`） | 旧 OSD 寄存器区，写不回错 |
| `0x034` | `32'h0001_0000` | 只读（写报 PSLVERR） | ⚠ 2026-10-26 版曾写"常数 148,500,000"，**错** |
| `0x038` | `32'h0000_01ff` | 只读 | |
| `0x03c` / `0x160` | `{27'd0,reset_sync}` | 只读 | `reset_status={display_reset_n,capture_reset_n,cal_done,pll_locked,barrier_sys_reset_n}` |
| `0x040/044/048` | `R/G/B_SHADOW`（`cap_shadow[15:0]/[31:16]/[47:32]`） | 写 | RGB 增益（Q8.8），复位 360/256/425 |
| `0x04c` | `disp_shadow[31:0]` | 写 `&0x00ffff01` | `TONE_SHADOW`（bit0=enable，[15:8]=high_green） |
| `0x050` | 0 | **`CFG_APPLY`**：bit0=应用 capture 配置、bit1=应用 display 配置 | 带合法性校验；被拒时返回 PSLVERR 且不生效 |
| `0x054` | `{30'd0,disp_busy,cap_busy}` | — | `CFG_STATUS` |
| `0x058/05c` | `cap_seq` / `disp_seq` | — | 已应用次数 |
| `0x060/064/068` | `R/G/B_ACTIVE`（cap_mirror） | — | 生效值回读 |
| `0x06c` | `disp_mirror[31:0]` | — | |
| `0x080` | `disp_shadow[63:32]` | 写 `&0x0000ff01`（写 bit1 报错） | `LIFT_SHADOW`（bit0=enable，[15:8]=strength） |
| `0x084/088/08c` | `disp_shadow[79:64]` / mirror | 写（084） | |
| `0x0c0/0c4` | `stats_seq` / `st_y`（AE 亮度和） | — | |
| `0x0d0` | `{28'd0,faults_sync,1'b1}`（**bit0 恒 1**） | — | 固件用它判"统计有效" |
| `0x0d4` | `cap_shadow[55:48]` | 写 | |
| `0x0d8` | `st_frame` | — | AE 帧号 |
| `0x0dc` | `st_cfg`（= `cap_source_seq`） | — | ⚠ 2026-10-26 版写"`STATS_CFG`（未实现）"，**错——它是已实现的** |
| `0x0e0`/`0x150` | `raw_frames` | — | `raw_event` 累加 |
| `0x0e4/0e8` | `st_n`（AE 采样数） / `st_hot`（过曝数） | — | 2026-10-27 修正了 `st_hot` 的位段（原 `[73:52]`→`[73:53]`） |
| `0x0ec` | `1` | 只读 | |
| `0x100/104` | `disp_shadow[82:80]` / mirror | 写（100） | 直方图控制（下游已 tie-off） |
| `0x140` | `fault_sticky` | — | bit5 = "0x050 写被拒" |
| `0x144/148/14c` | `drop_count` / `axi_errors` / `underflows` | — | 32 位累计 |
| `0x154/158` | `resize_frames` / `display_frames` | — | |
| `0x15c` | `{25'd0,csi_sync}` | — | CSI 粘滞错误 |
| `0x190/194` | `cap_shadow[87:56]` / `[103:88]` | 写 | 增益合法性过滤器的字段 |
| `0x198/19c` | `cap_mirror` 对应段 | — | ⚠ 2026-10-26 版把整个 `0x180–0x1A0` 写成"未实现读回 0"，**不准确**：`0x190–0x19c` 是实现且可读写的（AWB 统计缺失指的是别的字段） |
| 其它 | 0 | 写报 PSLVERR | `default:ext_legal=0` |

---

## 六、DDR 带宽与仲裁

### 6.1 现状数字

| 项 | 值 | 出处 / 日期 |
|---|---|---|
| **DDR** | DDR3，控制器 `ddr3_top`，`sdram_clk` 400 MHz，DQ 16 bit | `ti60f225_oob_top.v:690-789` |
| **理论带宽** | **1.6 GB/s**（400 MHz × 2 × 16 bit） | 计算值 |
| **实测有效** | ≈**0.30 GB/s** 量级 | 由 0.26 GB/s @MS57 折算到 MS50；**注意这不是带宽上限，而是事务量的结果**（`reports/line_by_line/02_rowpipe_datapath.md:693`） |
| **显示帧率** | **18 fps @ MS 50 ms** | `reports/REPLY_TO_MODEL_20s_experiment.md:112`（2026-10-27 板上实测） |
| **每帧总流量** | 网络层间 12.29 MB + 显示读 2.46 MB + 源帧写 | 2026-10-26 口径，**待按新构建复核** |

### 6.2 ⚠ 帧时间分解（2026-10-27 校准 —— 本文件最关键的修正）

> **原文（2026-10-26）写的是"算力 7.85 ms（13.8%）+ DDR 等待 49.1 ms（86.2%）"，方向已经反了。**

**当前实测：50 ms/帧 = 算力 33.2 ms（66%）+ 总线 ≤18.5 ms（34%）**
[2026-10-27 板上实测：`reports/FOR_MODEL_FIRMWARE_GUIDE.md:304`（算力 33.2 ms/66%）、
`reports/REPLY_TO_MODEL_20s_experiment.md:112`（50 ms / 18 fps）]

**总线部分的 profiler 实测**（固件 DDR 日志第一行原样，2026-10-27）：
```
DDR100M T 101178407 AR 3 DAR 3 RGAP 12 B 19
```
`T = 101,178,407` 拍 @100 MHz = **1.0118 s** 观测窗（含约 18 帧）：

| 事件 | 占比 | 窗内时间 | 折算每帧（÷18.2 帧） | 含义 |
|---|---|---|---|---|
| `B` | 19% | 192 ms | **10.6 ms** | 写数据发完、等 B 响应回来 |
| `RGAP` | 12% | 121 ms | **6.7 ms** | 读 burst 在飞但没有 beat 到达（AR→首拍往返） |
| `AR` | 3% | 30 ms | **1.7 ms** | CNN 侧 AR 被压住 |
| `DAR` | 3% | 30 ms | **1.7 ms** | 显示侧 AR 被压住 |
| 合计（上界） | 37% | — | **≤20.7 ms** | 33.2 + 20.7 ≈ 54 ms ≈ 实测 50 ms ✓ |

> 🔴 **口径警告（必须连同数字一起引用）**：这四项是 **AXI 接口的占用率，不是互斥的时间划分** ——
> 同一拍可以既在等 B 又在读 gap。`style_ddr_profiler.sv:3` 的原文：
> *"Events overlap: they describe interfaces, not an additive time partition."*
> **只能当上界用，不能相加当结论。** 2026-10-26 那版就是把它当成互斥分解（7.85 + 49.1），导致结论整条反了。

**由此得到的下一步**：算力里最贵的是 **L10（8→4，640×480）一层吃掉全网 29.6% 的 MAC**却只做上采样
（L10 降到 320×240 可省 14.4 ms、L0 降到 160×120 可省 5.6 ms ⇒ 33.2→20 ms、50→37 ms、17→27 fps）。

### 6.3 仲裁是**两层桥串联**，不是"三主一仲裁"

```
[CNN 加速器]──(awid=0x03,arid=0x03)─┐
[显示写 frame_store](awid=0x01)─────┤ 内层 axi_shared_ddr_2m  (style_video_system.sv:82, DDR_ID_W=6)
[显示读 style_axi_rows](arid=0x02)──┘   写 1 笔 / 读 1 笔在途，无 outstanding 队列
                                          │ ddr_* 6 位 ID = {owner, src_id[4:0]}
                                          ▼
                              fb_awid/fb_arid（顶层零扩展成 8 位, ti60f225_oob_top.v:649,651）
                                          │
[Sapphire CPU](awid=3,arid=3)─────────────┤ 外层 axi_shared_ddr_2m  (soc_video_ddr_integration.sv:203, DDR_ID_W=4)
                                             │ 4 位 ID = {owner, src_id[2:0]}
                                             ▼
                                      [ddr3_top]  4 位 ID / 128 位 / 100 MHz
```
**ID 压缩为什么安全**：外层桥只把视频侧的 6 位 ID 取低 3 位发给 DDR，但**返回给主设备的 ID 取自桥内寄存器**
（`axi_shared_ddr_2m.sv:71,74` `cpu_bid/vid_bid = wr_id`），不是取自 DDR 回声 ⇒ 无信息损失。
前提是 DDR 控制器真的回声 `awid/arid`（用于 `b_error/r_error` 校验，`axi_shared_ddr_2m.sv:56-61`）；
可用 APB 的 `0x148`（VIDEO）/ STYLE `0x50` 计数是否恒增来验证。

### 6.4 仲裁参数（**内层与外层不同**，2026-10-27 校准）

| 参数 | 内层（`style_video_system.sv:82`） | 外层（`soc_video_ddr_integration.sv:203`） | 说明 |
|---|---|---|---|
| `DDR_ID_W` | 6 | 4 | owner bit 占最高位，源 ID 分别 5 / 3 位 |
| `VIDEO_READ_PRIORITY` | `!ADAPTIVE_READ` = **0** | **0**（默认） | =1 会让视频侧无条件优先 |
| `DYNAMIC_VIDEO_READ` | `ADAPTIVE_READ` = **1** | **1**〔2026-10-27 打开〕 | 有界动态优先（见下） |
| `URGENT_OVERRIDES_FAIRNESS` | **0** | **0** | **必须 0**：=1 会绕开 streak 上限 ⇒ 持续 urgent 时饿死对侧 |
| `RESERVE_URGENT_READ` | **0** | **0** | **必须 0**：=1 会在 urgent 期间无条件拒 CPU/CNN 的 AR（即使显示侧没请求） |
| `MAX_VIDEO_BURSTS` | 3（默认） | 3（默认） | 连续抢 3 笔后强制让 1 笔 ⇒ 对侧保底 25% |

**有界性**：`streak>=3` 时强制让位（`axi_shared_ddr_2m.sv:49-52`），且 `cpu_arready` 一到就把 streak 清零（`:94`）
⇒ 稳态严格 **3:1**，CPU 每 4 次仲裁必得 1 次。最坏附加读延迟 ≈ 3 ×（512 B 突发 320 ns + DDR ~150 ns）≈ **1.4 µs**
（对照 UART 一字节 87 µs ⇒ 不会让串口/3A 停顿；3A 走 I2C 根本不过 DDR）。
2026-10-27 起 `video_read_urgent` 已从 `style_demo` 导出并接到外层桥，使外层也认显示截止期。

### 6.5 写通道 burst 合并（历史）

分支 `wburst-18.5fps` 里的 burst 合并版（`MAXB=8`）把写命令从 451,250/帧降到 90,250/帧，**单面板 18.5 fps**，
但当时因写通道占用变长导致双面板欠载闪烁而被回退。**2026-10-27 的 Track1 已把"posted-B + 64 拍 burst + 显示读优先级"作为当前设计合入**
（`reports/REPLY_TO_MODEL_20s_experiment.md:108`），上一轮的"已回退"结论已过期。

---

## 七、固件结构

| 文件 | 职责 |
|---|---|
| `main.c` | 主循环：DDR 自检 → 风格自检 → 摄像头初始化 → 3A 服务 → 指标上报 |
| `style_driver.c` | 权重加载到 `0x06F00000`、APB 寄存器访问、自检（**只校验权重 XOR，不做像素对比**） |
| `camera_3a.c` | AE/AWB（AWB 因统计硬件缺失而无法工作）、曝光控制、**色彩增益写入** |
| `camera_ae.c` | `camera_ae_target()` — 曝光目标计算 |
| `camera_awb.c` | `camera_awb_target()` — AWB 目标（**因 `r_sum=0` 第一行就 return**） |
| `soc_video_driver.c` | VIDEO 区寄存器访问 |
| `video_ctrl.c` | `video_apply_gains(r,g,b)` — 写 shadow + apply |
| `rowpipe_weights.h` | 当前权重表（`ROWPIPE_WEIGHT_WORDS = 3612`，14,448 B = **903 beat**；`:908` 是 XOR `0xcbc67865`） |

### 当前固件的关键改动（我加的）

```c
// camera_3a.c:16-20
#define STYLE_AE_FREEZE 0        // AE 恢复自动
#define STYLE_R_GAIN 520u        // debayer 增益（RTL 默认 360）
#define STYLE_G_GAIN 290u        // RTL 默认 256
#define STYLE_B_GAIN 520u        // RTL 默认 425

// camera_3a_init() 末尾
video_apply_gains(STYLE_R_GAIN, STYLE_G_GAIN, STYLE_B_GAIN);
```

**⚠️ 校准状态（2026-10-27 更新）**：上面是**源码里的值**；而 **2026-10-27 板上实际生效的是 400/256/414**
（24 色卡校准，`reports/COLOR_CHECKER_CALIB_2026-10-27.md`、`REPLY_TO_MODEL_20s_experiment.md:110`）。
**读"当前用什么增益"时必须区分"源码默认值"与"板上生效值"。**

**⚠️ 这个校准是在暗光色卡环境下调的，换到亮场景会过曝。已知问题，待重新校准。**

---

## 八、当前已知问题（按责任方）

| # | 问题 | 现象 | 责任方 | 状态 |
|---|---|---|---|---|
| **1** | **右半大面积同色** | `#989898` 占 32.5%（关 lift 后 70%）→ **2026-10-26 夜改 L11 量化头后平坦区 0%** | **模型侧（标定）** | 🟡 **结构已修**，残留低对比度需模型侧重标（见 §十四） |
| **2** | **输出均值偏正 / 通道 DC 不等** | 2026-10-27 实测修正前 `B−R=+8.1` → 修正后 **−0.2** | 模型侧（DC 随场景变） | 🟡 板侧可线性补偿，但**不存在对所有场景都对的常数 DC** |
| **3** | **G/R σ 比异常** | 板上 1.95 vs 模型侧 1.06 | **疑似 debayer** | 🟡 未验证 |
| **4** | 双面板空间细节损失 | σ 12.3 vs DDR 23 | RTL（lift 贡献 24%） | 🟡 部分定位 |
| **5** | 色彩校准过曝 | 亮场景 23% 像素饱和 | RTL（我的校准） | 🟡 需重校 |
| **6** | AWB 完全失效 | 统计硬件不存在（`0x180-0x1A0` 读回 0） | RTL（缺模块） | 🔴 **无法修复（需加硬件）** |
| **7** | AE 曝光到顶 | `exp=4989` 已达上限 | 传感器进光量 | 🟡 硬件限制 |
| **8** | ~~DDR 有效带宽低~~ | 0.26 GB/s vs 1.6 GB/s 理论 | RTL（仲裁/命令数） | 🟢 **2026-10-27 已改善/降级**：posted-B + 64 拍 burst 后总线不再是瓶颈（算力占 66%，见 §六/§十三） |
| **9** | `style_display_beats` FIFO 深 32 vs 需 160 | — | RTL | 🟢 **已证伪为根因**（三项反例），但深度确实偏小 |

---

## 九、已验证的修复

| # | 修复 | 效果 | 状态 |
|---|---|---|---|
| **1** | **双重 XOR** | 原画和风格各自 XOR 一次 → 互相抵消。改成 `right_side` 判断后**只对风格 XOR** | ✅ **右半亮度 22→170** |
| 2 | 按键边沿检测 | 原为电平触发（每拍翻转）→ 改下降沿 | ✅ 按键正常 |
| 3 | 按键软件消抖 → 删除 | 硬件已消抖 | ✅ 省 50 XLR |
| 4 | AXI stall 下数据错误 | `rd_idx = rptr + beat_idx + wready` | ✅ 写引擎正确 |
| 5 | PnR seed 1 → 7 | 资源 97% 时 seed 1 不收敛 | ✅ 布线通过〔**待核**：2026-10-27 查 `_b.bat` 只有 `efx_run … compile`，**没有 seed 参数**；seed 应在工程 XML/设置里，本文无法从脚本复核〕 |
| 6 | 居中单面板 | `img_x0=580, img_x1=1220`，1:1 不拉伸 | ✅ 已实现 |

---

## 十、关键源码位置速查

| 要查什么 | 文件:行 |
|---|---|
| **XOR 转换（显示）** | `style_display.sv:107` |
| **显示几何（双/单面板）** | `style_display.sv:40-49` |
| **行请求 FSM** | `style_display.sv:126-152` |
| **像素 FIFO** | `style_display.sv:108`（WIDTH 60, LOG_DEPTH 9） |
| **beat FIFO（深度 32）** | `style_display_beats.sv:10-14` |
| **AXI 读（无 XOR）** | `style_axi_rows.sv:45-50` |
| **RGB 增益映射** | `video_apb_ctrl.sv:47` |
| **CAP_DEFAULT（增益默认）** | `video_apb_ctrl.sv:32` |
| **DISP_DEFAULT（lift/tone 默认）** | `video_apb_ctrl.sv:33` |
| **12 层描述符** | `style_network_rowpipe.sv:79-95` |
| **层描述符位域** | `rowpipe_engine.v:88-114` |
| **bank 基址** | `rowpipe_frame_driver.v:78-80` |
| **权重 blob 解析（M）** | `rowpipe_engine.v:350-360` |
| **权重 blob 解析（shift/qlo/qhi）** | `rowpipe_engine.v:363-370` |
| **结果帧打包（字节序）** | `rowpipe_ddr_banks.v:956`（2026-10-26 版引的 `:808` 已失效） |
| **量化 RHE 实现** | `requant.v`（整个文件）；**末层强制透传**：`requant.v:98,122` + `rowpipe_engine.v:145-146` |
| **L11 量化头（当前值）** | DDR `0x06F03860` = `0x001FE065`（shift 37 / qlo 129 / qhi 127） |
| **lift 公式** | `luma_tone_map.v:25-45` |
| **lift 查找表** | `lift_tables.vh:3/267/531` |
| **debayer 增益通道映射** | `rgb_gain_v1.v:70-90` |
| **AE 逻辑** | `camera_3a.c:104-160` |
| **AWB 逻辑（失效）** | `camera_awb.c:12-20` |
| **权重加载** | `style_driver.c:36-48` |

---

## 十一、当前构建命令

```bash
# 固件（必须用 bash 脚本，Python 版会让 GCC 崩溃）
bash tools/build_firmware.sh
# → software/firmware/build/soc_video_app.bin

# bit（清工作目录后编译）
rm -rf work_syn work_pnr work_pt outflow
cmd //c _b.bat
# → outflow/ti60f225_oob.bit

# 烧录（板子必须先重启！）
cmd //c _flash_new.bat           # bit
cmd //c _ocd_new.bat             # OpenOCD
# 然后 telnet 4444: reset halt → load_image → 校验 → reg pc 0x1000 → resume

# 串口（115200 8N1，COM 号每次确认）
```

---

## 十二、诚实边界

| 项 | 状态 |
|---|---|
| 模块层次与实例名 | ✅ **逐个核对源码**（含 2026-10-27 补的 `fps_overlay`/profiler/两层桥） |
| 地址映射 | ✅ **读 localparam / case 语句确认**（VIDEO 表 2026-10-27 已按 case 全量补齐） |
| 12 层拓扑与 bank 分配 | ✅ **从描述符逐字段解析**（2026-10-27 修正 `idxor`/`s2` 两处） |
| 时钟域 | 🟡 **按 SDC 13 条约束 + 端口连接核对**（2026-10-26 那句"按信号名前缀统计"正是把 `cnn_clk`/`pix_clk` 当成独立时钟的原因） |
| 量化公式与参数位宽 | ✅ **读 RTL 源码**（`requant.v`） |
| **`qlo>=0` 即 ReLU / 末层透传** | ✅ **读源码 + 板上验证**（见 §十四） |
| lift 公式 | ✅ **读源码，已纠正为增益型** |
| **AWB 统计硬件缺失** | ✅ **APB 直读确认**（`0x180-0x18c` 为 0；注意 `0x190-0x19c` 是实现的） |
| **G 通道 σ 异常原因** | ❌ **只是候选假设，未验证** |
| **右半大面积同色的中间层来源** | ❌ **无法读取历史层（bank 复用）** |
| 各层的实际周期数 | 🟡 **部分可测**（2026-10-27 起有 profiler 5 项 + STYLE `0x1c/0xa8..0xb8` 快照；逐层尚未展开） |
| RAM 244/256 的细分 | 🟡 `outflow/ti60f225_oob.hier_util.rpt` 已有层级细分，**未展开到本文** |
| 性能数字（帧率/带宽/帧时间分解） | ✅ **每个数字带日期与出处**（2026-10-27 校准）；本文中未标日期的数字一律视为 2026-10-26 前历史值 |

---

## 十三、帧时间账：50 ms 花在哪了〔2026-10-27 校准，新增〕

> 本节是 §六 的展开。**结论：瓶颈已从总线转移到算力。**

### 13.1 总账

| 项 | 值 | 占比 | 出处 / 日期 |
|---|---|---|---|
| 帧时间 `MS` | **50 ms** | 100% | 2026-10-27 板上固件日志（`REPLY_TO_MODEL_20s_experiment.md:112`） |
| 帧率 | **18 fps** | — | 同上 |
| **算力**（12 层 3×3 conv 的 MAC 时间） | **33.2 ms** | **66%** | 2026-10-27，`FOR_MODEL_FIRMWARE_GUIDE.md:304` |
| **总线等待**（上界，事件重叠） | **≤18.5 ms** | **≤34%** | 2026-10-27 profiler 实测（见 13.3） |

### 13.2 算力侧：贵在哪一层

成本函数（`FOR_MODEL_QUANT_CONTRACT.md:184`、`FOR_MODEL_FIRMWARE_GUIDE.md:295`）：

```
每帧算力拍 ≈ Σ_layers  (out_px_l / 16) × (ci_l × 9 + 16)      # MAC 阵列 16 像素 × 8 通道全并行
```

| 维度 | 成本 | 结论 |
|---|---|---|
| 分辨率 | **平方** | 640×480 加一层 = 11.4 ms；160×120 加一层 = 0.71 ms（**差 16 倍**） |
| `ci` | **线性**（×9） | ci 翻倍 ⇒ 该层算力翻倍 |
| `cout` | **免费**（≤8 时） | MAC 阵列 16 px × 8 ch 全并行，cout 4→8 不花时间 |

**当前的浪费点**：`L10`（8→4，640×480）一层吃掉全网 **29.6%** 的 MAC，却**只做上采样**；
`L0`（3→4，640×480）再占 5.6 ms。**理想形态是"窄输入、宽输出、深在低分辨率"**，而当前 L0/L10/L11 都是"宽进窄出"，正好反了。

**可执行项**：L10 降到 320×240 省 **14.4 ms**，L0 降到 160×120 省 **5.6 ms**
⇒ 算力 33.2 → 20 ms，帧时间 50 → 37 ms（**17 → 27 fps**）[`FOR_MODEL_FIRMWARE_GUIDE.md:305-307`]。

### 13.3 总线侧：profiler 实测与**口径警告**

固件 DDR 日志第一行（2026-10-27 板上原样）：
```
DDR100M T 101178407 AR 3 DAR 3 RGAP 12 B 19
```
- `T = 101,178,407` 拍 @100 MHz = **1.0118 s**（观测窗，含约 18 帧）
- 四项按每帧折算：`B` 19% → **10.6 ms**；`RGAP` 12% → **6.7 ms**；`AR` 3% → **1.7 ms**；`DAR` 3% → **1.7 ms**

> 🔴 **口径警告：这四项是 AXI 接口占用率，不是互斥的时间划分。** 同一拍可以既在等 B 又在读 gap
> （`style_ddr_profiler.sv:3` 原文：*"Events overlap: they describe interfaces, not an additive time partition"*）。
> **只能当上界用**；把它们相加（10.6+6.7+1.7+1.7 = 20.7 ms）与算力 33.2 ms 相加得 53.9 ms，比实测 50 ms 略大，
> 差额就是重叠部分。**2026-10-26 那版文档正是把它当互斥分解，才得出"总线占 86.2%"的反向结论。**

### 13.4 一句话结论

`50 ms ≈ 算力 33.2 ms（66%）+ 总线 ≤18.5 ms（34%）`。
**要提速，改网络结构（把重卷积搬到低分辨率）的收益远大于继续优化总线。**

---

## 十四、量化层的两条铁律〔2026-10-27，新增〕

### 铁律 1：`qlo >= 0` 等于给这层开 ReLU；**末层已被 RTL 强制透传**

```verilog
// requant.v:98 / :122（2026-10-27 最新版）
wire signed [31:0] ar = (relu_dis_r || (qlo_r < 0)) ? a : ((a > 0) ? a : 32'sd0);
//      ↑ 末层强制透传（新增）        ↑ 原有的"qlo<0 即不 ReLU"判据
```
- 硬件**没有独立的 ReLU 开关**：`qlo>=0` 就等于声明"这一层带 ReLU"（2026-10-26 版 `:114` 只是这一条）。
- **2026-10-27 新增的根除手段**：`rowpipe_engine.v:145-146` `wire last_layer = (L == NL-1); wire relu_dis = last_layer;`
  → 经 `rowpipe_layer.v:128,923` → `requant.v:57,75,84`（`ld_relu_dis` / `relu_dis_r`），
  **末层无论导出的 `qlo` 是多少都不会再被 ReLU**。
  ⇒ 这把"靠权重侧避开"变成了 **"RTL 层根除"**：即使模型侧又导出 `qlo=0` 的末层头，也不会再复现"右半平坦泛白"。
- 11 个中间层保持 `qlo=0`（它们本来就是 ReLU 层），与 `spec.json` 的
  `activation_signed=[F,F,F,F,F,T,F,T,F,T,F,F]` 及描述符的 `xorin` 一一对应——**不要动**。
- **当前 L11 头（2026-10-27 板上）**：`shift 37 / qlo 129（=−127）/ qhi 127`，字 `0x001FE065`，位于 `0x06F03860`。
- 量程换算：`m = M >> shift`，要求 `m × (末层 acc 跨度 ≈ 105,286) ≈ 255` ⇒ `shift ≈ 38`；
  `shift=37` 时 conv 满幅 460 LSB（超量程 1.8 倍，会大面积贴轨）[`FOR_MODEL_QUANT_CONTRACT.md:123-134`]。

### 铁律 2：权重 blob 的 XOR 自检**只在开机跑一次** ⇒ 可以 DDR 直写换权重

- 固件：开机写一次 blob，算一次 XOR 与 `ROWPIPE_WEIGHT_XOR` 比对（`style_driver.c:40-45`）。
- RTL：`rowpipe_engine` **每帧都从 DDR 重读权重**（`L11_QUANT_FIX_2026-10-26.md:52`）。
- ⇒ 运行中直接改 DDR 的 blob 区域，**下一帧即生效**，不动固件、不重烧 bit/ELF（见 §十五）。
- ⚠ 两个边界：① 改动**掉电即失**（`REPLY_TO_MODEL_20s_experiment.md:114`）；
  ② 改完 XOR 不再等于固件里的常量 ⇒ **下次复位固件判校验失败并 return -3**，卡在自检；要固化必须同时改 `rowpipe_weights.h` 并重编固件。

---

## 十五、不重烧的三种现场调试法〔2026-10-27，新增〕

> 前提：读者已能 halt/resume（OpenOCD）与读写 APB。三种手段都**不需要重新构建、不需要重烧 ELF/bit**。

| # | 手段 | 地址 / 命令 | 生效时机 | 单次耗时 | 适用场景 |
|---|---|---|---|---|---|
| **A** | **DDR 直写权重 / 偏置** | blob 内任意字；例 L11 bias ch0/1/2 = `0x06F037A0/A4/A8`（int32，2026-10-27 板上值 `64324/60688/33738`） | 下一帧 | **~20 s**（halt→`mww`→resume） | 调风格强度、消通道 DC 偏色（2026-10-27 实测 `B−R +8.1 → −0.2`，σ 不变） |
| **B** | **DDR 直写量化头** | `0x06F03860` = `{qhi[21:14], qlo[13:6], shift[5:0]}`；当前 `0x001FE065` | 下一帧 | **~20 s** | 改末层是否 ReLU、改输出量程（`shift`）——修"平坦泛白"用的就是这条 |
| **C** | **APB 改相机增益** | 写 `0xf8100040/44/48` = gain_r/g/b（Q8.8），再写 `0xf8100050 = 1` 生效 | 下一个 `raw_vs` 边界（≤1 帧） | **微秒级**（+1 帧等待） | 白平衡 / 与曝光联动；比"改固件→编译→烧→重配 bit"快约 20 倍 |

**各自的坑（务必先读）**：
- **C 的坑**：`0x050` 的提交要等**采集帧边界**（`video_cfg_cdc` 在 `raw_vs` 边沿提交）。
  若**相机断流（无 `raw_vs`）**，请求永不 ACK ⇒ `cap_busy` 永久为 1 ⇒ **之后所有 `0x050` 写都返回 PSLVERR**、
  增益再也改不动（`video_apb_ctrl.sv:79-80`；`video_cfg_cdc.sv:2` 原文 *"No-frame requests remain pending"*）。
  此时只能重新上电恢复。
- **A/B 的坑**：连续重烧 ELF 会锁存采集故障（`FAULT 1 / CAP 0 / 3A state 7`），
  **只 reset CPU 清不掉，必须重新上电**（`docs/PROJECT_HANDOFF.md`、`L11_QUANT_FIX_2026-10-26.md:63-64`）。
- **A/B 的固化路径**：验证成功的值要写进 `software/firmware/rowpipe_weights.h` 并重编固件
  （含同步更新 `ROWPIPE_WEIGHT_XOR`），否则下次上电即回退。

**推荐工作流**：用 C 调相机侧（秒级迭代）→ 用 B 定末层量化域 → 用 A 扫偏置/风格强度 → 三个都定下来后一次性固化进 `rowpipe_weights.h` + 固件。
