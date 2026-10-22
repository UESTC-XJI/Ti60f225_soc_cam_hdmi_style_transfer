# 完整 SoC 视频应用与下载

从板卡接线、FPGA 烧录到 ELF 下载和运行的完整步骤，见工程根目录 [README_PROGRAMMING.md](../../README_PROGRAMMING.md)。其中列出了保存版本的配套 bitstream/ELF，以及 IDE 与命令行两种下载方式。

下载文件：`build/soc_video_app.elf`。使用 BSP 实际 UART/I²C/CLINT 驱动，入口 `_start=0x1000`。旧 `work/soc_video_driver*.elf` 是只有摄像头函数入口的历史产物，不用于整机运行；新构建脚本只生成完整应用。

2026-10-09：ACK/RECOVER和延迟曝光确认修复已实板恢复RAW/RESIZE30，用户确认AE工作，UART显示AE/AWB均更新、code/err0。最新`reports/software_3a_ae_tuning/`针对小高光抽动：高光有限降低亮度目标、粗调加快、细调阻尼与滞回/连续统计确认；仿真通过，防抽动效果尚待实板验证，UART增加goal/hold。原`reports/software_3a_i2c_fix/`保留。若 RAW 有计数而 RESIZE=0、DROP=1、3A state=7，不要反复只重载 ELF：先重新配置当前配套bit清除视频fault，再加载最新ELF。进入 DDR 测试的 pass 循环两次是正常的两组数据模式。

同日推荐硬件已更新为`reports/soc_cleanup/soc_cleanup.bit`：清理旧AE/I²C/OSD链，修复动态文字使能CDC并在帧边界开关。统一APB接口兼容，软件算法未再修改，配套归档ELF在`reports/soc_cleanup/`且与本目录build完全一致。新bit完成编译/时序检查，实板效果待验证；旧bit仅用于历史回退。

## 应用行为

FPGA 配置完成、HDMI 时钟锁定后，输出独立的 1280×720 / 60 Hz 八色彩条（74.25 MHz，1650×750 总时序），不等待 DDR 校准或固件下载。新增 APB `VIDEO_READY` 寄存器 `0xf8100028`，bit 0 可读写，复位为 0；写 0 显示彩条，写 1 请求摄像头输出。固件进入 `main` 首先清零该寄存器，DDR 测试、摄像头初始化及 OSD COMMIT/ACK 成功后置 1；初始化失败保持彩条，后续恢复和 OSD 提交成功可重新放行。旧固件不会写该寄存器，需下载本版 ELF 才能切到摄像头。

RTL 在 HDMI 域同步就绪标志；观察到摄像头帧同步后，完成当前彩条帧，空白等待下一个摄像头 VS 再切入完整视频帧。两路时序相位独立，切换时显示器可能短暂重新锁定。CPU 系统复位或 DDR 就绪丢失会清零放行条件，返回彩条。彩条从输出端旁路 ISP/OSD，摄像头和 OSD 在后台继续初始化。

`start.S` 禁止中断、初始化 GP/SP、设置异常入口、同步 cache、处理数据段并清零 BSS 后进入 `main()`。程序异常时记录 `firmware_trap_cause/pc/value` 并停在 `trap_halt`，供 IDE 观察。

主程序初始化 UART 115200/8N1，在隔离 scratch DDR 前 64 KiB 执行两种地址相关模式的读写测试；初始化 100 kHz Sapphire I²C，等待 20 ms，验证 SC431HAI ID `0xCD6B` 并写入 165 项初始化表，然后提交 `HELLO SOC`。摄像头 ID/init 失败时每秒调用恢复。主循环轮询 CLINT，约1ms服务一次软件 AE/AWB，每秒异步提交 `RAW/RESIZE/DISP/DROP/ERR`；DDR 压测只在启动执行，避免周期性阻塞3A。无需定时器中断。

诊断文字中的 `RAW` 是 CSI 接收端原始 VS 下降沿频率；`RESIZE` 是 area resize 完成帧频；两者由不同源时钟域的事件同步后，在同一个 1 秒窗口锁存。`DISP` 仍是 CVO 显示帧频。新增只读寄存器：`0xf810002c`=`RAW_FPS`、`0xf8100030`=`RESIZE_FPS`；`0xf8100024` 保持原来的 `DISP_FPS:RESIZE_FPS` 兼容布局。

使用本版 bitstream 和 ELF 后，摄像头启动并运行至少 2 秒，查看屏幕或 COM4/115200 的连续数个样本。`RAW 10 RESIZE 10` 表示原始 CSI 帧率也低，应检查传感器时钟/帧长；`RAW 30 RESIZE 10` 表示原始帧边界频率较高，但有效帧未全部通过 gearbox/Debayer/resize，应检查接收错误及采集/缩放故障；`RAW 30 RESIZE 30` 表示两级帧率匹配。RAW 统计接收端 VS，不证明每帧像素完整；帧起始与帧完成跨越窗口边界时，两项可能相差 1，需观察持续差异。RESIZE 位于 DDR frame_buffer 之前，不能用它单独证明 DDR 或 HDMI 正常。

IDE 的 GDB Console 可直接读取以下地址（十进制值），无需新增调试探针：

```gdb
p /u *(unsigned int *)0xf810002c
p /u *(unsigned int *)0xf8100030
```

每秒窗口为 100 MHz core_clk 的 100,000,000 个周期，RAW/RESIZE/DISP 同拍更新，均以 16 位饱和到 65535。初始不足一秒时读回 0；CPU 读不同地址时若恰逢更新边界，可能取到相邻窗口，判断时应观察多个样本。当前版本在诊断基础上增加软件 AE/AWB：调整曝光与 RAW 数字gain，VTS/PLL保持初始化模式。

每次 OSD 更新写满非显示页的 80 个字符，短字符串尾部补空格。启动 COMMIT 等待 ACK 最长250ms；运行期改为非阻塞 submit/poll，250ms超时记录错误，busy时拒绝写页。正常提交的 UART 内容与字符页一致。`app_ddr_errors/app_camera_errors/app_metrics_updates` 可在 IDE 中查看。

## 统一统计与软件 AE/AWB

详见 [实现说明](../../docs/VIDEO_3A_IMPLEMENTATION.md)。新 bit/ELF 配套；默认启用软件 AE/AWB（需硬件 CAPS 与真实 VTS/I²C 检查通过）。`app_3a` 为 IDE 可见状态和更新计数，`app_awb_mode`=0固定校准/1自动/2锁定。曝光Group Hold、真实NACK/timeout、读回验证及保守N+2等待均在CPU执行。gain与筛选参数通过统一APB在RAW帧边界生效；AE/AWB同帧、同版本整包发布。

采集统计实际使用增益前RAW8和增益后RGB；64bin Y histogram可冻结读取。自动lift关闭、手动强度32；不修改传感器VTS/PLL，不承诺提高当前约12FPS。新功能未实板验证，历史3898字节固件的上板记录仅适用于旧版本。

## 构建与仿真

新增启动输出回归：`python tools/test_hdmi_startup.py`。验证两个完整 720p 帧的逐像素彩条和 HS/VS/DE、无摄像头同步时的彩条、CPU 就绪跨时钟域、帧边界切换、重新加载返回彩条，以及 APB ACCESS 写入/读回/清零/复位。`tools/test_firmware_runtime.py` 执行实际 RV32 ELF，额外检查就绪只能在摄像头初始化和 OSD ACK 后置位，DDR 错误或 ACK 超时保持 0。

帧率诊断回归：`python tools/test_video_frame_diagnostics.py`，涵盖三个异步源时钟、窄帧事件、resize 计数进位、复位/空闲、同窗独立帧率及 tick 边界/饱和，APB RAW_FPS/RESIZE_FPS 读回及只读保护。实际 ELF 仿真额外验证 OSD 页和 UART 输出 `RAW 30 RESIZE 9 DISP 60 DROP 0 ERR 0`，这里数值来自模型，不是实板测量。

从 Git 工作区根目录运行（当前安装为 Efinity RISC-V IDE 2026.1）：

```powershell
python tools/build_firmware.py
python -m pip install --target work/sim_deps -r tools/firmware_sim_requirements.txt
python tools/test_firmware_runtime.py
python tools/test_camera_3a_runtime.py
python tools/test_video_3a.py
python tools/check_firmware_config.py
```

工具链默认 `C:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin`，可用环境变量 `SOC_RISCV_TOOLCHAIN` 覆盖。构建使用 RV32IM/Zicsr/Zifencei、ILP32，附调试符号，输出 ELF/BIN/MAP。BIN 起始地址是 `0x1000`，没有自动添加 Flash boot header。

仿真执行真实 ELF 的 RV32 指令并建模 UART/I²C/CLINT/APB 寄存器；验证启动 GP/SP/BSS/中断配置、正确 ID 初始化、错误 ID 重试、无 ACK 超时、DDR 错误、CLINT 低 32 位回绕及异常记录。Sapphire custom cache 指令作为模型操作处理，未模拟真实 cache、受保护 CPU RTL、DDR 控制器时序或物理 I²C。结果写入 `reports/simulation/firmware_runtime.json`。原 Python driver 协议模型是独立的较弱证据。

## Efinity RISC-V IDE 下载

1. 在 Efinity Programmer 烧录本工程 bitstream，等待 `cal_done`。CPU 释放复位及 ELF 下载都依赖 DDR 校准；将 ELF 从 JTAG 加载到 DDR，不是写入片上 RAM。
2. 断开 Programmer/EDB 的 JTAG 连接，释放板载 FTDI adapter。保留 FPGA 已加载的配置。
3. IDE 中 **File → Import → General → Existing Projects into Workspace**，选择当前工作区的 `software/firmware`，导入 `soc_video_app`。不要勾选 Copy projects into workspace，否则工程的相对 BSP/tools 路径会失效。
4. **Project → Build Project**。工程使用 Python 外部构建脚本，必须让 IDE 能找到 `python`；产物为 `software/firmware/build/soc_video_app.elf`。
5. **Run → Debug Configurations → GDB OpenOCD Debugging**，选择共享配置 `soc_video_app_ti`。若未自动出现，刷新项目，再通过 **File → Import → Run/Debug → Launch Configurations** 导入项目中的 `.launch`。
6. Main 页核对 Project 为 `soc_video_app`，C/C++ Application 为 `${workspace_loc:/soc_video_app/build/soc_video_app.elf}`；该变量指向工程真实目录，与 IDE workspace 存放目录无关。OpenOCD/GDB 来自 2026.1 的安装目录。配置引用 `openocd/soc_video.cfg` 和本项目匹配的 `cpu0.yaml`，采用 native VexRiscv/USER1，FTDI channel 1，JTAG 800 kHz。
7. 共享 launch 使用主机 `127.0.0.1`、GDB `13333`、Tcl `16666`、Telnet `14444`。本机 vendor GDB 使用 `localhost` 可复现 error 138，详见根目录 `README_PROGRAMMING.md` 的排查记录。使用其他端口不能替代清理旧 OpenOCD 和释放 USB adapter。重新导入更新后的共享 launch；已存在的 GUI 配置需要核对 Startup 的初始化命令为 `monitor reset halt`、运行命令为 `set $pc = _start`、停止位置为 `*main`，GDB 初始化命令包含 `set riscv use-compressed-breakpoints no`。本 CPU 未启用压缩指令，使用 4 字节断点并停在函数准确入口。点击 **Debug**：CPU reset/halt → 加载 ELF/symbols → 设置 PC 为 `_start` → 在 `main` 入口临时断点停下。点击 **Resume**（F8）后运行应用。
8. 串口 **COM4，115200/8N1** 查看 `SOC VIDEO boot`、`DDR scratch PASS`、`Camera CD6B initialized`、`HELLO SOC` 和每秒的统计。本次实际确认串口为 COM4，重新枚举后端口号可能变化。帧率由 FPGA 寄存器提供，不是固件自造数值。

此 launch 在下载前通过 native debug 复位 CPU，不在下载后重置整块 FPGA。实板取指异常时，仅设置 PC 曾无法恢复；`reset halt` 后重新下载已验证可启动。RAM 下载不提供断电保留；当前 bitstream 内的 boot ROM 不包含这份新应用，上电自动启动需要另做 Flash 镜像。

2026-10-08 最终实板复测使用原始配置的 JTAG 800 kHz、readWaitCycles 40：烧录 bitstream 成功；GDB 停在 `main=0x1184`，SP=`0x20000`、GP=`0x273c`、BSS 全零；3898 字节固件读回与 BIN 完全一致。COM4 收到 boot、DDR scratch PASS、Camera CD6B initialized、HELLO SOC 及连续统计。约 8 秒后 `app_metrics_updates=8`，继续 1.5 秒后为 10；`app_ddr_errors/app_camera_errors/app_osd_errors` 和三个异常记录均为 0。统计样本 FPS 3–11、DISP 50–56、DROP 0、ERR 0。已恢复完整固件、清除诊断程序，resume 后关闭测试 OpenOCD，板卡继续运行。日志见 `reports/hardware_debug/gdb_final_main.log`、`uart_COM4.log`、`final_app_state.log`；尚未通过观察显示器确认 HDMI 画面。

vendor native VexRiscv target 不支持 `checksum_memory`，不能用 GDB `compare-sections` 判定下载结果；本次使用 `dump binary memory`/`dump_image` 逐字节比较。

### Launch failed: binary not found

先选中项目按 F5 刷新，关闭再打开项目以重载 `.cproject` 中的 ELF Binary Parser。使用 **Run → Debug Configurations → GDB OpenOCD Debugging → soc_video_app_ti**，而不是直接从 C/C++ Application 的本机 Run 配置启动。Main 页的 Project 必须为 `soc_video_app`，C/C++ Application 可通过 Browse 选择项目的 `build/soc_video_app.elf`；不要选择 `.bin`。点击 Apply 再 Debug。若启动的配置未显示上述 ELF 变量，重新导入更新后的共享 `.launch`，或在当前配置中手动 Browse ELF。

### OpenOCD 配置路径报 Not implemented

Windows 版 vendor OpenOCD 的 Jim Tcl 未实现 `file normalize`，而且 `file dirname` 只识别正斜杠。当前 `soc_video.cfg` 先将配置文件路径中的反斜杠转换为正斜杠，再用 dirname 获取工程目录。更新该 cfg 后可直接重新 Debug，不需要重编 ELF 或 bitstream。`check_firmware_config.py` 直接执行原始 cfg，覆盖全反斜杠、混合分隔符、全正斜杠和相对路径；只用 `SOC_CONFIG_CHECK` 跳过硬件 init/halt，IDE 正常启动时不要设置此变量。

### FTDI did not accept all data: 0, tried 60

此错误表示 OpenOCD 向 FTDI adapter 写 USB 数据时，要求传输 60 字节，实际完成 0 字节。若此前已出现正确的 FPGA ID `0x10660a79` 和 `Target successfully examined`，说明初始 USB/JTAG 访问已经成功；应先检查 USB 连接、adapter 驱动状态及其他程序是否占用 adapter。`Target Descriptions Supported, but disabled` 和建议使用 `extended-remote` 的警告不解释这次 USB 写失败。初始 CPU examined 也不代表 ELF 下载或 DDR 访问已验证。

1. 在 IDE Debug 视图终止失败的会话，确认其 OpenOCD/GDB 进程退出；重新插 USB 后应启动新会话，旧进程不能继续使用失效的 USB handle。
2. 确认板卡供电及 JTAG USB 连接，优先使用可靠的数据线直连电脑。用下面命令检查当前在线设备；无输出说明 Windows 当前未枚举到此 FTDI，先恢复 USB 连接再 Debug。若没有 `-PresentOnly` 时才显示 `Unknown`，那些是离线设备记录。

   ```powershell
   Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_0403&PID_6011' } | Format-Table Status,Class,FriendlyName,InstanceId -AutoSize
   ```

3. 本工程使用 FT4232H 的 channel 1，即 USB `MI_01` / Interface 1。核对该接口状态正常并使用 vendor OpenOCD 可访问的 USB 驱动；不要改其他 UART 接口。本目录板卡资料中的 `XL_YLS_DL_Interface_1.inf` 匹配 `PID_6010`，与当前配置的 `PID_6011` 不同，不要直接套用。
4. 关闭 Programmer/EDB 的 JTAG 连接及其他 OpenOCD 会话，然后重新 Debug。若曾给板卡断电，须先重新烧录本工程 bitstream、等待 DDR 校准，再释放 Programmer 的 adapter。
5. 若 FTDI 持续在线而仍失败，可临时将 `openocd/soc_video.cfg` 的 `adapter speed 800` 改为 `adapter speed 200` 复测，并保留 OpenOCD `-d3` 完整日志。降速仅用于排查 JTAG 时序/链路稳定性，不能恢复未枚举的 USB 设备。修改 cfg 无需重编 ELF 或 bitstream。

## 命令行备用下载

仍在工作区根目录，先在第一个 PowerShell 终端启动。以下命令使用 OpenOCD 默认端口 3333，与 IDE launch 的 13333 区分；必须先关闭 IDE 调试会话释放 USB adapter，且默认端口无残留占用：

```powershell
& 'C:/Efinity/efinity-riscv-ide-2026.1/openocd/bin/openocd.exe' -f software/firmware/openocd/soc_video.cfg
```

第二个终端执行：

```powershell
& 'C:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin/riscv-none-elf-gdb.exe' software/firmware/build/soc_video_app.elf -x software/firmware/openocd/download.gdb
```

GDB 将停在 `main`；输入 `continue` 运行。只有用户实际连接板卡时才执行这两个下载命令。
