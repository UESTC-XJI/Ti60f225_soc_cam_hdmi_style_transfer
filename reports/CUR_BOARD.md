# 当前板子操作手册（CUR_BOARD）

> 最后更新：2026-10-22
> 本文是**上板操作的唯一权威指引**。历史过程见 `reports/archive/`。

---

## 一、烧什么（配对表，缺一不可）

| 组合 | bit | 固件 | 状态 |
|---|---|---|---|
| **ch24（可用）** | `outflow_panelsw2/ti60f225_oob.bit` | `demo/reports/ink/firmware/soc_video_app_v3.bin` | ✅ **已验证可用** |
| ch24（原基线） | `outflow_v3/ti60f225_oob.bit` | 同上 | ✅ 可用（无双面板按键） |
| ch12（剪枝） | `outflow_ch12/ti60f225_oob.bit` | 需 ch12 固件 | ❌ **自检失败** |

**⚠️ bit 与固件必须配对** —— 系数内嵌在固件二进制里（偏移 `0x4D4C`，6144 词）。

---

## 二、烧录步骤（每次都要重新枚举）

### 步骤 0：枚举设备（**JTAG URL 和 COM 每次插拔都会变**）

```bash
# JTAG
python "D:\Efinity\2026.1\pgm\bin\jtag_chain_detect.py"
# 输出示例：Scanning JTAG IDCODES at ftdi://0x0403:0x6011:1:4/2
#           Device 1.  0x10660a79 (Ti60)

# 串口
python -c "import serial.tools.list_ports as p;[print(x.device) for x in p.comports()]"
# 输出：COM13 / COM14（COM13 有输出）
```

### 步骤 1：烧 bit

```bash
call "D:\Efinity\2026.1\bin\setup.bat"
set EFINITY_USER_DIR=C:/Users/36040/.efinity
set EFINITY_USER_DIR_INI=C:/Users/36040/AppData/Local/Efinity/user_dir.ini
set PYTHONPATH=D:\Efinity\2026.1\debugger\bin;D:\Efinity\2026.1\pgm\bin
python "D:\Efinity\2026.1\pgm\bin\efx_pgm\ftdi_program.py" -m jtag ^
  -u "ftdi://0x0403:0x6011:1:4/2" --jtag_clock_freq 1000000 <bit路径>
```

**成功标志**：`Device ID read from JTAG: 0x10660A79` → `finished with JTAG programming`

### 步骤 2：载固件

```bash
# 先启动 OpenOCD（后台）
cd demo\software\firmware\openocd
"D:\Efinity\2026.1\debugger\openocd\bin\openocd.exe" ^
  -f "..\..\bsp\EfxSapphireSoc\openocd\ftdi_ti.cfg" ^
  -f "..\..\bsp\EfxSapphireSoc\openocd\debug_ti.cfg"
```

然后用 telnet 4444：
```
reset halt
load_image "<固件路径>" 0x1000 bin
mdw 0x1000 4          # 应为 30047073 30401073 0000b197 64818193
reg pc 0x00001000
resume
shutdown
```

**成功标志**：`44624 bytes written` + `fpga_spinal.cpu0 ... running`

### 步骤 3：读遥测（COM13, 115200）

**正常输出的 4 行**：
```
MONET CAP 11 NN 11 DISP 60 DROP ... MS 83 ERR 0
3A state 1 exp ... mean ... hot ... goal 96 ...
DDR100M T ... AR 35 DOWN 0 RGAP 19 ... DRB 9385408 RB 12641360 RPMS 41 CPMS 31
VIDEO UF 11 DUF 0 DDROP ... FAULT 4 CSI 0 DME 0 IERR 0 AXI 0
```

---

## 三、遥测判据（怎么判断正常/异常）

### ch24 双面板（基线）

| 指标 | 正常值 | 异常信号 |
|---|---|---|
| `NN` | **11** | 0 = 推理未跑 |
| `MS` | **83** | — |
| `DISP` | 60 | <60 = 显示异常 |
| `AR` | **35–36%** | **100% = 死锁** |
| `RGAP` | 19% | 0 = 没开始读 |
| `DRB` | **9,385,408** | **0 = 完全没读** |
| `RB` | 12,641,360 | **0 = 死锁** |
| `UF` | **≤14** | **>1000 = 严重欠载** |
| `ERR` | **0** | ≠0 = DDR/硬件错 |

### ch24 单面板（按 KEY1 切换后）

| 指标 | 正常值 |
|---|---|
| `NN` | **12–13** |
| `MS` | **79** |
| `AR` | **28%** |
| `DRB` | **4,693,888** |
| `UF` | **5** |

### APB 寄存器（深度诊断用）

基址 `0xF8100200`，16 个寄存器：

| 寄存器 | 偏移 | 含义 |
|---|---|---|
| `regs[0]` | `0x00` | 版本，应为 `0x3154534E` |
| `regs[2]` | `0x08` | `{coeff_idle,?,error_sticky,done_sticky,pending}` |
| `regs[7]` | `0x1C` | `last_cycles` |
| `regs[10]` | `0x28` | `coefficient_index` |
| `regs[12]` | `0x30` | `{acknowledged, issued}` |
| `regs[13]` | `0x34` | 148,500,000 |

---

## 四、⚠️ 常见故障与处置

| 症状 | 原因 | 处置 |
|---|---|---|
| **串口 0 输出** | 固件未载 或已崩 | 重读 `0x1000` 内存：应为 `30047073`；`ffffffff` = 固件丢失，需重载 |
| **PC = 0x12F0** | 自检失败死循环（`j 0x12F0`） | 读 APB 寄存器定位失败分支 |
| **`ERROR: No USB target detected`** | 板子掉线 | 重新插 USB，重新枚举 |
| **`AR=100%, RB=0, DRB=0`** | 仲裁死锁 | 只出现在 `UOF=0` 的 bit，烧回正常 bit |
| **`MS 84 + UF 暴增`** | 长 burst（240/256）饿死显示 | 烧回 `BURST_MAX=32` 的 bit |
| **固件重编后自检失败** | 头文件与 RTL 不同源 | 检查 `style_weights.h` vs `coeff.bin` 是否 6144/6144 |

---

## 五、关键路径速查

| 项 | 路径 |
|---|---|
| **可用 bit** | `Ti60f225.../outflow_panelsw2/ti60f225_oob.bit` |
| **可用固件** | `demo/reports/ink/firmware/soc_video_app_v3.bin` |
| **新架构工程** | `C:/Users/36040/Downloads/Ti60F225_DemoBoard_v4/Ti60f225_soc_cam_hdmi_style_transfer-feature-resource_optimize` |
| **编译命令** | `efx_run.bat ti60f225_cam_hdmi --prj -f compile --output_dir <dir>`（须经 `setup.bat`） |
| **固件编译** | `bash tools/build_firmware.sh`（工具链 `D:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin`） |
| **RTL 模型** | `rtl/style/model/{graph.json,coeff.bin,program.hex,style_weights.h}` |

---

## 六、编译检查清单（每次编 bit 前）

| # | 检查项 | 命令/位置 |
|---|---|---|
| **1** | `BURST_MAX=32` | `grep BURST_MAX rtl/style/style_network.sv` |
| **2** | **顶层显式传参**（不能靠默认值） | `rtl/ti60f225_oob_top.v` 的 `STYLE_BURST_MAX` |
| **3** | `STYLE_UOF=1'b1` | `rtl/ti60f225_oob_top.v` |
| **4** | `PAD_PITCH=0` | 同上 |
| **5** | 清缓存 | `rm -rf work_syn work_pnr` |
| **6** | 编译后查时序 | `grep sdram_clk outflow/ti60f225_oob.place.timing.rpt`（**不能为负**） |
| **7** | 查资源 | XLR < 60,800 · RAM < 256 |

**⚠️ 曾经踩过的坑**：
- `style_video_system` / `style_accel` 的**默认 `BURST_MAX` 是 240**，会静默覆盖 per-module 设置 → 必须顶层显式传参
- 中断编译留下的 `work_syn`/`work_pnr` 会污染下次编译 → 必须清

---

## 七、相关报告（未归档）

| 文件 | 内容 |
|---|---|
| [BOARD_WORKFLOW_20261021.md](ink/BOARD_WORKFLOW_20261021.md) | 完整上板流程 |
| [BOARD_VERIFICATION_CHECKLIST.md](ink/BOARD_VERIFICATION_CHECKLIST.md) | 验证清单 |
| [PANEL_SWITCH_VERIFIED.md](ink/PANEL_SWITCH_VERIFIED.md) | 按键切换实测 |
| [BOARD_RESULT_20261021.md](ink/BOARD_RESULT_20261021.md) | 基线遥测记录 |
| [BOARD_FAIL_BURST240.md](ink/BOARD_FAIL_BURST240.md) | 失败案例（长 burst） |
| [BOARD_FAIL_UOF_DEADLOCK.md](ink/BOARD_FAIL_UOF_DEADLOCK.md) | 失败案例（仲裁死锁） |
| [BOARD_FINAL_CONCLUSION.md](ink/BOARD_FINAL_CONCLUSION.md) | 结论汇总 |
