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
