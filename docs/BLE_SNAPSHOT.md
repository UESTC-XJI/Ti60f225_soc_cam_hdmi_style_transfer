# BLE 控制 + 图传（2026-10-29）

> 状态：**构建全 PASS；2026-10-29 已上板：位流 + 固件均易失加载成功，app 主循环在跑
> （metrics 增长、trap=0、摄像头/DDR/风格自检错误 0）。HDMI 画面与 BLE 链路待用户目视确认。**

## 1. 为什么不用 SoC UART1

10-26 的 redsky 方案在 SoC 里开第二路 `system_uart_1_io`。本项目**不能**这么做：

- 现有 `soc.v` 由 **efx_ipmgr 2025.2.288.3.8** 生成（本机只装了 Efinity 2026.1）；
- 用 2026.1 重新生成同配置 SoC，端口表能对上（163 个），但网表 **FF +1,450**，PnR 放置从 59,503 涨到 **60,550（99.59%）**，净亏 1,047 XLR；
- 实测后已全部回退。

所以改用**复用 UART0**：把 UART0 的引脚从调试口 `GPIOL_02/GPIOR_28` 改到 BLE 口
`GPIOL_06/GPIOR_13`，波特率 128000，固件把调试打印全部编译掉。**SoC 一行没动，0 额外 XLR。**

## 2. 引脚（3.3 V LVCMOS）

| 功能 | 顶层端口 | 引脚 | 方向 |
|---|---|---|---|
| BLE RX（模块→FPGA） | `system_uart_0_io_rxd` | **GPIOL_06** (C3) | input，weak pullup |
| BLE TX（FPGA→模块） | `system_uart_0_io_txd` | **GPIOR_13** (A12) | output |
| 旋钮 SW1/SW2 | `io_sw1/io_sw2` | GPIOL_04 / GPIOL_10 | input |
| 面板按键 | `panel_key` | GPIOR_22 | input |

> ⚠ 10-24 的 `USER_IO_UART_ENCODER.md` 写的是 TX=GPIOL_06 / RX=GPIOR_13，与 10-26 的
> BLE 文档相反；本实现按 10-26 的（RX=GPIOL_06、TX=GPIOR_13）。**上板若收不到数据，
> 先把 `ti60f225_oob.peri.xml` 里这两行的 `gpio_def` 对调**再试。

## 3. 协议（UART0，128000 8N1）

命令（ASCII 行，`\n` / 50 ms 空闲 / 64 字节结束）：

| 命令 | 作用 | 回复 |
|---|---|---|
| `STATE` | 查询状态 | `KNOB,<0..3>`、`BANK,<k>,<名>`、`RATE,<B/s>` |
| `KNOB,<0..3>` | 按物理旋钮映射切风格 | `KNOB,n`、`BANK,k,name` |
| `RATE` / `RATE,<B/s>` | 读/设输出限速 200–12800 | `RATE,n` |
| `SNAP[,<w>[,<q>[,<win>]]]` | 拍一张风格结果，w=160/320（默认 320），q=1..100（默认 60），win=1..8 | `IMG,<w>,<h>,<bytes>,<crc32>,<packets>` 后跟数据包，最后 `IMG,END` |
| `ACK,<n>` / `NAK,<n>` / `ABORT` | 图传确认/重传/中止 | — |

图片数据包：`A5 5A seq(u16 LE) len(u8) payload[len] crc16(u16 LE)`，crc16 = CRC-16/CCITT-FALSE。

**限速**：BLE 模块没有流控，输出队列默认按 **1500 B/s** 排空（`QSE_BLE_RATE`，**这是 10-26 的板测保守值，不是模块上限**；`RATE,<n>` 可实时调到 12800）。
UART 本身是 128000 baud（≈12.8 KB/s）。按 1500 B/s，一张 320×240、q60 的 JPEG（约 8–15 KB）需
**5–10 秒**；用 `SNAP,160,50` 预览约 2–4 秒。实际吞吐与是否丢字节**必须上板实测**。

## 4. 数据来源

- 风格结果帧在 DDR：`0x05000000 + slot*0x140000 + 0x00800000`，**320×240，每像素 32 bit，
  stride 320 words**，R=bit[7:0]、G=[15:8]、B=[23:16]。
- 当前显示 slot 从 style APB **0x88** 回读：`{bit31=1, bit27:4=0, bit3=valid, bit2:0=slot}`。
  截图前后各读一次，slot 变了就报 `IMG,ERR,MOVED`。
- 截图期间固件清 `regs[1].bit4` 暂停 CNN，等引擎空闲 + 50 ms 再拷，拷完恢复。

## 5. 构建

```bash
# 固件（会生成 build/soc_video_app.elf）
SOC_RISCV_TOOLCHAIN=/g/Efinity/efinity-riscv-ide-2026.1/toolchain/bin \
  bash tools/build_firmware.sh

# 位流
python ~/.claude/skills/efinity/scripts/efx.py build ti60f225_cam_hdmi.xml -f compile
python tools/build_check.py
```

手机端：`tools/ble_web/`（`serve.py` 起本地页面，浏览器 Web Bluetooth 连接 BLE 模块）。

## 6. 改动清单

| 文件 | 改动 |
|---|---|
| `rtl/style/style_video_system.sv` | APB 0x88 slot 回读（+6 LUT / −10 FF，≈0 XLR） |
| `ti60f225_oob.peri.xml` | UART0 引脚改 GPIOL_06/GPIOR_13；RX 加弱上拉 |
| `software/firmware/qse_ble.c/h` | 新：UART0 传输层 + 命令解析 + 限速队列（裁剪版，无 GPIO/OSD） |
| `software/firmware/qse_imgtx.c/h` | 新：快照拷贝（源尺寸改 320×240）+ 分包重传 |
| `software/firmware/qse_jpeg.c/h` | 新：基线 JPEG 编码器 |
| `software/firmware/style_driver.c/h` | 加 `style_stream_set` / `style_busy` / `style_display_slot` |
| `software/firmware/main.c` | 去 UART 日志；初始化并轮询 BLE；去掉串口单字符命令 |
| `software/bsp/.../bsp.h` | `BLE_SILENT_UART` 下把 `uart_writeStr`/`bsp_putChar` 编译成空 |
| `tools/build_firmware.sh` | 加 `-DBLE_SILENT_UART` 和三个新源文件 |

## 7. 未验证项（无板）

1. **引脚方向**（RX/TX 是否与模块交叉）——最可能的出错点，见上面的对调方法。
2. BLE 模块的波特率/协议是否与 10-26 一致。
3. 32 bit/px 的 DDR 帧格式与 JPEG 颜色是否正确（R/B 是否互换）。
4. `SNAP` 全流程耗时、重传窗口与 1500 B/s 限速的配合。
5. 限速下 BLE 模块是否仍会丢字节（默认 1500 是 10-26 的板测值）。

## 8. 本轮构建结果（2026-10-29 10:11）

| 项 | 值 |
|---|---|
| XLR | **59,486 / 60,800（97.84%）**，RAM 202，DSP 147 |
| 时序 | vid_clk_dvi2 **+0.190 ns**、core_clk +2.419 ns |
| 裁决 | `tools/build_check.py` = **USABLE** |
| 位流 | `outflow/ti60f225_oob.bit`，md5 `d3dac97845320f3628059bffdc2da1c1`（3,192,180 B） |
| 固件 | `software/firmware/build/soc_video_app.elf`，md5 `e7dbde890fce1beb257664c02524f7ca`，text 93,988 B |
| 离线验证 | JPEG 编码器主机编译 + PIL 解码通过（320×240、4:2:0、300 MCU、SOI/EOI 正确） |

## 9. 上板 checklist（板子回来 2 小时内）

1. **盲刷前**：确认手边有回滚位流（见 §10），并且知道 UART0 现在是 BLE 协议口——**没有调试控制台**。
2. JTAG 烧 `outflow/ti60f225_oob.bit`（md5 `d3dac978…`）+ `software/firmware/build/soc_video_app.elf`（md5 `e7dbde89…`）。
3. 先验主链路：HDMI 出图、旋钮 G1/G2/G3 切换、屏上 FPS 叠加。**这一步不通过就不要碰 BLE**，直接用 §10 回滚。
4. 手机 Web Bluetooth 连模块：
   - 收到 `BOOT,1` → 链路通；发 `STATE` 应回 `KNOB/BANK/RATE`。
   - **收不到任何字节 → 先怀疑 RX/TX 方向**，按 §2 对调 `gpio_def` 重编（一次完整构建 ~13 分钟）。
5. 发 `SNAP,160,50` 做快速预览（160×120，传输约 2–4 s），通了再试 `SNAP,320,60`。
6. 看图颜色：和 HDMI 风格半屏比对；若不一致，记下差异（R/B 反还是整体偏色）。

## 10. 回滚预案（10 分钟内回到"能出图"的上一版）

| 件 | 位置 | md5 |
|---|---|---|
| 上一版可用位流（10-28 30fps，无 BLE，UART0=调试口） | `backup/tier1_status_diag_20261029/ti60f225_oob_350eb510.bit` | `350eb5105972bfc5cd89779a16669992` |
| 对应固件 | 交付包 `deliverable/starry30_q_20261028/artifacts/soc_video_app_starry30_knob4_20261028.elf` | `eae55f8bbbbe21dcd8f3841737698235` |

回滚步骤：JTAG 烧上面两颗 → 上电 → 串口应回到 115200 的 `CAP/NN` 日志。
如果连 JTAG 都连不上：用 Efinity Programmer 的 "SPI Active using JTAG Bridge" 重刷 flash 里的 `.hex`（完整 app 在 0x380000）。

> **冻结约定**：本 BLE 演示位流（XLR 97.84%）不再合入任何 RTL 改动；后续功能走独立分支、独立 PnR。改 RTL 前先看 XLR 余量，**余量 <500 不合**。

## 11. 2026-10-29 首次上板记录（易失加载）

**位流**：`efx_run.bat ti60f225_cam_hdmi.xml -f program --pgm_opts mode=jtag` → `Device ID 0x10660A79`。
**固件**：OpenOCD `load_image <build/soc_video_app.bin> 0x1000 bin`（94000 B / 9.08 s），
然后**必须** `reset halt`（只复位 CPU、DDR 保留）→ `reg pc 0x1000` → `resume`；
直接 resume 会执行 I-cache 里的旧 app（bss 不清、PC 回 0）。

**实测**：`app_metrics_updates` 持续增长、`firmware_trap_cause=0`、`app_camera_errors/app_ddr_errors/app_style_* = 0`。

**坑**：
- `efx_run -f program` 默认走 **SPI Active**（直连 flash），在这块板的 FT4232H 上读不到 flash；要用 **`mode=jtag`（易失）** 或 **`mode=jtag_bridge`（写 flash）**。
- 杀掉 OpenOCD/GDB 后 FTDI MPSSE 会卡死（`mpsse_flush` 无进展）；先 `taskkill /F /IM openocd.exe`，不行再拔插 USB。
- 位流与固件都是**易失**的，掉电回 flash 旧版。

## 12. 回归事故：删诊断模块 → AE 停摆 → 13 fps（2026-10-29）

**现象**：第一刀（删 `video_status_counters`/`video_frame_diagnostics`）后上板，屏显 FPS 13，
引擎实测 12.6 帧/s；`app_3a.status=2`（EXPOSURE_WAIT）、`ae_updates=0`、曝光冻结在 7103。

**因果链**：AE 的曝光更新以 `VIDEO_SENSOR_FRAME`（APB 0x0e0，= `video_apb_ctrl.raw_frames`）为帧边界门控；
`raw_frames` 由 `raw_event` 递增。诊断模块删掉后 `raw_event` 被接成 `1'b0` → 帧号永不前进 →
AE 永远等不到"下一帧" → 曝光不再更新 → 传感器停在长曝光 → 13 fps。

**修复**：只补回 raw VS 的边沿检测（pclk 域 toggle → core_clk 两级同步 → 脉冲），不恢复整个诊断模块。
代价 **+164 XLR**（其中大头是把原本被常量剪掉的 32 位 `raw_frames` 计数器重新激活）。
修复后：`status=1`、`ae_updates=13`、**28.2 fps**。

**机器检查（必须遵守）**：任何删"诊断/统计"模块的动作，先 grep 消费者：
```bash
grep -rn "raw_event\|VIDEO_SENSOR_FRAME\|raw_frames" rtl/ software/firmware/
```
`VIDEO_SENSOR_FRAME` 是 AE 的功能依赖，不是调试信息。

## 13. 31 fps 的测量口径（对外必须带这句）

- **口径**：板上实测，屏上 FPS 叠加读数（style_irq 1 s 窗口），用户目视 31；
  同时 JTAG 读引擎计数 `app_style_inferred` 约为 28–29/s（读数期间 CPU 被 halt，计数偏低）。
- **对应产物**：位流 `8ed79a95…`（AE 修复版）、固件 `e7dbde89…`。
- **对应 PnR**：XLR 59,650 / 60,800（98.11%），
  `vid_clk_dvi2` **+0.015 ns**（约束 148.5 MHz）、`core_clk` +1.714 ns，`build_check = USABLE`。
- 这是**实测帧率**，不是约束频率换算；对外报 31fps 时同时注明 vid slack 余量很薄（+0.015），
  交付前需要重跑 PnR 换放置。

## 14. 快照颜色发花：DDR 编码契约不一致（2026-10-29，已修）

**现象**：BLE 链路通、`IMG` 头 CRC 全过、`IMG,END` 正常，但 JPEG 每通道最高位被翻转——
画面发花、颜色全错。**不是链路问题，不是 MIPI/DDR/显示缺陷。**

**根因**：两套工程的风格结果槽编码约定不同。

| | `worktree-auto-resume-fw`（10-25） | 本工程 |
|---|---|---|
| 写 DDR | `wr_pixel ^ 0x808080` | 相同 |
| 读回（`style_axi_rows`） | **再 XOR 一次** | **不 XOR** |
| 显示 | 又 XOR 一次（抵消） | XOR 一次 |
| DDR 里存的 | 屏上值 | **屏上值 ^ 0x808080** |

`qse_imgtx.c` 的拷贝循环两份逐字节相同、不 XOR，所以复制过来后在验证工程里正确、在本工程上翻色。

**修复**（`software/firmware/qse_imgtx.c::copy_rows`）：读像素时补
`uint32_t v = p[sx] ^ 0x00808080u;`。契约见 `docs/BLE_BRINGUP.md` §5——
**任何直接读风格结果槽的消费者必须自己 XOR 一次**。

**验证**：构建 PASS（header↔bin 逐字节一致、`weights XOR` 实算一致、Q beat `(37,129,127)`）；
板上自检 `selftest=0 / errors=0`，引擎 `inferred` 递增；用户目视确认 HDMI 与 BLE 快照均正常。

**本轮产物**：位流 `8ed79a95…` + 固件 `e33708e9…`
（含星空 `starry_xxg640_v2_sn_dc`：XOR `0x9277287c`，L11 bias `-443/12673/17511`，
DC 目标 R−51.6 / G−35.6 / B−17.6 用**原版** `starry_night.jpg`）。
回滚锚点：`backup/weights_rollback_20261029/`。
