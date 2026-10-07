# CPU 与视频 DDR 地址划分

Sapphire BSP 的 `default.ld` 使用片上 RAM `ORIGIN=0x00001000, LENGTH=124K`，因此程序、栈和默认堆不会占用视频 DDR。为 CPU 的 DDR 读写测试另外保留 `0x0100_0000..0x0110_0000` 的 1 MiB 对齐窗口；板载 DDR 按 256 MiB 容量约束，视频缓存放在 `0x0400_0000`。

| 区域 | 起始地址 | 长度 | 说明 |
|---|---:|---:|---|
| SoC 片上程序/栈/堆 | `0x0000_1000` | 124 KiB | `software/bsp/EfxSapphireSoc/linker/default.ld` |
| CPU DDR scratch | `0x0100_0000` | 1 MiB | 固件并发读写测试 |
| 视频帧 0 | `0x0400_0000` | `0x0038_4200` | 有效载荷 `0x0038_4000`，含 `bank_switch` guard |
| 视频帧 1 | `0x0438_4200` | `0x0038_4200` | 三帧 ping-pong 第2帧 |
| 视频帧 2 | `0x0470_8400` | `0x0038_4200` | 三帧 ping-pong 第3帧 |
| 视频区结束 | `0x04A8_C600` | — | 结束地址为开区间 |

地址是字节地址；AXI 128 位控制器要求 16 字节对齐。`rtl/soc_integration/ddr_address_map_check.sv` 在仿真中断言 CPU 窗口与三帧视频区不重叠，并导出三个帧起始地址。顶层 frame buffer 的 `START_ADDR` 宏已改为 `0x0400_0000`。
