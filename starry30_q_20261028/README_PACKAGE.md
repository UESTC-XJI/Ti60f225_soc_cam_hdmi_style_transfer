# starry30_q —— 星空 30fps · 4 风格旋钮 · 4:3 单画面（2026-10-28）

> 自包含工程包：源码 + 最终位流/固件 + 复现步骤。
> 基线 = `F:\...redsky-q (2).zip`（30fps 星空、4 套 DC 权重、UART 热切换），
> 本包在其上加了 **①4:3 单画面显示（我们的 style_display）②旋钮 G1..G4 切换 ③rainbow 风格(G3)**。
> 工作目录：`G:/FPGAtest/_incoming/starry30_q/`（本包是其副本）。

## 0. 一句话状态

板上实测 **30–31 fps / MS 26–27 ms / DROP 0 / UF 0 / DUF 0 / FAULT 0**；
旋钮 G1 星空、G2 red_sky、**G3 彩虹**、G4 保持；按键切 **4:3 单画面**（960×720 居中 + 左右各 160 黑边）。

## 1. 产物（artifacts/）

| 文件 | md5 |
|---|---|
| `ti60f225_starry30_single43_20261028.bit` | `350eb5105972bfc5cd89779a16669992` |
| `ti60f225_starry30_single43_20261028.hex`（SPI flash 用，未写） | `1e280a9fb9ffd10273b4863286e5073d` |
| `soc_video_app_starry30_knob4_20261028.elf` | `eae55f8bbbbe21dcd8f3841737698235` |

⚠ 同目录下的 `ti60f225_cap8_fps_fair.bit` / `soc_video_app_cap8_*.elf` 是 zip2 自带的历史件，
**不含本包的旋钮/彩虹改动**，别拿错。

## 2. 功能与判据

| 项 | 实现 | 判据 |
|---|---|---|
| 帧率 | 传感器 VTS 1457，引擎 26–27 ms/帧 | UART `CAP/NN 30–31`、`DROP 0` |
| 显示 | 720p60，对比模式 = 左原画 / 右风格 | `UF 0 DUF 0` |
| 单画面 | 板键（GPIOR_22）切换；**4:3 完整**，3× 最近邻 → 960×720 居中，左右各 160 黑边 | 仿真每帧 691,200 px 全对 |
| 风格切换 | 旋钮两位 `{SW2,SW1}`（GPIOL_04/10）→ 20 ms 消抖 → bank 切换 | `KNOB n (Gn)` + `STYLE SW n <名> ok` |
| 档位 | **G1=starry_old / G2=red_v3_dc / G3=rainbow / G4=保持** | 上板轮转实测 |
| 串口备份 | UART0 发 `1`..`5` 直接切 bank，`s` 列清单 | `STYLE BANKS …` |

旋钮 raw→物理档位是**非线性**的：`0b00=G3, 0b01=G1, 0b10=G2, 0b11=G4`（10-26 实测表）。

## 3. 资源与时序（Efinity 2026.1 / Ti60F225 / I3）

| 项 | 值 |
|---|---|
| XLR | **60,277 / 60,800（99.14%）** ← 已贴天花板 |
| RAM / DSP | 202 / 256、147 / 160 |
| vid_clk_dvi2 | +0.226 ns（约束 148.5 MHz） |
| core_clk | +2.500 ns（约束 100 MHz） |
| 裁决 | `tools/build_check.py` = **USABLE** |

⚠ 后续任何 RTL 改动先跑 `map` 看 XLR 增量，**>100 就别做**（实测 +131 就布不通）。

## 4. 构建

**位流**（工程根目录执行）：
```bash
python ~/.claude/skills/efinity/scripts/efx.py build ti60f225_cam_hdmi.xml -f compile
python tools/build_check.py          # 需要 build.log；efx.py 的日志请先 cp 成 build.log
```

**固件**（改风格/bank 才需要）：
```bash
SOC_RISCV_TOOLCHAIN=/g/Efinity/efinity-riscv-ide-2026.1/toolchain/bin \
  bash tools/build_firmware.sh weights/starry_old_signed_dc/rowpipe_weights.h
# 产物 software/firmware/build/soc_video_app.elf
```

## 5. 上板顺序（踩过的坑，照做）

1. 配 bit：`python tools/flash_bit.py --file artifacts/ti60f225_starry30_single43_20261028.bit`
   （工具会自动发现 FTDI URL；EFINITY_ROOT 默认 D:，本机需 `EFINITY_ROOT='G:\Efinity\2026.1'`）
2. 起 OpenOCD：`openocd -f software/firmware/openocd/soc_video.cfg`
3. 下 ELF：`riscv-none-elf-gdb <elf> -x <reset halt / load / pc=0x1000 / monitor resume / detach>`
4. 看 UART：`MONET CAP 30 NN 30 … MS 26 … VIDEO UF 0 DUF 0 FAULT 0`

**判据**：`MS` 必须是 **26–27**；若是 **57**，说明板子吃的是 SPI flash 里的旧全分辨率位流 → 重配 bit。
**只热重载 ELF 会锁存 `VIDEO FAULT 1`**（CAP/NN 归零、DROP 涨）→ 必须重配 bit 再下 ELF。
**JTAG 配置易失**：断电会从 SPI flash 载旧位流；要断电保留需写 flash（本包未做）。

## 6. 权重约定（重要，D 线注意）

显示端对风格侧做 `^0x808080`（有符号补码 → 显示域）。因此 **所有风格 blob 的末层必须是**：
`qlo=129 / qhi=127`（有符号），bias 已含 **−128 平移**。

本包 rainobw 用的是修正版：原包 `qlo=0/qhi=255`（无符号）会被 +128 抬亮并串色；
修正 = L11 bias 各 −79230（=128 个 q 步）+ Q 头 `0x001FE067`。
修正后 `weights/rainbow_dc_blob.bin` md5 `6b778fc8bf7ffab05faeb9e1b0805ff6`、XOR `0xa09b9352`。
夹断量化（对 golden）：R 0.073% / G 1.318% / B 1.660% 像素，误差恒 **1 LSB**。

## 7. 已知问题 / checklist

- **OSD metrics COMMIT timeout 每秒一行**：OSD 块已从设计移除，固件仍在等 ACK；只影响 `DISP` 字段，不进判据。
- `artifacts/` 里的历史 ELF 不含旋钮切换，提交前别拿错。
- `tools/style_probe.py l11|weights` 能直写 DDR 权重头，**演示前不要跑**。
- 面积 99.14%：不要再加 RTL。
- 上板前若断电过：先确认 `MS`，再看 `STYLE BANKS` 有 5 项（旧固件只有 4 项）。

## 8. 仿真回归（本包内可复跑）

```bash
MS=/e/modeltech64_2020.4/win64
rm -rf work_q && $MS/vlib.exe work_q
$MS/vlog.exe -quiet -sv -timescale "1ns/1ps" -work work_q \
  rtl/style/style_display.sv rtl/style/style_display_beats.sv rtl/style/style_async_fifo.sv \
  rtl/style/style_axi_rows.sv tests/tb_disp_720p.sv tests/tb_disp_ab.sv \
  tests/style_display_old_ab.sv tests/tb_disp_toggle.sv
$MS/vsim.exe -c -quiet work_q.tb_disp_720p +single=0        -do "run -all; quit -f" -l sim_cmp.log
$MS/vsim.exe -c -quiet work_q.tb_disp_720p +single=1 +frames=6 -do "run -all; quit -f" -l sim_single.log
$MS/vsim.exe -c -quiet work_q.tb_disp_ab                     -do "run -all; quit -f" -l sim_ab.log
$MS/vsim.exe -c -quiet work_q.tb_disp_toggle                 -do "run -all; quit -f" -l sim_toggle.log
```
期望：对比 614,400 px/帧 0 错；单画面 **691,200 px/帧** 0 错 0 uf；A/B `diff=0`；切换两方向 0/0。

## 9. 本包相对 zip2 的改动清单

| 文件 | 改动 |
|---|---|
| `rtl/style/style_display.sv` | 单画面铺满→**4:3 960×720 + 左右黑边**；`obsolete` 消隐期修正；`sp_lat` 帧首锁存模式；`dup_cnt` 3× |
| `rtl/ti60f225_oob_top.v` | 加 `io_sw1/io_sw2` 输入 + 2FF 同步；送 `video_apb_ctrl.knob_in` |
| `rtl/soc_integration/video_apb_ctrl.sv` | 只读 `0x54` 的 bit[3:2] = 旋钮两位 |
| `ti60f225_oob.peri.xml` | 加 `io_sw1=GPIOL_04`、`io_sw2=GPIOL_10`（输入/weak pullup） |
| `software/firmware/main.c` | 旋钮轮询/20ms 消抖/G1..G4 映射/上电按档位/标签修正 |
| `software/firmware/style_banks.h` | 新增 `style_bank_rainbow`（修正版 blob） |
| `software/firmware/style_driver.c` | `STYLE_BANK_COUNT 4→5`，表加 `rainbow` |
| `tools/flash_bit.py` | 用户目录按当前登录用户（原写死 `C:/Users/36040`） |
| `tests/` | 新增 `tb_disp_720p.sv` / `tb_disp_ab.sv` / `tb_disp_toggle.sv` / `style_display_old_ab.sv` |
