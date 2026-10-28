# Ti60F225 FPGA 烧录与 SoC 固件下载

适用于本工程、Windows PowerShell、Efinity 2026.1 和 Efinity RISC-V IDE 2026.1。

运行顺序：**板卡上电 → JTAG 配置 FPGA → 释放 Programmer 的 JTAG 连接 → 下载配套 ELF → Resume/F8 运行**。FPGA 配置完成并锁定时钟后显示 720p 彩条；CPU 成功初始化摄像头和 OSD 后切换到摄像头画面。

2026-10-09 用户已实板恢复RAW/RESIZE30并确认AE工作，UART可见AE/AWB更新且无错误。最新固件针对小高光光源下的曝光抽动与响应速度，验证记录见 `reports/software_3a_ae_tuning/README.md`；此调整待实板确认。曾出现只热重载ELF导致视频fault锁存，更新时按先停止IDE、重配原bit、再加载新ELF的顺序执行一次。

同日SoC清理已完成：旧硬件AE/I²C和无效OSD链移除，修复文字使能同步并在帧边界生效。新硬件`reports/soc_cleanup/soc_cleanup.bit`已完成全部编译与时序检查，详细记录见[清理版产物](reports/soc_cleanup/README.md)。此RTL修复须配置新bit；配套ELF仍是上一轮AE调整固件，实板待验证。

## 1. 选择配套文件

默认使用最新的 **统一 APB / 软件 AE/AWB 版**，包含启动彩条、RAW/RESIZE诊断及原始直方图快照。实现与运行状态见 [实现说明](docs/VIDEO_3A_IMPLEMENTATION.md)，产物校验值与测试记录见 [配套产物](reports/software_3a/README.md)。

| 版本 | FPGA bitstream | CPU 固件 ELF | 运行后的统计文字 |
| --- | --- | --- | --- |
| SoC清理版（推荐，含文字使能修复、I²C修复及AE调整） | `reports/soc_cleanup/soc_cleanup.bit` | `reports/soc_cleanup/soc_video_app.elf` | `RAW / RESIZE / DISP / DROP / ERR`，UART另有3A状态 |
| 统一 APB / AE/AWB 版（历史） | `reports/software_3a/software_3a.bit` | `reports/software_3a_ae_tuning/soc_video_app.elf` | 同上；未包含文字使能修复 |
| RAW/RESIZE 诊断版（历史） | `reports/raw_resize/raw_resize.bit` | `reports/raw_resize/soc_video_app.elf` | `RAW / RESIZE / DISP / DROP / ERR` |
| 早期启动彩条版 | `reports/startup_colorbar/startup_colorbar.bit` | `reports/startup_colorbar/soc_video_app.elf` | `FPS / DISP / DROP / ERR` |

**必须使用同一行的 bitstream 与 ELF。** 旧固件不写 `VIDEO_READY`，搭配彩条版 bitstream 会一直显示彩条；新的诊断固件也需要支持 RAW/RESIZE 寄存器的 bitstream。

`.bit` 配置 FPGA；`.elf` 包含 CPU 程序、加载地址和调试符号，下载到 DDR。IDE/GDB 选择 `.elf`。同目录 `.bin` 是原始程序数据，起始加载地址为 `0x1000`，不是 Flash 启动镜像。

软件 AE 默认在真实 ID/VTS/I²C 检查通过后启用；AWB默认自动，`app_awb_mode`=0固定/1自动/2锁定。UART每秒打印 `3A state ... exp ... vts ... mean ... hot ... goal ... hold ... R ... B ... AE ... AWB ... code ... req ... rb ... err ...`；状态和计数也可在IDE查看 `app_3a`。`app_hist_enable`=1可开启非阻塞快照读取，默认0。VTS/PLL保持不变。

## 2. 接线与工作目录

1. 连接摄像头、HDMI 显示器、板卡电源和板载 JTAG USB，保持板卡供电。
2. 启动前终止 IDE 中旧的调试会话，释放其 OpenOCD；Programmer、EDB 和 OpenOCD 不要同时占用 JTAG。
3. 在 PowerShell 中进入工程根目录。后续各 PowerShell 窗口均使用这个目录：

```powershell
Set-Location 'C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim'
```

检查当前在线 FTDI 设备：

```powershell
Get-PnpDevice -PresentOnly |
    Where-Object { $_.InstanceId -match 'VID_0403&PID_6011' } |
    Format-Table Status,Class,FriendlyName,InstanceId -AutoSize
```

本板 JTAG 使用 FT4232H **channel 1 / Interface 1 / MI_01**，USB VID/PID 为 `0403:6011`。此前该接口使用 `libusb-win32`，其余接口提供串口。无输出表示 FTDI 当前未在线，先恢复 USB 连接。

串口使用 **115200，8 数据位，无校验，1 停止位，无流控**。此前应用输出端口是 **COM4**，重新插拔后端口号可能改变。可用设备管理器核对；在 CPU 开始运行前打开串口终端，以便看到启动日志。

## 3. 烧录 FPGA bitstream

### Efinity Programmer 图形界面

1. 打开 Efinity Programmer，选择 Ti60F225 板卡的 JTAG 接口。
2. 选择 **JTAG 配置模式**，添加 `reports/software_3a/software_3a.bit`。
3. 执行 Program，确认 Programmer 报告配置成功。不要只凭窗口关闭或命令返回码判断成功。
4. 时钟锁定后应显示 1280×720 / 60 Hz 八色彩条。此时未下载应用，彩条属于预期行为。
5. 等待 DDR 校准完成，再连接 CPU 调试。**彩条出现不代表 DDR 已校准**，彩条发生器不依赖 DDR；有监测条件时检查 `cal_done`。
6. 断开或关闭 Programmer/EDB 的 JTAG 连接，释放 FTDI；保持板卡供电，保留 FPGA 已加载的配置。

### PowerShell 命令行

先关闭其他占用 JTAG 的程序，然后在工程根目录执行：

```powershell
& 'C:/Efinity/2026.1/pgm/bin/ftdi_pgm.bat' `
    'reports/software_3a/software_3a.bit' `
    -m jtag `
    -u 'ftdi://0x0403:0x6011:0:2/1' `
    --jtag_clock_freq 1000000
```

该 URL 对应本次板卡的 FTDI 设备与 channel 1；有多块 FTDI 板卡时应先用 Programmer 确认目标设备。若使用早期彩条版，仅将 bitstream 路径改为 `reports/startup_colorbar/startup_colorbar.bit`，后续 ELF 也切换到同目录版本。

遇到 `No USB target detected` 即未完成烧录；本机曾出现工具返回码为 0、实际日志却报告该错误的情况。

## 4. 下载固件：IDE 方式

1. 打开 **Efinity RISC-V IDE 2026.1**。
2. **File → Import → General → Existing Projects into Workspace**，选择工程下的 `software/firmware`，导入项目 `soc_video_app`。不勾选 **Copy projects into workspace**，保留 BSP/tools 的相对路径。
3. **Run → Debug Configurations → GDB OpenOCD Debugging**，选择共享配置 `soc_video_app_ti`。若未出现，通过 **File → Import → Run/Debug → Launch Configurations** 导入 `software/firmware/soc_video_app_ti.launch`。
4. Main 页 Project 选择 `soc_video_app`。为了下载本文保存的 I²C 修复版，在 **C/C++ Application** 中 Browse 选择工程下的 **`reports/software_3a_i2c_fix/soc_video_app.elf`**；关闭该配置的下载前自动构建。共享 launch 默认是 `build/soc_video_app.elf`，不会自动选择 reports 中的保存版本。
5. 核对以下配置，点击 Apply：

| 项目 | 值 |
| --- | --- |
| OpenOCD 配置文件 | `software/firmware/openocd/soc_video.cfg` |
| GDB executable | `C:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin/riscv-none-elf-gdb.exe` |
| OpenOCD executable | `C:/Efinity/efinity-riscv-ide-2026.1/openocd/bin/openocd.exe` |
| IDE GDB / Tcl / Telnet 端口 | `13333 / 16666 / 14444` |
| IDE GDB 主机地址 | `127.0.0.1`（共享 launch 已设置） |
| Startup 初始化命令 | `monitor reset halt` |
| Startup 运行命令 | `set $pc = _start` |
| Stop at | `*main` |
| GDB 初始化命令 | `set riscv use-compressed-breakpoints no` |

配置使用项目配套的 `cpu0.yaml`、native VexRiscv 调试接口、USER1、JTAG 800 kHz、readWaitCycles 40；无需切换为标准 RISC-V DMI。下载后不再复位整块 FPGA。

6. 点击 **Debug**。预期流程为 CPU reset/halt → 下载 ELF 和符号 → 设置 `_start` → 临时断点停在 `main`。
7. **停在 main 不等于程序已经运行。点击 Resume 或按 F8**，开始摄像头初始化。
8. 查看串口及 HDMI。摄像头、DDR 和 OSD 初始化成功后，彩条切换成摄像头画面；切换时显示器可能短暂重新锁定。

若需要从当前源码重新构建，执行第 7 节的构建步骤，再将 Application 改回 `software/firmware/build/soc_video_app.elf`，并使用同次 RTL 构建的 bitstream。

## 5. 下载固件：命令行方式

此方式与 IDE 二选一。先退出 IDE 调试会话及 Programmer 的 JTAG 连接。

**PowerShell 窗口 A**：启动 OpenOCD，保持该窗口运行。

```powershell
& 'C:/Efinity/efinity-riscv-ide-2026.1/openocd/bin/openocd.exe' `
    -f 'software/firmware/openocd/soc_video.cfg'
```

正常连接应看到 FPGA ID `0x10660a79`、`Target successfully examined` 及 GDB 监听端口。命令行默认端口是 **3333 / 6666 / 4444**，与 IDE 端口不同。

**PowerShell 窗口 B**：使用配套 ELF 和现有下载脚本。

```powershell
& 'C:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin/riscv-none-elf-gdb.exe' `
    'reports/software_3a_i2c_fix/soc_video_app.elf' `
    -x 'software/firmware/openocd/download.gdb'
```

脚本已经包含 `target extended-remote localhost:3333`、`monitor reset halt`、`load`、设置 PC 为 `_start`，然后停在 `main`。在窗口 B 的 **`(gdb)` 提示符**输入：

```gdb
continue
```

需要观察寄存器或变量时，先在 GDB 中按 Ctrl+C 暂停，再运行第 6 节的检查命令；完成后输入 `continue` 恢复。

若想结束调试并让程序继续运行，在 GDB 暂停状态下执行：

```gdb
detach
quit
```

随后在窗口 A 按 Ctrl+C 退出 OpenOCD，释放 JTAG。不要将 PowerShell 命令输入 GDB Console，也不要将 GDB 命令直接输入 PowerShell。

## 6. 确认程序运行

诊断版正常启动的 UART 日志应包含：

```text
SOC VIDEO boot
DDR scratch PASS
Camera CD6B initialized
HELLO SOC
RAW n RESIZE n DISP n DROP n ERR n
```

`HELLO SOC` 可能很快被每秒统计覆盖。启动至少两秒后观察多个样本；`n` 表示实板测量值，不预设实际帧率。

| 现象 | 下一步 |
| --- | --- |
| FPGA 烧录后显示彩条 | 下载配套 ELF 并 Resume/F8 |
| 停在 main，仍显示彩条 | Resume/F8 运行程序 |
| `Camera ID/init FAIL` | 检查摄像头连接、供电和 I²C；固件每秒重试 |
| `DDR scratch FAIL` | 程序停在失败循环；检查 DDR 校准和访问 |
| `OSD initial COMMIT timeout` | 检查后台视频/OSD 帧同步和 ACK；首次失败不放行视频 |
| `RAW` 和 `RESIZE` 都低 | 优先检查摄像头模式、帧长和时钟 |
| `RAW` 持续明显高于 `RESIZE` | 检查 CSI/gearbox/Debayer/resize 路径 |

在 IDE 的 GDB Console，或命令行 `(gdb)` 中暂停 CPU 后可读取：

```gdb
p /u *(unsigned int *)0xf8100028
p /u *(unsigned int *)0xf810002c
p /u *(unsigned int *)0xf8100030
p app_metrics_updates
p app_ddr_errors
p app_camera_errors
p app_osd_errors
p /x firmware_trap_cause
p /x firmware_trap_pc
p /x firmware_trap_value
```

三个地址依次为 `VIDEO_READY`、`RAW_FPS`、`RESIZE_FPS`。就绪在初始化前为 0，成功后为 1；就绪为 1 仍需摄像头 VS 才能切换。正常运行时 metrics 持续增加，错误和异常记录应为 0。RAW/RESIZE 初始不足一秒时为 0，跨窗口可能相差一帧；早期彩条版不支持后两项寄存器。

## 7. 修改源码后的重新构建

在工程根目录执行，以下命令仅构建，不连接硬件：

```powershell
python tools/build_firmware.py
python tools/check_firmware_config.py
& 'C:/Efinity/2026.1/bin/efx_run.bat' `
    ti60f225_cam_hdmi.xml --flow compile --timeout 1200
```

对应输出为 `software/firmware/build/soc_video_app.elf` 和 `outflow/ti60f225_oob.bit`。修改 APB 地址、视频就绪协议或 FPGA/固件共同使用的接口时，重新构建并下载配套的两份文件。`reports` 中保存的版本不随源码构建自动更新。

## 8. 常见下载问题

### USB/FTDI 错误

`No USB target detected`、`no device found`、`ftdi device did not accept all data: 0, tried 60` 都应先检查在线 FTDI、供电、USB 数据线和 adapter 占用。初始找到 FPGA ID 并不保证后续 USB 连接仍有效。

1. 在 IDE Debug 视图终止失败会话，关闭 Programmer/EDB 的 JTAG 连接。
2. 保持板卡供电，重新插好 JTAG USB，重新运行在线设备检查。
3. 确认 `MI_01` 接口驱动正常。不要直接套用匹配 `PID_6010` 的旧 INF，也不要改动其他串口接口驱动。
4. 启动新的 OpenOCD 会话；掉线前的进程可能仍持有失效 USB handle。
5. FTDI 持续在线但仍失败时，可将 `soc_video.cfg` 中 `adapter speed 800` 临时改为 `adapter speed 200` 排查；USB 未枚举时降速无效。

若板卡已断电或 FPGA 配置丢失，先重新烧录 bitstream，再下载 ELF。

### 端口占用

IDE 使用 `13333/16666/14444`，命令行使用 `3333/6666/4444`。终止对应旧会话后重试。可检查监听进程，按 PID 确认所属程序再关闭：

```powershell
Get-NetTCPConnection -State Listen |
    Where-Object { $_.LocalPort -in 3333,6666,4444,13333,16666,14444 } |
    Select-Object LocalPort,OwningProcess
```

### GDB 连接 localhost:13333 报 error 138

2026-10-08 使用 IDE 自带 GDB 和仅绑定 IPv4 的本机模拟 RSP 服务复现：`target remote localhost:<port>` 报相同 error 138，`target remote 127.0.0.1:<port>` 正常完成协议握手和 detach。错误中的“系统试图将驱动器合并……”是本次 GDB 的错误文本，不应据此修改盘符、OneDrive 路径或 USB 驱动。共享 `soc_video_app_ti.launch` 已将主机地址改为 `127.0.0.1`；IDE 中刷新项目，核对 Debug Configurations → Debugger → Remote Target 的 Host name 为 `127.0.0.1`、Port 为 `13333`，Apply 后重试。

同时检查旧 OpenOCD：本次发现 PID 6760/33136 仍占用两组端口、Tcl 无响应，而 taskkill 报没有运行的实例。仅显示 Listen 不能证明服务可用，换一组端口也不能释放旧 USB 会话。先终止 IDE 中失败的会话；若进程无法结束，保持板卡独立供电，仅重新拔插 JTAG USB，再检查旧端口是否释放。若 JTAG USB 同时为板卡供电，应使用原有供电/恢复流程；断电会丢失 FPGA 配置。必要时重启 Windows 释放残留状态。本次未进行实板重连、烧录或 ELF 下载。

### IDE 提示 binary not found

确认已选择实际存在的 `.elf`；选中项目按 F5 刷新。使用 **GDB OpenOCD Debugging** 配置，Main 页 Project 为 `soc_video_app`，Application 通过 Browse 指向本次配套 ELF。选择 `.bin` 或本机 C/C++ Run 配置不能完成这里的 CPU 下载。

### 下载完成但不运行

先确认是否仍停在 `main`。重新下载时先执行 `monitor reset halt`，再 `load`、`set $pc = _start`；不要仅修改 PC 后重试。当前 CPU 没有压缩指令，保持 `set riscv use-compressed-breakpoints no`。

### 断电后需要重新下载

本文的 **JTAG 配置 FPGA + ELF 下载 DDR** 都不提供断电保留。当前 boot ROM 不包含这份应用。断电自动启动需要另行制作和验证 Flash 配置及固件启动镜像，不能直接把这里的 `.bin` 当作已完成的启动镜像。

详细固件行为见 `software/firmware/README.md`；版本、测试与硬件记录见 `INTEGRATION_LOG.md`。
