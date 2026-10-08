# 原始 VS / 缩放完成帧率诊断产物

2026-10-08，全流程编译和仿真已通过，尚未烧录或实板测量。

配套烧录 `raw_resize.bit` 与下载 `soc_video_app.elf`；BIN 为 4054 字节，加载地址 0x1000。bitstream 包含 CPU 初始化前的独立 720p 彩条。不能用旧 bitstream 配新固件，否则新增 APB 寄存器不存在。

启动并运行至少两秒后，在屏幕或 COM4/115200 UART 查看连续数个样本：

```text
RAW n RESIZE n DISP n DROP n ERR n
```

- RAW：CSI 原始 VS 下降沿，每秒帧边界数，不保证每帧像素完整。
- RESIZE：1080p → 720p 缩放模块完成的帧数/秒，位于 DDR frame_buffer 之前。
- DISP：CVO 显示帧同步数/秒。

`0xf810002c` 为 RAW_FPS、`0xf8100030` 为 RESIZE_FPS，均只读，低 16 位有效。初始不足一秒时为 0。两路事件使用 toggle CDC，同一个 100 MHz core_clk 的 1 秒窗口锁存；帧开始/完成跨窗口时可能相差 1，应观察持续差异。

RAW 与 RESIZE 都约 10：优先检查摄像头模式、帧长、时钟。RAW 约 30、RESIZE 约 10：检查 CSI/gearbox/Debayer/resize 及故障信号。两者约 30：两级帧率匹配，继续检查显示路径。

验证记录：`diagnostics_test.log`、`firmware_runtime.json`（数值为仿真模型输入）、`timing.rpt`。完整编译日志为上级目录的 `raw_resize_compile.log`。

SHA256：

```text
raw_resize.bit   180B337E29A0200219B5EF93EF56872501FE195CA72496010AF3059CC347C050
soc_video_app.elf D352E991DDB1770EDBF2EA4AB85FBFE3BA63CA8F7FFF9EC868B7A591D6B5D2E4
```
