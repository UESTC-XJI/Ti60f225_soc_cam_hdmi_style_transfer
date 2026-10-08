# Sapphire SoC 资源和调试通道整理

## 已迁入资源

`soc/efx_sapphire_soc/soc/` 来自 `09_Ti60F225_hardjtag_demo/par/ddr_demo_ti60/ip/soc/`，包含实际 `soc.v`、`soc_define.vh`、IP 设置、仿真/综合 netlist 和启动 RAM 初始化文件。匹配的 Sapphire BSP 驱动头文件位于 `software/bsp/driver/`，其余 EfxSapphireSoc BSP 资源位于 `software/bsp/EfxSapphireSoc/`。

该 IP 的实际接口包括：

- 100 MHz `io_systemClk`；
- 128 位 `io_ddrA_*` CPU AXI 端口；
- 8 位 CPU AXI ID；
- `jtagCtrl_*` 硬 JTAG 通道；
- UART、SPI、I2C 和 APB 外设在生成 SoC 内部；UART TX/RX、SPI SS/SCLK/D0/D1 已从 wrapper 接到顶层端口。

## 通道冲突处理

原视频工程的 v7 EDB 使用 USER1。集成顶层将 `jtag_inst1_*` 直接连接到 Sapphire 的 `jtagCtrl_*`，CPU 独占 USER1；原手动 VIO/LA 已移除，Efinity auto debugger 移至 USER2。`soc_jtag_channel_mux` 只是保留的独立模块，当前顶层未实例化。RISC-V IDE 使用 native VexRiscv OpenOCD target，`jtagMapping 8 8 0 1 2 2`；不要选择标准 RISC-V DMI 或 soft TAP。虽然通道独立，同一 USB JTAG adapter 仍须由单一主机程序使用。

完整固件和 IDE 下载步骤见 `software/firmware/README.md`。下载 ELF 在 DDR `0x1000` 运行；4 KiB 片上 boot RAM 位于 `0xF9000000`，不能将两者混淆。

## 视频控制资源

原 VIO 的 gain、Gamma 和 OSD 控制不再作为 CPU 运行时依赖：

- RGB gain 默认值为 1.0（8 位通道对应 255）；
- Gamma 保持基线工程的禁用状态；
- OSD 控制由 APB 寄存器模块提供，VIO 仅作为仿真兼容源；
- 同一控制信号只能有一个驱动源，工程文件不重复添加原始 VIO 和 SoC 调试模块。

## 资源紧张策略

逻辑分析仪和 EDB 的捕获 RAM 优先级低于视频、DDR 和 SoC。若 Efinity 资源报告显示 RAM 或 GBUF 不足，先将 EDB 探针压缩为采集 `DE/VS/RAW` 三组状态，再减少捕获深度；该策略不改变视频数据路径和协议验证。
