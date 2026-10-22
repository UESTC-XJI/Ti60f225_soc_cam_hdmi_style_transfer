# 烧录记录 2026-10-20（含 selective adoption 后的新 bit）

## 烧录物

| 项 | 值 |
|---|---|
| bit | `outflow_check/ti60f225_oob.bit` |
| bit SHA256 | `64043297381f2cea6fcfe793b0f5d1d9761120fe8a08f1379d8cd873e9be0da7` |
| bit 大小 | 3,225,249 B |
| 固件 | `reports/style_demo/flicker_diagnostics/soc_video_app.bin` |
| 固件大小 | 44,624 B |
| 固件 SHA256 | `da10c166d5787454f57ae919ad67ddc987f50bb518f69eb813f0618c05bdd713` |
| 配套 ELF | `release_display_deadline/soc_video_app.elf` = `3f8325dec3710cc9714be51a62c61220d3f6f840c5107f4d45adcd9dab3800f2`（与 skill 记录一致） |

## 结果（全部 PASS）

| 阶段 | 证据 |
|---|---|
| JTAG 链 | `Found 1 devices in chain` / `0x10660a79 (Ti60)` |
| bit 烧录 | `Connecting to JTAG_TAP: efx_ti` → `finished with JTAG programming` |
| 固件加载 | `44624 bytes written at address 0x00001000` |
| 落盘校验 | `0x00001000: 30047073`（csrrw，合法 RISC-V） |
| CPU | `running` |
| 串口 | `DISP 60`、`ERR 0`、`CSI 0`、`AXI 0` |

## 与 skill 记录的差异（本机当前枚举）

| 项 | skill 记录 | 本机实测 |
|---|---|---|
| **FTDI URL** | `ftdi://0x0403:0x6011:1:4/2` | **`ftdi://0x0403:0x6011:3:3/2`** |
| **串口** | COM18 / COM17 | **COM11 / COM12**（COM12 无输出，日志在 **COM11**） |

skill 的 URL 在本机报 `Specified FTDI URL could not be matched`；
用 `--scan_usb` 得到设备 `{vid:0x0403, pid:0x6011, idcode:0x10660a79}`，
再试 `3:3/2` 形式成功。

## 串口输出样本（COM11，115200 8N1）

```
MONET CAP 12 NN 13 DISP 60 DROP 3077 MS 77 ERR 0
3A state 1 exp 1206 vts 1500 mean 102 hot 8 goal 96 hold 1 R 267 B 436 AE 26 AWB 58 code 0 req 0 rb 1206 err 0
DDR100M T 101801399 AR 23 DOWN 0 RGAP 16 RBP 0 DBP 0 AW 0 W 1 B 0 IDLE 0 RB 13471488 DRB 4694496 RPMS 45 CPMS 31
VIDEO UF 0 DUF 0 DDROP 18 FAULT 0 CSI 0 DME 0 IERR 0 AXI 0
```

- `DISP 60` → 720p60 显示在跑
- `ERR 0` / `CSI 0` / `AXI 0` / `FAULT 0` → 无错误
- `CAP 12 NN 13` → 采集与 CNN 任务在跑
- `3A exp 1206 mean 102` → AE 闭环有响应

## 收尾

- OpenOCD 已退出（JTAG 已释放）
- 临时脚本已清理

## 注意

⚠️ **HDMI 输出侧仍无 +5V**（本工作区已定位的硬件问题，见 skill 第 8 节）：
pin18 实测 3.3V，采集卡依赖该 5V 判源端 → 可能仍不出画面。
**本次烧录只验证了 FPGA/固件链路正常，不代表 HDMI 可被采集卡捕获。**
