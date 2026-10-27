# 逐行阅读总纲（00_INDEX）

> 日期：2026-10-26
> 方法：6 名 teammate 分块逐行阅读 + Lead 交叉裁决，**全程只读，未改任何 RTL/固件/工程文件**
> 覆盖：97 个编译单元 / 81,882 行 / 177 个 module

---

## 一、交付清单

| 报告 | 负责 | 覆盖 | 行数 |
|---|---|---|---|
| [01_rowpipe_layer.md](01_rowpipe_layer.md) | rowpipe-layer | rowpipe_layer(973) / conv3x3_core(248) / requant(210) | 479 |
| [02_rowpipe_datapath.md](02_rowpipe_datapath.md) | rowpipe-datapath | engine(444) / ddr_banks(860) / frame_driver(191) / network(145) / fps_overlay(153) | 715 |
| [03_style_system.md](03_style_system.md) | style-system | rtl/style 全部 14 个综合文件 | 650 |
| [04_top_soc.md](04_top_soc.md) | top-soc | top.v(996) + soc_integration 18 个 | 958 |
| [05_video_frontend.md](05_video_frontend.md) | video-frontend | debayer 6 / CSI 接口 / gearbox / ISP 5 + LUT | 741 |
| [06_firmware.md](06_firmware.md) | firmware-reader | software/firmware 全部自研源文件 | 744 |
| [07_cross_module.md](07_cross_module.md) | Lead | 编译单元、APB 三向、交叉裁决 | 255 |

合计约 4,540 行。每份报告都按 `file:line` 可复现，事实与推测严格分开标注。

---

## 二、当前基线（阅读期间重建过一次）

会话开始时 `outflow/ti60f225_oob.bit` 是 10-25 的产物。**10-26 17:50 有人跑了一次完整构建**（map 17:43 → pgm 17:50），产物已覆盖为**当前工作区版本**（含 3 个 RTL 未提交改动）。

| 指标 | 10-26 17:50 构建 | 与 10-25 一致？ |
|---|---|---|
| XLR | 59,132 / 60,800（97.26%） | ✅ 完全一致 |
| RAM | 244 / 256（95.31%） | ✅ |
| DSP | 147 / 160（91.88%） | ✅ |
| setup 最小 slack | 0.355 ns（tx_cal_clk_90edge） | ✅ |
| core_clk slack | 1.874 ns | ✅ |
| hold 最小 slack | 0.038 ns | ✅ |

**结论**：那个"双重 XOR"修复对面积与时序零代价（只是 24 位 mux），但也说明 `ARCHITECTURE_FULL.md` 写的 "slack +0.046 ns" 在任何一版报告里都不存在。

> ⚠️ 同一次构建把 `ti60f225_cam_hdmi.xml` 的 `sw_version` 属性改了（`2026.1.132.4.5` → `2026.1.132`），这是 Efinity 保存工程的老毛病（见 `docs/PROJECT_HANDOFF.md`）。内容无实质变化，但**如果 Efinity GUI 还开着，它会继续回写**，建议关掉再提交。

---

## 三、十二个已确诊发现（按可行动性排序）

### 1. 输出层被隐式 ReLU —— 能解释"均值 +28 / 70.9% 同色"

`requant.v:114`：`ar = (qlo_r < 0) ? a : (a > 0 ? a : 0)` —— ReLU 没有独立使能位，靠 `qlo` 的符号隐式决定。
按 RTL 的 blob 解析规则还原两套权重：**L11 是 `qlo=0 / qhi=255` ⇒ 输出层强制 ReLU**，而 L4/L6/L8 是 `qlo=-127` 不 ReLU。
显示端 `style_display.sv:107` 却按零中心有符号数做 `^0x808080`。两个约定互斥。

自洽验算：70.9% 像素被夹成 0，其余均值 ≈ 96 → 整体 ≈ 27.8，与实测 +28 吻合。
**判别实验（10 分钟，不改 RTL）**：把 L11 改 `qlo=-128/qhi=127` 重标定 M/shift 重出 blob；或读最后一层直方图看 0 附近是否有 ≈70% 尖峰。
→ 详见 [01](01_rowpipe_layer.md) §给 Lead 第 1 条

### 2. 遥测整块失效 —— 一行 UART 日志有一半是恒定 0

| 字段 | 偏移 | 为什么是 0 |
|---|---|---|
| `RPMS/CPMS/PF/PFC/OVLP` | 0xa8/ac/b0/b4/b8 | `style_network_rowpipe.v:137-141` 把 5 个 stat 全接 `32'd0` |
| `DDR100M T/AR/DOWN/…` | 0x54 + 0x58~0x84 | RTL 里根本没有这两个地址；`style_ddr_profiler` 在 `4fdc3c8` 之后被从 `style_video_system` 移除，全工程零实例 |
| `DISP`（fps） | 0xf8100024 | 落在 `video_apb_ctrl` 的 `legacy_hit`（`paddr<=0x30`），恒 0 |
| `hot` | 0x0e8 | 固件 `camera_3a.c:116` 强制置 0 |

**后果**：`ARCHITECTURE_FULL.md` §六 的「算力 7.85 ms + DDR 等待 49.1 ms」不可能来自当前构建；任何用这些字段做的带宽推断都是自证的。
**修复**：profiler 挂回去 ≈20 行；5 个 stat 接真实计数 ≈5 行（`rowpipe_ddr_banks` 里已有 `acked`/`acked_virt` 可复用）。
→ 详见 [02](02_rowpipe_datapath.md) 要点 2/5、[03](03_style_system.md) 要点 5、[07](07_cross_module.md) §四 F1 与 §八

### 3. 外层 AXI 桥对显示读毫无优先 —— 显示欠载的机制链

内层 `style_video_system.sv:69` 的 `axi_shared_ddr_2m`（`DDR_ID_W=6`）有完整的 display urgency（`MAX_VIDEO_BURSTS=3`）；
但外层 `soc_video_ddr_integration.sv:184` 实例化时**零参数覆盖、`video_read_urgent` 根本没连** → `DYNAMIC_VIDEO_READ=0`，读冲突只剩 `rd_turn` 纯轮转。
内层那套精心设计的优先级跨过外层就被降级成普通请求。
**最小验证改动**：1 根线 + 2 个参数。
→ 详见 [04](04_top_soc.md) 要点 2

### 4. 上电 452 ms 内 HDMI 没有同步信号，而兜底代码就在库里

`vid_rst_n = dly_cnt[26]`（top:855），148.5 MHz 下 2^26 拍 = **451.9 ms**，串在 `video_reset_n` 里管着 capture/display/style 全链；
而 `dvi_encoder` 只等 3 拍就出复位 → 前 0.45 s 输入恒 0。
`hdmi_startup_colorbar` + `hdmi_startup_select`（含帧边界切换 FSM）已 include（top:27）、`bar_*` 线还在（top:950-951），**只是实例被删了**。
→ 详见 [04](04_top_soc.md) 要点 3

### 5. 权重 blob 是 14,448 B，不是 22,512 B

`ci*9+13` 按 12 层描述符求和 = **903 beat = 14,448 B**，与 `wbase_of` 偏移表（854+49=903）、map 里 `.rodata.rowpipe_weights = 0x3870` 三方吻合。
22,512 B / 1,407 beat 出自 `model/weights_blob_D_sw1e5_640.bin`（旧导出，L11 段有 553 beat），与当前 bit 无关。
**建议勘误** `style_driver.c:38-39`、`ARCHITECTURE_FULL.md:175/261/339`。
→ 详见 [06](06_firmware.md) 要点 1

### 6. 带宽：读写两侧同时是瓶颈，只修一侧只值 +6%

一帧事务账：读 547,200 beat / 39,000 条 AR + 写 374,400 beat / **374,400 条 AW**，共 14.75 MB；×17.4 fps = 257 MB/s，与实测 0.26 GB/s 逐位吻合。
即 0.26 GB/s 是"事务量×帧率"的结果，**不是带宽上限**。真指标是每 beat 摊 9.3 个 148.5 MHz 拍（地板 1.485），**6.3 倍事务开销**。
写侧单 beat + 逐 beat 等 B（49.1 ms @100 MHz）；读侧 `want_r` 单标志把并发限成 1 个 burst，`MAXB=16` 比 4 KB 页允许的 256 beat 紧 16 倍。
历史 `wburst` 只把写侧改好 → +6%，就是"读侧接棒"的直接证据。
**建议顺序**：先读侧（只动 `MAXB`/`FIFO` 深度/并发计数，不碰打包），再写侧（posted B）。
→ 详见 [02](02_rowpipe_datapath.md) 要点 1/2

### 7. 面积：CI/CO/COUT=16 是 2× 超配

12 层实测 `ci ≤ 8`、`cout ≤ 8`。改 `.CI(8)` 后 `TILED=0`，tile 全套逻辑（`S_RLD`/`wrap1280`/读口 mux/tap 路径上的 `wci` 减法器/72 个 2:1）被剪掉；
`lb` 163,840→81,920 bit（**省 8 个 10 kbit RAM 块**）、`id_rb` 省 2 块、`rq_id_r1..5` 640→320 FF。
RAM 244/256 的压力下，这是**只改例化参数、不动一行逻辑**的最划算一刀。
→ 详见 [01](01_rowpipe_layer.md) 要点 2

### 8. AE 顶到 4989 是固件常量，不是硬件限制

`camera_3a.c:31` `CAMERA_VTS_OVERRIDE=2500` → `:58` `2*vts-11 = 4989`。VTS 提到 5000 上限即 9,989（帧率相应下降）。
→ 详见 [06](06_firmware.md) 要点 3

### 9. R 通道在 bit[7:0]，不在 bit[23:16]

`debayer_top_2to1.v:150-151` 的拼接是 `{b[15:8],g[15:8],r[15:8],b[7:0],g[7:0],r[7:0]}` → 低字节 = R；
`style_vga_crop.sv:17` 按 `[7:0]`/`[31:24]` 配对；`top.v:830` `hdmi_tx_rdata = display_pixel[7:0]`；rowpipe 输入输出两端对称。
24 位字读作 `{B,G,R}`（MSB→LSB）。文档的标签 "XBGR" 对，括号里 "[23:16]" 错。
→ 详见 [07](07_cross_module.md) §七裁决 1

### 10. 显示"细节损失"是测量口径问题，不是丢像素

`style_display` 是严格 1:1 拷贝，匹配失败**一律变黑**，全链路无插值/复制/移位。
23.0 是 DDR 里**单通道 R** 的 σ（R=23.0/G=44.9/B=26.1），12.3 是截图 **luminance** 的 σ；三通道独立时应有 18.9，实测 12.3 只需通道相关 0.6 + 采集卡 1.5× 上采样。
**判别实验**：dump `0x05800000` 按 `(R+G+B)//3` 重算 σ，若得 11–13 则问题 #4 销案。
→ 详见 [03](03_style_system.md) 要点 1

### 11. G/R σ 异常：debayer 结构不支持，最可能是增益+硬截断

`rgb_gain_v1` 对 BGGR 是**逐像素恰好乘一次**（`gain_g` 出现两次只因绿像素数量是 2 倍），无重复乘、无通道互换。
解析上双线性核给出 **σ_G/σ_R = 1.054**，与模型侧 1.06 吻合 1%，结构上到不了 1.95。
而 `rgb_gain_v1.v:92-93` 的饱和点是：R/B（gain 520）在 RAW≥126 就夹到 255，G（gain 290）要到 ≥226。
`520/290 = 1.79` vs `1.95/1.06 = 1.84`（差 3%），且实测 R、B 的 σ 同量级且都低（23.0/26.1）——形状完全吻合。
**判决实验**：读 `0x05000000` 源帧一行，统计三通道 mean/σ/`==255` 占比。
→ 详见 [05](05_video_frontend.md)

### 12. 五个性能字段之外的死代码清单

零实例化（只占编译时间）：`osd_apb_regs`、`osd_text_double_buffer`、`osd_fixed_text`、`osd_font8x16`、`hdmi_info_overlay`、`hdmi_frame_histogram`、`hdmi_startup_colorbar`、`capture_frame_stats`（8 个）。
不综合：`style_network`、`style_row_core`、`style_mac8x12`（`USE_ROW_PIPE` 从未被覆盖，唯一实例在 TB）、`style_ddr_profiler`。
→ 详见 [04](04_top_soc.md) 要点 1、[03](03_style_system.md) 要点 5

---

## 四、被排除的怀疑（省得再查）

| 怀疑 | 结论 | 依据 |
|---|---|---|
| debayer `gain_g` 用两次导致通道不对称 | ❌ 排除，结构上 σ 比被限制在 [1.00, 1.054] | [05](05_video_frontend.md) |
| display FIFO 深度/欠载造成画面糊 | ❌ 排除，失败即黑、无平滑 | [03](03_style_system.md) |
| AXI 主机在 DDR 校准前发事务 | ❌ 排除，三重同源保证 | [04](04_top_soc.md) 要点 3 |
| rowpipe 打包器丢通道信息 | ❌ 排除，输入输出两端对称 | [07](07_cross_module.md) §七裁决 1 |
| `style_accel` 双实例化双驱动 | ❌ 排除，`generate` + 常量参数 | [07](07_cross_module.md) §七裁决 4 |
| requant 的 RHE 舍入写错 | ❌ 排除，两种 ARCH 都做了代数证明 | [01](01_rowpipe_layer.md) 要点 4 |
| `resize_fault` 是悬空 wire | ❌ 排除，由 `style_video_system.capture_fault` 驱动 | [07](07_cross_module.md) §七裁决 3 |

---

## 五、定时炸弹（当前不触发，但会静默出错）

| # | 位置 | 触发条件 | 后果 |
|---|---|---|---|
| C1 | `rowpipe_ddr_banks.v:834` + `engine.v:418` | 某层 `hout*wout` 不是 `2^fmt` 倍数 | 残留像素写进下一层的 bank/地址 |
| C2 | `engine.v:418` `S_WAITPIX` / `frame_driver.v:183` `S_FLUSH` | `frame_width*height` 与描述符不符 | 永久 busy，无超时（加 1M 拍看门狗即可） |
| C3 | `rowpipe_layer.v:458-462` | 出现 `2*cfg_win == D` 的层（win=640 已临界） | tile 路径静默错（现靠"ci≤8 ⇒ tile 永不触发"幸存） |
| C4 | `rowpipe_engine.v:338-348` vs `conv3x3_core.v:105` | 出现 `cout > 8` 的层 | 高半区偏置是上一层残值、高半区输出 0 |
| C5 | `rowpipe_ddr_banks.v:768` | `beat_push` 那拍恰好 FIFO 满 | 丢 beat（现靠"count 两拍不变"的隐含假设） |
| C6 | `camera_3a.c:109` 校验 `G_ACTIVE==256`，`:172` 下发 290 | AWB 复活或切 `AWB_FIXED` | 首次握手判超时 → `enabled=0` 永久停摆 |
| C7 | `video_apb_ctrl.sv:179` `st_hot<=ae_rx[73:52]`（应为 `[73:53]`） | `hot` 或 `n` 超过 2^20 | 统计值错位（当前数值远小于） |
| C8 | `style_vga_crop.fault` 只在复位分支赋值 | crop 侧行/拍数异常 | 永远检测不到 |

---

## 六、建议的下一步（按性价比）

1. **10 分钟级、不改 RTL**：dump `0x05800000` 一层直方图（判 L11 ReLU）、dump `0x05000000` 三通道统计（判 G/R σ）。这两个实验能同时关门两个最老的未解问题。
2. **20 行级改动**：把 `style_ddr_profiler` 挂回 `style_video_system` + 把 5 个 `stat_*` 接真实计数 → 恢复全部性能遥测，之后才谈得上调带宽。
3. **1 根线 + 2 个参数**：外层桥接上 `video_read_urgent`、置 `DYNAMIC_VIDEO_READ=1` → 验证显示欠载是否消失。
4. **改例化参数**：`rowpipe_layer` 的 `.CI(8)` → 换回 10 个 RAM 块（当前 244/256），为后续留空间。
5. **补 tb**：rowpipe 全链零仿真覆盖，至少补 `requant` 和 L11 的 result 路径。
6. **文档勘误**：`ARCHITECTURE_FULL.md` 有 30+ 处偏差（各报告末尾都有清单），建议一次性重写而不是逐条打补丁。

---

## 七、诚实边界

| 项 | 状态 |
|---|---|
| 全部结论可复现 | ✅ 均带 `file:line` |
| 事实 / 推测分离 | ✅ 每份报告都标注了置信度 |
| 是否跑过仿真/综合验证 | ❌ 一次没跑（阅读任务，且综合会污染 outflow） |
| L11 ReLU 的因果 | 🟡 代码事实已定，因果需一次判别实验 |
| G/R σ 1.95 的定量 | 🟡 定性成立，定量需板上读回 |
| 板载实测 | ❌ 本次未接触硬件，所有"板上"数字引自既有报告 |
