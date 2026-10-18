# CPU 与视频 DDR 地址划分

Sapphire BSP 的 `soc.h` 将 `SYSTEM_DDR_BMB` 映射到 `0x00001000`，将 4 KiB 片上 RAM 映射到 `0xF9000000`。原 `default.ld` 虽把 MEMORY 名称写为 `ram`，其 `ORIGIN=0x00001000, LENGTH=124K` 实际位于 DDR。此前将它描述为片上 RAM 有误。完整应用使用 `software/firmware/app.ld` 保留这段 DDR，范围 `[0x1000,0x20000)`；程序/BSS 必须低于 `0x1F000`，4 KiB 栈位于 `[0x1F000,0x20000)`，初始化 SP 为 `0x20000`。当前应用不使用动态堆。

为 CPU 的 DDR 读写测试另外保留 `0x0100_0000..0x0110_0000` 的 1 MiB 窗口，应用测试使用其前 64 KiB；板载 DDR 按 256 MiB 容量约束，视频缓存放在 `0x0400_0000`。程序、scratch 和视频三段完全不重叠。CPU 及 JTAG 下载访问应用区均须等待 DDR 校准完成。

| 区域 | 起始地址 | 长度 | 说明 |
|---|---:|---:|---|
| CPU DDR 程序/BSS/栈窗口 | `0x0000_1000` | 124 KiB | `software/firmware/app.ld`；链接时检查栈不重叠 |
| 片上 RAM | `0xF900_0000` | 4 KiB | 原 SoC boot RAM；OpenOCD work area 使用前 1 KiB |
| CPU DDR scratch | `0x0100_0000` | 1 MiB | 固件并发读写测试 |
| 视频帧 0 | `0x0400_0000` | `0x0038_4200` | 有效载荷 `0x0038_4000`，含 `bank_switch` guard |
| 视频帧 1 | `0x0438_4200` | `0x0038_4200` | 三帧 ping-pong 第2帧 |
| 视频帧 2 | `0x0470_8400` | `0x0038_4200` | 三帧 ping-pong 第3帧 |
| 视频区结束 | `0x04A8_C600` | — | 结束地址为开区间 |

地址是字节地址；AXI 128 位控制器要求 16 字节对齐。`rtl/soc_integration/ddr_address_map_check.sv` 在仿真中断言 CPU 窗口与三帧视频区不重叠，并导出三个帧起始地址。顶层 frame buffer 的 `START_ADDR` 宏已改为 `0x0400_0000`。
