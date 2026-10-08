# SoC 视频流集成工作日志

- 基线提交：`3ab82f8319c8f12284078f6373327093e50bb40e`
- 分支：`feature/soc-hardjtag-sim`
- 工作区：`Ti60f225_soc_cam_hdmi_soc_sim`
- 验证范围：RTL/协议仿真、RISC-V 编译/host 模型、静态检查和 Efinity compile；按用户要求不做上板测试。

## 12 项目标验收记录

| 项目 | 实现与证据 |
|---|---|
| 1 基线备份 | `reports/baseline/sources.tar`、checkout、原始 artifacts、manifest 已保存；基线 Efinity map/debug/interface/PNR/PGM PASS；`tools/test_resize.py` 完整 1080p→720p、DMA、CVO 回归 PASS。基线为 RAW10 1920×1080/4 lane，采集 148.5 MHz 双像素，HDMI 74.25 MHz 单像素，TMDS 371.25 MHz；基线资源 XLR 29,505/60,800、RAM 135/256、DSP 11/160、GBUF 19/32、RBUF 1/32。|
| 2 接口与时钟 | `docs/VIDEO_INTERCONNECT.md` 记录 CSI→RAW gearbox→Debayer/gain/AE→area resize→frame_buffer DDR→CVO→tone/lift→histogram/overlay→OSD→DVI/TMDS。OSD 输入是最终单像素域 RGB/DE/HS/VS，双像素 148.5 MHz 与单像素 74.25 MHz 关系已明确。|
| 3 固定 OSD | `osd_font8x16.sv`、`osd_fixed_text.sv` 实现 8×16 ASCII 与流水同步；`osd_fixed_text_tb.sv` PASS，`HELLO SOC` 194 个有效字模像素；主顶层 OSD 进入 `dvi_encoder` 前。|
| 4 SoC 资源 | 导入实际 `soc/efx_sapphire_soc/soc/soc.v`、settings/init/BSP；`soc_video_ddr_integration.sv` 接 UART TX/RX、SPI SS/SCLK/D0/D1、Sapphire I2C、CPU hard JTAG、APB 和唯一 DDR；UART/SPI 已贯通到顶层及 peri 引脚；CPU 使用 USER1，Efinity auto debugger 使用 USER2；VIO gain/tone 路径改固定默认值/APB。|
| 5 DDR 地址 | CPU 程序/BSS/栈在 DDR `[0x1000,0x20000)`，4 KiB 片上 boot RAM 为 `0xF9000000`；`docs/DDR_ADDRESS_MAP.md` 已纠正此前将程序区误记为片上 RAM 的说明。CPU scratch `0x0100_0000..0x0110_0000`，视频 `0x0400_0000` 起始，三帧 stride `0x0038_4200`，开区间结束 `0x04A8_C600`；链接断言及地址检查保证不重叠。|
| 6 共享 DDR | `axi_shared_ddr_2m.sv` 保留一个 DDR3 控制器，CPU/视频两个 master；CPU ID8→DDR ID4，保存完整 ID/owner，B/R 响应完整归属，地址和数据在 backpressure 下保持；4-beat burst、仲裁、公平性、B/R 错误及并发模型 PASS。|
| 7 复位屏障 | `ddr_startup_barrier.sv` 将实际 `pll_locked`/`cal_done` 分别同步到 core/display 域，阻塞 CPU/video AXI；已接入顶层 `barrier_sys_reset_n/barrier_vid_reset_n`。多次复位、cal_done 前禁止访问的 TB PASS。|
| 8 并发状态 | SoC CPU AXI 与 frame_buffer AXI 同时进入共享 bridge；`video_status_counters.sv` 对采集帧、显示帧、欠载、溢出、每次 AXI 错误和 1 s FPS 计数，已接入 APB 状态；并发计数 TB、DMA/HDMI/DDR bridge 回归 PASS。真实 protected CPU RTL 仿真不可由 Icarus 解析，使用 Efinity 综合集成 + AXI/APB BFM 证据。|
| 9 APB 控制 | `osd_apb_regs.sv` 提供 ID/enable/X/Y/color/char/page/COMMIT/status，并以 `STATUS2` 独立提供采集 FPS/显示 FPS；只在 APB ACCESS 完成写入，非法和只读写有 `pslverr` 且无副作用；busy/ACK/active CDC 已同步。APB TB PASS。|
| 10 双缓冲 | `osd_text_double_buffer.sv` 写非 active 页，VS 上升沿切页并 ACK，配置快照随 toggle 过两级同步；busy 时重复 COMMIT 被 APB 拒绝；frame-boundary 与 CDC TB PASS。|
| 11 固件 | `camera_init_table.h` 为 165 项 RTL 表；完整 `soc_video_app.elf` 具有 `_start`、GP/SP/BSS/异常入口及 `main()`，初始化 UART/I²C、执行 DDR 测试、启动摄像头、显示 HELLO SOC、CLINT 每秒更新统计。Efinity RISC-V 13.4 完整应用编译 PASS；真实 ELF 的通用 RV32 指令模型与外设模型验证 PASS。此前只有 `camera_init_cpu` 入口的两个 driver ELF 仅为历史链接产物，不能作为完整启动应用，其结果由本轮替代。|
| 12 CPU 摄像头初始化 | `camera_verify_id()` 读取 `0x3107/0x3108` 并按 SC431HAI 手册校验 `0xcd6b`；BSP 使用 SID 低电平对应的 8 位从地址 `0x60`（7 位 `0x30`），调用 `i2c_writeData_w/i2c_readData_w`；`i2c_owner_mux.sv` 使 CPU 独占开漏 SDA/SCL，旧 RTL master 断开物理 pad；ID、初始化、停启和恢复协议模型及 mux TB PASS。|

## 最终 Efinity 证据

2026-10-08 主工程 `C:/Efinity/2026.1/bin/efx_run.bat ti60f225_cam_hdmi.xml --flow compile --timeout 1200`：map PASS、debugger auto instantiation PASS、interface PASS、PNR PASS、PGM PASS。UART/SPI 顶层端口和 peri 约束已纳入本次编译。最终 map 资源（`outflow/ti60f225_oob.map.rpt`）：RAM10 141/256、DPRAM10 4、DSP48 11/160、FF 15,347、LUT4 16,825；bitstream `outflow/ti60f225_oob.bit`，SHA256 `4E39809ACFF0C22563B7C162F8CC06473A3901D88519EC67D0F7C915B6AD4DD0`。调试配置由 `tools/generate_soc_debug.py` 固定为 USER2、6 个 1-bit 关键 probe、capture depth 512；RAM10 余量 115，未触发进一步削减。

## 回归命令

前轮提交：`a851252`、`dd611ae`（UART/SPI 顶层端口、peri 引脚约束及实际编译资源更新）。

- `python tools/check_rtl_config.py` PASS
- `python tools/test_resize_checks.py`、`python tools/test_resize.py` PASS
- `python tools/run_rtl_checks.py` PASS
- `python tools/test_firmware_driver.py` PASS
- 新增 AXI、startup barrier、APB、double buffer、status counter、I2C mux、fixed OSD TB 全部 PASS
- `python tools/build_firmware.py` PASS：完整 BSP 应用 `software/firmware/build/soc_video_app.elf/.bin`
- 最终 Efinity map 资源和 bitstream 哈希已按 UART/SPI 贯通后的编译产物更新；调试探针维持 6 个 1-bit 信号、512 深度。

“PASS”均指仿真、协议模型、静态检查或 Efinity compile 证据；由于用户明确取消上板，本日志不把物理摄像头画面或真实 JTAG CPU 指令执行描述为已在板确认。

## 2026-10-08 补齐可启动固件与 IDE 下载配置

发现并修正：原构建使用 `-e camera_init_cpu` 且没有启动代码/主循环；gc-sections 裁掉 OSD 更新函数。原 `default.ld` 的 `ram` 名称也掩盖了实际 DDR 映射。本轮只改软件、构建工具及文档，没有改 RTL/peri/bitstream。

- `start.S` 提供 `_start=0x1000`，初始化 GP、SP=`0x20000`、mtvec，关闭中断、同步 cache、处理 data/BSS，调用 main；异常记录 mcause/mepc/mtval 并停机。
- `app.ld` 采用 DDR `[0x1000,0x20000)`，为栈保留末尾 4 KiB，并以 ASSERT 防止程序/BSS 越界。代码与数据分别使用 RX/RW ELF LOAD segment。
- `main.c` 初始化 UART 115200/8N1 与 I²C 100 kHz，启动时和每次统计更新时对 scratch 前 64 KiB 执行两种模式读写；校验 CD6B、初始化摄像头，显示 HELLO SOC，随后轮询 CLINT，前次更新完成至少一秒后再发布 FPGA FPS/DISP/DROP/ERR。ID/init 失败进行周期性恢复，OSD ACK 超时和 DDR 错误有日志/计数。
- OSD 驱动写满非活动字符页并补空格，避免长字符串切换为短字符串后残留旧字符；busy 时不写页，ACK 用 CLINT 限时 250 ms。
- 新增 `.project/.cproject`、`soc_video_app_ti.launch`、匹配源工程的 `cpu0.yaml`、native VexRiscv USER1 OpenOCD 配置及备用 GDB 下载脚本。OpenOCD 使用 FTDI channel 1、800 kHz、instruction 8。launch 加载完整 ELF 后从 `_start` 运行，在 main 停下，不做下载后硬复位。
- 安装的 Efinity RISC-V IDE 2026.1 headless 导入和 clean/build PASS，0 errors/0 warnings；实际 plugin launch 属性检查、XML/路径检查、vendor OpenOCD 配置解析 PASS（跳过 init/halt，不访问硬件）。GDB 离线 ELF/symbol 读取 PASS。
- `test_firmware_runtime.py` 执行实际 ELF：正常启动、错误 ID 后恢复、无 ACK、DDR 损坏、CLINT 32-bit 回绕五种场景 PASS；GP/SP/BSS、timer cadence、UART/字符页一致性、短字符尾部清空、异常 CSR 记录 PASS。Sapphire cache 指令被模型截获，不代表真实 cache 或 CPU RTL 仿真。
- `test_firmware_driver.py` 旧独立协议模型仍 PASS。完整应用大小：text 3898、data 0、BSS 28 bytes；无未解析符号，摄像头/OSD/main/start 函数均保留。
- 完整 ELF SHA256：`49B575225F1235B8D83F3EC27C06786ED697144CDE20145BB3811E2C205CC2C6`；BIN SHA256：`C4B02209B9FD3A3D9A72050540D46EA036C78C784B77825EF765D23BBA347329`。输出路径 `software/firmware/build/`；仿真细节 `reports/simulation/firmware_runtime.json`。
- 下载步骤与验证边界见 `software/firmware/README.md`。未连接板卡做下载、真实 UART、摄像头或 cache/DDR 时序测试，也未制作 Flash 自动启动镜像。

## 2026-10-08 IDE binary not found 修正

用户在 GUI Build 后点击 Run 报 binary not found。检查实际 `software/firmware/build/soc_video_app.elf` 已存在，构建产物并未缺失；原 `.cproject` 未显式配置 ELF Binary Parser。补入安装版 CDT 支持的 `org.eclipse.cdt.core.ELF`，共享 launch 改为 `${workspace_loc:/soc_video_app/build/soc_video_app.elf}` 明确绑定工程文件，静态检查同时验证 parser、变量解析和 ELF magic。README 补充项目 F5/重开、选择 GDB OpenOCD Debugging 配置和 Main 页 Browse ELF 的操作。仅验证配置/构建，不启动实际硬件调试。

## 2026-10-08 Windows OpenOCD 路径命令兼容修正

用户 OpenOCD 报 `soc_video.cfg:3: Error: Not implemented`。在同一 vendor OpenOCD 0.11.0+dev 二进制中独立执行 `file normalize .` 复现退出码 1；`file dirname` 和 `file join` 正常，但 dirname 仅识别正斜杠。先对 `[info script]` 执行反斜杠→正斜杠 string map，再连续两次 dirname 获取 app_dir，移除 normalize。

此前 `check_firmware_config.py` 将 app_dir 行替换为绝对路径，导致漏测原路径逻辑；本轮删除替换流程，直接执行原始 cfg。仅通过 `SOC_CONFIG_CHECK=1` 跳过最终硬件 init/halt，其余路径、source、FTDI、target、cpu0.yaml 和 JTAG mapping 语句照常执行。Windows 绝对路径、用户日志的混合分隔符路径、正斜杠绝对路径和工程目录相对路径四种检查均 PASS。检查脚本兼容 GUI 保存的相对 ELF 路径、listAttribute 以及其他调试插件属性；保留用户已有 `.launch` 改动。未做硬件访问。

## 2026-10-08 FTDI USB 传输失败排查

用户日志已发现 FPGA ID `0x10660a79`、CPU examined，并在 GDB 连接后报 `ftdi device did not accept all data: 0, tried 60`。排查时 IDE 启动的 OpenOCD/GDB 仍运行，但 Windows `Get-PnpDevice -PresentOnly` 未发现任何 `VID_0403` FTDI；历史记录中 `PID_6011` 的全部接口均为离线 `Unknown`，Interface 1 使用 libusb-win32。此快照说明检查时 adapter 不在线，尚不能区分故障导致掉线与用户报错后主动拔线，也不能确认 ELF 下载成功。未发现运行中的 Efinity Programmer/EDB；配置解析检查再次 PASS，无硬件访问。

README 增加 USB 恢复、失败会话终止、Interface 1 驱动核对、adapter 独占及可选 200 kHz 排查步骤；提醒板卡资料附带的 Interface 1 INF 匹配 `PID_6010`，并非本工程的 `PID_6011`。保留现有 800 kHz、USER1、FTDI channel 1 和用户 `.launch` 设置；未终止用户进程、修改驱动或执行硬件下载。

用户随后确认重新插线。在线枚举显示所有 FTDI 接口 OK，Interface 1 的 libusb-win32 1.2.7.3 / libusb0 驱动 problem code 0。结束旧 OpenOCD/GDB 会话后，新 OpenOCD 在 800 kHz 下成功识别 FPGA、examined/halt CPU，无 FTDI 写失败；旧 PID 6760 的默认端口仍有残留记录，3333 连接失败。改用 13333/16666/14444 后 GDB 连接、寄存器读取、3898 字节 ELF 下载及全量 DDR 逐字节读回 PASS。vendor target 不支持 checksum_memory，GDB compare-sections 报 memory fault 实为该功能未实现，改用 dump binary memory 验证。启动到 main 的测试 30 秒超时，随后 halt 读取 PC=0、SP=0x1186；尚未确认启动/断点问题原因，不声明应用运行 PASS。共享 launch 仅同步替换四个端口属性，保留用户其余设置；证据保存于 reports/hardware_debug/。

## 2026-10-08 用户授权上板后：烧录与完整应用运行 PASS

用户明确要求掉电上电后烧录 bitstream 并开始测试。本轮通过 FTDI channel B/interface 1 烧录 `outflow/ti60f225_oob.bit`（上述 SHA256），JTAG programmer 1 MHz、device ID `0x10660A79`，报告 finished。

此前异常状态中，从 DDR 或片内 RAM 设置 PC 再 resume，短循环未执行，CSR 曾读到 mcause=1/mepc=0。把片内 RAM 复位入口暂时改为短循环并执行 CPU reset 后，x8 增长、PC 位于循环；恢复启动代码，执行 `reset halt` 后重新下载完整 ELF，CPU 成功执行到 main 和主循环。这些实验确认 CPU 复位可以恢复本次状态，尚不足以确定受保护 CPU 内部的异常挂起机制。诊断程序已通过重新烧录清除，最终恢复完整固件。

共享 launch 和 `download.gdb` 在下载前执行 `monitor reset halt`，禁止压缩断点并使用 `*main` 函数入口，匹配当前无 C 扩展的 CPU。保留 GUI 其余属性及 13333/16666/14444 端口；检查脚本同步验证这三项启动设置。未修改 RTL、驱动或固件机器码。

最终复测服务器临时使用 23333/26666/24444，配置保持 adapter 800 kHz、readWaitCycles 40。`gdb_final_main.log` 确认 PC=`0x1184`、SP=`0x20000`、GP=`0x273c`、BSS 清零；`final_firmware_readback.bin` 全部 3898 字节与应用 BIN 一致。COM4 115200/8N1 收到 `SOC VIDEO boot`、`DDR scratch PASS`、`Camera CD6B initialized`、`HELLO SOC` 和连续统计，日志 `uart_COM4.log`。统计样本 FPS 3–11、DISP 50–56、DROP=0、ERR=0。

`final_app_state.log`：约 8 秒运行后 app_metrics_updates=8，继续 1.5 秒后=10；app_camera_errors、app_osd_errors、app_ddr_errors、firmware_trap_value/pc/cause 全部为 0。最终 resume 后正常 shutdown 测试 OpenOCD，释放 USB/JTAG，板卡继续运行。`python tools/check_firmware_config.py` PASS。实板证据覆盖指令执行、DDR scratch、摄像头 ID/初始化软件路径、OSD 提交 ACK 和统计；未观察 HDMI 显示器画面，不声称视觉效果已验证。

## 2026-10-08 画面偏绿及彩色斑纹调查

用户提供实际显示照片并报告集成前正常、集成后偏绿及斑纹。基线 `3ab82f8:debug.json`/debug_top.v 的 Q8.8 增益为 R=0x168、G=0x100、B=0x1a9；SoC 删除 USER1 VIO 后误改为三通道 255，并关闭原先启用的 tone/lift。已恢复这些静态白平衡、tone_enable=1、high_green/dark_red=32、lift_enable=1、lift_strength=32；同步修正 remove_manual_debug.py，check_rtl_config.py 新增与基线校准值的对照。旧 AE 已失去物理 I2C 所有权，继续禁用，未声称恢复基线自动曝光/自动提亮。

修改前实板使用只读诊断固件逐项读取摄像头初始化表的最终寄存器值：162 个不同寄存器、mismatches=0，包括 ROI/镜像/图像模式。完成后恢复完整应用并 resume，诊断日志 `reports/color_regression/camera_readback.log`。新增 `tools/test_video_dma_shared.py`，真实 frame_buffer 经过 axi_shared_ddr_2m、并发 200 次 CPU 四拍写读，三个输出帧逐像素比较 PASS，涵盖背压和 4 KiB 边界；tone 5895 像素、lift 45791 像素回归 PASS。仿真不覆盖物理 MIPI/DDR 信号完整性。

校准修正 bitstream 已完成 map/debug/interface/PNR/PGM，setup/hold 时钟汇总均正裕量；RAM10=142、DPRAM10=4、DSP48=12、LUT4=16875。新 bitstream SHA256 `D85C8B128394160C5E6C9B2589E2C5AC6FA887B41C18746AC05E1913B7CEE4A8`；旧版本另存 `reports/color_regression/before_color_fix.bit`。烧录尝试时 FTDI 已从 Windows 在线枚举消失，Programmer 报 No USB target detected，OpenOCD 报 no device found；因此修正版本尚未烧录，不能声明偏绿或斑纹在实板消失。证据 `reports/color_regression/compile.log`、program.log、dma_shared_test.log；失败的 GDB 重试日志另存 gdb_failed_usb_attempt.log。

用户随后报告早期正常 bitstream 现在也有彩色斑纹。这降低斑纹由 SoC 集成独有 RTL 引起的可能性，但仍需完全断电重启摄像头、确认肉眼可见（排除拍屏摩尔纹）、使用 FPGA 内部色条旁路摄像头，以及检查摄像头排线/连接器、供电纹波、MIPI CSI CRC/ECC/帧错误与 HDMI 线材。OSD DROP/ERR=0 不包含所有 MIPI 链路错误，也不能验证颜色正确。静态白平衡回退与斑纹硬件调查应分别验证。

## 2026-10-08 CPU 初始化前输出独立 HDMI 彩条

用户确认彩色斑纹来自故障显示器，并要求固件下载/初始化前输出彩条。本改动确保启动输出有完整的视频时序；未据此判断显示器损坏的原因。

- 新增 `rtl/soc_integration/hdmi_startup_colorbar.sv`，生成 74.25 MHz、1280×720/60 Hz、1650×750 总时序的八色彩条，HS/VS 为正极性。RGB 与 DE/HS/VS 同拍寄存，消隐 RGB 为 0。HDMI 输出复位只等待全局 PLL 锁定及 HDMI 域复位同步，不再等待 DDR 校准或延迟释放的摄像头/显示处理复位。
- 新增 APB `VIDEO_READY`（`0xf8100028`，bit 0 RW，复位 0），由 CPU 明确放行。APB 在全局、DDR 启动屏障或 SoC 系统复位时清零。固件 main 首先写 0；DDR 测试、摄像头初始化和 OSD COMMIT/ACK 成功才写 1。摄像头初始化失败或 OSD ACK 超时维持彩条，后续恢复成功可放行。旧 ELF 不写该寄存器，需配套下载新 ELF。
- 输出选择器将就绪标志同步到 HDMI 域。未观察到摄像头 VS 时继续输出彩条；放行后完成当前彩条帧，空白等待下一个摄像头 VS 再切到完整视频帧。两路时序相位独立，切换时显示器可能短暂重新锁定；不声称无缝切换。清除就绪标志/DDR 就绪丢失后空白等待彩条帧边界并返回彩条。彩条旁路 ISP/OSD，后台摄像头、DDR、OSD 不依赖 HDMI 选择结果。
- `python tools/test_hdmi_startup.py` PASS：两个完整 720p 帧逐像素验证 8×160 像素彩条、每行 40 像素 HS、5 行 VS、1280×720 有效区、消隐；验证无摄像头同步/CPU 未放行时的彩条、异步就绪、帧边界切换及重新加载/复位。APB 回归覆盖 SETUP 无副作用、ACCESS 置位/读回/清零和复位。实际 RV32 ELF 回归的 normal/id_retry/no_ack/ddr_corrupt/timer_wrap 和 trap 均 PASS；就绪置位必须在真实初始化表写完和 OSD ACK 后，DDR 错误/ACK 超时保持 0。固件 3954 字节；配置和受保护 RTL 审计、git diff --check 均通过。
- Efinity map/debug/interface/PNR/PGM 全部 PASS；时钟关系汇总最小 setup slack=0.300 ns、hold slack=0.026 ns，HDMI 像素域 setup=7.296 ns。新 bitstream SHA256 `739843914D00C42F22A53CDA6772745EB7EFAF0BBAF6B898751D0AEBBE9967F4`，ELF SHA256 `57C1929FE04101C9D7EB63AF4B5EE2F90200C41F108309B8A098DCAB8A22DDF0`。编译日志 `reports/startup_colorbar_compile.log`；仿真日志 `reports/simulation/hdmi_startup.log`。
- 编译期间 FTDI 曾在线；烧录时又从 Windows 在线设备枚举消失，Programmer 报 `No USB target detected`。此时尚未烧录本版本，未完成实板就绪寄存器 0→1、UART 或显示器目视验证；失败日志 `reports/startup_colorbar/program.log`。
- 用户随后要求“先保留编译结果，暂不烧录”，已停止硬件下载/测试。配套产物另存 `reports/startup_colorbar/startup_colorbar.bit`、`soc_video_app.elf`、`soc_video_app.bin`，时序报告另存 `timing.rpt`，供后续烧录；本轮未成功改变板卡运行版本。

## 2026-10-08 原始 VS 与缩放完成帧率诊断

用户要求执行方法二以区分摄像头原始帧率和缩放链路帧率。新增 `video_frame_diagnostics.sv`：在 `i_mipi_rx_pclk` 域对 `w_mipi_rx_vs` 下降沿计数，在 `vid_clk_dvi2` 域对 `resize_completed_frames` 变化计数，在 HDMI 域统计 CVO VS；三个事件均以 toggle CDC 同步到 `core_clk`，同一 1 秒窗口锁存，避免直接跨时钟域读取计数器。

新增只读 APB：`0xf810002c`=`RAW_FPS`、`0xf8100030`=`RESIZE_FPS`。OSD 和 UART 文本改为 `RAW n RESIZE n DISP n DROP n ERR n`，旧 `0xf8100024` 保留显示 FPS/缩放 FPS 布局。诊断回归覆盖短脉冲、异步时钟、二进制计数进位、复位、空闲窗口、饱和及 APB 只读保护，`tools/test_video_frame_diagnostics.py` PASS；固件构建 4054 字节，运行时五场景和 trap 回归 PASS。

Efinity map/debug/interface/PNR/PGM 全部 PASS；时钟关系汇总最小 setup slack=0.274 ns、hold slack=0.026 ns，HDMI 域 setup=7.279 ns、core_clk setup=3.926 ns。编译日志 `reports/raw_resize_compile.log`。受保护 RTL/DDR/配置审计、固件配置、协议测试、实际 ELF 五场景/trap、诊断 RTL/APB 回归及 git diff --check 均 PASS。Efinity 自动保存的项目 XML 格式变化已恢复，诊断模块由 top include 纳入工程。

配套产物保存在 `reports/raw_resize/raw_resize.bit`、`soc_video_app.elf`、`soc_video_app.bin`；时序报告 `timing.rpt`，仿真记录 `diagnostics_test.log`、`firmware_runtime.json`。bitstream SHA256 `180B337E29A0200219B5EF93EF56872501FE195CA72496010AF3059CC347C050`；ELF SHA256 `D352E991DDB1770EDBF2EA4AB85FBFE3BA63CA8F7FFF9EC868B7A591D6B5D2E4`。

按用户之前“暂不烧录”的要求，本轮未访问硬件或下载 bitstream，尚无实板 RAW/RESIZE 测量结果。必须使用包含该诊断逻辑的新 bitstream 与新 ELF 后，屏幕或串口才能看到 RAW/RESIZE 数值；仿真中的 RAW 30/RESIZE 9 是受控测试数据，不能当作摄像头实际帧率。
