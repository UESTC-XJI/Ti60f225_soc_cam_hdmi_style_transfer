# Ti60F225 实时 AI 风格化视频（SC431HAI → CNN → HDMI）

易灵思 Titanium Ti60F225 上的端到端风格迁移演示：摄像头 RAW → debayer/ISP → 640×480 风格网络（行缓冲全流水）→ 720p60 HDMI 输出。

- 网络：12 层 int8 卷积（3×3 / 1×1），权重编译进固件
- 显示：720p60，显示与网络共享 DDR3，按 burst 公平仲裁
- 控制：Sapphire RISC-V 软核跑 3A（软件 AE/AWB）、统计与 UART 日志

## 实板实测

| 指标 | 数值 | 口径 |
|---|---|---|
| 风格化帧率 | **17.2 fps**（`MS 57–58`） | 640×480，实板，≥15fps 达标 |
| 显示 | 720p60 | `UF/DUF 0`，无 underflow |
| 逻辑 | XLR **59,057 / 60,800**（97.13%） | PnR 后 |
| RAM / DSP | **244** / **147** | PnR 后 |
| 视频时钟 slack | **+0.192 ns** | I3 时序模型 |
| 3A | `exp 4989 / vts 2500 / err 0` | 暗部细节可辨 |

## 仓库结构

```
rtl/           RTL 源码（rowpipe 网络、采集/显示、SoC 集成、DDR 仲裁）
soc/           Efinity Sapphire SoC（RISC-V 子系统）
software/      BSP + 固件（C）
  firmware/    3A、风格驱动、视频驱动
tests/         ModelSim 测试平台
tools/         构建与校验脚本
docs/          模块说明与集成记录
model/         权重 blob 与导出头文件
artifacts/     已验证的位流 + ELF
ti60f225_cam_hdmi.xml    Efinity 工程（相对路径，直接打开）
ti60f225_oob.peri.xml    SoC 外设定义
ti60f225_oob.sdc         时序约束
```

## 构建

**位流**（Efinity 2026.1，`efx_run_*` 脚本）：

```bash
efx_run_map.py  ti60f225_oob --family Titanium --device Ti60F225 \
    --project_xml ti60f225_cam_hdmi.xml --output_dir outflow --work_dir work_syn \
    --opt root=ti60f225_oob_top --opt veri_options=verilog_mode=sv_09,vhdl_mode=vhdl_2008
efx_run_pt_unified.py ti60f225_oob Titanium Ti60F225 --output_dir outflow --timing_model I3 \
    --project_xml ti60f225_cam_hdmi.xml
efx_run_pnr.py  ti60f225_oob --prj ti60f225_cam_hdmi.xml --family Titanium --device Ti60F225 \
    --timing_model I3 --output_dir outflow --work_dir work_pnr \
    --opt sdc_file=ti60f225_oob.sdc
efx_run_pgm.py  ti60f225_oob --family Titanium --device Ti60F225 --output_dir outflow \
    --work_dir work_pnr --opt mode=active width=1 enable_roms=on spi_low_power_mode=on \
    io_weak_pullup=on oscillator_clock_divider=DIV8 enable_crc_check=on \
    bitstream_compression=on active_capture_clk_edge=posedge release_tri_then_reset=on \
    enable_external_master_clock=off jtag_usercode=0xFFFFFFFF
```

> 工程必须整个放在 Efinity 可访问的路径内；把单个源文件放到工程外会让 `efx_map` 失败。

**固件**（RISC-V 工具链，Efinity 自带）：

```bash
SOC_RISCV_TOOLCHAIN=/path/to/efinity-riscv-ide/toolchain/bin python tools/build_firmware.py
# 产出 software/firmware/build/soc_video_app.elf
```

## 运行

1. 烧 `artifacts/ti60f225_cap8_fps_fair.bit`；
2. 通过 JTAG 下载 `artifacts/soc_video_app_cap8_ae_crop_goal128_vts2500_max4989.elf`；
3. UART 115200 8N1 观察每秒一行的 3A / 帧率 / DDR 统计。

**位流与 ELF 必须配套使用**，md5：

```
848717a2fa1c691ad323a7f8d215bfd3  ti60f225_cap8_fps_fair.bit
e9f7e5e4af27a60937461f4ad4db36d5  soc_video_app_..._vts2500_max4989.elf
```

相机在 `VTS=2500`（约 18fps）下跑，AE 曝光上限 4989 半行。改 VTS 后必须重验 UART 的 3A 行。

## 已知问题

- `OSD metrics COMMIT timeout` 每秒一次：文本 OSD 已从设计中移除，固件仍在等 ACK；不影响画面，`DISP` 字段因此恒为 0。
- 显示与网络共享 DDR，网络帧率受仲裁参数影响；`rtl/style/style_video_system.sv` 中 `URGENT_OVERRIDES_FAIRNESS` / `RESERVE_URGENT_READ` 为帧率关键开关。

## 说明

Efinix Sapphire SoC / BSP 归 Efinix 所有，随其 SDK 发行；本项目其余部分为竞赛作品源码。
