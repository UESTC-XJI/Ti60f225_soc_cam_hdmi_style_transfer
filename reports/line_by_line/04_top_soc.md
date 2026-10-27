# 顶层与 SoC 集成逐行阅读

> 范围：`rtl/ti60f225_oob_top.v`（996 行，887 非空，已逐行读完）+ `rtl/soc_integration/` 全部 18 个文件
> 交叉核对：`rtl/defines.v`（生成的 CFG 宏）、`ti60f225_oob.sdc`、`rtl/style/style_video_system.sv`（仅接口与桥实例化）、
> `rtl/frame_buffer_V4/rst_n_piple.v`、`software/firmware/{main.c,style_driver.c,video_regs.h}`、`reports/ARCHITECTURE_FULL.md`
> 方法：只读静态分析；未跑综合、未改任何 RTL。事实与推测严格分开标注。

---

## 结论摘要（5 条）

1. **顶层只有 996 行，且 15 个 `include` 里有 8 个模块在本构建中零实例化。**
   `hdmi_startup_colorbar` / `hdmi_startup_select` / `osd_apb_regs` / `osd_text_double_buffer` / `osd_fixed_text` /
   `osd_font8x16` / `hdmi_info_overlay` / `hdmi_frame_histogram` / `capture_frame_stats` 都只有 module 定义、没有实例
   （全库 grep 见「include 内联清单」）。Lead 背景里"osd_apb_regs / osd_text_double_buffer 仍在 672 行附近被实例化"
   **不成立**：672 行是 `video_apb_ctrl osd_apb`（同名不同物）。这些文件仍在编译单元里，是历史残留，不是活路径。

2. **AXI 是"两层桥串联"，不是"三主一仲裁"。** 内层 `style_video_system` 里的 `axi_shared_ddr_2m`
   （`DDR_ID_W=6`，`style_video_system.sv:69`）把 CNN(awid/arid=0x03)、显示写(awid=0x01)、显示读(arid=0x02) 三个主
   合成**一个** 6 位 ID 端口；再由顶层 `soc_video_ddr_integration.sv:184` 的另一个 `axi_shared_ddr_2m`（`DDR_ID_W=4`，
   全部参数用默认值）把这个端口与 Sapphire CPU(ID=3) 合成**一个** 4 位 ID 的 DDR 口。**每层都只有写 1 笔 + 读 1 笔在途。**

3. **显示欠载的可定位机制（本报告最高价值结论）：外层桥对显示读完全无优先。**
   `soc_video_ddr_integration.sv:184` 实例化时**没有覆盖任何参数**，也**没有连接 `video_read_urgent`**，
   于是外层桥是 `VIDEO_READ_PRIORITY=0 / DYNAMIC_VIDEO_READ=0 / URGENT_OVERRIDES_FAIRNESS=0 / RESERVE_URGENT_READ=0`
   → 读写冲突时只有 `rd_turn` 纯轮转（`axi_shared_ddr_2m.sv:52`）。内层桥那套精心设计的 urgency 机制
   （`MAX_VIDEO_BURSTS=3`）**在跨过外层桥时被降级成一个普通轮转请求**。叠加"单 outstanding"，显示每 512 B 突发
   都必须等 CPU 一笔完整读事务 + R 返回才能拿到下一次 AR。这是"偶尔欠载闪烁"最直接的可解释路径（事实：参数与连线；
   推测：它就是主因）。

4. **复位/栅栏是安全的，但复位释放有三个真实隐患。**
   ① AXI 主机不可能在校准前发事务：`barrier_sys_reset_n` 同时是 SoC 的 `io_asyncReset`（`soc_video_ddr_integration.sv:194`）、
   `allow_access`，也是 `style_demo` 复位链的组成部分，三者同源，没有"先放行后复位"的窗口。
   ② `status_reset_n = barrier_sys_reset_n && capture_reset_n && display_reset_n`（top:597）是**跨 3 个时钟域的组合与**，
   却直接当作 `core_clk` 域（status_counters、style_demo）的异步复位 → 复位**释放**边沿对 core_clk/cnn_clk/pix_clk
   都没有同步器，不受 SDC 约束。
   ③ `style_video_system` 内部 `style_async_fifo` 两侧共用同一根 `rst_n`（`style_video_system.sv:35`），
   而该 rst_n 在两个时钟域的释放时刻不同 → 上电一次性的 FIFO 指针错位风险。
   ①是事实（无风险），②③是事实（结构），后果是推测（概率低但一旦发生不可自愈）。

5. **上电后 452 ms 内 HDMI 没有任何同步信号，而本来写好用于兜底的开机彩条被摘掉了。**
   `vid_rst_n = dly_cnt[26]`（top:855），`dly_cnt` 是 `vid_clk_dvi2`（6.734 ns）上的 27 位计数器 → 2^26 × 6.734 ns
   = **452 ms**，串在 `video_reset_n`（top:551）里，串起了 capture/display/style_demo/整条显示流水线；
   而 `dvi_encoder` 只等 `rst_n_piple DLY=3`（top:538-539）、三个时钟周期就出复位了，之后 452 ms 里它看到的
   `out_vs/out_de` 恒为 0。同时 `bar_*` 线（top:950-951）只剩声明、`hdmi_startup_colorbar/select` 未实例化。
   → 冷启动/复位后显示器可能不锁或锁了再丢，这可以解释"刚上电/按复位后显示闪"。

---

## 顶层实例化全表

`rtl/ti60f225_oob_top.v` 内的 **20 个实例**（含被 include 内联到同文件作用域的模块）：

| # | 实例名 | 模块 | 行 | 时钟源 | 复位源 | 关键连线 / 备注 |
|---|---|---|---|---|---|---|
| 1 | `inst_reset_ctrl` | `reset_ctrl` (`rtl/reset.v:14`) | 387 | `i_mipi_rx_pclk` | `i_arst={2{w_arstn}}` | NUM_RST=2, CYCLE=1, IN_RST_ACTIVE=4'b00, OUT_RST_ACTIVE=4'b10 → 输出 `w_mipi_rx_pclk_arst/arstn`（低有效→高有效） |
| 2 | `inst_efx_csi2_rx` | `csi_rx_controller` | 416 | `clk=i_mipi_clk`(=**core_clk**, top:406)；`clk_pixel=i_mipi_rx_pclk`；`clk_byte_HS=i_cam_ck_CLKOUT` | `reset_n=i_arstn`；`reset_pixel_n=w_mipi_rx_pclk_arstn` | 4 lane RAW；AXI 配置口全 tie-off（awaddr=6'b0, wvalid=0）→ 不上总线 |
| 3 | `ddr_startup` | `ddr_startup_barrier` | 543 | `sys_clk=core_clk`, `vid_clk=hdmi_tx_slow_clk` | `global_reset_n=w_arstn` | 产出 `barrier_sys_reset_n / barrier_vid_reset_n / barrier_allow_sys / barrier_allow_vid / barrier_cpu_waiting`（最后一项无人用） |
| 4 | `hdmi_output_reset` | `rst_n_piple` DLY=3 | 538 | `hdmi_tx_slow_clk` | `w_arstn` | **只**驱动 `dvi_encoder.rst_p`；不经过 DDR 栅栏 |
| 5 | `capture_reset` | `rst_n_piple` DLY=3 | 552 | `vid_clk_dvi2` | `video_reset_n` | 输出 `capture_reset_n` → debayer / camera_replay / style_demo 的 cnn 侧 |
| 6 | `display_reset` | `rst_n_piple` DLY=3 | 553 | `hdmi_tx_slow_clk` | `video_reset_n` | 输出 `display_reset_n` → tone/lift/meter/fps_overlay/style_demo 的 pix 侧 |
| 7 | `csi_reset` | `rst_n_piple` DLY=3 | 555 | `i_mipi_rx_pclk` | `video_reset_n` | 输出 `csi_reset_n` → camera_replay 的源侧、CSI sticky 诊断 |
| 8 | `camera_replay` | `camera_raw_gearbox` | 556 | `s_clk=i_mipi_rx_pclk`, `d_clk=vid_clk_dvi2` | `csi_reset_n` / `capture_reset_n` | 跨域：把 CSI 像素流搬到 148.5 MHz 域，`fault→capture_fault` |
| 9 | `frame_diagnostics` | `video_frame_diagnostics` | 599 | raw/pix/display/core 四域 | `status_reset_n` | 产出 `raw_event / resize_event(→status_capture_event) / display_event` |
| 10 | `status_counters` | `video_status_counters` | 617 | `core_clk` | `status_reset_n` | 1 s 窗口 FPS + 累计计数；`interval_tick` 由 top:604 比较 27'h5F5E0FF(=99,999,999) 产生 |
| 11 | **`style_demo`** | `style_video_system` | 633 | `clk=core_clk`, `cnn_clk=vid_clk_dvi2`, `pix_clk=hdmi_tx_slow_clk` | `status_reset_n && !soc_system_reset` | **视频 AXI 主**（6 位 ID）；APB 从（`paddr[7:0]`）；`rgb_*` 输入、`pixel/hs/vs/de` 输出；`underflow→display_underflow`；`resize_fault→capture_fault`（**resize_fault 无驱动源**，见风险清单） |
| 12 | **`soc_video_inst`** | `soc_video_ddr_integration` | 647 | `core_clk` | `barrier_sys_reset_n` | `allow_access=barrier_allow_sys`；**CPU↔视频 AXI 交接点**；JTAG/USER1、UART、I2C、SPI 全在此；APB 主接口 |
| 13 | `osd_apb` | `video_apb_ctrl` | 672 | `pclk=core_clk`；另有 capture/display 两域用于配置 CDC | `status_reset_n && !soc_system_reset` | VIDEO 区 APB 从；内含 2×`video_cfg_cdc`(128b) + `isp_cdc_mailbox`(144b)；OSD 输出全 tie-off（top:916） |
| 14 | `u_ddr3_top` | `ddr3_top` | 690 | `axi_clk=core_clk`, `sdram_clk=400 MHz`, `core_clk`, `rx/tx_cal_clk` | `rstn=w_arstn`（**不经栅栏**） | 唯一 AXI 从；4 位 ID；`cal_done` 是栅栏的输入 |
| 15 | `debayer_top` | `debayer_top_2to1` | 808 | `vid_clk_dvi2` | `capture_reset_n` | `RAW_GREEN_FIRST=`CFG…INST_DEBAYER_TOP_RAW_GREEN_FIRST → `CAM_RAW_GREEN_FIRST`=0；增益 `\|g_gain ? g_gain : 255`（0→255 兜底） |
| 16 | `tone_adjustment` | `luma_color_suppress` | 880 | `hdmi_tx_slow_clk` | `display_reset_n` | `i_enable=video_display_tone[0]`；**R/B 由 `CAM_RAW_GREEN_FIRST` 决定是否交换，该宏=1'b0 → 实际不交换** |
| 17 | `display_meter` | `ae_frame_stats` | 893 | `hdmi_tx_slow_clk` | `display_reset_n` | 1280×720×1px/clk、MEAN_ONLY=1；输出 `display_stats_valid/mean` 仅供 APB 观测，**无反馈控制**（top:898-900 注释） |
| 18 | `lift_adjustment` | `luma_tone_map` | 901 | `hdmi_tx_slow_clk` | `display_reset_n` | `i_strength = min(disp_lift[15:8],128)`（top:900）；HIGHLIGHT_SAFE=1 |
| 19 | `u_fps_overlay` | `fps_overlay` (`rtl/accel_rowpipe/fps_overlay.sv:13`) | 937 | `hdmi_tx_slow_clk` | `display_reset_n` | LUT 叠加 FPS（0 RAM），是**显示通路最后一级**；`style_fps_disp` 由 style_irq 在 74.25 MHz 域 1 s 计数 |
| 20 | `dvi_encoder_m0` | `dvi_encoder`（**厂商加密** `rtl/dvi_tx/dvi_encoder.v_encrypted.v`） | 963 | `hdmi_tx_slow_clk` | `~hdmi_output_reset_n` | VIC=7'd4（=720p60），audio 全 0；输出取反后送 `tmds_tx_*_TX_DATA` |

**未被实例化但被 `include` 的模块**：见下一节清单。
**被声明但没有任何实例使用的顶层线**（grep 确认只出现 1 次）：`bar_hs/bar_vs/bar_de/bar_r/bar_g/bar_b`(950-951)、
`m_axis_tdata/tvalid/tready/tlast/tuser`(566-570)、`fifo_rd_period`(571)、`app_ref_ack`(298/737)、
`resize_vs/resize_valid/resize_data`(563-565，只写不读)、`osd_r/osd_g/osd_b`(913，只写不读)、
`osd_apb_*` 全部 9 根(588-589，只在 686 被驱动)、`video_display_hist`(683，只被驱动)。
这些是"功能被摘除但线留着"的痕迹，是判断历史演化的直接证据。

---

## APB 寄存器全表（STYLE / VIDEO 两区）

### 地址划分（事实）

```
SoC APB 主 → io_apbSlave_0_{PADDR,PSSEL,PENABLE,...}   (soc_video_ddr_integration.sv:198)
           → apb_paddr[15:0]  (top:653)
           ├── style_select = (paddr[15:8]==8'h02)  → style_demo.apb，只给 paddr[7:0]  (top:629,637)
           └── !style_select                        → osd_apb(video_apb_ctrl).apb，给全 16 位 (top:685)
soc_apb_prdata = style_select ? style_prdata : video_prdata    (top:630-632，三根线各一个 2 选 1)
```
- 固件侧：`VIDEO_BASE 0xf8100000`（`video_regs.h:3`）、`STYLE_BASE 0xf8100200`（`style_driver.c:7`）
  → **与 `paddr[15:8]==0x02` 完全一致 ✓**
- APB 时序：两区 `pready` 都恒 1（`video_apb_ctrl.sv:64`、`osd_apb_regs.sv:36`）→ 零等待，无 SLEEP 周期需求。
- 非法地址：`video_apb_ctrl` 用 `default:ext_legal=0` → `pslverr=access&&!ext_legal`（:65,:128）。

### 组合环与 mux 深度核查（任务必答项）

**结论：`soc_apb_prdata / pready / pslverr` 这组 2 选 1 没有组合环**，但确实构成一条较深的组合路径。逐条论证：

| 候选环 | 路径 | 是否成环 | 依据 |
|---|---|---|---|
| ① pready 反馈 | `soc_apb_pready` → `soc_video_inst.apb_pready` → SoC `io_apbSlave_0_PREADY` → (SoC 内部 APB 主) → `PADDR/PSEL/PENABLE` → 回到从机 | **不成环** | APB 协议要求传输期间 `PADDR/PSEL/PENABLE/PWRITE` 保持稳定，主设备只在 ACCESS 阶段末采 PREADY，**不会因 PREADY 改地址**。这是协议级保证（SoC 是生成网表，不可读，无法代码级验证） |
| ② style 侧 | `style_prdata ← style_accel ← psel/penable/pwrite/paddr`；`psel=soc_apb_psel&&style_select`、`paddr=soc_apb_paddr[7:0]` 全是 SoC 输出 + 组合 | **不成环** | 从机输出不回灌到自己的输入 |
| ③ video 侧 | `video_prdata/pready/pslverr ← always @* (paddr,pwrite,pwdata) + pslverr←value_error←cap_busy/filter_valid` | **不成环** | 同上；`value_error` 只依赖 APB 输入与本地寄存器 |
| ④ `video_read_urgent` | 外层未连接（隐式 net，未驱动） | 无环（也无功能） | `soc_video_ddr_integration.sv:184-191` 无此项 |

**组合路径深度**（需要时序收敛的部分）：`SoC APB 主 → style_select(=8 位比较, top:629) → 从机地址 case
（`video_apb_ctrl.sv:66-129` 的 `always @*`，`paddr` 全 16 位比较）→ `prdata` 2 选 1(top:630) → 回 SoC`。
按 LUT4 估算约 4–6 级；`pclk=core_clk=10 ns`，属普通 core_clk→core_clk 路径，SDC 会自动分析 ✓。
**两个非环但值得注意的点**：
- `style_select` 只看 `paddr[15:8]`，**不看 psel**。若 SoC 在 `PSEL=0` 期间把 `PADDR` 改成 `0x02xx`，`style_select`
  会短暂为真——但两区从机的 `psel` 都被 `soc_apb_psel` 门控（top:637,685），所以无副作用。
  前提是两区从机**内部只用 `psel&&penable` 判访问**（`video_apb_ctrl.sv:61 access=psel&&penable` ✓；
  `style_accel` 不在本报告范围，**待确认**）。
- `video_apb_ctrl.pslverr` 在 ACCESS 阶段**当拍**由 `pwrite/pwdata/value_error` 组合算出，靠"PWDATA 在 SETUP
  阶段末已稳定"的 APB 协议保证成立；`pready=1'b1` 使 SLEEP 周期为 0。→ 单周期 APB，无等待态，**但也没有给
  任何从机留缓冲余地**（若将来加寄存器化的从机，必须同步改 `pready`）。

### VIDEO 区（基址 0xf8100000，偏移 = fabric `paddr`）

| 偏移 | 读值 | 写行为 | 复位值 | 备注/源码 |
|---|---|---|---|---|
| 0x000–0x030 | `paddr==0` 返回 `CORE_ID=0x4f534431`('OSD1')，其余 0 | **静默忽略**（`legacy_hit=paddr<=0x30`，:24,:202） | – | 写 0x000–0x030 **不报错**，是被吃掉的地址区（历史遗留） |
| 0x034 | `32'h0001_0000` | 只读 → 写报 PSLVERR | – | :70。文档说这是 148.5e6，**不符** |
| 0x038 | `32'h0000_01ff` | 只读 | – | :71 |
| 0x03C | `{27'd0,reset_sync[4:0]}` | 只读 | 0 | :72；`reset_status={display_reset_n,capture_reset_n,cal_done,pll_locked,barrier_sys_reset_n}`(top:679) |
| 0x040 | `{16'd0,cap_shadow[15:0]}` = gain_r | 写 `cap_shadow[15:0]` | **0x0168=360** | CAP_DEFAULT(:32) |
| 0x044 | gain_g | 写 `cap_shadow[31:16]` | **0x0100=256** | |
| 0x048 | gain_b | 写 `cap_shadow[47:32]` | **0x01A9=425** | |
| 0x04C | `disp_shadow[31:0]` | 写 `pwdata & 0x00ff_ff01` | **0x0020_2001** | DISP_DEFAULT(:38)；bit0=lift_en，bit15:8=strength |
| 0x050 | 0 | **apply 命令**：bit0=应用 capture 配置、bit1=应用 display 配置 | – | 写会做合法性校验（:79-80）：`pwdata==0` / `pwdata[31:2]!=0` / `bit0 && (cap_busy \|\| !filter_valid \|\| 三路增益有 0)` / `bit1 && disp_busy` → 任一成立则 `value_error` → PSLVERR 且**不生效** |
| 0x054 | `{30'd0,disp_busy,cap_busy}` | – | 0 | `*_busy = req != seen`（:43） |
| 0x058 | `cap_seq` | – | 0 | 已应用次数 |
| 0x05C | `disp_seq` | – | 0 | |
| 0x060/064/068 | `cap_mirror[15:0]/[31:16]/[47:32]` | – | CAP_DEFAULT | 已生效值回读（跨域确认后的） |
| 0x06C | `disp_mirror[31:0]` | – | DISP_DEFAULT | |
| 0x080 | `disp_shadow[63:32]` | 写 `& 0x0000_ff01`；**写 bit1 → value_error** | 0x0000_2001 | :89 |
| 0x084 | `{16'd0,disp_shadow[79:64]}` | 写 | 0 | |
| 0x088/08C | `disp_mirror` 对应段 | – | | |
| 0x090/094 | 0 | **只读**（`ext_writable=0` → 写报错） | – | :93-94 |
| 0x0C0 | `stats_seq` | – | 0 | AE 结果到达计数 |
| 0x0C4 | `st_y`（AE 亮度和，32b） | – | 0 | |
| 0x0C8/0CC | 0 | 只读 | – | |
| 0x0D0 | `{28'd0,faults_sync[2],faults_sync[1],faults_sync[0],1'b1}` → **bit0 恒 1** | – | 0x1 | :100，注释指明固件 `video_stats.c:82` 用它判"数据有效" |
| 0x0D4 | `{24'd0,cap_shadow[55:48]}` | 写 `pwdata[7:0]` | 0 | |
| 0x0D8 | `st_frame` | – | 0 | AE 帧号 |
| 0x0DC | `st_cfg` | – | 0 | = `cap_source_seq` |
| 0x0E0 | `raw_frames` | – | 0 | `raw_event` 累加 |
| 0x0E4 | `{11'd0,st_n}` | – | 0 | AE 采样数 |
| 0x0E8 | `{11'd0,st_hot}` | – | 0 | AE 过曝计数 |
| 0x0EC | `1` | 只读 | – | :107 |
| 0x100 | `{29'd0,disp_shadow[82:80]}` | 写 `pwdata[2:0]` | 0 | 直方图 3 位（**下游已 tie-off，无消费者**） |
| 0x104 | `disp_mirror[82:80]` | – | | |
| 0x140 | `fault_sticky` | – | 0 | :197 位定义：`{[..],faults_sync[2],1'b0,csi\|\|,axi_err\|\|,underflow\|\|,faults_sync[1:0]}`，bit5 = "0x050 写被拒" |
| 0x144 | `drop_count32` | – | | 来自 status_drop_count |
| 0x148 | `axi_errors32` | – | | 来自 `soc_axi_error_count`（桥的 B/R 校验错） |
| 0x14C | `underflows32` | – | | |
| 0x150 | `raw_frames` | – | | 与 0x0E0 同源 |
| 0x154 | `resize_frames32` | – | | = `status_capture_frames` |
| 0x158 | `display_frames32` | – | | |
| 0x15C | `{25'd0,csi_sync[6:0]}` | – | 0 | CSI 粘滞错误 |
| 0x160 | `{27'd0,reset_sync[4:0]}` | – | | 与 0x03C 同源 |
| 0x180–0x18C | 0 | 只读 | – | 保留 |
| 0x190 | `cap_shadow[87:56]` | 写 `pwdata & 0x00ff_ff01` | 0 | 见下"未解字段" |
| 0x194 | `{16'd0,cap_shadow[103:88]}` | 写 `pwdata[15:0]` | 0 | 同上 |
| 0x198/0x19C | `cap_mirror` 对应段 | – | | |
| 0x1A0 | 0 | 只读 | – | |
| 其它 | 0 | 写 → PSLVERR | – | `default:ext_legal=0` |

**CAP/DISP 配置字位置推断（事实级）**：`CAP_DEFAULT = {24'd0,16'h0200,32'h00f8_0800,8'd232,16'h01a9,16'h0100,16'h0168}`
逐段对应 `cap_shadow[127:120]=0`、`[119:104]=0x0200`、`[103:72]=0x00f80800`、`[71:64]=232`、`[63:48]=0x01a9`、
`[47:32]=0x0100`（注释写反了顺序，实际 `[47:32]`=0x0100=G）、`[31:16]=0x0100`? 需以位段为准：
`:52-53` 明确 `gain_r=[15:0], gain_g=[31:16], gain_b=[47:32], disp_tone=disp[31:0], disp_lift=disp[63:32], disp_hist=disp[82:80]`。
`cap_shadow[71:64]`（0x0D4 写）、`[103:88]`（0x194 写）、`[87:56]`（0x190 写）三者构成 `filter_valid` 判据（:63）：
`0 < byte9 < byte10 && u16@[103:88] >= 256`。这是"增益合法性过滤器"，语义是 `min_gain < max_gain` 且 `样本数>=256`。

### STYLE 区（基址 0xf8100200，只给 `paddr[7:0]`）

顶层只做转发，映射在 `style_video_system.sv:79-81`（可见部分）：

| 偏移 | 读值 |
|---|---|
| 0x38 | `captured`（已采集帧数） |
| 0x3C | `dropped`（丢帧数） |
| 0x40 | `inferred`（已完成风格化帧数） |
| 0x44 | `infer_errors` |
| 0x48 | `display_frame_id` |
| 0x4C | `display_dma_errors` |
| 0x50 | `bridge_errors`（**内层**桥的 B/R 校验错，与 VIDEO 区 0x50 的"apply"无关，两区互不冲突） |
| 其它 | `accel_prdata`（`style_accel` 的寄存器，不在本报告逐行范围） |

### 与固件侧偏移的一致性核对

| # | 固件用法 | RTL 实际 | 判定 |
|---|---|---|---|
| 1 | `STYLE_BASE 0xf8100200`（`style_driver.c:7`） | `paddr[15:8]==0x02`（top:629） | ✅ 一致 |
| 2 | `VIDEO_BASE 0xf8100000`（`video_regs.h:3`） | 非 0x02 即 VIDEO 区 | ✅ 一致 |
| 3 | `main.c:115` 读 `0xf8100020`，期待 **bit2 = OSD busy**（这是死代码 `osd_apb_regs.sv:46` 的 `busy_sync2` 位） | `0x020` 落在 `legacy_hit`，恒返回 0 | ❌ **不一致**：`!(0&4)` 恒真 → `app_osd_errors` 每秒 +1，诊断计数被污染（低风险，高置信） |
| 4 | `style_driver.c:114` 读 `0xf8100024>>16` 当 display_fps（旧 `osd_apb_regs:0x24` 映射） | `0x024` 是 legacy，恒 0；且 `video_apb_ctrl` 的 `i_display_fps` 端口**模块内完全未使用** | ❌ **不一致**：固件永远读到 display_fps=0 |
| 5 | 文档 `ARCHITECTURE_FULL.md:277` 说 `0x34 = 148,500,000` | `0x034` 返回 `0x0001_0000` | ❌ 文档错 |

> 附：`video_apb_ctrl` 的 **6 个**统计输入端口 `i_frame_count / i_capture_fps / i_display_fps / i_drop_count /
> i_error_count / i_raw_fps`（:11-13）在模块体内**没有任何读引用**（grep 只命中端口声明行），是 `osd_apb_regs`
> 被合并进来时留下的悬空端口。顶层仍认真地把 `status_display_fps` 等连上去（top:686），但这些值到不了 CPU。
> 注意 `0x150` 返回的 `raw_frames` 是模块内的本地计数器（:54,:193 `raw_event` 累加），**不是** `i_raw_fps` 端口。

---

## rtl/ti60f225_oob_top.v（996 行）

### 职责与契约

顶层 = 板级 IO + 时钟/复位树 + 4 条数据通路（CSI 采集、显示、DDR、APB）的连线台。**几乎不含算法**，
唯一"逻辑"是：复位栅栏树、APB 二区选择、状态统计（1 s FPS）、OSD tie-off、FPS 叠加计数、led 指示。
它同时是 Efinity 工程的唯一 `top`（`ti60f225_cam_hdmi.xml`），通过 `include` 把 15 个模块拉进同一编译单元。

### 端口（按功能分组，全部 `input/output wire`）

| 组 | 端口 | 方向/位宽 | 时钟域 | 语义 |
|---|---|---|---|---|
| JTAG | `jtag_inst1_{CAPTURE,DRCK,RESET,RUNTEST,SEL,SHIFT,TCK,TDI,TMS}` / `TDO` | in 9 / out 1 | TCK 异步 | **USER1 硬 JTAG，归 Sapphire CPU**；`syn_peri_port=0` 属性禁止当普通 IO |
| UART | `system_uart_0_io_rxd/txd` | in/out 1 | core_clk | 115200 调试口 |
| SPI | `system_spi_0_io_{data_0/1_IN,ss,sclk_write,data_0/1_OUT,data_0/1_OE}` | 8 根 | core_clk | 全给 SoC |
| 时钟 | `i_arstn`, `i_mipi_rx_pclk`(20 ns), `vid_clk_dvi2`(6.734 ns=148.5M), `hdmi_tx_slow_clk`(13.468 ns=74.25M), `core_clk`(10 ns=100M), `CLK_25M`(40 ns) | in | – | **只有这 5 个是真时钟端口**；`cnn_clk/pix_clk` 不是时钟，是 `style_demo` 的参数名 |
| PLL | `pll_inst1_RSTN`, `i_pll_locked`, `pll_locked`, `USER_PLL_RSTN`, `DDR3_PLL_RSTN`, `user_pll_locked` | out/in | – | `w_arstn = i_pll_locked & pll_locked & user_pll_locked`（**纯组合，无滤波**，:376） |
| CSI | `io_cam_{sda,scl}_{IN,OUT,OE}`, `o_cam_rst_p`, `i_cam_ck_{LP_P_IN,LP_N_IN,CLKOUT}`, `o_cam_ck_HS_{TERM,ENA}`, `cam_d{0..3}_{HS_IN[7:0],LP_P_IN,LP_N_IN,HS_TERM,HS_ENA,RST,FIFO_RD,FIFO_EMPTY}` | – | 混合 | 4-lane MIPI；`o_cam_rst_p=~w_arstn`（:521） |
| DDR 校准 | `tx_cal_clk_90edge`, `rx_cal_clk`, `tx_cal_clk` | in | – | 2.5 ns 约束，走 DDR PHY |
| DDR 状态 | `pll_shift[2:0]`, `pll_shift_sel[4:0]`, `pll_shift_ena` | out | – | 调试用 |
| DDR 物理 | `ddr_ck_hi/lo, ddr_reset_n, ddr_cke, ddr_addr, ddr_ba, ddr_cas_n, ddr_cs_n, ddr_ras_n, ddr_we_n, ddr_dqs_in_hi/lo, ddr_dq_in_hi/lo, ddr_dqs_oe(_n), ddr_dq_oe, ddr_dqs_out_hi/lo, ddr_dq_out_hi/lo, ddr_dm_hi/lo, ddr_odt` | – | – | 位宽全由 `CFG_*_RANGE_*` 宏 → `CKE_WIDTH/ROW_WIDTH/…` 参数 |
| 板级 | `led[7:0]`, `panel_key` | out/in | core_clk | `panel_key` = GPIOR_22，低有效，切换 并排/全屏 |
| HDMI | `tmds_tx_{clk,data0,data1,data2}_{TX_OE,TX_DATA[9:0],TX_RST}` | out | hdmi_tx_slow_clk | `TX_OE` 恒 1、`TX_RST` 恒 0（:863-871），数据取反后输出（:989-992） |
| 已删除 | MIPI DSI / LCD 23 根 → 被块注释（:192-236） | – | – | **注释掉的端口**，不是悬空 |

`log2` function（:256-264）与 `WR_FIFO_DEPTH/RD_FIFO_DEPTH/SOURCE_WIDTH/SOURCE_HEIGHT/HACT/HFP/HSP/HBP/VACT/VFP/VSP/VBP`
localparam（:270-292）**在模块体内无任何使用**（`CAM_RAW_GREEN_FIRST` 例外，:806 用了），是模板残留。

### include 内联清单（top:20-31，共 15 个文件）

| include 行 | 文件 | 定义的 module | 本构建是否被实例化 | 实例位置 |
|---|---|---|---|---|
| 20 | `isp/isp_cdc_mailbox.v` | `isp_cdc_mailbox` | ✅ | `video_apb_ctrl.sv:173`（AE 144 位邮箱） |
| 21 | `isp/ae_frame_stats.v` | `ae_frame_stats` | ✅ | top:893 `display_meter` |
| 22 | `isp/luma_color_suppress.v` | `luma_color_suppress` | ✅ | top:880 `tone_adjustment` |
| 23 | `isp/luma_tone_map.v` | `luma_tone_map` | ✅ | top:901 `lift_adjustment` |
| 24 | `isp/hdmi_frame_histogram.v` | `hdmi_frame_histogram` | ❌ | 仅在 `hdmi_info_overlay.v:36` 内被实例化，而后者也没人实例化 → **整支死** |
| 25 | `isp/hdmi_info_overlay.v` | `hdmi_info_overlay` | ❌ | 无 |
| 26 | `soc_integration/osd_font8x16.sv` | `osd_font8x16` | ❌ | 仅被 `osd_fixed_text.sv:32`、`osd_text_double_buffer.sv:42` 使用，两者都死 |
| 27 | `soc_integration/hdmi_startup_colorbar.sv` | `hdmi_startup_colorbar` + `hdmi_startup_select` | ❌ | 无（**开机彩条能力存在但未接**） |
| 28 | `soc_integration/video_frame_diagnostics.sv` | `video_frame_event_cdc` + `video_frame_diagnostics` | ✅ | top:599 |
| 29 | `soc_integration/video_cfg_cdc.sv` | `video_cfg_cdc` | ✅ | `video_apb_ctrl.sv:46,49`（×2） |
| 30 | `isp/capture_frame_stats.sv` | `capture_frame_stats` | ❌ | 无 |
| 31 | `soc_integration/video_apb_ctrl.sv` | `video_apb_ctrl` | ✅ | top:672 `osd_apb` |

> 结论：15 个 include 里 **7 个有实例（10 个实例），8 个是纯死代码**。注释（top:18-19）说明 include 的目的是
> "防止 Efinity GUI 保存工程时丢源文件"——这解释了为什么 `rtl/isp` 不在 XML 里却不是死代码（部分是活的），
> 反过来也说明**不能仅凭"在 XML 里"判断死/活**，必须按实例计。死代码不消耗资源（综合会 prune 无实例模块），
> 但会增加编译时间与阅读成本。

### 逐行要点（按行号分段覆盖 1–996）

**1–32 头部/宏**：`include "defines.v"`（1，含全部 `CFG_*` 生成宏）；`include ddr3_parameter.vh`（17）；
18–19 行的注释明确"include 的模块不要再加为独立 design file"。`//define SOFT_TAP 1`（16）已注释。

**34–57 参数**：27 个参数全部来自 `CFG_TI60F225_OOB_TOP_V_PARAMETER_*` 宏（`defines.v:4344-4364`），实际值：
`DATA_WIDTH=16, ADDR_WIDTH=30, AXI_ID_WIDTH=4, AXI_ADDR_WIDTH=32, AXI_DATA_WIDTH=128`（`defines.v:24-28`），
`ASYN_AXI_CLK=1`（:59）。**AXI_ID_WIDTH=4 是全局硬约束**：DDR3 控制器只认 4 位 ID，后面两层桥的
`DDR_ID_W=4` 与"owner bit 占最高位"的设计正是从这个 4 推出来的。

**58–254 端口声明**：见上表。注意 `(* syn_peri_port = 0 *)` 只加在 JTAG 的 10 根上（60-70），
MIPI DSI 段被 `/* */` 整段注释（192-236），说明这是从 MIPI+HDMI 双屏版本裁剪成 HDMI-only。

**256–292 函数与 localparam**：`log2` 未被使用；11 个 localparam 里只有 `CAM_RAW_GREEN_FIRST`（806）被用。

**297–351 AXI 中间线**：`s_axi_*` 是**最终**汇到 DDR 的唯一一组 AXI（27 根，:303-341）；
`fb_*`（:346-351）是 `style_demo` 的 AXI 主端口，**6 位 ID + 128 位数据**。注释（:343-345）说明
"framebuffer 用 6 位 ID、CPU 用 8 位 ID，共享桥把 frame ID 零扩展并保留 CPU ID 直到 B/R 完成"——
这正是外层桥 `wr_id/rd_id` 存全 8 位、只把低 3 位发给 DDR 的实现依据（见仲裁专题）。

**356–401 复位入口**：`w_arstn = i_pll_locked & pll_locked & user_pll_locked`（376，**三个 locked 直接相与，
无去抖/无同步**，作为全设计异步复位）；`pll_inst1_RSTN/USER_PLL_RSTN/DDR3_PLL_RSTN = i_arstn`（377-379，
注意用的是 `i_arstn` 而非 `w_arstn`）；`inst_reset_ctrl`（380-392）只给 `i_mipi_rx_pclk` 域造复位对
（`IN_RST_ACTIVE=4'b00` 低有效、`OUT_RST_ACTIVE=4'b10` → `o_srst[0]=arstn`、`o_srst[1]=arst`）。
`cnt`（396-401）：26 位自由计数器，`led[0] = cal_done ? cnt[24] : 0` → **校准完成后才闪灯**（约 1.34 Hz @100M）。

**403–514 MIPI RX**：`i_mipi_clk = core_clk`（406）——CSI 控制器的 `clk` 口用 100 MHz，字节时钟用
`i_cam_ck_CLKOUT`（约束 10 ns），像素时钟用 `i_mipi_rx_pclk`（20 ns=50 MHz）。4 个 `cam_d*_RST` 恒 0（408-411）。
AXI 配置口全 tie-off（449-465），`axi_rready=1'b1` 但 `arvalid=0` → 不会真的发起。`mipi_debug_out[15:0]`（:413）
拆成 9 个具名诊断位（505-513）。

**516–586 帧缓冲与复位树（本报告重点）**：
- 521 `o_cam_rst_p = ~w_arstn` → 相机复位跟随 PLL 锁定，**不等 DDR 校准**。
- 527-535 一批 `wire` 声明（capture_*/resize_*/display_*/ch0_*/underflow/capture_reset_n/display_reset_n）。
- 536-539 `hdmi_output_reset`（DLY=3，`hdmi_tx_slow_clk`）→ 只喂 `dvi_encoder.rst_p`。
- 542-548 `ddr_startup` 栅栏（详见「复位与启动时序专题」）。
- **550-551**：`wire vid_rst_n; wire video_reset_n = vid_rst_n && barrier_vid_reset_n;`
- 552-555 三个 `rst_n_piple DLY=3`（capture/display/csi 各域）。
- **556-562** `camera_replay`：源 `{w_mipi_rx_data[39:32],[29:22],[19:12],[9:2]}` —— 从 64 位像素里抽 4 个
  **byte2** 出来拼 RAW8×4（说明相机是 RAW8 打包在 5 字节/4 像素的 CSI 格式）。`s_valid = de & hs`。
- 563-565 `resize_vs=rgb_vs; resize_valid=0; resize_data=0` —— **resize 通路已被硬关闭**（只写了不读，见死线清单）。
- **571** `wire fifo_rd_period;` 声明后无人使用。
- 573-586：SoC 相关线声明 + **I2C 开漏直接连线**：`io_cam_scl_OE = ~soc_i2c_scl_out`（585-586），
  注释（581-582）说明"写 1 释放、写 0 拉低"。顶层**不再经过 `i2c_owner_mux`**（该模块零实例化）。

**587–624 状态统计**：`status_reset_n = barrier_sys_reset_n && capture_reset_n && display_reset_n`（597，**三域组合与**）；
`frame_diagnostics`（599-603）把三个帧事件搬到 core_clk；`status_tick_count`（595）=27 位，
`status_interval_tick = (status_tick_count == 27'd99_999_999)`（604）→ 100 MHz 下正好 1.000 s ✓；
`status_axi_error_event = (soc_axi_error_count != status_axi_error_d)`（605）——寄存器比较，变化后仅 1 拍高 ✓；
`capture_fault/display_underflow` 用 2 位 `ASYNC_REG` 链（613-616）**电平**同步（不是边沿），
配合 `video_status_counters` 里的 `overflow_d/underflow_d` 做边沿检测 ✓。

**626–665 APB 与两个大实例**：
- 629 `style_select=soc_apb_paddr[15:8]==8'h02`；630-632 三根 2 选 1（prdata/pready/pslverr）。
- **633-643 `style_demo`**：`rst_n = status_reset_n && !soc_system_reset`（634）——注意这是**跨 3 域组合**再与 SoC 复位；
  APB 从口：`psel(soc_apb_psel&&style_select)`、`paddr(soc_apb_paddr[7:0])`（637）；
  AXI 主口 fb_*（640-643）。
- **647-657 `soc_video_inst`**：`rst_n=barrier_sys_reset_n`、`allow_access=barrier_allow_sys`（648）；
  视频 AXI 的 ID 零扩展发生在**端口处**：`vid_awid({2'b0,fb_awid})`、`vid_arid({2'b0,fb_arid})`（649,651）；
  返回方向 `vid_bid(soc_vid_bid)` 8 位，再在 665 行截回 `fb_bid = soc_vid_bid[5:0]`。
  `.jtag_*(jtag_inst1_*)`（654）→ USER1 归 CPU；`.uart_*`、`.i2c_*`、`.spi_*` 直连板级；
  `.style_irq(style_irq)`（657）→ SoC `userInterruptA`。
- 658-664 板级输出 assign；665 一整行把 8 个 vid 返回信号映射回 fb_*。

**666–689 视频 APB 从**：666 `video_display_tone/lift[31:0]`、`video_display_hist[2:0]`；
667-671 `video_csi_sticky` 7 位粘滞（在 `i_mipi_rx_pclk` 域用 `csi_reset_n` 复位）；
`osd_apb`（672-686）22 组端口，其中：
`capture_clk=vid_clk_dvi2`、`display_clk=hdmi_tx_slow_clk`、`pclk=core_clk`——**一个模块吃三个时钟**；
`preset_n=status_reset_n && !soc_system_reset`（685，与 style_demo 同源）；
`.display_at_max(1'b0)`（681，常量）、`.i_frame_count(status_display_fps)`（686，**语义已错位**：
frame_count 端口收的是 fps）。

**688** `wire db_vs,db_hs,db_de,db_char_pixel; wire [7:0] db_r,db_g,db_b;` —— 为 `osd_text_double_buffer`
预留的输出线，实际由 914-916 行用 `fp_*` 直通。

**690–789 `u_ddr3_top`**：`axi_clk=core_clk`（693）、`core_clk`、`sdram_clk`、`rx/tx_cal_clk`、`rstn=w_arstn`（699，**不经栅栏**）。
`app_sr/ref/zq_req` 全 tie 0（733-735），`awqos/arqos=4'h0`（749,772）→ **QoS 通道完全没用**（DDR 侧无法靠 QoS 做优先）。
`cal_done`（788）是栅栏唯一输入。

**791–829 debayer**：`RAW_GREEN_FIRST` 由宏 `CFG…INST_DEBAYER_TOP_RAW_GREEN_FIRST` → `CAM_RAW_GREEN_FIRST`（=1'b0，
`defines.v:4415`）决定；**同时 top:806 又定义了一个同名 localparam** `CAM_RAW_GREEN_FIRST`，它遮蔽了全局宏在
模块内的展开。二者当前值相同（都是 0），所以没出错，但**这是靠巧合维持的**：若哪天有人只改宏
`CFG…LOCALPARAM_CAM_RAW_GREEN_FIRST` 而不改局部值，debayer 与 luma 的相位会**反向失配**（一个 BGGR、一个 RGGB）。
`raw_hs_i/raw_de_i/raw_valid_i` 全接 `capture_de`（816-818）——HS 与 DE 同源，等于**丢弃了真实行同步**，
debayer 只靠 DE 计列，若 CSI 送来不完整的行（短包）就会整帧错位一行（`camera_raw_gearbox` 的 `fault` 会报）。
增益：`|r_gain ? r_gain : 255`（820-822）——APB 未配置前 gain=0 → 用 255 而不是 256（Q8.8 里的 1.0 是 256），
**默认偏暗 0.4%**，可忽略但确实是笔误级偏差。

**830–856 输出与延时链**：`hdmi_tx_{r,g,b}data = display_pixel[7:0]/[15:8]/[23:16]`（830-832）→
**像素字节序是 B,G,R**（低字节=B），这与 `style_video_system` 输出的 XBGR 一致。
837-840 `underflow_seen` 粘滞（`display_reset_n` 域）。841-844 led[1]=capture_fault、led[2]=**resize_fault（无驱动源）**、
led[3]=underflow_seen、led[7:4]=resize_completed_frames[3:0]。
**845-855 关键延时链**：27 位 `dly_cnt` 在 `vid_clk_dvi2` 上从 `w_arstn` 起计，`dly_cnt[26]?dly_cnt:dly_cnt+1`
→ 2^26 拍后自锁；`vid_rst_n = dly_cnt[26]` = **452 ms** 后释放。

**860–905 像素链（tone → lift）**：863-871 TX_OE/TX_RST 常量。
**880-887 `tone_adjustment`**：`.i_r(CAM_RAW_GREEN_FIRST ? bdata : rdata)` / `.i_b(... ? rdata : bdata)`（884-885）——
因为 `CAM_RAW_GREEN_FIRST=0`，**实际不发生交换**，是等价直通。若将来把该宏改成 1，R/B 会在这一级被交换，
而 debayer 也会切相位，两处必须同步改。
**891-897 `display_meter`**：`i_rgb={24'd0,lift_b,lift_g,lift_r}`（895）——注意这里**没有**做 R/B 条件交换，
与 tone 级的写法不一致（当宏=1 时两者会一个交换一个不交换）。
**898-900**：`effective_lift_strength = disp_lift[15:8]>128 ? 128 : disp_lift[15:8]`，自动 lift 已按 APB 契约关闭。
**901-905 `lift_adjustment`**：`i_enable=video_display_lift[0]`。

**907–943 OSD tie-off 与 FPS 叠加**：
- **912-913** `osd_vs/hs/de = lift_*`、`osd_r/g/b = lift_*`（保留给已死的 OSD 通路的直通）。
- **914-916**：`assign db_vs=fp_vs, db_hs=fp_hs, db_de=fp_de, db_char_pixel=1'b0;`
  `assign db_r=fp_r, ...; assign osd_db_ack=1'b0, osd_db_active=1'b0, osd_db_busy=1'b0;`
  → **`db_char_pixel` 与 `osd_db_ack` 硬接 0**（Lead 背景属实）。因为 `osd_text_double_buffer` 没实例化，
  这三根 tie-off 实际只影响 `video_apb_ctrl` 的 `i_ack_toggle/i_active_page/i_busy` 输入（都喂 0）——
  后果：`video_apb_ctrl` 里 0x050 的 `bit1 && disp_busy` 校验对 OSD 页永久"不忙"，但 OSD 段本身已被删。
- **914 行 `fp_vs` 在 921 行声明之前就被使用** → 隐式 net + 后续显式声明。Efinity/Verific 容忍（工程能编过），
  严格工具会报"already declared"。属**风格/可移植性**问题，功能无影响（同宽 1 位）。
- 918-943 FPS 叠加：`style_irq` 经 `style_irq_s1/s2` 打两拍（74.25 MHz 域），检上升沿计数；
  **阈值 28'd74_249_999**（932）→ 74.25 M cycles = 1.000 s ✓（注释 929-931 明确解释旧的 148.5M 阈值
  把窗口做成 2 s 导致屏显 FPS 是真实值的 2 倍——这是一个已修复的 bug，值得记录）。
  `fps_cnt<999` 上限防溢出。

**945–996 末级与输出**：948-951 注释+`bar_*` 死声明；**953-960** `out_* = db_*`（OSD 直通），
两个 `assign out_r=db_r` 分两段写（958-960）以保留注释位；
**963-988 `dvi_encoder_m0`**：`video_format=2'b00`(RGB)、`video_VIC=7'd4`（=720p60）、`audio_N=6144`、
`audio_CTS=74250`、`.audio_sample_frequency(audio_samp_freq)` / `.audio_word_length({audio_samp_word_len,audio_max_word_length})`
—— **这三个信号在全工程无声明**（grep 只有 top:981-982 两处引用）→ 隐式 1 位 net，未驱动 → 综合置 0；
`audio_word_length` 是 4 位端口只接了 2 位。因 `audio_valid=0` 功能无影响，但属**隐式 net 缺陷**。
989-992 四路 TMDS 取反输出。994 注释"auto-debug 用 USER2，Sapphire 用 USER1"。

### 风险与疑点（顶层）

| # | 位置 | 问题 | 现象 | 事实/推测 | 置信度 |
|---|---|---|---|---|---|
| T1 | top:855 + 551 | `vid_rst_n=dly_cnt[26]` 把 452 ms 延时串进 `video_reset_n`，整条显示/采集/style 通路都等它 | 上电/复位后 0.45 s 内 HDMI 无同步（`dvi_encoder` 已在 3 拍后出复位，但输入恒 0）；显示器可能不锁或锁后丢 | 事实（代码+算术） | 高 |
| T2 | top:914-916 vs 950-951 | 开机彩条 `hdmi_startup_colorbar/select` 已写好、已 include，但没实例化，只留下 `bar_*` 死线 | 上电没有彩条兜底，正好放大 T1 | 事实 | 高 |
| T3 | top:597 | `status_reset_n` 是 3 个不同时钟域信号的组合与，直接当 core_clk 域异步复位 | 复位释放边沿无同步器，SDC 不覆盖；上电时同域 flop 可能差一拍出复位 | 事实（结构）/ 后果推测 | 中 |
| T4 | top:634,685 | `style_demo` / `video_apb_ctrl` 的 `rst_n/preset_n = status_reset_n && !soc_system_reset`；`soc_system_reset` 来自 SoC（core_clk 域，异步） | 固件一旦触发 system reset，fabric 侧异步复位；`!soc_system_reset` 是电平而非脉冲，若 SoC 抖动则 fabric 被反复复位 | 事实（连线）/ 后果推测 | 中 |
| T5 | top:529,639,676,842 | **`resize_fault` 只有 1 处声明 + 3 处读，无任何驱动**（resize 通路 top:563-565 已废） | 仿真为 x/z；综合后为 0。`led[2]` 恒灭、`capture_fault` 输入恒 0、APB `faults_sync[2]` 永假 | 事实 | 高 |
| T6 | top:981-982 | `audio_samp_freq/audio_samp_word_len/audio_max_word_length` **隐式 net、未驱动**，且 `audio_word_length` 位宽不匹配 | 音频参数恒 0（当前 audio 关闭，无外显） | 事实 | 高 |
| T7 | top:820-822 | 增益 0 兜底用 `255` 而非 `256`（Q8.8 的 1.0） | 未配置时画面偏暗 0.4% | 事实 | 高 |
| T8 | top:806 vs 809 | 局部 `localparam CAM_RAW_GREEN_FIRST` 与全局宏 `CAM_RAW_GREEN_FIRST` 同名，靠值相同维持一致 | 若只改一处，debayer 与 luma 相位反向失配（颜色整体错） | 事实（同名）/ 后果推测 | 中 |
| T9 | top:895 vs 884 | `display_meter` 的 RGB 拼接未做 `CAM_RAW_GREEN_FIRST` 条件交换，与 tone 级写法不一致 | 宏=1 时 AE 均值算在错误的通道上 | 事实 | 中 |
| T10 | top:914/921 | `fp_vs` 先用后声明（隐式 net） | 严格工具报错；Efinity 容忍 | 事实 | 高（影响低） |
| T11 | top:376 | `w_arstn` 由 3 个 locked 纯组合相与，无同步/滤波 | locked 抖动会造成全局异步复位毛刺 | 事实（结构）/ 后果推测 | 低-中 |
| T12 | top:686 | `.i_frame_count(status_display_fps)` 语义错位（端口名 vs 实参） | 该端口在模块内未使用，故无外显 | 事实 | 高 |

### 文档偏差（`reports/ARCHITECTURE_FULL.md`，仅记录不改）

| # | 文档位置 | 文档说法 | 源码事实 |
|---|---|---|---|
| D1 | `:53` | `rtl/ti60f225_oob_top.v (7,581 行)` | **996 行**（887 非空）——差 7.6 倍，疑为把 include 内联展开后总行数误记成顶层行数 |
| D2 | `:234-235` | 时钟表把 `cnn_clk`(148.5 MHz)、`pix_clk`(74.25 MHz) 列为独立时钟 | 它们是 `style_video_system` 的**端口名**，分别接 `vid_clk_dvi2`、`hdmi_tx_slow_clk`（top:634）。真实时钟只有 5 个端口 / SDC 13 条约束（`ti60f225_oob.sdc:6-19,80`），**没有 cnn_clk/pix_clk** |
| D3 | `:277` | APB `0x34` = 常数 148,500,000（cnn_clk 频率） | `video_apb_ctrl.sv:70` 返回 `32'h0001_0000` |
| D4 | `:78` | `video_apb_ctrl` 挂在 `soc_video_ddr_integration` 之下 | 实际在**顶层** top:672 实例化，`soc_video_ddr_integration` 里没有它 |
| D5 | `:6` | 时序 slack +0.046 ns | 与 `outflow/` 报告（0.355 / 1.874 ns）不符（Lead 已核） |
| D6 | `:111-114` | frame_store 6 slot、`0x05000000+slot×0x140000`、结果 `+0x00800000` | **与源码一致** ✓（`style_frame_store.sv:26-27,87`），但 `ddr_address_map.svh` 里的 `0x0400_0000 / 3 帧 / 0x384200` 与二者都不同，且该 .svh 只被**零实例化**的 `ddr_address_map_check.sv` 引用 → 地址映射实际无任何强制校验 |

---

## rtl/soc_integration/*（逐文件章节）

### 1. `ddr_startup_barrier.sv`（30 行）

**职责**：把 `pll_locked` 与 `ddr_cal_done` 两个**异步单比特**分别同步进 `sys_clk`(core_clk) 和 `vid_clk`(hdmi_tx_slow_clk)
两个域，各自观察到"两者都为 1"之后才放出该域的复位与放行。位置：top:543，是 DDR 与所有 AXI 主之间的唯一闸门。

**端口**：`sys_clk, vid_clk, global_reset_n`(in，异步复位) / `pll_locked, ddr_cal_done`(in，异步单比特) /
`sys_reset_n, vid_reset_n, master_allow_sys, master_allow_vid, cpu_waiting`(out)。`SYNC_STAGES=2`。

**实现**：两条各 2 位移位链（:11-24），`always_comb`（:25-29）输出
`sys_reset_n = global_reset_n && sys_pll[1] && sys_cal[1]`，`master_allow_sys = sys_reset_n`（**同一个信号**），
`cpu_waiting = !sys_reset_n`（**无任何消费者**，top 里声明了但没人读）。

**要点/疑点**：
- 复位是 `always_ff @(posedge clk or negedge global_reset_n)` 的**异步复位、同步释放** ✓ 标准做法。
- 但 `sys_reset_n` 是**组合输出**（由 2 位同步链相与），它不是寄存器输出 → 作为下游 1000+ 个 flop 的复位时，
  释放沿理论上对齐到 `sys_pll[1]` 的时钟沿（因为两位都是寄存器输出），可以接受；
  但**综合不会把它当复位树**，Efinity 会按普通组合网布，扇出极大（全 SoC + 全桥）→ **布线/时序风险**（推测，需看实现报告）。
- `master_allow_sys == sys_reset_n` 意味着"放行"与"复位"完全同源，**没有独立的"校准完成后 N 拍再放行"余量**。
  这对"校准后立刻发事务"是安全的（不会提前），但对 DDR 控制器内部状态机是否已准备好收 AXI 命令，
  只依赖 `cal_done` 这一个信号——`cal_done` 到 DDR AXI 口真正可接受命令之间若有延迟，没有任何保护（推测）。
- `barrier_cpu_waiting` 悬空：说明原本设计想把这个信号送给 CPU（比如 stall 总线），现在只做了复位。

### 2. `axi_shared_ddr_2m.sv`（105 行）

**职责**：两主一从的 AXI4 共享 DDR 桥。一个 CPU 主 + 一个视频主（写/读各自独立仲裁），
**写 1 笔、读 1 笔在途**（无 outstanding 队列）。位置：被实例化 **两次**
（内层 `style_video_system.sv:69` `DDR_ID_W=6`；外层 `soc_video_ddr_integration.sv:184` `DDR_ID_W=4`）。

**端口**（共 ~110 根）：`clk,rst_n,allow_access,video_read_urgent`；
`cpu_*`（aw/w/b/ar/r，ID_W=8）；`vid_*`（同构，ID_W=8）；`ddr_*`（ID 只有 DDR_ID_W 位）；`axi_error_count[31:0]`。

**关键常数与位宽（逐个说明为什么是这个数）**：
| 常数 | 值 | 为什么 |
|---|---|---|
| `SRC_ID_W = DDR_ID_W-1`（:40） | 外层 3 / 内层 5 | DDR3 控制器 AXI ID 只有 4 位（`AXI_ID_WIDTH=4`），最高位被借去当 **owner bit**（0=CPU，1=视频），所以源 ID 只剩 3 位 |
| `expected_bid={wr_owner,wr_id[SRC_ID_W-1:0]}`（:56） | – | 与发给 DDR 的 `ddr_awid` 完全同构，用于逐拍校验回声 |
| `write_streak<4'd8`（:48） | 8 | 视频写可连续抢 8 笔后强制让 1 笔给 CPU；8 是经验值，无理论依据 |
| `MAX_VIDEO_BURSTS=3`（:19） | 3 | 内层"显示读连续抢 3 笔后让给 CNN"；等于 display 的 FIFO 深度/延迟容忍度 |
| `video_write_streak` 4 位（:45） | 4 | 饱和在 4'hf，只要 ≥8 即可 |
| `STREAK_W=$clog2(MAX_VIDEO_BURSTS+1)`（:46） | 2 | 计到 3 需要 2 位 → 但 `video_read_streak` 用它，而比较用 `>=MAX_VIDEO_BURSTS`(3)，2 位最大 3 ✓ |

**仲裁逻辑（逐条）**：
```
:48  choose_vid_w = cpu_awvalid&&vid_awvalid ? (video_write_streak<8) : vid_awvalid
:49-52 choose_vid_r = cpu_arvalid&&vid_arvalid ?
        VIDEO_READ_PRIORITY ? 1 :
        DYNAMIC_VIDEO_READ && urgent && (URGENT_OVERRIDES_FAIRNESS || streak<MAX) ? 1 :
        DYNAMIC_VIDEO_READ && streak>=MAX ? 0 : rd_turn
      : vid_arvalid
```
- 只有一方请求时，"谁请求谁走"（`vid_awvalid`/`vid_arvalid` 直通）→ **CPU 独占不受视频影响，反之亦然**。
- 双方都请求时才轮到策略。写侧：视频 8:1 偏置（对视频写有利，对 CPU 写不利）。
- 读侧：**外层**（`DYNAMIC_VIDEO_READ=0`）→ 落到 `rd_turn`，即**纯轮转**；**内层**（=1）→ urgency 机制。
- `:64-65` `awready = allow_access && !wr_busy && awvalid && !choose_vid_w` —— **ready 组合依赖 valid**。
  AXI 允许，但这意味着主机一旦举起 valid，当拍就可能完成握手（无缓冲）。也意味着**桥没有"提前接收地址"的能力**，
  必须等前一笔 B 回来才接下一笔 → 这是带宽上限的直接来源。

**地址/数据 skid**：`wr_addr/wr_len/wr_size/wr_burst/wr_id/wr_owner` 一组寄存器（:42,:84）在 AW 被接收时锁存，
释放条件是 B 完成（:89）→ 注释称之为 "address skid registers"。

**错误检测**：`:58-61` `b_error`/`r_error` 在用 `ddr_bvalid&&ddr_bready`（即握手当拍）比较
`ddr_bresp!=00 || ddr_bid !== expected_bid`，两条线可同时置位（注释 :53-55 说明为什么用 wire 而不是两个非阻塞赋值）。
`:101-102` `axi_error_count <= axi_error_count + b_error + r_error`。

**疑点**：
- **A1**：`video_read_urgent` 在外层实例化时**未连接**（`soc_video_ddr_integration.sv:184-191` 里没有这一项）
  → 隐式 1 位 net、未驱动。当前因 `DYNAMIC_VIDEO_READ=0` 无影响，但它使"把 urgency 接到外层"这件事
  变成一行参数 + 一根线就能做（见给 Lead 的要点）。
- **A2**：`ddr_wvalid` 要等 `wr_aw_sent`（:67），即 **AW 必须先于 W 被接收**。若某主先发 W 后发 AW
  （AXI 允许），桥会死等到 AW 完成；若该主 AW 卡住，**整条写通道永久死锁**（没有超时、没有 abort）。
- **A3**：`bready` 只对被选中的主开放（:71），未被选中的主看到 `bvalid=0`，符合 AXI ✓。
- **A4**：`wr_busy` 与 `rd_busy` 完全独立 → 同一 DDR3 控制器上读写交错进行，**每次切换都要付 tWTR/tRTW 转向代价**。
  这是"有效带宽只有 16%"的结构性原因之一（另一部分是单 outstanding）。
- **A5**：`r_error` 若 DDR 不回声 ID（有些 DDR 控制器 B 通道固定返 0），则每次 CPU 响应都会记一次错。
  需实测 `0x148 (axi_errors32)` 是否恒增来确认（**推测**，DDR3 控制器为厂商加密源码，不可读）。

### 3. `soc_video_ddr_integration.sv`（423 行）

**职责**：Sapphire SoC（VexRiscv + UART/I2C/SPI/JTAG）的封装层：
把生成 IP 的 `io_ddrA_*`（8 位 ID / 128 位数据）接到外层共享桥，把 `io_apbSlave_0_*` 引出成 fabric APB，
把第二个 AXI 主（`axiA_*`）与第二个 DDR 主（`io_ddrMasters_0_*`）**全部 tie 0**（:201-247，注释 :254-255 明说）。

**端口**：见文件 5-14 行；`allow_access/style_irq` 是唯一两个非纯连线的控制信号。

**要点**：
- **:184-191 外层桥实例化，零参数覆盖** → `ID_W=8, DDR_ID_W=4, VIDEO_READ_PRIORITY=0, DYNAMIC_VIDEO_READ=0,
  URGENT_OVERRIDES_FAIRNESS=0, RESERVE_URGENT_READ=0, MAX_VIDEO_BURSTS=3`，且 **`.video_read_urgent` 未连**。
- :194 `io_asyncReset = !rst_n`（= `!barrier_sys_reset_n`）→ **CPU 在 DDR 校准完成前被复位** ✓ 这是"AXI 主不会提前发事务"的第一重保证。
- :198 APB 直连：`io_apbSlave_0_PREADY = apb_pready` → SoC 的 APB 主**确实遵守 pready 握手**，
  所以 fabric 侧可以安全地用 0 等待（两个从都恒 1）。
- :217 `userInterruptA = style_irq` → style 网络的中断进 CPU。
- :248-253 SPI 输出映射；:194 `io_memoryClk = clk`（DDR 控制器在 SoC 侧也用 core_clk）。

**疑点**：
- **S1**：`soc u_soc(...)` 是整个 SoC 的生成网表（`rtl/soc/`），**本报告未逐行**（不属清单）；
  但 `io_systemReset / io_memoryReset` 两个输出直接当 fabric 复位用（top:634,685），其极性与脉冲宽度
  只能靠固件行为推断——**未验证**。
- **S2**：`axiA_awready/arready/wready/bvalid/rvalid/rdata/... = '0`（:201-212）但 `axiA_*` 的**输入方向**
  （awaddr/awlen/awvalid...）是 `wire` 未驱动 → 悬空输入给 SoC。SoC 侧若真的发起 AXI 访问会挂死；
  当前 `axiA_*` 应该是被 IP 关掉的主口，故无影响，但**这是"未使用口没有显式接 0"的一处遗漏**（应为 0 而非悬空）。
- **S3**：`io_ddrMasters_0_*` 全部被 `assign ... = '0`（:218-246），但 `io_ddrMasters_0_r_valid/r_payload_*/b_valid/w_ready/aw_ready/ar_ready`
  是**输入**方向却也是 `wire` 未声明驱动（声明在 :137-177 的 `wire` 列表里，没人赋值）→ 同样是悬空输入。
  由于该 DDR 主口未启用，应无外显，但会触发 lint。

### 4. `video_apb_ctrl.sv`（221 行）

**职责**：VIDEO 区唯一的 APB 从，同时是**跨域配置分发中枢**：
- 128 位 capture 配置（`cap_shadow`）经 `video_cfg_cdc` 在 **`raw_vs`（采集帧边界）** 生效 → `gain_r/g/b`；
- 128 位 display 配置（`disp_shadow`）经第二个 `video_cfg_cdc` 在 **`display_vs` 下降沿** 生效 → `display_tone/lift/hist`；
- 采集域 AE 统计（每帧 y_sum/n/hot）经 `isp_cdc_mailbox(WIDTH=144)` 送到 `pclk` → 0x0C0-0x0E8；
- 一批跨域粘滞/同步：`faults(3b)/csi(7b)/reset_status(5b)` 各 2 级 `ASYNC_REG`；
- **OSD 输出全部 tie 0**（:28-30）——OSD 功能在这个文件里被删干净了。

**端口**：APB 从（`pclk/preset_n/psel/penable/pwrite/paddr[15:0]/pwdata/prdata/pready/pslverr`）+
OSD 输出（tie 0）+ 统计输入（**6 个全部未使用**）+ 三路时钟（`capture_clk/display_clk`，`pclk` 即 core_clk）+
`gain_*`/`display_tone/lift/hist` 输出。

**关键常数**：
| 常数 | 值 | 为什么 |
|---|---|---|
| `CAP_DEFAULT`（:32） | R=0x168(360)/G=0x100(256)/B=0x1a9(425)/LIFT=232/… | Q8.8 增益，1.0=256；R/B 偏大是白平衡预置 |
| `DISP_DEFAULT`（:38） | `tone=0x00202001, lift=0x00002001` | bit0=enable、bit15:8=strength，默认 strength=0x20=32（注释 :33-37 解释为什么是 32：降到 8 会让同道色像素占比 32.5%→70%，画面更"平"） |
| `legacy_hit=paddr<=0x30`（:24） | 0x30 | 旧 OSD 寄存器区整体作废，**写入静默丢弃**（不回错） |
| `filter_valid`（:63） | `0<b9<b10 && u16[103:88]>=256` | 增益上限>下限 且 采样数≥256 才允许应用 |
| `ae` 窗口（:147） | x∈[160,800) pairs、row∈[60,1020) | 1280×960 中心裁剪，2 px/clk → 640×960 = **614,400 de 周期 = 1,228,800 像素**（注释 :144-146 自洽 ✓） |
| `ae_hot` 阈值（:142-143） | ≥232 | 与 display_meter 的 `i_high_threshold=8'd232`（top:895）一致 ✓ |

**时序/握手**：
```
写 0x050 (bit0=1) → pclk: cap_pending<=cap_shadow, cap_req<=~cap_req
                 → (capture_clk) video_cfg_cdc: 2FF 同步 req → 等 raw_vs 边界 → active<=payload, acknowledge<=req_sync
                 → (pclk) cap_ack_sync 2FF → cap_seen 翻转 → cap_mirror<=cap_pending, cap_seq+1
                 → 0x054 的 cap_busy 归 0
```
即"**双缓冲 + 帧边界提交 + ACK 回读**"，最长等一帧（33 ms @30fps）。

**拍级延时（最短路径）**：`pclk` 写 0x050（1 拍锁 pending/翻 req）→ `capture_clk` 2FF 同步（2 拍）
→ 等 `raw_vs` 边界（0 ~ 1 帧）→ `apply_now` 提交（1 拍，同时 `acknowledge` 翻转）
→ 回 `pclk` 2FF（2 拍）→ `cap_seen` 跟上（1 拍）→ `cap_busy` 归 0
= **无帧等待时 7 拍 ≈ 70 ns；有帧等待时 +1 帧（33 ms @30 fps）**。
事件方向（`video_frame_event_cdc`）：源域 toggle（1 拍）→ `sync1`（1）→ `sync2`（1）→ `seen`（1）
= **4 拍后**在目的域出一个 1 拍宽的脉冲。

**疑点**：
- **V1（真 bug，低风险）**：`:179-180` `st_hot<=ae_rx[73:52]; st_n<=ae_rx[52:32];`
  按 `:164` 的打包 `{6'd0, cap_source_seq[31:0], ae_frame[31:0], ae_hot[20:0], ae_n[20:0], ae_y[31:0]}`
  位段应是 `hot=[73:53]`、`n=[52:32]`。现在 `st_hot` 取 22 位截成 21 位 → 实际值 `{hot[19:0], n[20]}`，
  **丢掉 hot 的 MSB、混入 n 的 MSB**。因 hot、n 都远小于 2^20（n=1,228,800 的 bit20=0），当前数值上等价，
  属潜伏 bug（若过曝像素数 >1,048,575 或采样数 ≥2^20 就会读错）。
- **V2**：`:64 assign pready=1'b1;` 与 `:65 pslverr=...value_error` 组合 —— 写入被拒时**当拍**回 PSLVERR，
  而 `:202` 的写入 case 用 `!pslverr` 门控 ✓ 自洽。
- **V3**：`cap_busy` 依赖帧边界。**若相机断流（无 `raw_vs`），请求永不 ACK → `cap_busy` 永久为 1**
  → 之后所有 `0x050 bit0` 写都返回 PSLVERR（注释 `video_cfg_cdc.sv:2` 已声明这一行为）。
  叠加 `fault_sticky[5]`（:200）会记录，固件若把 PSLVERR 当致命错误会反复重试刷屏。
- **V4**：`:52-53` `gain_r=cap_active[15:0]` 等直接来自 CDC 的 `active` 寄存器（采集域），
  而 `gain_r/g/b` 又是 top 里 `debayer` 的增益输入（**采集域使用**）✓ 同域，安全。
  但 `display_tone/lift` 来自 display 域的 `disp_active`，消费者（tone/lift 模块）也在 display 域 ✓ 安全。
  **唯一跨域消费者是 APB 回读（pclk 域读 `disp_active`/`cap_active`）——`:76,:89` 的 prdata 直接用 CDC 输出，
  没有回读同步**（读的是 display/capture 域的寄存器）。这是**读方向的 CDC 漏洞**（值本身是准静态的，
  实际风险低，但严格说应有 2FF 或 toggle 回读）。
- **V5**：`:206` `disp_shadow[31:0]<=pwdata&32'h00ffff01` —— 掩码允许写 bit15:8（strength）与 bit0（enable），
  但掩掉了 bit1..7 与 bit23:16；`:89` 又禁止写 bit1。两个约束叠加后 **0x04C 实际只有 bit0 和 bit15:8 可写**。

### 5. `video_cfg_cdc.sv`（31 行）

**职责**：128 位配置的"捆绑数据 + toggle 请求 + 帧边界提交 + ACK"CDC。
**端口**：`clk,rst_n,vs,request` in；`payload[WIDTH-1:0]` in；`acknowledge, active[WIDTH-1:0], sequence_id[31:0]` out；
`frame_sequence[31:0]` out（组合：`sequence_id + apply_now`）。
**实现**：`req_meta/req_sync` 2FF（:14）；`boundary = FALLING_EDGE ? (vs_d&&!vs) : (!vs_d&&vs)`（:16）；
`apply_now = boundary && req_sync!=acknowledge`（:17）；`apply_now` 时 `active<=payload, sequence_id++, acknowledge<=req_sync`（:26-28）。

**疑点**：
- **C1**：`acknowledge` 只记录"上次应用的 `req_sync` 值"，若请求方在 ACK 回来之前**翻转两次**（req 回到原值），
  `req_sync==acknowledge` 成立 → **该次请求被静默丢弃**。本设计中 `video_apb_ctrl` 用 `cap_busy` 阻止重叠请求 ✓ 规避。
- **C2**：`payload` 是**准静态**的（只在 `req` 翻转的同一拍改变，:208-209），且 ACK 前不再变 → 数据与 toggle 同源 ✓ 安全。
  但模块**自身不校验**这一点，属于"靠调用者守约"的设计。
- **C3**：`FALLING_EDGE=1`（capture 用 `raw_vs` 下降沿）vs `=0`（display 用 `display_vs` 上升沿，:49）。
  两者为什么极性不同？源码无解释。推测：采集侧在 vs 下降沿刚好写完一帧（后沿提交），显示侧在 vs 上升沿
  是帧首（前沿提交）。**未验证**，若搞反会让配置晚一帧生效（不可见，因为配置本来就慢）。
- **C4**：`rst_n` 是**两个域的公共复位**（文件头注释 :2 明说）。`preset_n` 来自 `status_reset_n && !soc_system_reset`
  （core_clk 域组合），异步作用于 capture/display 两个域 → **释放时刻相对于 raw_vs/display_vs 是随机的**，
  若恰好在 vs 边沿附近释放，`vs_d` 的初值可能与真实 vs 相位差半帧 → 第一帧的 `boundary` 误判（一次性，无外显）。

### 6. `video_frame_diagnostics.sv`（52 行，含 2 个 module）

**职责**：把三个"帧完成"事件（原始 CSI vs、resize 完成、显示 vs）从各自源域搬到 core_clk 域。
**`video_frame_event_cdc`**：源域把 event 变 toggle（:10-12），目的域 2FF + `seen` 延迟一拍，
`d_event = sync2 ^ seen`（:16）→ **每事件一个 core_clk 宽脉冲**。约束：事件间隔 > 3 个目的域周期（注释 :2）。
**`video_frame_diagnostics`**：先在每个源域用 `{reset[0],1'b1}` 造出"同步释放的复位"（:31-38），
再用 `vs_d` 取边沿（:39-44），最后三个 `video_frame_event_cdc` 实例（:45-51）。
`resize_event` 的源是 `resize_completed_frames[0] ^ resize_parity_d` —— 即 **32 位二进制计数器的 bit0 当 toggle 用**。

**疑点**：
- **F1**：`resize_completed_frames` 是 `style_demo` 的输出。`style_demo.clk=core_clk`，而这里 `resize_clk=vid_clk_dvi2`
  → **在 148.5 MHz 域采样 core_clk 域计数器的 bit0**。因为 bit0 每帧才翻转一次（慢），且采样后有 2FF，
  实际风险低；但严格说这是"用错了时钟去采另一个域的寄存器"，**若某帧计数器跳变恰在采样沿附近，
  可能漏掉或多出一次事件**（概率 ~1e-9/帧，可忽略，但属不规范）。
- **F2**：`resize_completed_frames[0]` 作为 toggle 要求**每次只 +1**；若 style 侧某次跳 +2（丢帧计数），
  bit0 不变 → **该事件丢失**。丢帧场景下恰好会丢统计，逻辑上自相矛盾（推测，需 style 侧确认）。
- **F3**：`raw_reset/resize_reset/display_reset/core_reset` 四条链（:30-38）的 `[1]` 位既当作 CDC 子模块的 `s_rst_n`，
  又作为 2 位移位寄存器链的一部分 → 复位释放被"人为延迟 2 拍"，但**这 2 拍相对于目的域时钟是同步的** ✓ 正确做法。

### 7. `video_status_counters.sv`（34 行）

**职责**：core_clk 域的 1 s 窗口 FPS + 累计计数。**端口**：`clk,rst_n`、6 个事件输入、`interval_tick`、
5 个 32 位累计输出 + 3 个 16 位 fps 输出。
**实现**：三个 32 位区间计数器（:19-21），三个边沿计数器（:22-25，用 `_d` 寄存器做边沿检测），
`interval_tick` 时把区间值写入 fps 并清零（:26-31），带 `>0xffff` 饱和。

**疑点**：
- **N1**：`:27` `capture_fps <= (cap_interval + (frame_start?1:0) > 32'hffff) ? 16'hffff : cap_interval[15:0] + ...`
  —— 溢出判据比较的是 32 位 `cap_interval+1` 与 `0xffff`，但**赋值只取 `cap_interval[15:0]`**。
  当 `cap_interval` 在 0x10000..0x1FFFF 时，判据（>0xffff）成立 → 输出 0xffff ✓ 正确饱和。
  逻辑正确但写法绕（`cap_interval[15:0]` 实际恒等于 `cap_interval`，因为 fps 不可能过 65535）。
- **N2**：`rst_n` 是 `status_reset_n`（跨 3 域组合），见 T3/T4。
- **N3**：`drop_count` 计的是 `capture_overflow` 的**上升沿**（:22），而 top 送进来的是 `capture_fault_sync[1]`
  （2FF 后的电平）。如果 fault 一直是 1（相机故障持续），只记 1 次 ✓ 符合注释意图。
  但 **`:197` 的 `fault_sticky` 用的是同一类信号的 OR 累积**，两处语义不同（一处计数一处粘滞），易混淆。

### 8. `osd_apb_regs.sv`（75 行）—— **零实例化，死代码**

**职责**：OSD 字符叠加的 APB3 寄存器组（偏移 0x00-0x30），双页字符 RAM 的写侧控制。
**端口**：APB 从 + OSD 控制输出（enable/x/y/color/char_we/addr/page/data/commit）+ 状态输入（ack/active/busy/帧数/fps/丢帧/错帧）。
**要点**：`pready=1`、`pslverr=access&&(!legal||read_only_write)`（:36）；写 0x01C（commit）要求
`!busy_sync2 && char_page_reg!=active_sync2`（:68）才翻 toggle；复位值 `o_enable=1,o_x=16,o_y=16,o_color=0x20ff40`（:56）。
**死代码证据**：全库 grep 只有 module 定义（`osd_apb_regs.sv:4`），无实例。
**但它仍是"活文档"**：`main.c:115` 与 `style_driver.c:114` 用的 0x20/0x24 映射正是这个文件的映射 → **固件没跟上 RTL 的删除**。

### 9. `osd_text_double_buffer.sv`（80 行）—— **零实例化，死代码**

**职责**：256×8 双页字符 RAM（`page_mem`，页址 = `{page,addr}`）+ 8×16 字形 ROM + 三级流水对齐，
在显示域做字符叠加，输出 `o_char_pixel`（叠加掩码）。
**要点**：3 拍延迟链（`*1`→`*2`→`o_*`，:61-67）；`in_text` 窗口 = `active_x + 8*PAGE_SIZE` × 16 行（:33）；
`active_ch<page_mem[{active_page,char_idx}]`（:41，同步读 → 1 拍）；`osd_font8x16` 再 1 拍 → 共 3 拍 ✓；
`ack_toggle<=cmt2`（:72）在 vs 边界提交页切换；`busy = busy_wr2`（:50）经 `busy_pix→2FF→wr` 回写侧。
**疑点（死代码也记录）**：
- **O1**：`:27` `page_mem[{wr_page,wr_addr}]<=wr_data` 只在 `wr_page!=active_wr2` 时写 → **写的是非活动页** ✓ 双缓冲正确。
- **O2**：`:41` `active_page` 由 pix_clk 域驱动、被 `page_mem` 读地址使用（pix 域读）✓ 同域；
  但 `page_mem` 的**写入在 wr_clk 域**（:26-27），而 `page_mem` 是**单端口推断**的数组 —— 写口 wr_clk、读口 pix_clk
  → 这是**真双端口 RAM 的跨域访问**，综合工具会推成双口 RAM ✓；但**写侧没有地址 CDC 保护**
  （`{wr_page,wr_addr}` 来自 wr 域，读侧用 `{active_page,char_idx}` 来自 pix 域，两者互斥由双页保证）✓ 设计正确。
- **O3**：`initial` 块里塞了 "HELLO SOC" 默认字符（:18-19）—— 依赖 FPGA 的 RAM 初值加载（工作但不可综合为 ASIC）。

### 10. `osd_fixed_text.sv`（52 行）—— **零实例化，死代码**

**职责**：固定 9 字符（"HELLO SOC"）文本合成器，坐标只在 `i_de` 时前移、vs 后清零。
**要点**：两段流水（`x,y` → `sx,sy` → `o_*`），与字形 ROM 的 1 拍对齐（:38-43）；`text_char` 函数（:17-23）内联字符表；
叠加色固定 `FG_RGB=24'h20ff40`。
**疑点**：`glyph_col=(sx-BASE_X)&7`（:29）在 `s_in_text=0` 时仍计算（无影响）；`s_bit` 用 `s_enable&&s_de&&s_in_text` ✓ 门控完整。

### 11. `osd_font8x16.sv`（1535 行）—— **接口与寻址（抽样字形）**

**接口**：`module osd_font8x16(input logic clk, input logic [7:0] ch, input logic [3:0] row, output logic [7:0] bits);`
**存储**：`logic [7:0] rom [0:2047]`（2048×8 = **16 Kbit = 2 KB**）。
**寻址**：`rom[{safe_ch,row}]`（:1534），`safe_ch = printable ? ch[6:0] : 7'h20`（:1528-1533）
→ 地址 = `ch×16 + row`，`ch∈[0x20,0x7E]` 映射到 `[0x200,0x7EF]` ✓（首条非零 `rom[12'h200]` 正是空格行，:6-21）。
**抽样验证**：`'!'`=0x21 → `rom[0x210..0x21f]`：全 0 后 7 行 `8'h18`（竖点）+ 空行 + `8'h18,8'h18` ✓ 是感叹号；
`'"'`=0x22 → 4 行 `8'h3c` ✓；`'#'`=0x23 → `0x36,0x34,0x24,0x7f,0x24,0x24,0x7f,...` ✓ 是井号。
**疑点**：
- **G1**：`printable` 用 `ch>=0x20 && ch<=0x7e`，但 `safe_ch` 只有 7 位且取 `ch[6:0]`；对 `ch≥0x80` 走 0x20 ✓ 安全。
- **G2**：`initial` 块 1535 行是综合期 ROM 初始化（依赖 BRAM 初值加载）。若该模块被实例化，会吃掉 **2 KB RAM**；
  文档 `ARCHITECTURE_FULL.md:6` 报 RAM 244/256（95%），OSD 死掉后这部分应已释放（**而仍留着源码是维护负担**）。
- **G3**：`bits` 是 `always_ff`（同步读）→ 调用方必须多算 1 拍；`osd_text_double_buffer.sv:42` 与
  `osd_fixed_text.sv:32` 都按"ROM 1 拍"设计 ✓。

### 12. `hdmi_startup_colorbar.sv`（84 行，2 个 module）—— **零实例化，死代码（但有现实价值）**

**`hdmi_startup_colorbar`**：1280×720 彩条的纯计数器发生器。`HTOTAL=40+220+1280+110=1650`、`VTOTAL=5+20+720+5=750`
（:12-13）→ 74.25 MHz 下 `1650×750×13.468 ns` = **16.66 ms = 60 Hz** ✓ 与 dvi_encoder 的 VIC=4 匹配。
HS/VS **正极性**（`hs<=(x<HSP)`，:22）与注释 :2 一致。8 条竖彩条按 `HACT/8` 切分（:26-33）。
**`hdmi_startup_select`**：4 态 FSM（BARS/WAIT_CAMERA/CAMERA/WAIT_BARS，:51）在**帧边界**切换源，
`ready_async` 2FF 同步（:52），`cam_seen` 需连续检测到相机 vs 才允许切（:64-65）；切走时输出消隐（:80-83）。
**价值**：这正是解决 T1/T2（上电 452 ms 无同步）缺口的现成模块——**代码在、include 在、`bar_*` 线在，只是没连**。

### 13. `ddr_address_map.svh`（14 行）+ `ddr_address_map_check.sv`（29 行）—— **check 零实例化**

**`.svh`**：`SOC_CPU_DDR_BASE=0x0100_0000 / LEN=0x0010_0000`（1 MB scratch）、
`SOC_VIDEO_DDR_BASE=0x0400_0000`、`SOC_VIDEO_FRAME_BYTES=0x0038_4200`（payload 0x384000 + 0x200 guard）、
`FRAME_COUNT=3`、`SOC_DDR_AXI_DATA_BYTES=16`。
**`_check.sv`**：`valid` 组合校验（CPU 窗口与视频窗不重叠、16 B 对齐、帧序严格递增）+ `SYNTHESIS` 之外的
`initial $fatal` 三条（:22-28）。
**疑点（重要）**：
- **M1**：**实际 DDR 布局与这张表完全不同**：`style_frame_store.sv:26-27` 用 `0x0500_0000 + slot×0x140000`（6 slot），
  结果区 `+0x0080_0000`（:87），最高到 `0x06E4_0000`。而 `.svh` 说视频区从 `0x0400_0000` 开始、只有 3 帧、
  每帧 3.6 MB。**两套布局并存，`.svh` 是旧 1280×720 三缓冲时代的遗留**。
- **M2**：`ddr_address_map_check` **零实例化** → 那些 `$fatal` 断言**从未被展开**，
  `valid` 也没有任何消费者 → 地址映射在工程里**没有任何强制校验**。文档 `ARCHITECTURE_FULL.md:112-113`
  引用的地址（0x05000000/0x05800000）与 `frame_store` 一致、与 `.svh` 不一致 → **`.svh` 应视为过时文档**。
- **M3**：`SOC_VIDEO_DDR_END` 与 `video_end` 计算的 `FRAME_BYTES*FRAME_COUNT` 在宏展开时是 32 位无符号，
  `0x384200*3 = 0xA8C600`，加 `0x04000000` 不溢出 ✓。

### 14. `i2c_owner_mux.sv`（27 行）+ `soc_jtag_channel_mux.sv`（34 行）—— **均零实例化，死代码**

**`i2c_owner_mux`**：CPU/legacy 两个 I2C 主的开漏选择器（`:18 scl_oe=~cpu_scl_write`）。
**顶层已改为直接硬连**（top:583-586），不再经过它 → 但**功能等价**（`i2c_owner_mux` 的 cpu_owner=1 分支与 top:585-586 完全一样）。
**`soc_jtag_channel_mux`**：硬 JTAG 在 SoC 与 v7 EDB 之间二选一（`tdo_o`、`conflict`）。
顶层**未使用**，直接接 `jtag_inst1_*`（top:654），并在 top:994 注释"auto-debug 用 USER2、Sapphire 用 USER1"
→ 说明 USER1/USER2 **物理上已经分开**，这个 mux 的存在前提（"一条物理通道二选一"）已不成立 → 死代码。
**疑点**：`conflict` 输出无人用，若将来复用该 mux 必须接上（注释 :3 称"两者同时 enable 是集成错误"，
但现在没有任何机制检测）。

---

## 复位与启动时序专题

### 复位树（事实）

```
w_arstn = i_pll_locked & pll_locked & user_pll_locked        (top:376)
│
├─► inst_reset_ctrl @i_mipi_rx_pclk ──► w_mipi_rx_pclk_arstn/arst  (top:387)
│
├─► hdmi_output_reset  rst_n_piple DLY=3 @74.25M ──► hdmi_output_reset_n ──► dvi_encoder.rst_p  (top:538)
│        （只等 3 拍，不等 DDR 校准！）
│
├─► ddr_startup_barrier (ddr_startup, top:543)
│     sys = core_clk(100M)   : sys_pll[1], sys_cal[1]  ← pll_locked, cal_done
│     vid = 74.25M           : vid_pll[1], vid_cal[1]
│     sys_reset_n   = w_arstn & sys_pll[1] & sys_cal[1]   ──► barrier_sys_reset_n
│     vid_reset_n   = w_arstn & vid_pll[1] & vid_cal[1]   ──► barrier_vid_reset_n
│     master_allow_sys = sys_reset_n (= 同一信号)
│
├─► dly_cnt[26] @vid_clk_dvi2(148.5M) ──► vid_rst_n = dly_cnt[26]   (top:845-855)
│        2^26 × 6.734 ns = 451.9 ms  → 把 452 ms 上电延时串进 video_reset_n
│
├─► video_reset_n = vid_rst_n & barrier_vid_reset_n                 (top:551)
│     ├─► capture_reset  DLY=3 @148.5M ──► capture_reset_n  (debayer/camera_replay/style cnn)
│     ├─► display_reset  DLY=3 @74.25M ──► display_reset_n  (tone/lift/meter/fps_overlay/style pix)
│     └─► csi_reset      DLY=3 @50M    ──► csi_reset_n      (camera_replay 源侧)
│
├─► status_reset_n = barrier_sys_reset_n & capture_reset_n & display_reset_n   (top:597)  ★三域组合
│     └─► status_counters / frame_diagnostics / style_demo(core+cnn+pix) / video_apb_ctrl.preset_n
│
├─► soc_video_inst.rst_n = barrier_sys_reset_n ; allow_access = barrier_allow_sys   (top:648)
│     └─► io_asyncReset = !barrier_sys_reset_n  → CPU 也在校准后才出复位  (sv:194)
│
├─► u_ddr3_top.rstn = w_arstn    （DDR 控制器自己先跑，不等任何东西）  (top:699)
│
└─► style_demo.rst_n = status_reset_n & !soc_system_reset          (top:634)
    video_apb_ctrl.preset_n = status_reset_n & !soc_system_reset   (top:685)
```

### 上电时序图（文字版）

```
t (ms)      0        3拍(≈40ns)                         ≈452                ≈452+3拍
            │            │                                 │                    │
w_arstn     ─┐___________________________________________
             │(PLL 锁定)
dvi_encoder   ╲__出复位(3拍)─────────────────────────────────────────────────────
              （但输入 out_vs/out_de 恒 0，TMDS 无有效视频）
DDR3 ctrl    ╲__开始校准────────────cal_done──────────────────────
                                        │
barrier_sys_reset_n                     └─(2拍后)放行──────────────────► CPU/桥/style 开始工作
barrier_vid_reset_n                     └─(2拍后)放行──┐
dly_cnt[26] (=vid_rst_n)                               └────────452ms────────┐
video_reset_n                                                                └─放行
capture/display_reset_n                                                          └─(3拍后)放行
style_demo / 像素流水线                                                          └─开始出像素
                                                                    → 第一批有效 vs/de 到来
```

**关键推论**：
1. **AXI 主不可能在校准前发事务** —— 三重保证：①CPU 的 `io_asyncReset` 就是 `barrier_sys_reset_n`；
   ②外层桥 `rst_n` 是同一个；③`allow_access` 与 `rst_n` 同源，`awready/arready` 再门控一次。
   任务书里"嵌套复位是否可能让 AXI 主机提前发事务"的答案是：**不会**。
2. **但"校准完成 → 显示出图"之间多了 452 ms + 3 拍**。这段时间 HDMI 是"无同步"状态，不是黑屏也不是彩条。
3. **`master_allow_vid` 无消费者**：`barrier_allow_vid` 在 top 中没有任何实例接收（只有 `barrier_allow_sys` 被用）。
   也就是说 vid 域的"放行"只有 `barrier_vid_reset_n` 一条路径在起作用——语义上够用，但说明设计意图没落地。

### 复位释放的隐患（结构事实 + 后果推测）

| 隐患 | 位置 | 结构事实 | 推测后果 |
|---|---|---|---|
| R1 | top:597 → 606/617/634/685 | `status_reset_n` 是 3 个**不同时钟域**信号（100M 组合、148.5M 寄存器、74.25M 寄存器）的组合与，作为 core_clk 域异步复位 | 释放沿可能落在 core_clk 采样窗口 → 同域不同 flop 差 1 拍出复位；FSM 初态可能非法（一次性、上电概率） |
| R2 | top:634 + `style_video_system.sv:35,46,56` | `style_demo` 三个时钟域**共用同一根 rst_n**，内部 `style_async_fifo` 的读写两侧也共用 | 异步 FIFO 两侧指针复位释放不同步 → 指针错位（若发生则永不恢复，表现为持续欠载/花屏）。这是"偶尔闪烁"的候选之一，**但概率与是否真实发生未验证** |
| R3 | top:685 + `video_cfg_cdc.sv:2` | `preset_n` 同源异步作用于 capture_clk 与 display_clk 两侧 | `vs_d` 初相位随机 → 第一帧 `boundary` 误判（一次性，无外显） |
| R4 | `ddr_startup_barrier.sv:26-28` | `sys_reset_n` 是**组合输出**（大扇出：全 SoC + 全桥 + style） | 组合复位网扇出上千，布线可能成为关键路径；且不受复位树约束（推测，需看 impl 报告） |
| R5 | top:376 | `w_arstn` 三 locked 纯组合相与 | locked 抖动 → 全局异步复位毛刺（FPGA 上 locked 一般稳定，风险低） |

---

## 仲裁与带宽专题

### 拓扑（三层主、两级桥、单 outstanding）

```
[CNN 加速器]──(awid=0x03,arid=0x03)─┐
[显示写 frame_store](awid=0x01)─────┤ 内层 axi_shared_ddr_2m (DDR_ID_W=6)
[显示读 style_axi_rows](arid=0x02)──┘   VIDEO_READ_PRIORITY=0
                                        DYNAMIC_VIDEO_READ=1     ← ADAPTIVE_READ=1 默认
                                        URGENT_OVERRIDES_FAIRNESS=0
                                        RESERVE_URGENT_READ=0
                                        MAX_VIDEO_BURSTS=3
                                        写 1 笔 / 读 1 笔在途
                                          │  ddr_* 6 位 ID = {owner, src_id[4:0]}
                                          ▼
                              ╔═══════════════════════════════════════╗
                              ║  顶层 fb_awid/fb_arid (top:649,651)    ║
                              ║  vid_awid = {2'b0, fb_awid}  (零扩展)  ║
                              ╚═══════════════════════════════════════╝
                                          │
[Sapphire CPU](awid=3,arid=3)─────────────┤ 外层 axi_shared_ddr_2m (DDR_ID_W=4, 全默认参数)
                                           VIDEO_READ_PRIORITY=0
                                           DYNAMIC_VIDEO_READ=0    ← 无 urgency！
                                           video_read_urgent 未连接
                                           URGENT_OVERRIDES_FAIRNESS=0
                                           RESERVE_URGENT_READ=0
                                           写 1 笔 / 读 1 笔在途
                                             │ ddr_* 4 位 ID = {owner, src_id[2:0]}
                                             ▼
                                    [ddr3_top]  4 位 ID / 128 位 / 400 MHz / 16 位 DQ
```

### ID 映射全链路（含"为什么截位是安全的"）

| 层 | 主 | 发出 ID | 桥内保存 | 送 DDR 的 ID | 返回路径 |
|---|---|---|---|---|---|
| 内层 | CNN | `8'h03` | `wr_id/rd_id` 全 8 位 | `{owner=0, id[4:0]=5'b00011}` = 6'h03 | `ddr_bid` 校验后，`cpu_bid=wr_id`（全 8 位）→ CNN 拿到 0x03 |
| 内层 | 显示写 | `8'h01` | 同上 | `{1, 5'b00001}` = 6'h21 | `vid_bid=wr_id`=0x01 |
| 内层 | 显示读 | `8'h02` | 同上 | `{1, 5'b00010}` = 6'h22 | `vid_rid=rd_id`=0x02 |
| 顶层 | 视频（=内层 DDR 口） | `{2'b0, 6'hXX}` | 全 8 位 | `{owner, id[2:0]}` **只取低 3 位** | `vid_bid=wr_id` 全 8 位 → top:665 截 `[5:0]` → **正好还原内层的 6 位 ID** |

**关键结论**：外层桥把 6 位视频 ID **压缩到 3 位**送 DDR，但**返回给主设备的 ID 取自桥内寄存器而不是 DDR**，
所以"压缩"不损失信息。**前提是 DDR 控制器真的回声 `awid/arid`**（用于 `b_error/r_error` 校验）。
若 DDR 不回声，则 `axi_error_count`（APB 0x148 / STYLE 0x50）会持续增长——**这是一个可直接在板子上验证的判据**。

### 一笔视频读突发的拍级时序（文字版时序图）

以"显示读 512 B（32 拍）"为例，`core_clk` 100 MHz，两层桥都空闲：

```
拍  内层桥                          外层桥                          DDR3
0   看到 v_arvalid → 内层 arready=1（组合，同拍握手）
     锁 rd_id/rd_addr/rd_len → rd_busy=1, rd_turn<=~0
1   内层 ddr_arvalid ← rd_busy&&!rd_ar_sent
     （= 顶层的 fb_arvalid）          ← 外层看到 vid_arvalid
2                                    choose_vid_r: 若 cpu_arvalid 同时为 1 且 rd_turn=CPU
                                     → 外层 vid_arready=0，**这笔要等**（轮转，无 urgency）
                                     （无冲突时：外层 arready=1，锁 rd_owner=1, rd_id）
3                                    外层 ddr_arvalid=1 → 等 ddr_arready
4..N                                 DDR 接受 → rd_ar_sent=1 → 发读命令、CAS 延迟
N+1..                                ddr_rvalid 连发 32 拍（每拍 1 个 128 bit）
                                     ddr_rready=1（外层 rd_owner=1 → 用 vid_rready=1）
                                     vid_rvalid=ddr_rvalid → 内层逐拍转发到 style_display
N+32 ddr_rlast → 外层 rd_busy=0        → 内层 rlast → 内层 rd_busy=0
```

**"几拍"总结**：
- 内层授权 → 内层发起：**1 拍**（`ddr_arvalid` 需要 `rd_busy` 已置位）。
- 外层授权：**0 拍**（同拍组合握手），但**若 `rd_turn` 指向 CPU，则至少再加一整个 CPU 读事务**
  （512 B 读 = 32 拍数据 + DDR 延迟 + B/R 返回）→ 这就是"欠载"的量级来源。
- 数据传输：32 拍（无气泡时）。
- **一笔事务与下一笔之间必须有 1 拍 `rd_busy=0` 的空档**（内层、外层各一次）→ 单 outstanding 的固有开销。
- `wr_busy` 一侧同理，且写还必须 `wr_aw_sent` 后才会放 `wvalid`（`axi_shared_ddr_2m.sv:67`）→ AW 与 W 不能重叠。

### 带宽账（可核算的部分）

- **DDR 理论峰值**：`sdram_clk=400 MHz` × DDR(2) × 16 bit(DQ) = **1.6 GB/s** ✓ 与观测口径一致。
- **AXI 侧上限**：`core_clk=100 MHz` × 128 bit = **1.6 GB/s** —— 两侧恰好相等，说明**AXI 侧完全没有余量**：
  只要 DDR 侧利用率超过 ~100%，AXI 侧就先饱和。任何仲裁空隙都直接等于带宽损失。**这是设计上的紧耦合**。
- **单笔突发大小（事实）**：`style_frame_store.sv:47 awlen=31` → **32 拍 × 16 B = 512 B**；
  `style_axi_rows.sv` 显示读 `arlen=min(needed,32)`、且不跨 4 KiB → 同样 ≤512 B。
- **单笔突发时间**：512 B / 1.6 GB/s = **320 ns**（= 32 个 core_clk 周期）。
- **单 outstanding 的利用率上限**：
  `η = 320 / (320 + T_lat + T_arb)`。若 DDR 读延迟 `T_lat≈100-150 ns`（tRCD+CL+往返，400 MHz 下典型），
  两级桥握手 + 仲裁再加 10-30 ns → `η ≈ 320/450 ≈ 71%`。
- **实测 0.26 GB/s = 1.6 GB/s 的 16%** → **远低于单 outstanding 的结构上限**。
  说明瓶颈**不只是**仲裁/延迟，还有**请求不连续**（上游 CNN/显示的行 DMA 之间有计算间隙）。
  换算：0.26 GB/s ÷ 17.5 fps ≈ **14.9 MB/帧** 的 DDR 流量；若按 1.6 GB/s 搬运只需 9.3 ms（≈107 fps）。
  → **结论：当前是"事务发射率/需求间隙"限制，不是 DDR 峰值带宽限制**（此段为**推算**，假设 T_lat 与流量分布，
  需用 `0x148/0x144/0x14C` 与板上实测交叉验证）。

### 显示欠载的可定位机制（按优先级）

1. **外层桥不认 urgency（最高优先级，且改动最小）**
   内层为显示读准备了 `display_read_urgent`（`style_video_system.sv:55`），但跨过外层桥时：
   `video_read_urgent` **没接**、`DYNAMIC_VIDEO_READ=0`、`VIDEO_READ_PRIORITY=0`。
   于是"显示这一笔读很急"这个信息在外层**完全丢失**，只剩 `rd_turn` 与 CPU 均分。
   → 显示 DMA 的一次行请求，最坏要等 CPU 一整笔（≤512 B，320 ns）+ 完整 R 返回，再叠加 DDR 内部排队。
   若 `style_display` 的行前视缓冲 < 这个最坏延迟，就欠载。**这是"偶尔闪烁"最合理的解释**（推测，但机制链完整）。
2. **单 outstanding + 两级仲裁的串联延迟**
   同一笔显示读要经过：内层授权 → 外层授权 → DDR 排队 → R 返回 → 内层再分发。每一跳都要等前一笔完全结束。
3. **读写通道并发导致的转向惩罚**
   `wr_busy`/`rd_busy` 独立（`axi_shared_ddr_2m.sv:41,43`）→ 写突发与读突发可在 DDR 上交错，
   每次读写切换付 tWTR/tRTW。视频写是连续的（每帧 640×480×4 B + 12 层中间结果），读是间歇的，
   交错频率高 → 白付转向时间。
4. **写侧 8:1 偏置对 CPU 不利（不是欠载主因，但会拖慢固件）**
   `video_write_streak<8`（:48）→ CPU 写最多等 8 笔视频写。固件若在轮询 DDR scratch，吞吐会被压在 1/9。

### 给硬件侧的"一行级"假设验证清单（不改码，只用来定位）

| 假设 | 验证方法 | 预期 |
|---|---|---|
| H1：外层无 urgency 是欠载主因 | 把 `soc_video_ddr_integration.sv:184` 加两个参数 + 一根线（`video_read_urgent` 从 `style_video_system` 引出） | 欠载计数（0x14C / STYLE 0x4C）显著下降 |
| H2：DDR 不回声 ID 导致 `axi_error_count` 恒增 | 读 APB `0x148`（VIDEO）与 STYLE `0x50`，静置 10 s 看是否增长 | 若增长 → 修 `expected_bid` 校验或改 DDR 配置 |
| H3：452 ms 无同步导致显示器不锁 | 示波器/逻辑分析仪看 `tmds_tx_clk_TX_DATA` 上电前 500 ms；或临时实例化 `hdmi_startup_colorbar` | 上电即有彩条 → 锁屏稳定 |
| H4：`style_async_fifo` 复位错位 | 上电后立即读 STYLE `0x3C(dropped)`/`0x4C(dma_errors)`；软复位（`soc_system_reset`）后是否变化 | 若软复位后变好 → 指向 R2 |
| H5：请求不连续（计算间隙）是 17.5 fps 的主因 | 用 STYLE `0x40(inferred)` 的 1 s 增量 vs `0x50(bridge_errors)`；对比 CNN 实测 cycles（`style_accel` 有 `last_cycles` 口） | 若 cycles 已占满帧周期 → 与 DDR 无关 |

---

## 给 Lead 的 5 条要点

1. **顶层行数 996 已复核（887 非空），文档 7,581 是错的**（差 7.6 倍，疑为 include 展开后的总行数）。
   同时纠正 Lead 背景里一处：`osd_apb_regs` / `osd_text_double_buffer` **并没有在 672 行附近被实例化**，
   672 行是 `video_apb_ctrl osd_apb`，而那两个模块**全工程零实例化**（连同 `osd_fixed_text`、
   `hdmi_startup_colorbar/select`、`hdmi_info_overlay`、`hdmi_frame_histogram`、`capture_frame_stats`、
   `osd_font8x16` 共 8 个文件是死代码，只占编译时间不占资源）。

2. **"三主 AXI"实际是"两层桥串联 + 每层单 outstanding"。** 内层 `DDR_ID_W=6`（CNN/显示写/显示读 → 6 位 ID），
   外层 `DDR_ID_W=4`（该视频口 + CPU → 4 位 ID）。**外层桥实例化时零参数覆盖、`video_read_urgent` 未连接**
   （`soc_video_ddr_integration.sv:184-191`）→ 内层那套 `MAX_VIDEO_BURSTS=3` 的显示 urgency 机制
   **在跨过外层桥时被降级为纯 `rd_turn` 轮转**。这是"显示偶尔欠载"最可定位的机制链（事实级证据 + 推测级因果）。
   最小验证改动：外层接上 `video_read_urgent` 并置 `DYNAMIC_VIDEO_READ=1`（1 根线 + 2 个参数）。

3. **AXI 主机不可能在校准前发事务**（三重同源保证，任务书的疑问可以排除）；
   但**上电后 452 ms 内 HDMI 完全没有同步信号**：`vid_rst_n=dly_cnt[26]`（148.5 MHz 下 2^26 拍 = 451.9 ms）
   串在 `video_reset_n` 里，而 `dvi_encoder` 只等 3 拍就出复位。**解决方案的代码已经写好在仓库里**
   （`hdmi_startup_colorbar.sv` + `hdmi_startup_select`，含帧边界切换 FSM），include 和 `bar_*` 线都还在
   （top:27, 950-951），只是实例被删了。这能解释"上电/复位后显示闪或不锁"。

4. **两个真实小 bug（高置信，影响小）：**
   ① `resize_fault`（top:529 声明，639/676/842 读取）**没有任何驱动源** → 浮空，仿真 x、综合 0，
   导致 `led[2]` 恒灭、`capture_fault` 恒假、APB `fault_sticky` 对应位永假。
   ② `video_apb_ctrl.sv:179-180` AE 解包位段错位：`st_hot<=ae_rx[73:52]` 应为 `[73:53]`
   （当前等于 `{hot[19:0], n[20]}`），`st_n` 正确；因数值远小于 2^20 目前无害，属潜伏。
   另有 `audio_samp_freq/audio_samp_word_len/audio_max_word_length` 三个**隐式 net 未驱动**（top:981-982）。

5. **固件与 RTL 的 APB 映射已经脱节（可直接解释固件侧"永远读到 0"）：**
   `main.c:115` 读 `0xf8100020` 期待 OSD busy（bit2）→ 该地址落在 `legacy_hit`（`paddr<=0x30`），**恒返 0**，
   于是 `app_osd_errors` 每秒 +1；`style_driver.c:114` 读 `0xf8100024>>16` 当 display_fps → 同样恒 0
   （真正的 `i_display_fps` 端口在 `video_apb_ctrl` 里**根本没被映射到任何地址**，6 个统计输入端口全是悬空）。
   排查固件问题时**不要相信这两个读数**；真正的 fps 只能从 `0x0E0/0x150 raw_frames` 与板上计时反推。
   顺带：`ddr_address_map.svh`（0x0400_0000/3 帧）与实际 `style_frame_store`（0x0500_0000/6 slot）完全不符，
   且唯一的校验模块 `ddr_address_map_check` 零实例化 → **地址映射在工程里没有任何强制约束**。
