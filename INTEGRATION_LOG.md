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
| 4 SoC 资源 | 导入实际 `soc/efx_sapphire_soc/soc/soc.v`、settings/init/BSP；`soc_video_ddr_integration.sv` 接 UART、Sapphire I2C、CPU hard JTAG、APB 和唯一 DDR；CPU 使用 USER1，Efinity auto debugger 使用 USER2；VIO gain/tone 路径改固定默认值/APB。|
| 5 DDR 地址 | `docs/DDR_ADDRESS_MAP.md`、`ddr_address_map_check.sv` 固定 CPU scratch `0x0100_0000..0x0110_0000`，视频 `0x0400_0000` 起始，三帧 stride `0x0038_4200`，开区间结束 `0x04A8_C600`；仿真断言不重叠且 16-byte 对齐。|
| 6 共享 DDR | `axi_shared_ddr_2m.sv` 保留一个 DDR3 控制器，CPU/视频两个 master；CPU ID8→DDR ID4，保存完整 ID/owner，B/R 响应完整归属，地址和数据在 backpressure 下保持；4-beat burst、仲裁、公平性、B/R 错误及并发模型 PASS。|
| 7 复位屏障 | `ddr_startup_barrier.sv` 对 core/display 域分别同步 PLL/cal_done，阻塞 CPU/video AXI；已接入顶层 `barrier_sys_reset_n/barrier_vid_reset_n`。多次复位、cal_done 前禁止访问的 TB PASS。|
| 8 并发状态 | SoC CPU AXI 与 frame_buffer AXI 同时进入共享 bridge；`video_status_counters.sv` 对采集帧、显示帧、欠载、溢出、AXI 错误和 1 s FPS 计数，已接入 APB 状态；并发计数 TB、DMA/HDMI/DDR bridge 回归 PASS。真实 protected CPU RTL 仿真不可由 Icarus 解析，使用 Efinity 综合集成 + AXI/APB BFM 证据。|
| 9 APB 控制 | `osd_apb_regs.sv` 提供 ID/enable/X/Y/color/char/page/COMMIT/status，并以 `STATUS2` 独立提供采集 FPS/显示 FPS；只在 APB ACCESS 完成写入，非法和只读写有 `pslverr` 且无副作用；busy/ACK/active CDC 已同步。APB TB PASS。|
| 10 双缓冲 | `osd_text_double_buffer.sv` 写非 active 页，VS 上升沿切页并 ACK，配置快照随 toggle 过两级同步；busy 时重复 COMMIT 被 APB 拒绝；frame-boundary 与 CDC TB PASS。|
| 11 固件 | `camera_init_table.h` 为 165 项 RTL 表（含 5000 us stream-off、1000 us stream-on 延时）；driver 完成 OSD 字符写/提交/ACK、真实采集 FPS/显示 FPS/DROP/ERR 格式化、UART hook。Efinity RISC-V 13.4 `rv32im/ilp32` host 与 BSP 两套 `.elf/.bin` 编译链接 PASS；`test_firmware_driver.py` PASS 165 写入、20 次更新和状态模型。|
| 12 CPU 摄像头初始化 | `camera_verify_id()` 读取 `0x3107/0x3108` 并按 SC431HAI 手册校验 `0xcd6b`；BSP 使用 SID 低电平对应的 8 位从地址 `0x60`（7 位 `0x30`），调用 `i2c_writeData_w/i2c_readData_w`；`i2c_owner_mux.sv` 使 CPU 独占开漏 SDA/SCL，旧 RTL master 断开物理 pad；ID、初始化、停启和恢复协议模型及 mux TB PASS。|

## 最终 Efinity 证据

2026-10-08 主工程 `C:/Efinity/2026.1/bin/efx_run.bat ti60f225_cam_hdmi.xml --flow compile --timeout 1200`：map PASS、debugger auto instantiation PASS、interface PASS、PNR PASS、PGM PASS。最终 map 资源（`outflow/ti60f225_oob.map.rpt`）：RAM10 140/256、DPRAM10 4、DSP48 11/160、FF 15,294、LUT4 16,748；bitstream `outflow/ti60f225_oob.bit`，SHA256 `E45C85492B275F4E2EAB2D52287524E8181DD04C374D141373DA3DF7F24A45B6`。调试配置由 `tools/generate_soc_debug.py` 固定为 USER2、6 个 1-bit 关键 probe、capture depth 512，避免 RAM 紧张。

## 回归命令

- `python tools/check_rtl_config.py` PASS
- `python tools/test_resize_checks.py`、`python tools/test_resize.py` PASS
- `python tools/run_rtl_checks.py` PASS
- `python tools/test_firmware_driver.py` PASS
- 新增 AXI、startup barrier、APB、double buffer、status counter、I2C mux、fixed OSD TB 全部 PASS
- `python tools/build_firmware.py` PASS：host/BSP `.elf/.bin`
- 最终 Efinity map 资源和 bitstream 哈希已按本次编译产物更新；调试探针维持 6 个 1-bit 信号、512 深度。

“PASS”均指仿真、协议模型、静态检查或 Efinity compile 证据；由于用户明确取消上板，本日志不把物理摄像头画面或真实 JTAG CPU 指令执行描述为已在板确认。
