# SoC 视频流集成工作日志

## 工作范围

- 基线仓库：`Ti60f225_soc_cam_hdmi_720p`
- 基线提交：`3ab82f8319c8f12284078f6373327093e50bb40e`
- 工作分支：`feature/soc-hardjtag-sim`
- 工作区：`Ti60f225_soc_cam_hdmi_soc_sim`
- 验证方式：RTL/固件仿真、静态检查和 Efinity 编译；不进行上板测试。

用户提供的系统划分已纳入设计约束：单个 Sapphire RISC-V SoC 负责摄像头初始化、APB 控制、DDR 访问、UART/JTAG；采集、预处理、风格迁移和 HDMI 显示共享一个 DDR3 控制器；资源紧张时减少调试探针及逻辑分析仪存储。

## 阶段记录

### 1. 基线备份与可复现性

- [x] 从基线提交创建独立工作区和分支。
- [x] RTL、工程 XML、peri、SDC、IP 设置随 Git 工作区保留。
- [x] Efinity 基线 map/synthesis 通过；第一次完整 compile 因 worktree 中缺少未跟踪的 `work_dbg/debug_top.v` 在调试插入阶段停止，已补齐生成文件并重跑。
- [x] 基线仿真回归：配置审计 PASS；CSI/resize/DMA/overlay 快速及全帧测试运行通过。
- [x] 已记录已知基线资源：Ti60F225 I3，720p 输出；XLR 29,505/60,800，片上 RAM 135/256，DSP 11/160，GBUF 19/32，RBUF 1/32；HDMI 像素时钟 74.25 MHz，采集时钟 148.5 MHz，串行时钟 371.25 MHz。

### 2. 视频接口和时钟

- [x] 完成连接图和信号时序文档（`docs/VIDEO_INTERCONNECT.md`）。
- [x] 完成双像素/单像素域关系检查。

### 3. 固定文字 OSD

- [x] 8×16 ASCII 字模、坐标和合成器。
- [x] 固定 `HELLO SOC` 字符串仿真及与 HDMI 输入输出延迟检查。

### 4. SoC 资源整理

- [x] 移入实际 Sapphire SoC IP/BSP（`soc/efx_sapphire_soc/`、`software/bsp/`）。
- [x] 检查 UART、SPI、JTAG、时钟和引脚资源冲突；`soc_jtag_channel_mux` 固定 JTAG 所有者并报告双使能错误。

### 5. DDR 地址空间

- [x] CPU、栈、堆和三帧视频缓存地址表（`docs/DDR_ADDRESS_MAP.md`）。
- [x] 地址单位、长度和不重叠断言；frame buffer 起始地址改为 `0x1000_0000`。

### 6. 共享 DDR AXI 互连

- [ ] CPU 与 frame_buffer 两个 Master 的仲裁和 ID 适配。
- [ ] B/R 响应归属、背压和突发仿真。

### 7. 复位和 DDR 启动屏障

- [ ] 各时钟域同步释放。
- [ ] DDR 校准完成前禁止访问。

### 8. SoC/视频并发

- [ ] UART/JTAG 仿真模型、CPU DDR 测试和视频并发测试。
- [ ] 欠载、溢出和 AXI 错误计数。

### 9. APB 视频/OSD 控制

- [ ] 地址译码、寄存器、完成握手和非法访问。

### 10. 文字双缓冲和跨域提交

- [ ] COMMIT/ACK、消隐切页和配置快照。

### 11. OSD 固件驱动

- [ ] 初始化、字符串写入、提交、ACK 等待和指标格式化。

### 12. CPU 摄像头初始化

- [ ] C 表、延时、顺序、Sensor ID 和恢复状态机仿真。

## 验证命令和结果

| 时间 | 阶段 | 命令/测试 | 结果 |
|---|---|---|---|
| 2026-10-07 | 1 | `git worktree add -b feature/soc-hardjtag-sim ... 3ab82f8` | PASS |
| 2026-10-07 | 1 | Efinity 2026.1 基线 compile | 运行中 |
| 2026-10-07 | 1 | `python tools/check_rtl_config.py` | PASS |
| 2026-10-07 | 1 | `python tools/test_resize_checks.py` | PASS |
| 2026-10-07 | 1 | `python tools/run_rtl_checks.py` | 运行通过基础用例 |
| 2026-10-07 | 3 | `iverilog ... osd_fixed_text_tb.sv` | PASS，117 个字符像素 |
| 2026-10-07 | 4 | `iverilog ... soc_jtag_channel_mux_tb.sv` | PASS |
| 2026-10-07 | 5 | `iverilog ... ddr_address_map_tb.sv` | PASS |
