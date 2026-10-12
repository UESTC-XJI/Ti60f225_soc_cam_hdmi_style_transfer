# 显示闪烁诊断固件

后续实板诊断见 `hardware_20261012_run1/README.md`，当前修复版见 `../release_display_deadline/README.md`。下文“未下载”指初始打包时状态；后续已用本诊断 ELF 上板采样，并用于修复版验证。

2026-10-12。仅更新固件日志，RTL 和 FPGA 资源不变。

`soc_video_app.elf` / `soc_video_app.bin` 与 `../release_ddr_opt/ti60f225_oob.bit` 配套。本轮未下载到开发板；不是闪烁修复 bitstream。原 release 不覆盖。

UART 115200/8N1，每次 DDR100M 后增加：

```text
VIDEO UF 0 DUF 0 DDROP 16 FAULT 0 CSI 0 DME 0 IERR 0 AXI 0
```

UF 是显示欠载事件累计；DUF 是本次间隔增量，DDROP 是本次间隔队列/抓帧丢弃增量。第一行增量从零软件基线计算，应忽略。完整含义、视频证据、回归结果和判读流程见 `../../../docs/DISPLAY_FLICKER_DIAGNOSTICS.md`。

`frame_*.jpg` / `osd_sequence.jpg` 是用户视频抽帧。`display_lead1.sv` / `display_lead4.sv`、`deadline_tb.sv` 和 `deadline_*.log` 是行为 DDR 停顿对照的实验副本，不是集成工程源码。相同 50us 停顿下两种提前量都产生 9600 个欠载像素，因此工程未采用四行提前方案。

固件构建和实际 RV32 DDR/VIDEO 日志、OSD/计数回绕、完整启动/恢复/异常回归全部通过；manifest 记录文件校验和。
