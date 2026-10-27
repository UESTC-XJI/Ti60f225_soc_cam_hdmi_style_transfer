# 交叉模块核对（Lead）

> 日期：2026-10-26
> 分支：`feature/colour-calib-redsky-q` @ `5dfaf5a` + 6 个未提交改动
> 本文只写**一个模块自己看不出来、必须跨模块对账才能发现**的问题。
> 逐模块的逐行阅读见同目录 `01`~`06`。

---

## 〇、阅读范围与预算

| 项 | 数值 |
|---|---|
| 工程 XML 内 design_file | 84 |
| 额外靠 `` `include `` 进入编译单元 | 13 |
| **编译单元合计** | **97 个文件 / 81,882 行** |
| 定义的 module 总数 | 177（**无同名重复定义**，已全量校验） |
| 未实例化的同级 module | 2（`EFX_DSP48`/`EFX_GBUFCE` 是 Efinity 原语，正常） |

分工（写作用域互斥，每人只写自己那一份）：

| 任务 | 负责人 | 文件 | 报告 |
|---|---|---|---|
| task-1 | rowpipe-layer | rowpipe_layer / conv3x3_core / requant | `01_rowpipe_layer.md` |
| task-2 | rowpipe-datapath | engine / ddr_banks / frame_driver / network / fps_overlay | `02_rowpipe_datapath.md` |
| task-3 | style-system | rtl/style 全部 14 个综合文件 | `03_style_system.md` |
| task-4 | top-soc | top.v + rtl/soc_integration 17 个 | `04_top_soc.md` |
| task-5 | video-frontend | debayer / CSI / gearbox / ISP | `05_video_frontend.md` |
| task-6 | firmware-reader | software/firmware | `06_firmware.md` |

---

## 一、编译单元是怎么攒起来的

`ti60f225_cam_hdmi.xml`（84 项）+ 顶层 15 条 `` `include `` 展开后得到 97 个文件。include 树的形态：

```
rtl/ti60f225_oob_top.v
├── rtl/defines.v                       (4,621 行宏，所有 CFG_* 参数的唯一来源)
├── rtl/ddr3_controller/ddr3_parameter.vh
├── rtl/isp/isp_cdc_mailbox.v           ┐
├── rtl/isp/ae_frame_stats.v            │
├── rtl/isp/luma_color_suppress.v       │
├── rtl/isp/luma_tone_map.v             ├ rtl/isp 整目录都不在 XML 里，
│   └── rtl/isp/lift_tables.vh           │ 靠 include 进入编译单元
├── rtl/isp/hdmi_frame_histogram.v      │
├── rtl/isp/hdmi_info_overlay.v         │
├── rtl/isp/capture_frame_stats.sv      ┘
├── rtl/soc_integration/osd_font8x16.sv
├── rtl/soc_integration/hdmi_startup_colorbar.sv
├── rtl/soc_integration/video_frame_diagnostics.sv
├── rtl/soc_integration/video_cfg_cdc.sv
└── rtl/soc_integration/video_apb_ctrl.sv
```

代码里的原话（top.v:18）说明了动机：*"Include ISP modules here so GUI project-file saves cannot drop their sources."* —— 这是为了对抗 Efinity GUI 保存工程时丢源文件的行为，**不是随手写的**。

**推论**：判断一个文件是不是死代码，不能只看 `grep 文件不在 XML 里`。`rtl/cam`、`rtl/cam_i2c_ctrl`、`rtl/mipi_config`、`rtl/pp`、`rtl/soc_oob` 完全不在编译单元里（真死代码）；而 `rtl/isp` 全部在跑。

### 顺带解释 ARCHITECTURE_FULL.md 的一个错误

文档写 `rtl/ti60f225_oob_top.v (7,581 行)`。实测：

- `rtl/ti60f225_oob_top.v` = **996 行**（HEAD 887 行）
- `debug_top.v`（工程里的自动生成 JTAG 调试顶层）= **7,581 行**

7,581 这个数字来自 `debug_top.v`，被记到了 `top.v` 头上。两个文件都在 XML 的 design_file 列表里。

---

## 二、三份 `raw_base()` 是否一致

`style_frame_store.sv:23` 与 `style_display.sv:93` 各有一份 slot→地址的 case，**逐字节相同**：

```
0:0x05000000  1:0x05140000  2:0x05280000
3:0x053c0000  4:0x05500000  default:0x05640000
```

风格帧一律是 `raw_base + 0x00800000`（`style_frame_store.sv:87` 生成 `nn_result`，`style_display.sv:140/147` 读回），三处自洽。slot 间距 0x140000 = 1.31 MB，而一帧 640×480×4 = 1.23 MB，余量 82 KB。

`style_accel.sv:38-42` 的地址合法性检查也与此吻合：`frame_bytes = 640×480×4 = 0x12C000`，`source_cfg ≤ 0x05800000 - frame_bytes`，slot5 的源 0x05640000 仍在范围内。

---

## 三、APB 契约三向对照

STYLE 区的读 mux 被**拆成两级**：`style_video_system.sv:79-81` 处理 0x38~0x50，其余落到 `style_accel.sv:80-92`。只看 `style_accel` 会以为 0x38 之后全是 0。

| 偏移 | 提供者 | 内容 | 固件访问点 |
|---|---|---|---|
| 0x00 | accel | MAGIC `0x3154534e` | style_driver.c:34 |
| 0x04 | accel | `stream_enable` / 启动位 | :35, :57, :69 |
| 0x08 | accel | `{coeff_idle,error,done,pending}` | :15, :21, :37, :49 |
| 0x0c | accel | `irq_enable` | :49 |
| 0x10/14/18 | accel | source / result / geometry | :52 |
| 0x1c | accel | `last_cycles` | :17 |
| 0x28/2c | accel | 系数索引 / 系数载荷 | — |
| 0x30 | accel | `{acknowledged, issued}` | — |
| 0x34 | accel | 常数 148,500,000 | — |
| 0x38/3c/40 | video_system | captured / dropped / inferred | :59, :60, :95 |
| 0x44 | video_system | infer_errors | :102 |
| 0x48 | video_system | display_frame_id | — |
| 0x4c | video_system | display_dma_errors | :101 |
| 0x50 | video_system | bridge_errors | :122 |
| **0x54** | **无** | profile_freeze | **:71, :73** |
| **0x58–0x84** | **无** | 12× DDR 占用计数器 | **:72** |
| 0xa8/ac | accel | read / compute cycles | :18 |
| 0xb0/b4/b8 | accel | prefetch / overlap | :19 |

VIDEO 区（`video_apb_ctrl.sv`）固件实际读的四个偏移 **全部存在**：0x140 fault_sticky(:99)、0x148 axi_errors32(:103)、0x14c underflows32(:95)、0x15c csi_sync(:100)。`0x180~0x1a0` 硬编码返回 32'd0，确认了 ARCHITECTURE_FULL.md 问题 6（AWB 统计硬件缺失）。

---

## 四、三条硬发现

### F1 · DDR 占用遥测是一条死链（0x54 / 0x58~0x84）

**链条**：

1. 固件 `style_log_ddr()`（style_driver.c:68-74）每秒执行一次：往 STYLE 区 **0x54 写 1**（冻结计数器）→ **读 0x58~0x84 共 12 个字** → 写 0 → 算差分 → 打印 `DDR100M T ... AR ... DOWN ... RGAP ...`。调用点在 main.c:119，无条件每秒一次。
2. RTL 侧当前 `style_video_system.sv:79-81` 的 mux 只到 `0x50`，`style_accel.sv:82-91` 的 case 也没有 0x54/0x58 → **未命中任何分支，`prdata` 停在初值 0**。
3. 写入 0x54 也不被接受：`style_accel.sv:66-74` 的写 case 只有 0x04/0x08/0x0c/0x10/0x14/0x18/0x28；`pslverr` 也不会报（不在错误条件里）。

**曾经是通的**。`git show 4fdc3c8:rtl/style/style_video_system.sv` 里有完整实现：

```verilog
wire profile_write = ... && paddr==8'h54;
wire [3:0] profile_index = (paddr-8'h58)>>2;
style_ddr_profiler profiler(.clk(clk), ..., .freeze(profile_freeze), .index(profile_index), ...);
assign prdata = ... : paddr==8'h54 ? {31'b0,profile_freeze}
             : (paddr>=8'h58&&paddr<=8'h84) ? profile_value : accel_prdata;
```

`style_ddr_profiler.sv` 模块**现在还在**（12 个计数器、freeze/clear、100 MHz），`tests/style_ddr_profiler_tb.sv` 也还在——但**没有任何地方实例化它**（全仓 grep 只有 module 定义那一行）。

**后果**：板上每秒打印的 DDR 占用曲线 12 个数全是 0。更要紧的是，**ARCHITECTURE_FULL.md §六 那句「Measured 分解：算力 7.85 ms + DDR 等待 49.1 ms」不可能来自当前源码构建的 bit**——只可能来自 4fdc3c8 时代的产物。任何基于这条曲线做的带宽优化判断，都要先确认是在哪一版上测的。

**修复成本**：小。把 4fdc3c8 的那 8 行搬回 `style_video_system.sv`、实例化 profiler、在 mux 里加两个分支即可，不新增 RAM（12×32 bit 计数器吃 FF）。

### F2 · rowpipe 计算通路零仿真覆盖

47 个 testbench 里，**没有任何一个实例化 rowpipe 链条**（`rowpipe_layer`、`conv3x3_core`、`requant`、`rowpipe_engine`、`rowpipe_ddr_banks`、`rowpipe_frame_driver`、`style_network_rowpipe`）。全仓搜索，唯一提到这些名字的文件是 `style_accel.sv:109` 的那次实例化。

反过来，**有 tb 的三件套是不综合的死代码**：`style_network_tb.sv` → `style_network`、`style_row_tb.sv` → `style_row_core`、`style_mac_tb.sv` → `style_mac8x12`。它们在 `style_accel.sv:108` 的 `generate if (USE_ROW_PIPE)` 的 **else 支**里，而 `USE_ROW_PIPE` 默认 `1'b1`。

`rowpipe_frame_driver.v:173` 的注释还在引用一个不存在的 tb（"tb_rowpipe_frame640 的 descs 逐位相同"），`rowpipe_ddr_banks.v:426-428` 记录过一次"帧级 TB 两帧都不对"的实验——说明这套 tb 曾经存在，但没进这个仓库。

**后果**：`requant` 的 RHE 舍入、L4/L6/L8 的残差叠加、L11 的 result 路径、bank 轮转这类**最容易出错也最难在板上定位**的逻辑，目前只有"板上看着像"这一种验证手段。这次六路阅读报告可以直接作为"该补哪几个 tb"的输入。

### F3 · `auto_start` 路径绕过地址合法性检查（低危）

`style_accel.sv:75-77`：

```verilog
if(auto_start && auto_ready && stream_enable) begin
  mail_source <= auto_source; mail_result <= auto_result; ...   // 没有 config_ok
```

而 APB 启动路径会在 `pslverr` 里检查 `config_ok`（`!auto_ready || !config_ok`）。也就是说：帧缓存自动流水这条路上，越界的 source/result 地址不会被拦住。

目前 `style_frame_store` 给的地址恒在合法区间（见第二节），所以**不是现行 bug**；但一旦有人改 slot 间距或加 slot，这条路径不会报错，而是静默写坏别的东西。

---

## 五、验证手段现状（改动一个模块时该跑什么）

| 手段 | 覆盖 | 位置 |
|---|---|---|
| Verilog testbench | 47 个 tb，覆盖 32/177 个模块（**核心计算通路 0 个**） | `tests/` |
| Python 回归 | 50 余个 `test_*.py`，偏顶层集成/固件运行时/资源检查 | `tools/` |
| 资源与静态检查 | `run_rtl_checks.py` / `run_style_checks.py` / `check_rtl_config.py` | `tools/` |
| 板上验证 | UART 115200（COM 口每次确认）+ OpenOCD | `_ocd*.bat` |

---

## 六、留给队友回填的开放问题

这些问题单看一个模块答不了，等 01~06 回来后在此收敛：

1. **G/R σ = 1.95（板上） vs 1.06（模型）** —— debayer 增益相位（video-frontend 主线）。
2. **DDR 有效带宽 0.26 / 1.6 GB/s** —— 写引擎单 beat `awlen=0` 的命令开销（rowpipe-datapath 主线）。
3. **权重 blob 22,512 B 记录 vs 14,448 B 实写** —— 是布局空洞还是记录过期（firmware-reader 主线）。
4. **显示细节损失 σ 12.3 vs 23** —— 是 lift 贡献的 24% 还是 display FIFO 丢像素（style-system + video-frontend 交界）。
5. **一帧的端到端延迟** —— 从 CSI 到 HDMI 到底几帧（top-soc 的复位/栅栏时序 `rst_n_piple DLY=3` 是否引入额外缓冲）。

---

## 七、六份报告之间的裁决与勘误

六路独立阅读必然产生互相矛盾的结论。以下是我逐条回到源码裁决的结果。

### 裁决 1 · R 通道到底在哪个字节 —— **在 bit[7:0]**（报告 02 与文档均错）

- `debayer_top_2to1.v:150-151`（决定性证据）：
  `rgb_datax2_o = {b[15:8], g[15:8], r[15:8], b[7:0], g[7:0], r[7:0]}` → 低字节 = r。
- `style_vga_crop.sv:17` 把 `i_rgb[7:0]` 与 `i_rgb[31:24]` 当同一通道配对做 2×2 平均 → ch0 = R。
- 顶层 `top.v:830-832`：`hdmi_tx_rdata = display_pixel[7:0]`。
- rowpipe 两端对称：输入扩展 `{104'd0, wr_data[23:0]}`（ch0=byte0），输出打包 `{8'h00, wr_data[23:0]}`（ch0 回 byte0）。

24 位字的正确读法是 **`{B,G,R}`（MSB→LSB）**，即 R 在 bit[7:0]。ARCHITECTURE_FULL.md:114 的标签 "XBGR" 是对的，括号里"R 在 bit[23:16]"是错的；报告 02 §9 表第 11 行据此判"文档正确"也应修正。

### 裁决 2 · 8 个 include 模块是否被实例化 —— **全部零实例化**（我第一轮说错了）

`osd_apb_regs`、`osd_text_double_buffer`、`osd_fixed_text`、`osd_font8x16`、`hdmi_info_overlay`、`hdmi_frame_histogram`、`hdmi_startup_colorbar`、`capture_frame_stats` 在全工程**没有任何实例**，只有 include 进编译单元。`top.v:672` 的实例是 `video_apb_ctrl osd_apb`——同名不同物，这点报告 04 说得对。

`top.v:914-916` 的 tie-off（`db_char_pixel=1'b0`、`osd_db_ack=1'b0`）仍在，是因为 `video_apb_ctrl` 还留着 OSD 输出端口，而下游 `osd_text_double_buffer` 已经不存在了。

### 裁决 3 · `resize_fault` 是否悬空 —— **不悬空**（报告 04 说错了）

报告 04 把 `resize_fault` 判成"无驱动源、浮空"。实际 `top.v:639`：

```verilog
.capture_fault(resize_fault),      // style_video_system 的 output 端口
```

而 `style_video_system.sv:34` 是 `assign capture_fault = crop_fault || cap_overflow;`。所以它**被驱动**，`led[2]` 与 APB 的 fault 位是有效的。问题只在**命名**：这个线叫 resize_fault（旧 resize 通路的名字），实际语义是 capture fault。

### 裁决 4 · `style_accel` 是否双实例化 —— **否**（报告 02 的存疑可关闭）

`style_accel.sv:108` 是 `generate if (USE_ROW_PIPE)`，`USE_ROW_PIPE` 是 **parameter 默认值 `1'b1`**，全工程没有任何例化覆盖它（报告 03 已确认）。`g_monet` 支不综合，不存在双驱动。

### 裁决 5 · 文件行数口径 —— 队友对，我的任务书过期

`Measure-Object -Line` 统计的是**非空行**；队友用 read 工具得到的是物理行号。正确值：rowpipe_layer **973**、ddr_banks **860**、engine **444**、frame_driver **191**。ARCHITECTURE_FULL.md 的行号引用（`:808` 命中 `pk_acc`）反而精确，说明它用的是物理行号。

---

## 八、遥测失效不是一条，是一片（F1 的范围扩大）

F1 只写了 DDR profiler 一条。六路读完后，把固件每秒打印的字段逐个对到 RTL，得到完整表：

| 固件字段 | APB 偏移 | RTL 现状 | 可信？ |
|---|---|---|---|
| `MS`（毫秒/帧） | 0x1c `last_cycles` | `drv_cycles`，活 | ✅ |
| `CAP/NN/DROP/ERR` | 0x38/3c/40/44 | 活 | ✅ |
| `DME/IERR/AXI` | 0x4c/44/50 | 活 | ✅ |
| `RPMS/CPMS` | 0xa8/0xac | `stat_*` 被 `style_network_rowpipe.v:137-141` 拉 `32'd0` | ❌ 恒 0 |
| `PF/PFC/OVLP` | 0xb0/b4/b8 | 同上 | ❌ 恒 0 |
| `DDR100M T/AR/DOWN/…` | 0x54 + 0x58~0x84 | 无实体（profiler 未实例化） | ❌ 恒 0 |
| `VIDEO UF/DUF/DDROP/FAULT/CSI` | 0x14c/14c/144/140/15c | 活 | ✅ |
| `DISP`（fps） | 0xf8100024 >> 16 | 落在 `legacy_hit`（`paddr<=0x30`），恒 0 | ❌ 恒 0 |
| `hot` | 0x0e8 | 固件强制置 0（`camera_3a.c:116`） | ❌ |

**结论**：一行 UART 日志里有一半字段恒 0。任何用 `RPMS`/`DDR100M`/`DISP` 做的性能或带宽推断都是自证的；ARCHITECTURE_FULL.md §六 的「算力 7.85 ms + DDR 等待 49.1 ms」只能来自 4fdc3c8 时代那个还接了 profiler 的构建。

修复成本：把 profiler 挂回去 ≈20 行；把 5 个 stat 接上 rowpipe 真实计数 ≈5 行（`rowpipe_ddr_banks` 里已有 `acked`/`acked_virt` 可复用）。

---

## 九、方法学备注

- 全文结论可用 `git show` / `grep` 复现，命令都写在各节的引用里。
- 「已验证」= 我直接读到源码或报告；「待确认」= 只有间接证据。
- 本次不改任何 RTL/固件/工程文件；产出仅限 `reports/line_by_line/`。
