# 整合：全幅采集输入 + 新显示几何（2026-10-31）

> 从 `G:/FPGAtest/_incoming/starry30_q`（工作区，含 2026-10-30 采集改动）
> 合并到本 master 工程。本工程原有 **boot splash `original_single`** 功能保留。

## 1. 采集输入

| 文件 | 改动 |
|---|---|
| `rtl/style/style_vga_crop.sv` | 替换为全幅压缩：1920×1080 全幅 3×3 面积平均 → 640×360，上下各补 60 行黑边凑 640×480；帧存/引擎/显示接口不变 |
| `rtl/soc_integration/video_apb_ctrl.sv` | AE 测光从中心 1280×960 改为全幅：`ae_in_crop=1'b1`，样本数 1,228,800 → 2,073,600（21 位计数不溢出） |
| `tests/style_capture_tb.sv` | 期望模型改为全幅 3×3 + 黑边 |
| `tests/style_video_tb.sv` | 小尺寸全幅压缩/黑边/帧标签回归 |
| `tests/tb_ae_crop.sv` | AE 全幅样本数回归 |
| `tests/style_crop_blanking_tb.sv`、`tests/style_crop_edge_tb.sv` | 新增：消隐期吐黑边、边界/故障场景 |

接口未变：`style_vga_crop` 端口与实例化方式不变；`style_frame_store` 仍按 307,200 px/帧写 DDR。

## 2. 显示

`rtl/style/style_display.sv` 手动合并（没有整文件覆盖，因为本工程多了 `original_single`）：

| 模式 | 几何 |
|---|---|
| 对比（`single_panel=0`） | 左半屏完整原画 640×360（1:1），右半屏完整风格 320×180→2× = 640×360；图片区 v=205..564，上下各 180 行黑边；等比、不裁切 |
| 单画面（`single_panel=1`, `original_single=0`） | 风格 320×180 4× 铺满 1280×720，无黑边 |
| boot splash（`original_single=1`） | **保持原实现**：原画 960×720 全屏，左右各 160 黑边（采集帧内的上下黑边仍随整帧显示，未改动 boot 口径） |

关键实现点：
- 两种正常模式的 `dup_max`：对比原画 1×（0）/风格 2×（1），单画面风格 4×（3）；
- 对比第二段风格源行 = `30+((原画源行-60)>>1)`，读完整 320 px 写 2 条；
- `raw_single` 分支完全保留原有的 `(d*2)/3` 行映射与 `raw_odd` 交替 1/2 复制；
- `raw_single_pix/clk` 的声明移到 `single_panel_pix/clk` 之后，修掉 ModelSim 的前向引用报错。

## 3. 测试更新

| 文件 | 改动 |
|---|---|
| `tests/tb_disp_720p.sv` | 覆盖为 G 的新几何期望（对比/单画面两模式） |
| `tests/tb_disp_toggle.sv` | 覆盖为 G 的新几何期望 |
| `tests/tb_disp_boot_modes.sv` | 更新期望：对比 v=205..564；风格单画面 4×；raw_single 保持 960×720 |
| `tests/style_display_tb.sv` | 更新期望几何；修正 `data_at()` 对风格槽跨距 1280 B 的映射；显式驱动 `single_panel=0/original_single=0` |

`tests/tb_disp_ab.sv` 与 `tests/style_display_old_ab.sv` **未更新**：它们的前提是“对比模式逐拍不变”，
新几何是有意改动，A/B diff 必然非 0，不能再当回归用。

## 4. 验证（ModelSim 2020.4）

| 测试 | 结果 |
|---|---|
| `style_video_tb` | PASS（全幅压缩/黑边/帧存/6 槽轮转） |
| `style_capture_tb` | PASS（307,200 px、2,400 DDR bursts、无溢出） |
| `style_display_tb` | PASS（3 帧、配对 slot 2/4、精确 RGB、饥饿恢复；good=1,372,800） |
| `tb_disp_720p +single=0` | PASS（2 帧，921,600 px/帧，bad=0 uf=0） |
| `tb_disp_720p +single=1 +frames=8` | PASS（8 帧，bad=0 uf=0） |
| `tb_disp_toggle` | PASS（6 帧，帧中切换两方向，bad=0 uf=0） |
| `tb_disp_boot_modes` | PASS（8 帧，raw/对比/风格单画面 + 两次帧中切换，bad=0 uf=0） |

编译/运行使用临时 `work_int_1031` 库（已删）；日志在 `reports/integration_20261031/`
（`sim_cmp_int.log`、`sim_single_int.log`、`sim_toggle_int.log`、`sim_boot_int.log`、
`style_video_tb_int.log`、`style_capture_tb_int.log`、`style_display_tb_int.log`）。

> 本机没有 `C:/iverilog`，`tools/test_style_video.py` 无法直接跑；上面用 ModelSim 跑了等价的三个 TB。
> 若要恢复该脚本，需装 Icarus 或把脚本的编译器路径改到 ModelSim。

## 5. 综合检查

`python ~/.claude/skills/efinity/scripts/efx.py build ti60f225_cam_hdmi.xml -f map`
→ **map : PASS**（仅综合，未跑 PnR/未出位流、未上板）。

Map 后资源：FFs 25,317 / LUTs 35,640 / **RAM 253 / 256** / DSP 147。
RAM 只剩 3 块，PnR 前必须先确认资源；若不够，优先检查新采集模块的 lineA/lineB
（2 BRAM）和原有 startup_page（48 RAM）的取舍。
构建中间目录已清理；资源表/日志留在 `reports/integration_20261031/`
（`map_res.csv`、`map.rpt`、`map.log`）。

## 6. 备份

改动前的 3 个 RTL 和 7 个测试已备份到：

`backup/pre_capture_display_20261031/`

## 7. 后续

- 需要上板时再跑完整 `-f compile`；本工程原有 PnR 资源已接近上限，必须重新看 XLR/slack。
- 本工程当前 `deliverable/` 下的位流仍是整合前版本，未替换。
- 固件未改：AE 用 RTL 给出的 `ae_n` 做归一化，理论上自适应全幅样本数；
  本次只做了仿真 + map，**没有上板验证 AE**，上板时留意图像亮度是否正常。

## 8. 出位流与上板结果（2026-10-31 晚）

- **容量**：全功能（含 FPS 文字叠加）在默认综合下差 5 个 XLR。为保证稳定布线，
  本版在 `rtl/ti60f225_oob_top.v` 里**去掉了屏幕 FPS 叠加**（`fps_overlay` 旁路），
  采集/显示/启动画面/UI 全部保留；FPS 仍可由 BLE/STATE 读取。其余综合选项恢复默认。
- **构建**：PnR/pgm PASS；XLR **60,598/60,800（99.67%）**；vid slack **+0.455 ns**、
  core **+1.814 ns**；位流 `outflow/ti60f225_oob.bit` md5 **`77986d94485428ece0fa1ee81fa02e13`**。
- **上板现象**：JTAG 配位流成功、固件（与 `deliverable/boot_splash_20261030/` 的
  bin 逐字节相同，md5 `fd9ba7b4…`）加载成功；但 **CPU 卡在 PC=0x1000、单步不前进**，
  读 APB `0xF8100138` 返回 `0xbffed397`（垃圾值），HDMI 有 60 fps 同步但全黑。
- **隔离结论**：烧 **`deliverable/qse_mainline_merge_20261030/`** 的 bit + bin
  （原版 master 的配套版本）后，CPU 正常运行（PC `0x4620`）、FPS31、画面正常。
  黑屏只出现在 **boot_splash 分支**（包括它自己的交付位流 `42e0ca45…`）。
  ⇒ 不是采集/显示合并的问题，也不是 F master 整体的问题；是 boot_splash 分支在本板的
  SoC bring-up 问题。**master 应使用 qse 基线。**
- **最终可上板版本**（见第 9 节）：以 qse_master 为基线重建整合版，已实板验证。

## 9. 最终可上板版：采集 + 显示 + 启动动画 + FPS + mosaic（qse_master 基线，2026-10-31）

- **构建工程**：`F:/fm_qse_int_1031/`（qse_mainline_merge + 采集/显示 + RTL 自动启动动画 +
  BRAM 字模 FPS + mosaic bank3）。
- **位流**：`outflow/ti60f225_oob.bit` md5 **`06d3ad8aed317e6162c1b87febc1d375`**，
  XLR **60,385/60,800（99.32%）**，RAM **254/256**，vid **+0.411 ns**，core **+2.438 ns**。
- **固件**：`soc_video_app.bin` md5 **`5ea88e8c0b3dc6818c4490ab7887b742`**（94,852 B）；
  bank3 由 `red_v3_dc`（呐喊）替换为 **`mosaic_t025`**
  （XOR `0x9da15c61`，末层 Q beat (39,129,127)，DC [0,0,0]）。
- **启动动画**：boot_splash 模块/图片，RTL 上电约 56 ms 后自动播放，约 7.2 s 后切实时；
  不依赖 boot 固件/APB。
- **FPS**：5×7 字模改为 **128×5 BRAM ROM**（1 RAM），屏幕 FPS31 已恢复。
- **实板验证**：
  - 启动图：`G:/FPGAtest/sim/runs/bootanim2/cap_20.png`；
  - mosaic 对比 + FPS31：`runs/mosaic_g2/cap_01.png`；
  - mosaic 单画面 4×：`runs/mosaic_single/cap_01.png`；
  - 读固件：`style_active_bank_index=3`、`app_style_switches=1`、无错误位；CPU PC 正常。
- **交付包**：`deliverable/capture_display_20261031/`（最终 bit/bin/ELF + changes + 实抓图 + md5）。
- **boot_splash 分支**：它自己的位流+固件在本板仍然起不来（CPU 卡 0x1000 / APB 垃圾）；
  本交付没有用它，而是把同一 boot_splash 模块放到 qse 基线上由 RTL 自动启动。
